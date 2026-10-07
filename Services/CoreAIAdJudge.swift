import Darwin
import Foundation
import UIKit
#if !targetEnvironment(simulator)
import CoreAIKit
#endif

/// Contextual ad judge backed by the selected Core AI catalog model.
///
/// The deterministic reader still runs first. This judge then reads the transcript
/// in bounded windows and uses the same benchmarked JudgePrompt rules/schema as the
/// MLX path. The app owns download policy; CoreAIKit resolves device variants and loads cached bundles.
@available(iOS 27.0, *)
actor CoreAIAdJudge {
    static let shared = CoreAIAdJudge()

    enum JudgeError: LocalizedError {
        case notDownloaded
        case needsForeground
        case unavailable(String)
        case failed(String)
        /// Every part of the episode failed the same way. Asking again the
        /// same way gives the same answer, so the job uses the reader's cuts.
        case allPartsFailed(String)

        var errorDescription: String? {
            switch self {
            case .notDownloaded:
                return "The selected Core AI model isn't downloaded yet."
            case .needsForeground:
                return "Core AI ad detection needs PodSkipper open on screen."
            case .unavailable(let message), .failed(let message):
                return message
            case .allPartsFailed(let detail):
                return "Core AI couldn't read any part of this episode (\(detail))"
            }
        }
    }

    /// A part whose answer stopped moving for this long is given up on and
    /// counted as failed, instead of holding the job at 94 % or 99 % for
    /// minutes (his 5 Oct phone: the last part of Hourly Check never ended).
    /// Generous: the decode-only Core AI ports read the prompt one token per
    /// step (~40 s for 2,000 tokens on his phone), with no progress reported
    /// until the first answer token.
    static let partStallLimit: TimeInterval = 240
    /// The answer to one part: a short JSON list. Room for about eight parts.
    static let episodeAnswerTokens = 640

    private let maxWindowCharacters = 6_000
    private let overlapCharacters = 800
    private let maxAnswerTokens = 512

    /// Last moment a part made progress, shared with its stall watch.
    private final class Tick: @unchecked Sendable {
        private let lock = NSLock()
        private var last = Date()
        private var didBegin = false
        func touch() { lock.withLock { last = Date() } }
        var age: TimeInterval { lock.withLock { Date().timeIntervalSince(last) } }
        /// Pass 31: the answer has started (the prompt is read).
        func begin() { lock.withLock { didBegin = true } }
        var started: Bool { lock.withLock { didBegin } }
    }

    struct PartStalled: LocalizedError {
        var errorDescription: String? { "the model stopped answering for 4 min; this part was skipped" }
    }

    /// Runs one part's question, cancelling it if it stops moving.
    private static func watched<T: Sendable>(_ tick: Tick, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(3))
                    if tick.age > partStallLimit { throw PartStalled() }
                }
            }
            defer { group.cancelAll() }
            while let next = try await group.next() {
                if let value = next { return value }
            }
            throw CancellationError()
        }
    }

    func judgeReport(
        lines: [TimedLine],
        show: String,
        title: String,
        notes: String,
        evidence: [EvidenceSpan],
        corrections: String,
        modelID: String? = nil,
        only: [Range<Int>]? = nil,
        progress: @escaping @Sendable (Double) -> Void,
        status: @escaping @Sendable (String) -> Void = { _ in },
        requireCompleteAnswer: Bool = false,
        expectedModel: CoreAIModelDescriptor? = nil,
        episodeGUID: String = ""
    ) async throws -> JudgeReport {
        #if !targetEnvironment(simulator)
        var maxAnswerTokens = requireCompleteAnswer ? CoreAIClassifierSession.maxAnswerTokens : Self.episodeAnswerTokens
        guard !lines.isEmpty else {
            return JudgeReport(parts: [], failedLines: [], stats: JudgeStats(model: "Core AI"))
        }

        guard await canRun() else {
            throw JudgeError.needsForeground
        }

        // Pass 32: the catalog is read before anything is asked of it (it
        // used to be read only when a model screen opened, so a job right
        // after launch found "no model downloaded").
        await CoreAIModelLibrary.shared.ensureLoaded()
        let id = await MainActor.run { modelID ?? CoreAIModelLibrary.shared.selectedID }
        guard let entry = await CoreAIModelLibrary.shared.entry(for: id) else {
            throw JudgeError.unavailable("Core AI model \(id) isn't in the current catalog.")
        }
        guard entry.isCompatible else {
            throw JudgeError.unavailable("\(entry.name) has no iOS model bundle.")
        }
        guard await CoreAIModelLibrary.shared.isDownloaded(entry) else {
            throw JudgeError.notDownloaded
        }

        if let expectedModel, entry.repo != expectedModel.repo || entry.revision != expectedModel.revision || entry.variant != expectedModel.variant {
            throw JudgeError.failed("The selected model version changed while this test waited. Run the test again to use the new catalog version.")
        }
        try await ThermalPacing.beforePart(status: status)
        status("Loading " + entry.name)
        // Pass 30: only the model in use can't be deleted meanwhile.
        await MainActor.run { CoreAIModelLibrary.shared.markInUse(id, true) }
        defer { Task { @MainActor in CoreAIModelLibrary.shared.markInUse(id, false) } }
        // Pass 31 (the open Core AI crash, his 5 Oct MetricKit: an abort
        // inside Metal/MPSGraph under CoreAIDelegates, which no app code can
        // catch): a note while the model runs, so the next launch can say
        // which model was running when the app went down.
        CoreAIInFlight.write(id: id, name: entry.name, episode: episodeGUID)
        defer { CoreAIInFlight.clear() }
        let availableBeforeLoad = Int(os_proc_available_memory())
        let loadStarted = Date.now
        var classifier: CoreAIClassifierSession?
        let chat: ChatSession?
        do {
            // Pass 29: whole episodes use the classifier path too. The chat
            // path left Qwen3's thinking on and gave 0-token answers on every
            // part of a real episode on his phone (5 Oct, 16 of 16 parts),
            // while the same model scored 91 % on the Basic test through this
            // path: thinking off, answer held to the schema, prompt sized in
            // the model's own tokens. Pass 30: every model comes this way;
            // the chat session is only the fallback for a bundle the
            // classifier can't open.
            guard let cached = await CoreAIModelLibrary.shared.cachedBundle(for: id) else {
                throw JudgeError.notDownloaded
            }
            do {
                classifier = try await CoreAIClassifierSession(bundleAt: cached.url, engineHint: cached.engineHint)
            } catch {
                try Task.checkCancellation()
                await BackgroundLog.shared.note("Core AI \(entry.name): the direct reader couldn't open it (\((error as NSError).localizedDescription)); using the chat session")
                classifier = nil
            }
            if classifier != nil {
                chat = nil
            } else {
                var configuration = ChatSession.Configuration()
                configuration.temperature = nil
                configuration.maxResponseTokens = maxAnswerTokens
                configuration.systemPrompt = JudgePrompt.system
                guard let cached = await CoreAIModelLibrary.shared.cachedBundle(for: id) else {
                    throw JudgeError.notDownloaded
                }
                switch cached.engineHint {
                case "pipelined": configuration.engineVariant = .pipelined
                case "sequential": configuration.engineVariant = .sequential
                case "static-shape": configuration.engineVariant = .staticShape
                default: configuration.engineVariant = .auto
                }
                chat = try await ChatSession(bundleAt: cached.url, configuration: configuration)
                classifier = nil
            }
            try Task.checkCancellation()
        } catch {
            try Task.checkCancellation()
            let detail = error as NSError
            throw JudgeError.failed("Couldn't load \(entry.name): \(detail.localizedDescription) [\(detail.domain) \(detail.code)]. Bundle: \(entry.repo), model \(id). This is a runtime load failure; no sample was classified.")
        }

        // Pass 30: the prompt is sized to what this model holds on iPhone.
        // Qwen3 4B (4,096 tokens) gets the benchmarked rules with a short
        // answer; the GPU-pipelined models, held to 1,024 tokens in all on
        // iOS, get short rules. Tests use the same prompt as episodes, so a
        // test says how the model will do on an episode.
        let profile: JudgePrompt.Profile = classifier.map { JudgePrompt.Profile.forContext($0.contextLimit) } ?? .full
        let system = profile.system
        let schema = profile.schema
        if classifier != nil { maxAnswerTokens = profile.answerTokens }
        let notes = profile == .full ? notes : String(notes.prefix(profile.notesLimit))
        let corrections = profile == .full ? corrections : String(corrections.prefix(profile.correctionsLimit))

        let formatted = lines.indices.map { JudgePrompt.line($0, lines[$0], spans: evidence) }
        let windows: [Range<Int>]
        var windowTokens = 0
        let reading = (only ?? [0..<formatted.count]).filter { !$0.isEmpty }
        if let classifier, classifier.contextLimit > 0 {
            // Planned in the model's own tokens: the prompt without any
            // transcript, plus the answer's room, plus the lines.
            let header = JudgePrompt.userLocal(show: show, title: title, notes: notes, lines: lines,
                                               window: 0..<0, spans: evidence, corrections: corrections)
            let overhead = (try? await classifier.promptTokenCount(system: system, user: header)) ?? 1_500
            var counts: [Int] = []
            counts.reserveCapacity(formatted.count)
            for line in formatted { counts.append(await classifier.tokenCount(line + "\n")) }
            let room = classifier.contextLimit - overhead - maxAnswerTokens - 48
            guard room >= 120 else {
                throw JudgeError.allPartsFailed("\(entry.name) holds \(classifier.contextLimit) tokens here; the instructions alone take \(overhead)")
            }
            windowTokens = room
            windows = LocalJudge.windows(tokenCounts: counts, segments: reading,
                                         budget: windowTokens, overlap: windowTokens / 8)
        } else {
            windows = makeWindows(formatted)
        }
        await MainActor.run {
            LocalJudgeMonitor.shared.started()
            LocalJudgeMonitor.shared.planned(windows.count)
        }

        // Pass 31: the bar and the time left from the real work: each part's
        // prompt tokens at this model's measured reading speed, then its
        // answer at its writing speed (see WorkMeter). Core AI says nothing
        // while it reads a prompt, so that share is counted from the clock
        // at the measured speed, and set exactly when the answer starts.
        let measured = WorkMeter.rates(for: entry.id)
        let readRate = measured?.read ?? 50, writeRate = measured?.write ?? 9
        let expectedAnswer = Swift.min(maxAnswerTokens, Int(measured?.answer ?? 60))
        var meterParts: [WorkMeter.Part] = []
        for window in windows {
            let user = JudgePrompt.userLocal(show: show, title: title, notes: notes, lines: lines,
                                             window: window, spans: evidence, corrections: corrections)
            var tokens = (system.count + user.count) / 4
            if let classifier, let counted = try? await classifier.promptTokenCount(system: system, user: user) { tokens = counted }
            meterParts.append(WorkMeter.Part(promptTokens: tokens, expectedAnswer: expectedAnswer, answerCap: maxAnswerTokens))
        }
        let meter = WorkMeterBox(WorkMeter(parts: meterParts, readRate: readRate, writeRate: writeRate, loadSeconds: 0,
                                           ratesKnown: measured != nil))
        let report: @Sendable ((inout WorkMeter) -> Void) -> Void = { change in
            let now = meter.updateReading(change)
            progress(now.fraction)
            Task { @MainActor in LocalJudgeMonitor.shared.metered(now) }
        }
        report { $0.modelLoaded() }

        var stats = JudgeStats(model: entry.name)
        stats.availableBeforeLoad = availableBeforeLoad
        stats.loadSeconds = Date.now.timeIntervalSince(loadStarted)
        stats.windowTokens = windowTokens
        var found: [JudgedPart] = []
        var failed: [ClosedRange<Int>] = []
        let started = Date.now
        stats.windows = windows.count

        do {
            for (index, window) in windows.enumerated() {
                try Task.checkCancellation()
                guard await canRun() else {
                    throw JudgeError.needsForeground
                }
                try await ThermalPacing.beforePart(status: status)

                // Pass 31: numbered from 0 within the stretch (see userLocal).
                let user = JudgePrompt.userLocal(show: show, title: title, notes: notes, lines: lines,
                                                 window: window, spans: evidence, corrections: corrections)

                var parsed: [JudgePrompt.RawPart]?
                var lastError: Error?

                // Each transcript window is an independent classification problem.
                // ChatSession normally retains history for multi-turn chat, which would
                // otherwise make later windows grow the context with earlier windows.
                await chat?.reset()

                let generatedBefore = stats.generatedTokens
                let tick = Tick()
                let partLabel = "part \(index + 1) of \(windows.count)"
                // Pass 32: where a crash happened, for the next launch.
                CoreAIInFlight.update(stage: "\(partLabel) · about \(meterParts[index].promptTokens) prompt tokens · \(classifier?.engineName ?? "chat session")")
                let partStatus: @Sendable (String) -> Void = { message in
                    tick.touch()
                    JobHeartbeat.shared.beat()
                    status(message.replacingOccurrences(of: "sample", with: partLabel))
                }

                // Reading the prompt, counted from the clock until the
                // first answer token says it's done.
                let partStarted = Date.now
                let writing = Tick()
                let clock = Task {
                    while !Task.isCancelled {
                        let read = Int(Date.now.timeIntervalSince(partStarted) * readRate)
                        report { $0.reading(part: index, done: Swift.min(read, meterParts[index].promptTokens), measured: false) }
                        try? await Task.sleep(for: .milliseconds(500))
                        if writing.started { break }
                    }
                }
                defer { clock.cancel() }
                for attempt in 0..<2 where parsed == nil {
                    do {
                        if attempt > 0 { await chat?.reset() }
                        let windowStarted = Date.now
                        status("Reading " + partLabel)
                        let answer: String
                        let generatedTokens: Int
                        if let classifier {
                            let limit = maxAnswerTokens
                            let response = try await Self.watched(tick) {
                                try await classifier.respond(system: system, user: user,
                                                             schema: schema, maxAnswer: limit,
                                                             minimumAnswer: limit / 2) { message in
                                    partStatus(message)
                                    if let tokens = Int(message.split(separator: " ").dropLast().last ?? "") {
                                        writing.begin()
                                        report { $0.writing(part: index, written: tokens) }
                                    }
                                }
                            }
                            stats.constrained = true
                            answer = response.text
                            generatedTokens = response.generatedTokens
                            stats.reusedPromptTokens += response.reusedTokens
                            stats.promptTokens += response.promptTokens - response.reusedTokens
                            stats.promptSeconds += response.promptSeconds
                            stats.generatedTokens += response.generatedTokens
                            stats.generateSeconds += response.generateSeconds
                        } else if let chat {
                            var text = "", reasoningCharacters = 0
                            let stream = await chat.streamResponse(to: user)
                            try await withTaskCancellationHandler {
                                for try await event in stream {
                                switch event {
                                case .response(let delta): text += delta
                                case .thinking(let delta): reasoningCharacters += delta.count
                                case .stats(let usage):
                                    partStatus(reasoningCharacters > 0 && text.isEmpty
                                        ? "Model is reasoning · \(usage.generatedTokens) tokens"
                                        : "Writing classification · \(usage.generatedTokens) tokens")
                                case .complete: break
                                }
                                }
                            } onCancel: {
                                Task { await chat.cancelGeneration() }
                            }
                            try Task.checkCancellation()
                            answer = text
                            let usage = await chat.stats
                            generatedTokens = usage.generatedTokens
                            stats.promptTokens += usage.promptTokens
                            let promptSeconds = usage.ttftSeconds ?? 0
                            stats.promptSeconds += promptSeconds
                            stats.generatedTokens += usage.generatedTokens
                            stats.generateSeconds += max(0, Date.now.timeIntervalSince(windowStarted) - promptSeconds)
                            stats.peakMemoryBytes = max(stats.peakMemoryBytes, Int(usage.footprintBytes))
                        } else { throw JudgeError.notDownloaded }
                        try Task.checkCancellation()
                        stats.answerSample = String(answer.prefix(600))
                        // Partial objects remain useful to episode recovery, but a
                        // truncated answer must not masquerade as a completed test.
                        parsed = (requireCompleteAnswer ? JudgePrompt.parseComplete(answer) : JudgePrompt.parse(answer))
                            .map { JudgePrompt.shifted($0, window: window) }
                        stats.partsParsed += parsed?.count ?? 0
                        lastError = parsed == nil ? JudgeError.failed(ModelAnswerFailure.describe(
                            answer: answer, generatedTokens: generatedTokens,
                            limit: maxAnswerTokens)) : nil
                        // No benefit in repeating an identical greedy request: a
                        // truncated or invalid answer needs a changed input/config.
                        if parsed == nil { break }

                    } catch {
                        await chat?.cancelGeneration()
                        try Task.checkCancellation()
                        lastError = error
                        // ChatSession's reset does not join a cancelled generation.
                        // Do not race another request into that session.
                        break
                    }
                }

                clock.cancel()
                let wroteTokens = stats.generatedTokens - generatedBefore
                report { $0.finished(part: index, written: wroteTokens) }
                if let parsed {
                    found += parsed.compactMap { JudgePrompt.resolve($0, lines: lines) }
                } else {
                    failed.append(window.lowerBound...(window.upperBound - 1))
                    stats.failureDetails = lastError?.localizedDescription ?? "The model returned no classification."
                    if let lastError {
                        await BackgroundLog.shared.note("Core AI \(entry.name) \(partLabel) failed: \(lastError.localizedDescription)")
                    }
                }

                let wordCount = lines[window].reduce(0) {
                    $0 + $1.text.split(whereSeparator: \.isWhitespace).count
                }
                let elapsed = Date.now.timeIntervalSince(started)
                let speed = elapsed > 0 ? Double(wordCount) / elapsed : 0
                let doneNow = meter.snapshot.fraction
                await MainActor.run {
                    LocalJudgeMonitor.shared.advanced(doneNow, done: index + 1, wordsPerSecond: speed)
                }
            }
            WorkMeter.remember(model: entry.id, read: stats.readTokensPerSecond, write: stats.writeTokensPerSecond,
                               load: stats.loadSeconds, answer: Double(stats.generatedTokens) / Double(max(1, windows.count)))

            stats.failedWindows = failed.count
            stats.finishedAt = Date()

            await LocalJudgeMonitor.shared.finished(stats, error: stats.failureDetails)

            return JudgeReport(
                parts: ModelFinderMerge.merge(found),
                failedLines: failed,
                stats: stats
            )
        } catch {
            await chat?.cancelGeneration()
            stats.finishedAt = .now
            await LocalJudgeMonitor.shared.finished(stats, error: error is CancellationError ? nil : error.localizedDescription)
            throw error
        }
        #else
        throw JudgeError.unavailable("Core AI inference requires a physical device.")
        #endif
    }

    @MainActor private func canRun() -> Bool {
        UIApplication.shared.applicationState == .active || SignedEntitlements.backgroundGPU
    }

    private func makeWindows(_ formatted: [String]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        while start < formatted.count {
            var end = start
            var chars = 0
            while end < formatted.count {
                let next = formatted[end].count + 1
                if end > start && chars + next > maxWindowCharacters { break }
                chars += next
                end += 1
            }
            result.append(start..<end)
            guard end < formatted.count else { break }

            var back = end
            var repeated = 0
            while back > start + 1 && repeated < overlapCharacters {
                back -= 1
                repeated += formatted[back].count + 1
            }
            start = max(back, start + 1)
        }
        return result
    }
}

