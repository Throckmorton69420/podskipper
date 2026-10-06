import Foundation
import MLX
import MLXNN
import MLXGuidedGeneration
import MLXLLM
import MLXLMCommon
import Observation
import UIKit
import os

/// Numbers from one `judge` run, for the screen and Diagnostics.
struct JudgeStats: Sendable, Equatable {
    var model: String
    var windows = 0
    var failedWindows = 0
    var reusedWindows = 0
    /// Tokens read (prompts) and the time spent reading them.
    var promptTokens = 0
    var promptSeconds = 0.0
    /// Tokens written (answers) and the time spent writing them.
    var generatedTokens = 0
    var generateSeconds = 0.0
    var loadSeconds = 0.0
    /// Always 0 since pass 27: the model never runs on the CPU (kept so old
    /// screens and exports still read).
    var cpuWindows = 0
    /// Tokens per window this run used, and the free memory iOS reported
    /// before loading.
    var windowTokens = 0
    var availableBeforeLoad = 0
    /// The start of the last answer, as written (pass 27b: his self-test
    /// wrote 745 tokens and "found nothing"; this says what it wrote).
    var answerSample = ""
    var failureDetails: String?
    /// Parts the answers named before they were matched to lines; more than
    /// were found means the model's quoted words didn't match the lines.
    var partsParsed = 0
    /// Whether answers were held to the JSON schema while being written.
    var constrained = false
    var peakMemoryBytes = 0
    var finishedAt = Date.distantPast
    /// Pass 30: prompt tokens kept from the part before (the shared rules
    /// and show notes) instead of read again.
    var reusedPromptTokens = 0

    var readTokensPerSecond: Double { promptSeconds > 0 ? Double(promptTokens) / promptSeconds : 0 }
    var writeTokensPerSecond: Double { generateSeconds > 0 ? Double(generatedTokens) / generateSeconds : 0 }
}

/// Everything `judge` found, including what it couldn't read.
struct JudgeReport: Sendable {
    var parts: [JudgedPart]
    /// Line ranges of windows whose answer couldn't be read even after a
    /// retry. Nothing is invented for them.
    var failedLines: [ClosedRange<Int>]
    var stats: JudgeStats
}

/// The latest run, watched by the model screen and readable by Diagnostics.
@MainActor
@Observable
final class LocalJudgeMonitor {
    static let shared = LocalJudgeMonitor()
    private(set) var isRunning = false
    /// Fraction of windows done in the current run.
    private(set) var progress = 0.0
    private(set) var lastStats: JudgeStats?
    private(set) var lastError: String?
    /// For "part 3 of 7 (82 words/s)" on the Activity screen: windows read
    /// so far, how many there are, and transcript words read a second.
    private(set) var windowsDone = 0
    private(set) var windowsTotal = 0
    private(set) var wordsPerSecond = 0.0

    /// Pass 30: when the first part began and the latest one ended, for the
    /// time left on the Activity screen.
    private(set) var firstPartStartedAt: Date?
    private(set) var lastPartEndedAt: Date?
    /// Pass 31: seconds left from the work meter (tokens still to read and
    /// write at this model's measured speeds), and when it was said.
    private(set) var secondsLeft: Double?
    private(set) var secondsLeftAt: Date?

    func started() {
        isRunning = true; progress = 0; lastError = nil
        windowsDone = 0; windowsTotal = 0; wordsPerSecond = 0
        firstPartStartedAt = nil; lastPartEndedAt = nil
        secondsLeft = nil; secondsLeftAt = nil
    }
    /// Seconds left and when, while a metered read runs.
    var meterReading: (Double, Date)? {
        guard isRunning, let secondsLeft, let secondsLeftAt else { return nil }
        return (secondsLeft, secondsLeftAt)
    }
    func metered(_ fraction: Double, secondsLeft left: Double) {
        progress = max(progress, fraction)
        secondsLeft = left
        secondsLeftAt = .now
    }
    func planned(_ windows: Int) {
        windowsTotal = windows
        firstPartStartedAt = .now
    }
    func advanced(_ value: Double, done: Int, wordsPerSecond speed: Double) {
        progress = value
        windowsDone = done
        wordsPerSecond = speed
        lastPartEndedAt = .now
    }
    func finished(_ stats: JudgeStats?, error: String?) {
        isRunning = false
        if let stats { lastStats = stats }
        lastError = error
    }
}

