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

    /// Pass 63: and never more than the model's family is shown at a time
    /// (`ModelPromptPlan.maxWindowTokens`): the 2B and the Liquid models had
    /// been given the 4B's 3,000-token parts.
    static func windowTokens(_ plan: ModelPromptPlan) -> Int { Swift.min(windowTokens, plan.maxWindowTokens) }

    /// Pass 63: the answer's form as a grammar the engine holds every token
    /// to (`JudgePrompt.leanGrammar`): the short answer's parts, at most as
    /// many as the profile's schema allows.
    static func grammar(_ plan: ModelPromptPlan) -> String? {
        switch plan.profile {
        case .lean, .listener, .listenerEdges, .guided: JudgePrompt.leanGrammar(maxParts: 8)
        case .compact, .compactListener, .compactTight: JudgePrompt.leanGrammar(maxParts: 4)
        default: nil
        }
    }

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
        let windowTokens = Self.windowTokens(plan)
        let overlapTokens = Swift.min(Self.overlapTokens, windowTokens / 10)
        let grammar = Self.grammar(plan)
        let proposed = LocalJudge.windows(tokenCounts: tokenCounts, segments: segments,
                                          budget: windowTokens, overlap: overlapTokens)
        let identity = ModelWindowCheckpoint.identity(fields: [
            "cpu-classification-v1", model.repo, model.revision, model.file, model.chat.rawValue,
            plan.profile.system, plan.profile.schema, plan.identity, grammar == nil ? "greedy" : "greedy, held to the form",
            JudgePrompt.user(show: show, title: title, notes: notes, lines: lines,
                             window: 0..<lines.count, formatted: formatted, corrections: corrections),
            lines.map { "\($0.start):\($0.end)" }.joined(separator: ","), segments.description
        ])
        let saved = checkpoint.map { ModelWindowCheckpoint(checkpoint: $0, identity: identity) }
        let windows = saved?.plan(proposed: proposed, lineCount: lines.count,
                                  fits: { tokenCounts[$0].reduce(0, +) <= windowTokens },
                                  split: { LocalJudge.windows(tokenCounts: tokenCounts, segments: [$0],
                                                              budget: windowTokens, overlap: overlapTokens) },
                                  isReusable: { JudgePrompt.parseComplete($0) != nil }) ?? proposed
        stats.windows = windows.count
        stats.windowTokens = windowTokens
        let system = plan.profile.system
        let total = windows.count
        let promptTokens = windows.map { tokenCounts[$0].reduce(0, +) }
        // Pass 62: the rules and the episode's header, the same for every
        // part, read once; the engine puts their state back for each part.
        let header = JudgePrompt.userHeader(show: show, title: title, notes: notes, corrections: corrections)
        let headText = model.chatPrompt(system: system, header: header, rest: "").head
        let headTokens = engine.tokenize(headText, special: true)

        // Pass 63 (his 10 Nov phone: a CPU test's bar sat at 0 % for three
        // to five minutes, then jumped to 100 %): the bar and the time left
        // from the work itself (`WorkMeter`, as the MLX read) — every batch
        // of the prompt read and every token written, at this run's own
        // measured speeds. The rules and header are read once, with the
        // first part; later parts read only their own lines.
        let measured = WorkMeter.rates(for: model.engineID)
        let usualAnswer = Swift.min(cap, Int(measured?.answer ?? 80))
        var counted = false
        let meterParts: [WorkMeter.Part] = windows.indices.map { i in
            if saved?.answer(windows[i]).flatMap(JudgePrompt.parseComplete) != nil {
                return WorkMeter.Part(promptTokens: 0, expectedAnswer: 0, answerCap: cap)
            }
            let head = counted ? 0 : headTokens.count
            counted = true
            return WorkMeter.Part(promptTokens: promptTokens[i] + head + 24, expectedAnswer: usualAnswer, answerCap: cap)
        }
        let meter = WorkMeterBox(WorkMeter(parts: meterParts, readRate: measured?.read ?? 20, writeRate: measured?.write ?? 4,
                                           loadSeconds: 0, ratesKnown: false))
        let reporter = Reporter(meter: meter, parts: total, progress: progress, status: status)
        let report: @Sendable ((inout WorkMeter) -> Void) -> Void = { reporter.change($0) }
        await MainActor.run {
            LocalJudgeMonitor.shared.started()
            LocalJudgeMonitor.shared.planned(windows.count)
        }
        report { $0.modelLoaded() }

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
        func ask(_ window: Range<Int>, label: String, part: Int, readBefore: Int, paced: Bool) async throws -> (parts: [JudgePrompt.RawPart]?, outOfRoom: Bool, text: String, read: Int, written: Int) {
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
            // What the test's panel and the Activity bar say while it works:
            // the share of this part read with the speed measured so far,
            // then the tokens written.
            let clock = StepClock()
            let step: (LlamaEngine.Step) -> Void = { step in
                switch step {
                case .read(let done, let of):
                    reporter.read(part: part, before: readBefore, done: done, of: of, paced: paced, clock: clock)
                case .wrote(let tokens):
                    reporter.wrote(part: part, tokens: tokens, paced: paced, clock: clock)
                }
            }
            do {
                let (text, read) = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (done: CheckedContinuation<(String, LlamaEngine.Stats), Error>) in
                        Self.engineQueue.async {
                            do { done.resume(returning: try engine.answer(prompt: prompt, maxTokens: cap, sharedPrefix: shared,
                                                                          sampling: .init(grammar: grammar), progress: step,
                                                                          pace: pacer.step)) }
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
                return (parts, read.ranOutOfRoom, text, read.promptTokens, read.answerTokens)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                stats.failureDetails = error.localizedDescription
                stats.partReads.append(line + "failed: " + error.localizedDescription)
                return (nil, false, "", 0, 0)
            }
        }

        do {
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            if let cached = saved?.answer(window), let raw = JudgePrompt.parseComplete(cached) {
                stats.reusedWindows += 1
                found += JudgePrompt.shifted(raw, window: window, lines: lines, maxShare: plan.maxCutShare)
                    .compactMap { JudgePrompt.resolve($0, lines: lines) }
                report { $0.finished(part: index, written: 0) }
                await MainActor.run { LocalJudgeMonitor.shared.advanced(meter.snapshot.fraction, done: index + 1, wordsPerSecond: 0) }
                continue
            }
            let mode = await budget().mode
            status("Reading the sample on the CPU\(mode == .paced ? ", paced" : "") · part \(index + 1) of \(total)")
            var readInPart = 0, writtenInPart = 0
            // Pass 62: an answer that runs out of room is read again in
            // halves; a part too short to split keeps what was complete.
            var queue: [(Range<Int>, String)] = [(window, "part \(index + 1)")]
            while !queue.isEmpty {
                try Task.checkCancellation()
                let (stretch, label) = queue.removeFirst()
                let answer = try await ask(stretch, label: label, part: index, readBefore: readInPart, paced: mode == .paced)
                readInPart += answer.read
                writtenInPart += answer.written
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
            report { $0.finished(part: index, written: writtenInPart) }
            await MainActor.run { LocalJudgeMonitor.shared.advanced(meter.snapshot.fraction, done: index + 1, wordsPerSecond: 0) }
        }
        } catch {
            let message = error is CancellationError ? nil : error.localizedDescription
            await MainActor.run { LocalJudgeMonitor.shared.finished(nil, error: message) }
            throw error
        }
        stats.cooledSeconds = pacer.rested
        stats.finishedAt = .now
        // This run's speeds, for the next run's bar (weights only: the time
        // left always waits for the run's own measurement).
        if stats.promptSeconds > 0, stats.generateSeconds > 0 {
            WorkMeter.remember(model: model.engineID, read: Double(stats.promptTokens) / stats.promptSeconds,
                               write: Double(stats.generatedTokens) / stats.generateSeconds, load: stats.loadSeconds,
                               answer: Double(stats.generatedTokens) / Double(Swift.max(1, windows.count - stats.reusedWindows)))
        }
        let ending = stats
        await MainActor.run { LocalJudgeMonitor.shared.finished(ending, error: nil) }
        return JudgeReport(parts: LocalJudge.merge(found), failedLines: failed, stats: stats)
        #else
        throw CPUError.unavailable(model.twin.name)
        #endif
    }

    /// Pass 63: what a CPU read says of itself as it works — the bar and
    /// the time left from the work meter, and a line naming the part, its
    /// share read (or tokens written) and the speed measured so far. One
    /// place, so the app's read, the test of it and the screenshot run's
    /// stand-in all say the same things.
    struct Reporter: Sendable {
        let meter: WorkMeterBox
        let parts: Int
        let progress: @Sendable (Double) -> Void
        let status: @Sendable (String) -> Void

        func change(_ change: (inout WorkMeter) -> Void) {
            let now = meter.updateReading(change)
            progress(now.fraction)
            if meter.shouldPublish(now) { Task { @MainActor in LocalJudgeMonitor.shared.metered(now) } }
        }

        /// A batch of the prompt read: `done` of `of` tokens in this call,
        /// after `before` tokens of the same part read by earlier calls.
        func read(part: Int, before: Int, done: Int, of: Int, paced: Bool, clock: StepClock, now: Date = .now) {
            change { $0.reading(part: part, done: before + done, now: now) }
            guard let speed = clock.reading(done, now: now), clock.shouldSay(now: now) else { return }
            let share = of > 0 ? Int((Double(done) / Double(of) * 100).rounded()) : 100
            status(Self.readingLine(part: part, parts: parts, share: share, speed: speed, paced: paced))
        }

        func wrote(part: Int, tokens: Int, paced: Bool, clock: StepClock, now: Date = .now) {
            change { $0.writing(part: part, written: tokens, now: now) }
            guard let speed = clock.writing(tokens, now: now), clock.shouldSay(now: now) else { return }
            status(Self.writingLine(part: part, parts: parts, tokens: tokens, speed: speed, paced: paced))
        }

        static func readingLine(part: Int, parts: Int, share: Int, speed: Double, paced: Bool) -> String {
            "Reading the sample on the CPU\(paced ? ", paced" : "") · part \(part + 1) of \(parts) · \(share)%"
                + (speed > 0 ? " · \(Int(speed.rounded())) tokens a second" : "")
        }

        static func writingLine(part: Int, parts: Int, tokens: Int, speed: Double, paced: Bool) -> String {
            "Writing its answer\(paced ? ", paced" : "") · part \(part + 1) of \(parts) · \(tokens) token\(tokens == 1 ? "" : "s")"
                + (speed > 0 ? String(format: " · %.1f a second", speed) : "")
        }
    }

    /// Pass 63, screenshot and UI-test runs only (`CPUReading.isDemo`: the
    /// simulator has no CPU engine): a stand-in read that reports through
    /// the same `Reporter` and work meter as a real one — two parts, read in
    /// batches and answered token by token over about thirteen seconds — so
    /// the bar, the status lines and the time left can be seen moving.
    static func demoRead(progress: @escaping @Sendable (Double) -> Void,
                         status: @escaping @Sendable (String) -> Void) async throws {
        let prompts = [1_536, 1_024], answer = 36, batch = 128
        let meter = WorkMeterBox(WorkMeter(parts: prompts.map { WorkMeter.Part(promptTokens: $0, expectedAnswer: answer, answerCap: 96) },
                                           readRate: 20, writeRate: 4, loadSeconds: 0, ratesKnown: false))
        let reporter = Reporter(meter: meter, parts: prompts.count, progress: progress, status: status)
        await MainActor.run {
            LocalJudgeMonitor.shared.started()
            LocalJudgeMonitor.shared.planned(prompts.count)
        }
        defer { Task { @MainActor in LocalJudgeMonitor.shared.finished(nil, error: nil) } }
        reporter.change { $0.modelLoaded() }
        for (part, prompt) in prompts.enumerated() {
            let clock = StepClock()
            status("Reading the sample on the CPU · part \(part + 1) of \(prompts.count)")
            reporter.read(part: part, before: 0, done: 0, of: prompt, paced: false, clock: clock)
            var done = 0
            while done < prompt {
                try await Task.sleep(for: .milliseconds(400))
                try Task.checkCancellation()
                done = Swift.min(prompt, done + batch)
                reporter.read(part: part, before: 0, done: done, of: prompt, paced: false, clock: clock)
            }
            for token in 1...answer {
                try await Task.sleep(for: .milliseconds(70))
                try Task.checkCancellation()
                reporter.wrote(part: part, tokens: token, paced: false, clock: clock)
            }
            reporter.change { $0.finished(part: part, written: answer) }
        }
    }

    /// Pass 63: this part's reading and writing speed as it goes (tokens a
    /// second since the part's first report), and no more than two status
    /// lines a second.
    final class StepClock: @unchecked Sendable {
        private let lock = NSLock()
        private var readStart: (at: Date, tokens: Int)?
        private var writeStart: (at: Date, tokens: Int)?
        private var saidAt = Date.distantPast

        private func speed(_ start: inout (at: Date, tokens: Int)?, _ tokens: Int, now: Date) -> Double? {
            guard let begun = start else { start = (now, tokens); return 0 }
            let elapsed = now.timeIntervalSince(begun.at)
            return elapsed >= 0.5 && tokens > begun.tokens ? Double(tokens - begun.tokens) / elapsed : 0
        }

        func reading(_ tokens: Int, now: Date = .now) -> Double? { lock.withLock { speed(&readStart, tokens, now: now) } }
        func writing(_ tokens: Int, now: Date = .now) -> Double? { lock.withLock { speed(&writeStart, tokens, now: now) } }

        func shouldSay(now: Date = .now) -> Bool {
            lock.withLock {
                guard now.timeIntervalSince(saidAt) >= 0.5 else { return false }
                saidAt = now
                return true
            }
        }
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