/// Kept local so the Core AI judge does not need to expose ModelFinder's
/// overlap-merging implementation as public API.
private enum ModelFinderMerge {
    static func merge(_ parts: [JudgedPart]) -> [JudgedPart] {
        var merged: [JudgedPart] = []
        for part in parts.sorted(by: { ($0.firstLine, $0.lastLine) < ($1.firstLine, $1.lastLine) }) {
            if let i = merged.lastIndex(where: {
                $0.label == part.label && $0.firstLine <= part.lastLine && part.firstLine <= $0.lastLine
            }) {
                var kept = merged[i]
                let stronger = part.confidence > kept.confidence
                kept.firstLine = min(kept.firstLine, part.firstLine)
                kept.lastLine = max(kept.lastLine, part.lastLine)
                kept.funny = kept.funny || part.funny
                if kept.sponsor.isEmpty || (stronger && !part.sponsor.isEmpty) {
                    kept.sponsor = part.sponsor
                }
                if stronger { kept.why = part.why }
                kept.confidence = max(kept.confidence, part.confidence)
                merged[i] = kept
            } else {
                merged.append(part)
            }
        }
        return merged
    }
}


/// Pass 31: which Core AI model was running, kept while it runs.
/// Pass 32: also which episode (empty for a test) and how far it had got,
/// so a crash on a real episode says where it happened, and the job that
/// resumes after it doesn't walk straight back into the same crash.
enum CoreAIInFlight {
    private static let key = "coreAI.inFlight"
    static let launch = UUID().uuidString