/// Finds ads with the downloaded Bonsai model, inside the app.
///
/// The transcript is read in windows (about 12,000 tokens overlapping by
/// 1,000 for the 8B models, 6,000 and 800 for the 27B), one prompt each: an
/// 8 GB phone can't hold a whole episode's context. Parts found twice in an
/// overlap are merged. The model is loaded for one job and let go straight
/// after.
///
/// Background: iOS 27's continued-processing task uses MLX's GPU path when the
/// signed build carries Background GPU Access. The background window is kept
/// conservative to leave room for the model, cache, and the rest of the app.
/// Signed without it (his 1 Oct developer certificate), iOS refuses the GPU
/// off screen and the CPU is far too slow (pass 27: 90 s of CPU without
/// finishing one window, then iOS's CPU-limit kill), so leaving the app ends
/// the read with `.needsForeground`; the reader's cuts stand and the episode
/// is read again on screen. See `SignedEntitlements.backgroundGPU`.
///
/// Memory: no refusal up front (iOS reported 3.2 GB free and the refusal
/// stopped every job). The window is the largest that fits, never smaller
/// than the smallest step, and a breadcrumb written before loading tells
/// the next launch that iOS stopped the app mid-read, so the next try uses
/// a smaller window.
actor LocalJudge {
    static let shared = LocalJudge()

    // Window sizes are per model (`LocalModelSpec.windowTokens8B` etc.):
    // tokens per window, and how many the next window repeats so a part cut
    // by a window edge is still seen whole once.

    /// Lines read either side of each range in the "check the suspicious
    /// stretches" mode.
    /// Pass 31: 15, was 40. The flagged stretches already carry 90 s either
    /// side; forty more lines (two to three minutes) put most of an episode
    /// back in (his 27 exported episodes: 32 % of the transcript at 40
    /// lines, 25 % at 15).
    static let contextLines = 15
    /// The answer is a short JSON list; this stops a runaway one.
    static let maxAnswerTokens = 1_536
    /// The attention cache in 8 bits: half the memory of full precision,
    /// which is what lets an 8B model read a 12,000-token window on an 8 GB
    /// phone, for a loss too small to change a JSON answer.
    static let kvBits = 8
    /// Low: the job loads, runs and lets go, so there is nothing worth
    /// caching between windows, and the memory is better left free.
    static let gpuCacheLimit = 64 * 1024 * 1024

    /// One job at a time. The actor alone doesn't ensure it: a job waits
    /// inside, and a second one would load a second model beside it.
    private var busy = false
    // Only accessed on this actor, while the parent run waits for its joined
    // inference task. Avoid transferring MLX's non-Sendable context to a closure.
    private var activeInferenceContext: ModelContext?

    enum JudgeError: LocalizedError {
        case notDownloaded
        case notEnoughMemory(available: Int, needed: Int)
        case needsForeground
        case loadFailed(String)
        /// Some windows couldn't be read. `found` is everything the others gave.
        case someWindowsFailed(found: [JudgedPart], failedLines: [ClosedRange<Int>])

        var errorDescription: String? {
            switch self {
            case .notDownloaded:
                return "The on-device ad model isn't downloaded yet. Download it in Settings → On-device ad model, then try again."
            case .notEnoughMemory(let available, let needed):
                return "Not enough free memory for the ad model: \(Self.gb(available)) free, it needs about \(Self.gb(needed)). Closing other apps may help, or choose a smaller model."
            case .needsForeground:
                return "The ad model needs PodSkipper open on screen."
            case .loadFailed(let why):
                return "Couldn't load the ad model: \(why)"
            case .someWindowsFailed(_, let failed):
                return "The ad model couldn't read \(failed.count) part\(failed.count == 1 ? "" : "s") of the episode."
            }
        }

        private static func gb(_ bytes: Int) -> String {
            String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        }
    }

    /// Finds the commercial and structural parts of an episode.
    ///
    /// - Parameters:
    ///   - lines: the episode's transcript lines; parts refer to their indexes.
    ///   - evidence: audio evidence, shown to the model as «I» and «R».
    ///   - ranges: read only these line ranges, plus 40 lines either side.
    ///     nil reads everything.
    ///   - corrections: the listener's past verdicts on this show, as a
    ///     block before the transcript ("" for none).
    ///   - progress: fraction of windows done.
    /// - Throws: `JudgeError.someWindowsFailed` carrying what was found when
    ///   a window couldn't be read; the other errors when nothing could run.
    func judge(lines: [TimedLine], show: String, title: String, notes: String,
               evidence: [EvidenceSpan], only ranges: [Range<Int>]?, corrections: String = "",
               progress: @escaping @Sendable (Double) -> Void) async throws -> [JudgedPart] {
        let report = try await judgeReport(lines: lines, show: show, title: title, notes: notes,
                                           evidence: evidence, only: ranges, corrections: corrections,
                                           progress: progress)
        if !report.failedLines.isEmpty {
            throw JudgeError.someWindowsFailed(found: report.parts, failedLines: report.failedLines)
        }
        return report.parts
    }

    func judgeReport(lines: [TimedLine], show: String, title: String, notes: String,
                     evidence: [EvidenceSpan], only ranges: [Range<Int>]?, corrections: String = "",
                     model: LocalModelSpec? = nil, progress: @escaping @Sendable (Double) -> Void,
                     status: @escaping @Sendable (String) -> Void = { _ in },
                     requireCompleteAnswer: Bool = false, checkpoint: DetectionCheckpoint? = nil) async throws -> JudgeReport {
        // A job still winding down (cancelled, finishing its window) first.
        while busy { try await Task.sleep(for: .milliseconds(250)) }
        busy = true
        defer { busy = false }

        let (spec, folder) = await MainActor.run { () -> (LocalModelSpec, URL?) in
            let spec = model ?? ModelStore.shared.selected
            let folder = ModelStore.shared.isDownloaded(spec) ? ModelStore.folder(for: spec) : nil
            return (spec, folder)
        }
        // Pass 31: how this model is asked, from its architecture and template.
        let plan = ModelPromptPlan.plan(for: spec, folder: folder)
        try await Self.waitUntilCool(status: status)
        status("Loading " + spec.name)
        var stats = JudgeStats(model: spec.name)
        guard !lines.isEmpty else { return JudgeReport(parts: [], failedLines: [], stats: stats) }
        guard let folder else { throw JudgeError.notDownloaded }

        // Off screen only with Background GPU Access (see the type's note).
        if await Self.mustWaitForScreen() { throw JudgeError.needsForeground }

        // No refusal up front (pass 27, his call: let iOS manage memory).
        // The window is the largest step that fits what iOS says is free —
        // weights + 8-bit attention cache + working room — and never smaller
        // than the smallest step; if iOS stopped the app during an earlier
        // read, no larger than the step below that one.
        let available = os_proc_available_memory()
        if let killed = Breadcrumb.staleFromEarlierLaunch() {
            let smaller = Breadcrumb.lowerCap(model: killed.model, below: killed.window)
            await MainActor.run {
                let name = LocalModelSpec.named(killed.model).name
                BackgroundLog.shared.note("Last time iOS closed PodSkipper while \(name) was reading (\(killed.window)-token parts). From now on it reads parts of at most \(smaller) tokens.")
                ModelBench.shared.recordClosed(model: killed.model)
            }
        }
        let steps = LocalModelSpec.windowSteps.filter { $0 <= spec.windowTokens }
        let smallest = steps.last ?? spec.windowTokens
        let fitted = spec.windowThatFits(available: Int64(available)) ?? smallest
        let foregroundWindow = Swift.min(fitted, Breadcrumb.cap(model: spec.id) ?? spec.windowTokens, plan.maxWindowTokens)
        // Continued-processing uses a smaller prefill window for memory stability
        // instead of discarding a user-started job when the screen locks.
        let window = await Self.inBackground()
            ? Swift.min(6_000, foregroundWindow)
            : foregroundWindow
        stats.windowTokens = window
        stats.availableBeforeLoad = available

        await MainActor.run { LocalJudgeMonitor.shared.started() }
        Memory.cacheLimit = Self.gpuCacheLimit
        // Written before loading, removed when the read ends either way: one
        // still there at the next launch means iOS stopped the app mid-read.
        Breadcrumb.write(model: spec.id, window: window)
        // The model lives only inside `run`; once it returns, its memory can go.
        defer { Memory.clearCache(); Breadcrumb.clear() }
        do {
            let report = try await run(lines: lines, show: show, title: title, notes: notes,
                                       evidence: evidence, ranges: ranges, corrections: corrections, folder: folder,
                                       spec: spec, plan: plan, window: window, stats: &stats, progress: progress, status: status, requireCompleteAnswer: requireCompleteAnswer, checkpoint: checkpoint)
            let final = report.stats
            await MainActor.run { LocalJudgeMonitor.shared.finished(final, error: final.failureDetails) }
            return report
        } catch {
            let message = error.localizedDescription
            let partial = stats
            await MainActor.run { LocalJudgeMonitor.shared.finished(partial.windows > 0 ? partial : nil, error: message) }
            throw error
        }
    }

    private func run(lines: [TimedLine], show: String, title: String, notes: String,
                     evidence: [EvidenceSpan], ranges: [Range<Int>]?, corrections: String, folder: URL,
                     spec: LocalModelSpec, plan: ModelPromptPlan, window: Int, stats: inout JudgeStats,
                     progress: @escaping @Sendable (Double) -> Void,
                     status: @escaping @Sendable (String) -> Void,
                     requireCompleteAnswer: Bool, checkpoint: DetectionCheckpoint?) async throws -> JudgeReport {
        Memory.peakMemory = 0

        // Foreground and iOS 27 continued-processing both use the GPU. The
        // latter is legal only in a signed build carrying Background GPU Access.
        // Keep the background window conservative to control jetsam risk.
        let device = Device.gpu
        let loadStart = Date.now
        LocalModelSpec.patchConfig(of: spec, in: folder)
        let context: ModelContext
        do {
            context = try await withError {
                try await Device.withDefaultDevice(device) {
                    try await LLMModelFactory.shared.load(from: folder, using: LocalTokenizerLoader())
                }
            }
        } catch {
            if await Self.mustWaitForScreen() { throw JudgeError.needsForeground }
            throw JudgeError.loadFailed(error.localizedDescription)
        }
        if await Self.mustWaitForScreen() { throw JudgeError.needsForeground }
        stats.loadSeconds = Date.now.timeIntervalSince(loadStart)

        // Every line formatted once; windows are planned in the model's own tokens.
        let formatted = lines.indices.map { JudgePrompt.line($0, lines[$0], spans: evidence) }
        let tokenCounts = formatted.map { context.tokenizer.encode(text: $0 + "\n", addSpecialTokens: false).count }
        let proposedWindows = Self.windows(tokenCounts: tokenCounts,
                                   segments: Self.segments(ranges, lineCount: lines.count),
                                   budget: window, overlap: Swift.min(spec.overlapTokens, window / 8))
        let identity = ModelWindowCheckpoint.identity(fields: [
            "mlx-classification-v2-local", spec.id, spec.revision,
            ProcessInfo.processInfo.operatingSystemVersionString,
            plan.profile.system, plan.profile.schema, plan.identity,
            "kv8-prefill256-greedy-guided-or-temperature0.2-free",
            JudgePrompt.user(show: show, title: title, notes: notes, lines: lines,
                             window: 0..<lines.count, formatted: formatted, corrections: corrections),
            lines.map { "\($0.start):\($0.end)" }.joined(separator: ","),
            Self.segments(ranges, lineCount: lines.count).description
        ])
        let saved = checkpoint.map { ModelWindowCheckpoint(checkpoint: $0, identity: identity) }
        let windows = saved?.plan(proposed: proposedWindows, lineCount: lines.count,
            fits: { tokenCounts[$0].reduce(0, +) <= window },
            split: { Self.windows(tokenCounts: tokenCounts, segments: [$0], budget: window,
                                  overlap: Swift.min(spec.overlapTokens, window / 8)) },
            isReusable: { JudgePrompt.parseComplete($0) != nil }) ?? proposedWindows
        stats.windows = windows.count
        let planned = windows.count
        await MainActor.run { LocalJudgeMonitor.shared.planned(planned) }
        // Transcript words read a second, for the Activity screen.
        let wordCounts = lines.map { $0.text.split(whereSeparator: \.isWhitespace).count }
        var wordsRead = 0
        let readingStarted = Date.now

        // The answer held to the schema while it is written, when the grammar
        // engine takes it; otherwise free text read leniently.
        let grammar = Self.grammarTokenizer(for: context)
        stats.constrained = grammar != nil

        // Pass 31: the bar and the time left count the real work — every
        // part's prompt tokens (known now) at this model's measured reading
        // speed, and its answer (capped) at its writing speed. See WorkMeter.
        let system = plan.profile.system
        // Pass 31: each stretch numbered from 0, with its place in the
        // episode and the sponsors the notes name (`JudgePrompt.userLocal`).
        let users = windows.map { JudgePrompt.userLocal(show: show, title: title, notes: notes, lines: lines,
                                                         window: $0, spans: evidence, corrections: corrections) }
        let systemTokens = context.tokenizer.encode(text: system, addSpecialTokens: false).count
        let measured = WorkMeter.rates(for: spec.id)
        let expectedAnswer = Swift.min(plan.answerCap, Int(measured?.answer ?? 60))
        let meter = WorkMeterBox(WorkMeter(
            parts: users.enumerated().map { i, user in
                WorkMeter.Part(promptTokens: saved?.answer(windows[i]) != nil ? 0
                                : systemTokens + context.tokenizer.encode(text: user, addSpecialTokens: false).count + 24,
                               expectedAnswer: saved?.answer(windows[i]) != nil ? 0 : expectedAnswer,
                               answerCap: plan.answerCap)
            },
            readRate: measured?.read ?? 150, writeRate: measured?.write ?? 14, loadSeconds: 0))
        let report: @Sendable ((inout WorkMeter) -> Void) -> Void = { change in
            let now = meter.update(change)
            progress(now.fraction)
            Task { @MainActor in LocalJudgeMonitor.shared.metered(now.fraction, secondsLeft: now.secondsLeft) }
        }
        report { $0.modelLoaded() }

        var found: [JudgedPart] = []
        var failed: [ClosedRange<Int>] = []
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            let user = users[index]
            var parts = saved?.answer(window).flatMap(JudgePrompt.parseComplete).map { JudgePrompt.shifted($0, window: window) }
            let reused = parts != nil
            if reused {
                stats.reusedWindows += 1
                status("Reusing saved classification · part \(index + 1) of \(windows.count)")
            }
            var failure: String?
            // One retry, and the retry writes freely: a constrained answer is
            // greedy, so asking the same way again would give the same text.
            let total = windows.count
            let events = AnswerEvents(
                read: { done, _ in report { $0.reading(part: index, done: done) } },
                wrote: { written in
                    report { $0.writing(part: index, written: written) }
                    if written == 1 || written % 16 == 0 {
                        let expected = Swift.max(expectedAnswer, written + 8)
                        status("Writing its answer · \(written) of about \(Swift.min(plan.answerCap, expected)) tokens · part \(index + 1) of \(total)")
                    }
                })
            for attempt in 0..<2 where parts == nil {
                if await Self.mustWaitForScreen() { throw JudgeError.needsForeground }
                try await Self.waitUntilCool(status: status)
                if attempt > 0 { report { $0.retrying(part: index) } }
                do {
                    status(attempt == 0 ? "Reading · part \(index + 1) of \(total)" : "Asking again without the answer format · part \(index + 1) of \(total)")
                    let answer = try await ask(context: context, plan: plan, system: system, user: user,
                                               grammar: attempt == 0 ? grammar : nil, events: events)
                    stats.promptTokens += answer.promptTokens
                    stats.promptSeconds += answer.promptSeconds
                    stats.generatedTokens += answer.generatedTokens
                    stats.generateSeconds += answer.generateSeconds
                    stats.answerSample = String(answer.text.prefix(600))
                    parts = (requireCompleteAnswer ? JudgePrompt.parseComplete(answer.text) : JudgePrompt.parse(answer.text))
                        .map { JudgePrompt.shifted($0, window: window) }
                    failure = parts == nil ? ModelAnswerFailure.describe(answer: answer.text, generatedTokens: answer.generatedTokens, limit: plan.answerCap) : nil
                    stats.partsParsed += parts?.count ?? 0
                    try Task.checkCancellation()
                    if JudgePrompt.parseComplete(answer.text) != nil, let saved,
                       !saved.store(answer.text, window: window) {
                        status(saved.checkpoint.storageError ?? "Could not save this classification for resuming.")
                    }
                    let written = answer.generatedTokens
                    report { $0.finished(part: index, written: written) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The GPU refused because the app just left the screen
                    // (no Background GPU Access): read again on screen.
                    if await Self.mustWaitForScreen() { throw JudgeError.needsForeground }
                    // Retry once. If both attempts fail, the window is recorded
                    // as failed and the reader remains available as fallback.
                    parts = nil
                    failure = "Inference failed: " + error.localizedDescription
                }
            }
            if let parts {
                found += parts.compactMap { JudgePrompt.resolve($0, lines: lines) }
            } else {
                failed.append(window.lowerBound...(window.upperBound - 1))
                stats.failureDetails = failure
                await BackgroundLog.shared.note("MLX \(spec.name) window failed: \(failure ?? "No readable classification")")
            }
            stats.failedWindows = failed.count
            report { $0.finished(part: index, written: 0) }
            let done = meter.snapshot.fraction
            if !reused { wordsRead += wordCounts[window].reduce(0, +) }
            let elapsed = Date.now.timeIntervalSince(readingStarted)
            let speed = elapsed > 0 ? Double(wordsRead) / elapsed : 0
            let windowsDone = index + 1
            await MainActor.run { LocalJudgeMonitor.shared.advanced(done, done: windowsDone, wordsPerSecond: speed) }
        }

        // What this model actually does on this phone, for the next bar.
        let answered = Swift.max(1, windows.count - stats.reusedWindows)
        WorkMeter.remember(model: spec.id, read: stats.readTokensPerSecond, write: stats.writeTokensPerSecond,
                           load: stats.loadSeconds, answer: Double(stats.generatedTokens) / Double(answered))
        stats.peakMemoryBytes = Memory.peakMemory
        stats.finishedAt = .now
        return JudgeReport(parts: Self.merge(found), failedLines: failed, stats: stats)
    }

    /// What one prompt cost, and the answer.
    private struct Answer: Sendable {
        var text = ""
        var promptTokens = 0
        var promptSeconds = 0.0
        var generatedTokens = 0
        var generateSeconds = 0.0
    }

    /// Pass 31: what the model has read and written so far, for the meter.
    struct AnswerEvents: Sendable {
        var read: @Sendable (_ done: Int, _ total: Int) -> Void
        var wrote: @Sendable (_ tokens: Int) -> Void
    }

    /// One prompt, one answer.
    private func ask(context: ModelContext, plan: ModelPromptPlan, system: String, user: String,
                     grammar: GrammarTokenizer?, events: AnswerEvents) async throws -> Answer {
        guard !SignedEntitlements.backgroundGPU else {
            return try await generateAnswer(context: context, plan: plan, system: system, user: user,
                                            grammar: grammar, events: events)
        }
        // Cancel during prefill too, before iOS takes the scene's background
        // snapshot. Previously foreground checks only ran between windows.
        let resignations = NotificationInterruption(UIApplication.willResignActiveNotification)
        defer { resignations.finish() }
        if await Self.mustWaitForScreen() { throw JudgeError.needsForeground }
        activeInferenceContext = context
        defer { activeInferenceContext = nil }
        return try await InterruptibleOperation.run {
            try await self.generateActiveAnswer(plan: plan, system: system, user: user,
                                                 grammar: grammar, events: events)
        } monitor: {
            for await _ in resignations.events {
                try Task.checkCancellation()
                throw JudgeError.needsForeground
            }
            throw CancellationError()
        }
    }

    private func generateActiveAnswer(plan: ModelPromptPlan, system: String, user: String, grammar: GrammarTokenizer?,
                                      events: AnswerEvents) async throws -> Answer {
        guard let context = activeInferenceContext else { throw CancellationError() }
        return try await generateAnswer(context: context, plan: plan, system: system, user: user,
                                        grammar: grammar, events: events)
    }

    /// Paces the read by heat (see `ThermalPacing`): a short rest between
    /// parts when warm, a bounded pause when critical. Never an open-ended
    /// wait that holds the model and the line (his 5 Oct report).
    private static func waitUntilCool(status: @escaping @Sendable (String) -> Void) async throws {
        if await mustWaitForScreen() { throw JudgeError.needsForeground }
        if ThermalPacing.state == .serious || ThermalPacing.state == .critical { Memory.clearCache() }
        try await ThermalPacing.beforePart(status: status)
        if await mustWaitForScreen() { throw JudgeError.needsForeground }
    }

    /// Pass 31: a template that always opens a reasoning block (LFM2.5
    /// 2.6B) has it closed before the model writes: on his phone it spent
    /// every test's 1,536 tokens "analysing" and never answered.
    private static func closingOpenThinkBlock(_ input: LMInput, plan: ModelPromptPlan,
                                              tokenizer: any Tokenizer) -> LMInput {
        guard plan.thinking == .closeOpenBlock else { return input }
        let flat = input.text.tokens.reshaped([-1])
        let count = flat.dim(0)
        guard count > 0 else { return input }
        let tail = flat[Swift.max(0, count - 6)..<count].asArray(Int.self)
        guard tokenizer.decode(tokenIds: tail).trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("<think>") else {
            return input
        }
        let extra = tokenizer.encode(text: "\n</think>\n\n", addSpecialTokens: false)
        let joined = concatenated([flat, MLXArray(extra.map { Int32($0) }).asType(flat.dtype)])
        let shaped = input.text.tokens.ndim == 2 ? joined.reshaped([1, -1]) : joined
        return LMInput(tokens: shaped)
    }

    private func generateAnswer(context: ModelContext, plan: ModelPromptPlan, system: String, user: String,
                                grammar: GrammarTokenizer?, events: AnswerEvents) async throws -> Answer {
        context.model.train(false)
        let prefill = PrefillParameters(stepSize: 256) { done, total in
            events.read(done, total)
        }
        return try await withError {
            try await Device.withDefaultDevice(Device.gpu) {
                // Thinking off where the template has a switch (the answer is
                // short, and a reasoning model would otherwise spend the
                // budget before answering); closed where it has none.
                let prepared = try await context.processor.prepare(input: UserInput(
                    chat: [.system(system), .user(user)],
                    additionalContext: ["enable_thinking": false]))
                let input = Self.closingOpenThinkBlock(prepared, plan: plan, tokenizer: context.tokenizer)
                var answer = Answer()
                answer.promptTokens = input.text.tokens.size

                if let grammar {
                    let constraint = try GrammarConstraint(tokenizer: grammar, jsonSchema: plan.profile.schema,
                                                           fastForward: true, hostTokenizer: context.tokenizer)
                    var text = ""
                    var firstToken: Date?
                    var pieces = 0
                    let started = Date.now
                    let written = try GuidedGenerationLoop.run(
                        input: input, context: context, constraint: constraint,
                        maxTokens: plan.answerCap, vocabSize: grammar.vocabSize,
                        kvBits: Self.kvBits, prefill: prefill
                    ) { delta in
                        if firstToken == nil { firstToken = .now }
                        text += delta
                        pieces += 1
                        events.wrote(pieces)
                        return !Task.isCancelled
                    }
                    try Task.checkCancellation()
                    // The first piece of the answer arrives once the prompt is read.
                    answer.promptSeconds = (firstToken ?? .now).timeIntervalSince(started)
                    answer.generatedTokens = written
                    answer.generateSeconds = Date.now.timeIntervalSince(started) - answer.promptSeconds
                    answer.text = text
                    return answer
                }

                var parameters = GenerateParameters(maxTokens: plan.answerCap, kvBits: Self.kvBits,
                                                    temperature: plan.temperature, topP: plan.topP, topK: plan.topK)
                parameters.repetitionPenalty = plan.repetitionPenalty
                parameters.prefill = prefill
                let stream = try MLXLMCommon.generate(input: input, parameters: parameters, context: context)
                var pieces = 0
                for await item in stream {
                    switch item {
                    case .chunk(let piece):
                        answer.text += piece
                        pieces += 1
                        events.wrote(pieces)
                    case .info(let info):
                        answer.promptTokens = info.promptTokenCount
                        answer.promptSeconds = info.promptTime
                        answer.generatedTokens = info.generationTokenCount
                        answer.generateSeconds = info.generateTime
                    default:
                        break
                    }
                    if Task.isCancelled { break }
                }
                try Task.checkCancellation()
                return answer
            }
        }
    }

    /// The grammar engine's view of this model's vocabulary, or nil if it
    /// can't take it (the job then reads free-text answers).
    private static func grammarTokenizer(for context: ModelContext) -> GrammarTokenizer? {
        let vocab = TokenizerVocabExtractor.extractForGrammar(from: context.tokenizer)
        guard let eos = context.tokenizer.eosTokenId else { return nil }
        return try? GrammarTokenizer(vocab: vocab.vocab, vocabType: vocab.vocabType, eosTokenId: Int32(eos))
    }

    @MainActor private static func currentlyInBackground() -> Bool {
        UIApplication.shared.applicationState != .active
    }

    private static func inBackground() async -> Bool {
        await MainActor.run { currentlyInBackground() }
    }

    /// Off screen in a build signed without Background GPU Access.
    private static func mustWaitForScreen() async -> Bool {
        guard !SignedEntitlements.backgroundGPU else { return false }
        return await inBackground()
    }

    // MARK: Windows

    /// The line ranges to read: everything, or each asked-for range widened
    /// by `contextLines` either side, with overlapping ones joined.
    static func segments(_ ranges: [Range<Int>]?, lineCount: Int) -> [Range<Int>] {
        guard let ranges else { return [0..<lineCount] }
        let widened = ranges.map {
            Swift.max(0, $0.lowerBound - contextLines)..<Swift.min(lineCount, $0.upperBound + contextLines)
        }.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
        var joined: [Range<Int>] = []
        for range in widened {
            if let last = joined.last, range.lowerBound <= last.upperBound {
                joined[joined.count - 1] = last.lowerBound..<Swift.max(last.upperBound, range.upperBound)
            } else {
                joined.append(range)
            }
        }
        return joined
    }

    /// Windows of about `budget` tokens; each after the first starts
    /// `overlap` tokens before the previous one ended.
    static func windows(tokenCounts: [Int], segments: [Range<Int>], budget: Int, overlap: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for segment in segments {
            var start = segment.lowerBound
            while start < segment.upperBound {
                var end = start
                var sum = 0
                while end < segment.upperBound, end == start || sum + tokenCounts[end] <= budget {
                    sum += tokenCounts[end]
                    end += 1
                }
                result.append(start..<end)
                guard end < segment.upperBound else { break }
                var back = end
                var repeated = 0
                while back > start + 1, repeated < overlap {
                    back -= 1
                    repeated += tokenCounts[back]
                }
                start = Swift.max(back, start + 1)
            }
        }
        return result
    }

    /// Parts from overlapping windows: the same label on overlapping lines
    /// is one part.
    static func merge(_ parts: [JudgedPart]) -> [JudgedPart] {
        var merged: [JudgedPart] = []
        for part in parts.sorted(by: { ($0.firstLine, $0.lastLine) < ($1.firstLine, $1.lastLine) }) {
            if let i = merged.lastIndex(where: {
                $0.label == part.label && $0.firstLine <= part.lastLine && part.firstLine <= $0.lastLine
            }) {
                var kept = merged[i]
                let stronger = part.confidence > kept.confidence
                kept.firstLine = Swift.min(kept.firstLine, part.firstLine)
                kept.lastLine = Swift.max(kept.lastLine, part.lastLine)
                kept.funny = kept.funny || part.funny
                if kept.sponsor.isEmpty || (stronger && !part.sponsor.isEmpty) { kept.sponsor = part.sponsor }
                if stronger { kept.why = part.why }
                kept.confidence = Swift.max(kept.confidence, part.confidence)
                merged[i] = kept
            } else {
                merged.append(part)
            }
        }
        return merged
    }
}

