import Foundation
#if canImport(LlamaCPU)
import LlamaCPU
#endif

/// Pass 58: Qwen3.5 4B read on the CPU (llama.cpp), for when PodSkipper isn't
/// on screen and the GPU copy can't run. Same prompts, same windows, same
/// answer reading and the same saved-answer checkpoint as `LocalJudge`; what
/// differs is the engine, and that every step is paced (`CPUBudget`) unless
/// the overnight task on a charger allows full speed. See `CPUReading`.
actor CPUJudge {
    static let shared = CPUJudge()

    enum CPUError: LocalizedError {
        case unavailable
        var errorDescription: String? { "The CPU copy of \(CPUReading.twin.name) isn't on this iPhone." }
    }

    /// The prompt in Qwen's chat format, thinking off (an empty think block,
    /// as Qwen3.5's own template writes it with `enable_thinking` false).
    static func chatPrompt(system: String, user: String) -> String {
        "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

    /// Part size: smaller than the GPU copy's, since every token costs CPU
    /// time and a smaller part saves its answer sooner if iOS ends the app.
    static let windowTokens = 3_000
    static let overlapTokens = 300

    func judgeReport(lines: [TimedLine], show: String, title: String, notes: String,
                     evidence: [EvidenceSpan], only ranges: [Range<Int>]?, corrections: String,
                     budget: @escaping @Sendable () async -> CPUBudget,
                     progress: @escaping @Sendable (Double) -> Void,
                     status: @escaping @Sendable (String) -> Void,
                     checkpoint: DetectionCheckpoint?) async throws -> JudgeReport {
        #if canImport(LlamaCPU)
        guard CPUReading.isDownloaded else { throw CPUError.unavailable }
        let plan = ModelPromptPlan.plan(for: CPUReading.twin, folder: nil)
        var stats = JudgeStats(model: CPUReading.displayName)
        guard !lines.isEmpty else { return JudgeReport(parts: [], failedLines: [], stats: stats) }
        status("Loading \(CPUReading.displayName)")
        let loadStart = Date()
        stats.startedAt = loadStart
        let engine = try LlamaEngine(path: CPUReading.location.path,
                                     options: .init(threads: CPUReading.threads, contextTokens: 6_144, batchTokens: 128))
        stats.loadSeconds = Date().timeIntervalSince(loadStart)

        let formatted = lines.indices.map { JudgePrompt.line($0, lines[$0], spans: evidence) }
        let tokenCounts = formatted.map { engine.countTokens($0 + "\n") }
        let segments = LocalJudge.segments(ranges, lineCount: lines.count)
        let proposed = LocalJudge.windows(tokenCounts: tokenCounts, segments: segments,
                                          budget: Self.windowTokens, overlap: Self.overlapTokens)
        let identity = ModelWindowCheckpoint.identity(fields: [
            "cpu-classification-v1", CPUReading.repo, CPUReading.revision, CPUReading.file,
            plan.profile.system, plan.profile.schema, plan.identity, "greedy",
            JudgePrompt.user(show: show, title: title, notes: notes, lines: lines,
                             window: 0..<lines.count, formatted: formatted, corrections: corrections),
            lines.map { "\($0.start):\($0.end)" }.joined(separator: ","), segments.description
        ])
        let saved = checkpoint.map { ModelWindowCheckpoint(checkpoint: $0, identity: identity) }
        let windows = saved?.plan(proposed: proposed, lineCount: lines.count,
                                  fits: { tokenCounts[$0].reduce(0, +) <= Self.windowTokens },
                                  split: { LocalJudge.windows(tokenCounts: tokenCounts, segments: [$0],
                                                              budget: Self.windowTokens, overlap: Self.overlapTokens) },
                                  isReusable: { JudgePrompt.parseComplete($0) != nil }) ?? proposed
        stats.windows = windows.count
        stats.windowTokens = Self.windowTokens
        let system = plan.profile.system
        let total = windows.count
        let promptTokens = windows.map { tokenCounts[$0].reduce(0, +) }
        let allTokens = max(1, promptTokens.reduce(0, +))
        var doneTokens = 0

        // Pacing: the app's CPU time between two steps, rested off at the
        // allowed share. Checked again every step, so a charger plugged in
        // overnight (or pulled) changes the pace mid-read. The engine runs on
        // its own queue (`engineQueue`), never a Swift-concurrency thread, so
        // a rest can't hold up the rest of the app.
        let pacer = Pacer(budget: budget)
        var found: [JudgedPart] = []
        var failed: [ClosedRange<Int>] = []
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            if let cached = saved?.answer(window), let raw = JudgePrompt.parseComplete(cached) {
                stats.reusedWindows += 1
                found += JudgePrompt.shifted(raw, window: window, lines: lines, maxShare: plan.maxCutShare)
                    .compactMap { JudgePrompt.resolve($0, lines: lines) }
                doneTokens += promptTokens[index]
                progress(Double(doneTokens) / Double(allTokens))
                continue
            }
            let mode = await budget().mode
            status("Reading on the CPU\(mode == .paced ? ", paced" : "") · part \(index + 1) of \(total)")
            let user = JudgePrompt.userLocal(show: show, title: title, notes: notes, lines: lines, window: window,
                                             spans: evidence, corrections: corrections, reminder: plan.profile.reminder)
            let prompt = engine.tokenize(Self.chatPrompt(system: system, user: user), special: true)
            let started = Date()
            var line = "part \(index + 1): "
            do {
                let cap = plan.answerCap
                let (text, read) = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (done: CheckedContinuation<(String, LlamaEngine.Stats), Error>) in
                        Self.engineQueue.async {
                            do { done.resume(returning: try engine.answer(prompt: prompt, maxTokens: cap, pace: pacer.step)) }
                            catch { done.resume(throwing: error) }
                        }
                    }
                } onCancel: { pacer.cancel() }
                stats.promptTokens += read.promptTokens
                stats.promptSeconds += read.promptSeconds
                stats.reusedPromptTokens += read.reusedPromptTokens
                stats.generatedTokens += read.answerTokens
                stats.generateSeconds += read.answerSeconds
                let parts = JudgePrompt.parseComplete(text) ?? (read.ranOutOfRoom ? nil : JudgePrompt.parse(text))
                if let parts {
                    let shifted = JudgePrompt.shifted(parts, window: window, lines: lines, maxShare: plan.maxCutShare)
                    stats.partsParsed += shifted.count
                    stats.classifiedPromptTokens += read.promptTokens + read.reusedPromptTokens
                    found += shifted.compactMap { JudgePrompt.resolve($0, lines: lines) }
                    if JudgePrompt.parseComplete(text) != nil { saved?.store(text, window: window) }
                } else {
                    failed.append(window.lowerBound...(window.upperBound - 1))
                    stats.failureDetails = ModelAnswerFailure.describe(answer: text, generatedTokens: read.answerTokens,
                                                                        limit: plan.answerCap)
                    stats.wastedPromptTokens += read.promptTokens
                }
                line += String(format: "read %d tok (%d kept) at %.0f tok/s, wrote %d at %.1f tok/s, rested %.0f s, %.0f s · ",
                               read.promptTokens, read.reusedPromptTokens,
                               read.promptSeconds > 0 ? Double(read.promptTokens) / read.promptSeconds : 0,
                               read.answerTokens, read.answerSeconds > 0 ? Double(read.answerTokens) / read.answerSeconds : 0,
                               read.pausedSeconds, Date().timeIntervalSince(started))
                line += text.replacingOccurrences(of: "\n", with: " ").prefix(160)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed.append(window.lowerBound...(window.upperBound - 1))
                stats.failureDetails = error.localizedDescription
                line += "failed: " + error.localizedDescription
            }
            stats.partReads.append(line)
            stats.failedWindows = failed.count
            doneTokens += promptTokens[index]
            progress(Double(doneTokens) / Double(allTokens))
        }
        stats.cooledSeconds = pacer.rested
        stats.finishedAt = .now
        return JudgeReport(parts: LocalJudge.merge(found), failedLines: failed, stats: stats)
        #else
        throw CPUError.unavailable
        #endif
    }

    #if canImport(LlamaCPU)
    /// Where the engine reads: one at a time, off the Swift-concurrency pool.
    private static let engineQueue = DispatchQueue(label: "PodSkipper.CPUJudge.engine", qos: .utility)

    /// Rests between steps (see `CPUBudget`) and carries cancellation into
    /// the engine's queue, where there is no current task to ask.
    private final class Pacer: @unchecked Sendable {
        private let lock = NSLock()
        private let budget: @Sendable () async -> CPUBudget
        private var lastWall = Date()
        private var lastCPU = CPUBudget.processCPUSeconds()
        private var cancelled = false
        private(set) var rested = 0.0

        init(budget: @escaping @Sendable () async -> CPUBudget) { self.budget = budget }

        func cancel() { lock.withLock { cancelled = true } }
        private var isCancelled: Bool { lock.withLock { cancelled } }

        func step(_ phase: LlamaEngine.Phase) throws {
            if isCancelled { throw CancellationError() }
            let rest = CPUJudge.blockingBudget(budget).rest(cpu: CPUBudget.processCPUSeconds() - lastCPU,
                                                            wall: Date().timeIntervalSince(lastWall))
            var left = rest
            while left > 0 {
                if isCancelled { throw CancellationError() }
                let slice = min(left, 0.5)
                Thread.sleep(forTimeInterval: slice)
                left -= slice
            }
            lock.withLock { rested += rest }
            lastWall = Date()
            lastCPU = CPUBudget.processCPUSeconds()
        }
    }
    #endif

    /// The budget, read from the main actor from the engine's queue (the step
    /// is synchronous C code).
    private static func blockingBudget(_ budget: @escaping @Sendable () async -> CPUBudget) -> CPUBudget {
        let box = BudgetBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached { box.value = await budget(); done.signal() }
        done.wait()
        return box.value
    }

    private final class BudgetBox: @unchecked Sendable { var value = CPUBudget(mode: .paced) }
}