    struct Note: Sendable, Equatable {
        var id: String
        var name: String
        /// The episode being read; "" for a Basic/Hard test.
        var episode: String
        /// "part 3 of 7 · 2,410 prompt tokens", or "loading".
        var stage: String
    }

    static func write(id: String, name: String, episode: String = "", stage: String = "loading") {
        UserDefaults.standard.set(["id": id, "name": name, "launch": launch, "episode": episode, "stage": stage], forKey: key)
    }

    /// Where the read has got to (kept cheap: once a part).
    static func update(stage: String) {
        guard var note = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else { return }
        note["stage"] = stage
        UserDefaults.standard.set(note, forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    /// An earlier launch's note, taken once: that launch ended while the
    /// model was running (iOS closed it, or the Core AI runtime crashed).
    static func staleFromEarlierLaunch() -> Note? {
        guard let note = UserDefaults.standard.dictionary(forKey: key) as? [String: String],
              note["launch"] != launch, let id = note["id"] else { return nil }
        clear()
        return Note(id: id, name: note["name"] ?? id, episode: note["episode"] ?? "", stage: note["stage"] ?? "")
    }
}

/// Pass 32 (his 7 Oct report: Core AI Qwen3 4B closed the app on Legion of
/// Skanks and on Bad Friends). A model that took the app down while reading
/// an episode is not started on that episode again by a job that merely
/// resumes after the crash — that would crash again, in a loop. It runs
/// again only when he asks (Find Ads, or Find Ads Again). His chosen model
/// stays chosen either way: one episode's failure never changes the setting.
enum CoreAICrashGuard {
    private static let key = "coreAI.closedOnEpisode"

    /// Recorded at launch from the in-flight note.
    static func remember(_ note: CoreAIInFlight.Note, defaults: UserDefaults = .standard) {
        guard !note.episode.isEmpty else { return }
        var all = defaults.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        all[note.episode] = ["model": note.id, "name": note.name, "stage": note.stage,
                             "date": ISO8601DateFormatter().string(from: .now)]
        defaults.set(all, forKey: key)
    }

    /// The model that closed the app on this episode last time, if it is
    /// the one about to read it again.
    static func closedLastTime(model: String, episode: String, defaults: UserDefaults = .standard) -> (name: String, stage: String)? {
        guard let entry = (defaults.dictionary(forKey: key) as? [String: [String: String]])?[episode],
              entry["model"] == model else { return nil }
        return (entry["name"] ?? model, entry["stage"] ?? "")
    }

    /// He asked for this episode again: the model gets another try.
    static func forget(episode: String, defaults: UserDefaults = .standard) {
        guard var all = defaults.dictionary(forKey: key) as? [String: [String: String]], all[episode] != nil else { return }
        all[episode] = nil
        defaults.set(all, forKey: key)
    }
}