/// A note written just before the model loads and removed when its read
/// ends, however it ends. One still there at the next launch means iOS
/// closed the app mid-read; a breadcrumb cannot establish why. It leaves no
/// report MetricKit can pass on — his 26d0ec7 runs left only empty ones.
/// Each such close lowers that model's largest window by one step.
enum Breadcrumb {
    struct Note: Codable, Sendable {
        var model: String
        var window: Int
        var launch: String
        var date: Date
    }

    private static let key = "localJudge.inFlight"
    private static func capKey(_ model: String) -> String { "localJudge.maxWindow." + model }
    /// Tells this launch's note from an earlier one's.
    static let launch = UUID().uuidString

    static func write(model: String, window: Int) {
        let note = Note(model: model, window: window, launch: launch, date: .now)
        UserDefaults.standard.set(try? JSONEncoder().encode(note), forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// An earlier launch's note, taken (so it is counted once).
    static func staleFromEarlierLaunch() -> Note? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let note = try? JSONDecoder().decode(Note.self, from: data),
              note.launch != launch else { return nil }
        clear()
        return note
    }

    /// The largest window this model may use, when a close lowered it.
    static func cap(model: String) -> Int? {
        let value = UserDefaults.standard.integer(forKey: capKey(model))
        return value > 0 ? value : nil
    }

    /// Lowers the cap to the step below `window` (or the smallest step)
    /// and returns it.
    @discardableResult
    static func lowerCap(model: String, below window: Int) -> Int {
        let steps = LocalModelSpec.windowSteps
        let lower = steps.first { $0 < window } ?? steps.last ?? window
        let current = cap(model: model) ?? Int.max
        let value = Swift.min(current, lower)
        UserDefaults.standard.set(value, forKey: capKey(model))
        return value
    }

    /// Whether the last launch ended mid-read, for Diagnostics, without
    /// taking the note.
    static var pendingFromEarlierLaunch: Bool {
        guard let data = UserDefaults.standard.data(forKey: key),
              let note = try? JSONDecoder().decode(Note.self, from: data) else { return false }
        return note.launch != launch
    }
}

/// The latest self-test's numbers as one line, kept across launches for
/// the Diagnostics file (pass 27: the speed on his phone is the measurement
/// every other model decision waits on).
enum SelfTestRecord {
    private static let key = "localJudge.lastSelfTest"

