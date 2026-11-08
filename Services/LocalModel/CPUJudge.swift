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
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let name): "The CPU copy of \(name) isn't on this iPhone." }
        }
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

    /// Pass 62 (his 7 Nov PodSkipper test: the CPU copy failed 264d9ec5 when
    /// "the model reached its 320-token answer limit"). The CPU reads free
    /// text, written indented (~50 tokens a part), so a part with several
    /// breaks needs more than the profile's 320. Room for the most parts the
    /// rules allow, and never less than 640.
    static func answerCap(_ plan: ModelPromptPlan) -> Int {
        Swift.max(640, LocalJudge.heldAnswerCap(plan))
    }

    /// Pass 62: reading in batches of this many prompt tokens. Paced (off
    /// screen) the batch is short, so each rest comes soon; at full speed
    /// (on screen, or overnight on a charger) a longer batch reads faster —
    /// 256, not more: llama.cpp's compute buffer grows with it (131 MB at 128).
    static func batchTokens(_ mode: CPUBudget.Mode) -> Int { mode == .full ? 256 : 128 }

    /// Pass 62: a part whose answer still runs out of room is read again in
    /// two halves, down to this many lines; below it, the complete parts of
    /// the answer are kept.
    static let splitMinimumLines = 12

    /// The two halves of a part read again (each with a little of the
    /// other's edge), or nil when it is too short to split.
    static func halves(_ window: Range<Int>) -> [Range<Int>]? {
        guard window.count >= splitMinimumLines else { return nil }
        let middle = window.lowerBound + window.count / 2
        let overlap = Swift.max(1, window.count / 20)
        return [window.lowerBound..<Swift.min(window.upperBound, middle + overlap),
                Swift.max(window.lowerBound, middle - overlap)..<window.upperBound]
    }

    /// Pass 62: how many first tokens two token lists share.
    static func commonPrefix<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        var n = 0
        while n < min(a.count, b.count), a[n] == b[n] { n += 1 }
        return n
    }

    func judgeReport(lines: [TimedLine], show: String, title: String, notes: String,
                     evidence: [EvidenceSpan], only ranges: [Range<Int>]?, corrections: String,
                     model chosen: CPUModel? = nil,
                     budget: @escaping @Sendable () async -> CPUBudget,
                     progress: @escaping @Sendable (Double) -> Void,
                     status: @escaping @Sendable (String) -> Void,
                     checkpoint: DetectionCheckpoint?) async throws -> JudgeReport {
        let model = chosen ?? CPUReading.selected
        #if canImport(LlamaCPU)
        guard model.isDownloaded else { throw CPUError.unavailable(model.twin.name) }
        let plan = ModelPromptPlan.plan(for: model.twin, folder: nil)
        var stats = JudgeStats(model: model.name)
        guard !lines.isEmpty else { return JudgeReport(parts: [], failedLines: [], stats: stats) }
        status("Loading \(model.name)")
        let loadStart = Date()
        stats.startedAt = loadStart
        let startMode = await budget().mode
        let engine = try LlamaEngine(path: model.location.path,
                                     options: .init(threads: CPUReading.threads, contextTokens: 8_192,
                                                    batchTokens: Self.batchTokens(startMode)))
        stats.loadSeconds = Date().timeIntervalSince(loadStart)
        let cap = Self.answerCap(plan)

        let formatted = lines.indices.map { JudgePrompt.line($0, lines[$0], spans: evidence) }
        let tokenCounts = formatted.map { engine.countTokens($0 + "\n") }
        let segments = LocalJudge.segments(ranges, lineCount: lines.count)
        let proposed = LocalJudge.windows(tokenCounts: tokenCounts, segments: segments,
                                          budget: Self.windowTokens, overlap: Self.overlapTokens)
        let identity = ModelWindowCheckpoint.identity(fields: [
            "cpu-classification-v1", model.repo, model.revision, model.file, model.chat.rawValue,
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
        // Pass 62: the rules and the episode's header, the same for every
        // part, read once; the engine puts their state back for each part.
        let header = JudgePrompt.userHeader(show: show, title: title, notes: notes, corrections: corrections)
        let headText = model.chatPrompt(system: system, header: header, rest: "").head
        let headTokens = engine.tokenize(headText, special: true)

        // Pacing: the app's CPU time between two steps, rested off at the
        // allowed share. Checked again every step, so a charger plugged in
        // overnight (or pulled) changes the pace mid-read. The engine runs on
        // its own queue (`engineQueue`), never a Swift-concurrency thread, so
        // a rest can't hold up the rest of the app.
        let pacer = Pacer(budget: budget)
        var found: [JudgedPart] = []
        var failed: [ClosedRange<Int>] = []

        /// One read of one stretch: its parts, or nil when the answer
        /// couldn't be read; whether it ran out of room.
        func ask(_ window: Range<Int>, label: String) async throws -> (parts: [JudgePrompt.RawPart]?, outOfRoom: Bool, text: String) {
            let stretch = JudgePrompt.stretch(lines: lines, window: window, spans: evidence)
                + (plan.profile.reminder.map { "\n\n" + $0 } ?? "")
            let tail = model.chatPrompt(system: system, header: header, rest: stretch).tail
            // The whole prompt tokenized as before (the same tokens, so the
            // same answer); the start it shares with the header is what the
            // engine keeps (a token merged across the join isn't shared).
            let prompt = engine.tokenize(headText + tail, special: true)
            let shared = Self.commonPrefix(prompt, headTokens)
            let started = Date()
            var line = label + ": "
            do {
                let (text, read) = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (done: CheckedContinuation<(String, LlamaEngine.Stats), Error>) in
                        Self.engineQueue.async {
                            do { done.resume(returning: try engine.answer(prompt: prompt, maxTokens: cap,
                                                                          sharedPrefix: shared, pace: pacer.step)) }
                            catch { done.resume(throwing: error) }
                        }
                    }
                } onCancel: { pacer.cancel() }
                stats.promptTokens += read.promptTokens
                stats.promptSeconds += read.promptSeconds
                stats.reusedPromptTokens += read.reusedPromptTokens
                stats.generatedTokens += read.answerTokens
                stats.generateSeconds += read.answerSeconds
                let complete = JudgePrompt.parseComplete(text)
                let parts = complete ?? (read.ranOutOfRoom ? nil : JudgePrompt.parse(text))
                if parts != nil {
                    stats.classifiedPromptTokens += read.promptTokens + read.reusedPromptTokens
                    if complete != nil { saved?.store(text, window: window) }
                } else {
                    stats.failureDetails = ModelAnswerFailure.describe(answer: text, generatedTokens: read.answerTokens, limit: cap)
                    stats.wastedPromptTokens += read.promptTokens
                }
                line += String(format: "read %d tok (%d kept) at %.0f tok/s, wrote %d at %.1f tok/s, rested %.0f s, %.0f s%@ · ",
                               read.promptTokens, read.reusedPromptTokens,
                               read.promptSeconds > 0 ? Double(read.promptTokens) / read.promptSeconds : 0,
                               read.answerTokens, read.answerSeconds > 0 ? Double(read.answerTokens) / read.answerSeconds : 0,
                               read.pausedSeconds, Date().timeIntervalSince(started), read.ranOutOfRoom ? ", out of room" : "")
                line += text.replacingOccurrences(of: "\n", with: " ").prefix(160)
                stats.partReads.append(line)
                return (parts, read.ranOutOfRoom, text)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                stats.failureDetails = error.localizedDescription
                stats.partReads.append(line + "failed: " + error.localizedDescription)
                return (nil, false, "")
            }
        }

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
            // Pass 62: an answer that runs out of room is read again in
            // halves; a part too short to split keeps what was complete.
            var queue: [(Range<Int>, String)] = [(window, "part \(index + 1)")]
            while !queue.isEmpty {
                try Task.checkCancellation()
                let (stretch, label) = queue.removeFirst()
                let answer = try await ask(stretch, label: label)
                if let parts = answer.parts {
                    let shifted = JudgePrompt.shifted(parts, window: stretch, lines: lines, maxShare: plan.maxCutShare)
                    stats.partsParsed += shifted.count
                    found += shifted.compactMap { JudgePrompt.resolve($0, lines: lines) }
                } else if answer.outOfRoom, let halves = Self.halves(stretch) {
                    stats.splitWindows += 1
                    queue.insert(contentsOf: halves.enumerated().map { ($0.element, label + ($0.offset == 0 ? "a" : "b")) }, at: 0)
                } else if answer.outOfRoom, let salvaged = JudgePrompt.parse(answer.text), !salvaged.isEmpty {
                    // Too short to split: the parts it finished are kept.
                    let shifted = JudgePrompt.shifted(salvaged, window: stretch, lines: lines, maxShare: plan.maxCutShare)
                    stats.partsParsed += shifted.count
                    found += shifted.compactMap { JudgePrompt.resolve($0, lines: lines) }
                    stats.partReads.append(label + ": out of room; kept the \(shifted.count) complete part(s) of its answer")
                } else {
                    failed.append(stretch.lowerBound...(stretch.upperBound - 1))
                }
            }
            stats.failedWindows = failed.count
            doneTokens += promptTokens[index]
            progress(Double(doneTokens) / Double(allTokens))
        }
        stats.cooledSeconds = pacer.rested
        stats.finishedAt = .now
        return JudgeReport(parts: LocalJudge.merge(found), failedLines: failed, stats: stats)
        #else
        throw CPUError.unavailable(model.twin.name)
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