    /// Pass 27d: one line per model, so he can test several and share
    /// one Diagnostics file.
    private static let allKey = "localJudge.selfTests"
    static var last: String? {
        let all = (UserDefaults.standard.dictionary(forKey: allKey) as? [String: String]) ?? [:]
        if all.isEmpty { return UserDefaults.standard.string(forKey: key) }
        return all.keys.sorted().compactMap { all[$0] }.joined(separator: "  ||  ")
    }

    @MainActor static func save(_ report: JudgeReport?, error: String?) {
        let stamp = Date.now.formatted(date: .abbreviated, time: .shortened)
        let line: String
        if let report {
            let s = report.stats
            let found = report.parts.map { "\($0.label.rawValue) \($0.firstLine)–\($0.lastLine)" }.joined(separator: ", ")
            line = "\(stamp) · \(s.model) · read \(Int(s.readTokensPerSecond.rounded())) tok/s (\(s.promptTokens) in \(String(format: "%.1f", s.promptSeconds)) s) · wrote \(String(format: "%.1f", s.writeTokensPerSecond)) tok/s (\(s.generatedTokens)) · load \(String(format: "%.1f", s.loadSeconds)) s · peak \(ModelStore.gigabytes(Int64(s.peakMemoryBytes))) · free before \(ModelStore.gigabytes(Int64(s.availableBeforeLoad))) · parts of \(s.windowTokens) tokens · named \(s.partsParsed) part(s) · found: \(found.isEmpty ? "nothing" : found) · answer began: \(s.answerSample.replacingOccurrences(of: "\n", with: " ").prefix(400))"
        } else {
            line = "\(stamp) · \(ModelStore.shared.selected.name) · failed: \(error ?? "unknown")"
        }
        UserDefaults.standard.set(line, forKey: key)
        var all = (UserDefaults.standard.dictionary(forKey: allKey) as? [String: String]) ?? [:]
        all[report?.stats.model ?? ModelStore.shared.selected.name] = line
        UserDefaults.standard.set(all, forKey: allKey)
    }
}
