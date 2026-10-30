import Darwin
import Foundation
import os
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
        /// Pass 43: iOS was short of memory, so the read stopped between parts.
        case lowMemory(String)

        var errorDescription: String? {
            switch self {
            case .notDownloaded:
                return "The selected Core AI model isn't downloaded yet."
            case .needsForeground:
                return "Core AI ad detection needs PodSkipper open on screen: the iPhone locked or another app opened, and Core AI can't use the graphics chip in the background."
            case .unavailable(let message), .failed(let message):
                return message
            case .allPartsFailed(let detail):
                return "Core AI couldn't read any part of this episode (\(detail))"
            case .lowMemory(let why):
                return "Core AI stopped between parts because \(why); it reads this episode again later"
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
        episodeGUID: String = "",
        checkpoint: DetectionCheckpoint? = nil
    ) async throws -> JudgeReport {
        #if !targetEnvironment(simulator)
        var maxAnswerTokens = requireCompleteAnswer ? CoreAIClassifierSession.maxAnswerTokens : Self.episodeAnswerTokens
        guard !lines.isEmpty else {
            return JudgeReport(parts: [], failedLines: [], stats: JudgeStats(model: "Core AI"))
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
        // Pass 38: off screen only when what is installed runs without the
        // graphics chip (`CoreAIComputeUnits`); every Core AI language model
        // available here today uses it, so in practice: on screen.
        let installedBundle = await CoreAIModelLibrary.shared.cachedBundle(for: id)
        let needsScreen = !CoreAIComputeUnits.runsWithoutGPU(delegates: installedBundle.flatMap { CoreAIComputeUnits.delegates(inBundle: $0.url) })
        guard await canRun(needsScreen: needsScreen) else {
            throw JudgeError.needsForeground
        }
        // Pass 38 (his 14 Oct phone, e929aad: Gemma 4 E2B closed PodSkipper
        // twice, at the first prompt token, "compiled on this iPhone when
        // first used"). Symbolicated: a Swift trap inside CoreAIRuntime on the
        // first encode; CoreAIKit: "iOS MUST use the AOT-compiled bundle —
        // the plain bundle's ~2 GB of graph constants crash the on-device GPU
        // specializer". Nothing in the app can catch it, so on an iPhone
        // without the publisher's build for its chip, Gemma runs only from a
        // copy compiled for this iPhone.
        if let gate = await CoreAIGemmaReadiness.refusal(entry: entry, bundle: installedBundle?.url) {
            throw JudgeError.unavailable(gate)
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
        // Pass 35 (his 9 Oct phone, 36410ed): every Qwen3 4B abort, before and
        // after the 8-token prompt steps, is the same Metal failure inside
        // MPSGraph's on-device specializer (`-[MPSGraphExecutable
        // specializedModuleWithDevice:…]` from `MPSGraphDelegate.resolveCoreAI`,
        // symbolicated against iOS 27.0.1): Core AI compiling a part of the
        // model for this iPhone the first time it is used, writing a compiled
        // copy about the model's size. His phone had 339 MB free around then.
        // Not proven to be the cause, but compiling with no room is certain to
        // fail, and the failure can't be caught — so a load needs room first.
        let preparation = Int64(entry.sizeMB ?? 2_500) * 1_000_000
        let room = StorageGuard.check(writing: preparation)
        if case .insufficient = room, let message = StorageGuard.message(for: room, doing: "prepare " + entry.name) {
            throw JudgeError.unavailable(message)
        }
        CoreAIInFlight.write(id: id, name: entry.name, episode: episodeGUID)
        defer { CoreAIInFlight.clear() }
        let availableBeforeLoad = Int(os_proc_available_memory())
        // Pass 36: Core AI's one-time preparation for this iPhone as its own
        // step (CoreAIPreparation): said as such, kept with the persistent
        // policy, and waited for even after Stop, which it can't honour
        // until Core AI returns. Already prepared: nothing happens here.
        if let bundle = await CoreAIModelLibrary.shared.cachedBundle(for: id) {
            CoreAIInFlight.update(stage: "preparing the model for this iPhone")
            do {
                try await CoreAIPreparation.shared.prepare(modelID: id, name: entry.name, bundle: bundle.url, status: status)
            } catch let error as CoreAIPreparation.PreparationError {
                throw JudgeError.failed(error.localizedDescription + " No sample was classified.")
            }
            CoreAIInFlight.update(stage: "loading")
            status("Loading " + entry.name)
        }
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
            // Pass 37: Gemma 4 reads with its word tables bound beside it.
            guard let tables = await CoreAIModelLibrary.shared.tablesFolder(for: id) else {
                throw JudgeError.notDownloaded
            }
            do {
                classifier = try await CoreAIClassifierSession(bundleAt: cached.url, engineHint: cached.engineHint,
                                                               tablesURL: tables, family: entry.id + " " + entry.name)
            } catch where tables != nil {
                // The chat session can't bind the tables; it would fail the same way.
                throw error
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
        // Pass 38: the same per-family plan as MLX (`ModelPromptPlan`), with
        // what this model holds on this engine here.
        let plan: ModelPromptPlan? = classifier.map {
            ModelPromptPlan.coreAI(id: entry.id, name: entry.name, template: $0.chatTemplate, context: $0.contextLimit)
        }
        let profile: JudgePrompt.Profile = plan?.profile ?? .full
        let system = profile.system
        let schema = profile.schema
        if classifier != nil { maxAnswerTokens = profile.answerTokens }
        let notes = profile == .full ? notes : String(notes.prefix(profile.notesLimit))
        let corrections = profile == .full ? corrections : String(corrections.prefix(profile.correctionsLimit))

        let formatted = lines.indices.map { JudgePrompt.line($0, lines[$0], spans: evidence) }
        let proposedWindows: [Range<Int>]
        var windowTokens = 0
        let reading = (only ?? [0..<formatted.count]).filter { !$0.isEmpty }
        if let classifier, classifier.contextLimit > 0 {
            // Planned in the model's own tokens: the prompt without any
            // transcript, plus the answer's room, plus the lines.
            // The header every stretch shares, plus the stretch's own opening
            // sentence (its place in the episode), measured on a one-line stretch.
            let header = JudgePrompt.userHeader(show: show, title: title, notes: notes, corrections: corrections)
                + JudgePrompt.stretch(lines: lines, window: 0..<1, spans: evidence)
                + (profile.reminder.map { "\n\n" + $0 } ?? "")
            let overhead = (try? await classifier.promptTokenCount(system: system, user: header)) ?? 1_500
            var counts: [Int] = []
            counts.reserveCapacity(formatted.count)
            for line in formatted { counts.append(await classifier.tokenCount(line + "\n")) }
            // Pass 38: 24 tokens of slack (it was 48: on a 1,024-token model
            // every token is transcript); the plan's ceiling for small models.
            // Pass 46: and under the plan's prompt ceiling (Qwen3 4B).
            let room = plan?.windowRoom(context: classifier.contextLimit, overhead: overhead, answer: maxAnswerTokens)
                ?? classifier.contextLimit - overhead - maxAnswerTokens - 24
            guard room >= 120 else {
                throw JudgeError.allPartsFailed("\(entry.name) holds \(classifier.contextLimit) tokens here; the instructions alone take \(overhead)")
            }
            windowTokens = room
            proposedWindows = LocalJudge.windows(tokenCounts: counts, segments: reading,
                                         budget: windowTokens, overlap: windowTokens / 8)
        } else {
            proposedWindows = makeWindows(formatted)
        }
        // Pass 45 (his 22 Oct #960: Qwen3 4B closed PodSkipper at part 3 of
        // 11, and the try after it read parts 1 and 2 again): each part's
        // whole answer is kept with the episode as soon as it is given, so a
        // read iOS ends resumes at the part it reached. Same model, build,
        // instructions, room and lines, or nothing is reused.
        let saved = checkpoint.map {
            ModelWindowCheckpoint(checkpoint: $0, identity: ModelWindowCheckpoint.identity(fields: [
                "coreai-classification-v1", entry.id, entry.revision ?? "", entry.variant ?? "",
                ProcessInfo.processInfo.operatingSystemVersionString, system, schema, profile.reminder ?? "",
                "\(maxAnswerTokens)", "\(windowTokens)",
                JudgePrompt.userHeader(show: show, title: title, notes: notes, corrections: corrections),
                formatted.joined(separator: "\n"), reading.description]))
        }
        let windows = saved?.plan(proposed: proposedWindows, lineCount: lines.count, fits: { _ in true }, split: { [$0] },
                                  isReusable: { JudgePrompt.parseComplete($0) != nil }) ?? proposedWindows
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
            if saved?.answer(window).flatMap(JudgePrompt.parseComplete) != nil {
                meterParts.append(WorkMeter.Part(promptTokens: 0, expectedAnswer: 0, answerCap: maxAnswerTokens))
                continue
            }
            let user = JudgePrompt.userLocal(show: show, title: title, notes: notes, lines: lines,
                                             window: window, spans: evidence, corrections: corrections,
                                             reminder: profile.reminder)
            var tokens = (system.count + user.count) / 4
            if let classifier, let counted = try? await classifier.promptTokenCount(system: system, user: user) { tokens = counted }
            meterParts.append(WorkMeter.Part(promptTokens: tokens, expectedAnswer: expectedAnswer, answerCap: maxAnswerTokens))
        }
        let meter = WorkMeterBox(WorkMeter(parts: meterParts, readRate: readRate, writeRate: writeRate, loadSeconds: 0,
                                           ratesKnown: measured != nil))
        let report: @Sendable ((inout WorkMeter) -> Void) -> Void = { change in
            let now = meter.updateReading(change)
            progress(now.fraction)
            if meter.shouldPublish(now) { Task { @MainActor in LocalJudgeMonitor.shared.metered(now) } }
        }
        report { $0.modelLoaded() }

        // Pass 38: what every stretch repeats, kept in the engine between them.
        let sharedHeader = JudgePrompt.userHeader(show: show, title: title, notes: notes, corrections: corrections)
        var stats = JudgeStats(model: entry.name)
        stats.availableBeforeLoad = availableBeforeLoad
        stats.loadSeconds = Date.now.timeIntervalSince(loadStarted)
        stats.windowTokens = windowTokens
        // Pass 40: the heat policy and iOS's heat states over the read, and the
        // waits, as the MLX read records them.
        stats.startedAt = loadStarted
        stats.heatPolicy = ThermalPacing.policy.rawValue
        var found: [JudgedPart] = []
        var failed: [ClosedRange<Int>] = []
        let started = Date.now
        stats.windows = windows.count
        CoreAIMemory.watch()

        // Pass 54: episode order again — Pass 53's longest-part-first rested
        // on a 1,024-position line his 30 Oct phone disproved (`CoreAIPrefill`).
        let order = Array(windows.indices)
        var partsDone = 0

        do {
            for index in order {
                let window = windows[index]
                try Task.checkCancellation()
                guard await canRun(needsScreen: needsScreen) else {
                    throw JudgeError.needsForeground
                }
                // Pass 43: stopped here, between parts, rather than ended by
                // iOS part-way through one.
                if let kept = saved?.answer(window).flatMap(JudgePrompt.parseComplete) {
                    let parsed = JudgePrompt.shifted(kept, window: window, lines: lines, maxShare: plan?.maxCutShare)
                    found += parsed.compactMap { JudgePrompt.resolve($0, lines: lines) }
                    stats.reusedWindows += 1
                    stats.partReads.append("part \(index + 1): answered before, kept")
                    partsDone += 1
                    report { $0.finished(part: index, written: 0) }
                    status("Reusing saved classification · part \(index + 1) of \(windows.count)")
                    continue
                }
                if let short = CoreAIMemory.short(since: started) {
                    throw JudgeError.lowMemory(short)
                }
                let heat = ThermalPacing.state
                let cooledBefore = ThermalPacing.cooledSeconds()
                try await ThermalPacing.beforePart(status: status)
                let rested = ThermalPacing.cooledSeconds() - cooledBefore
                stats.cooledSeconds += rested
                let readStarted = Date.now
                let tokensBefore = (stats.promptTokens, stats.reusedPromptTokens, stats.generatedTokens)

                // Pass 31: numbered from 0 within the stretch (see userLocal).
                let user = JudgePrompt.userLocal(show: show, title: title, notes: notes, lines: lines,
                                                 window: window, spans: evidence, corrections: corrections,
                                                 reminder: profile.reminder)

                var parsed: [JudgePrompt.RawPart]?
                var lastError: Error?

                // Each transcript window is an independent classification problem.
                // ChatSession normally retains history for multi-turn chat, which would
                // otherwise make later windows grow the context with earlier windows.
                await chat?.reset()

                let generatedBefore = stats.generatedTokens
                let tick = Tick()
                let partLabel = "part \(index + 1) of \(windows.count)"
                // Pass 32: where a crash happened, for the next launch (Pass 54:
                // with PodSkipper's measured footprint at that moment).
                let freshBefore = await classifier?.freshEngines ?? 0
                CoreAIInFlight.update(stage: "\(partLabel) · reading about \(meterParts[index].promptTokens) prompt tokens · \(classifier?.engineName ?? "chat session")")
                let promptTokens = meterParts[index].promptTokens
                let engineName = classifier?.engineName ?? "chat session"
                let partStatus: @Sendable (String) -> Void = { message in
                    tick.touch()
                    JobHeartbeat.shared.beat()
                    // Pass 33: whether a crash came while the prompt was read
                    // or while the answer was written, and how far it got.
                    if message.hasPrefix("Writing") {
                        CoreAIInFlight.update(stage: "\(partLabel) · about \(promptTokens) prompt tokens read · \(message.lowercased()) · \(engineName)")
                    }
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
                var partPeakMB = 0
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
                                                             schema: schema, sharedUser: sharedHeader, maxAnswer: limit,
                                                             minimumAnswer: limit / 2) { message in
                                    partStatus(message)
                                    if let tokens = Int(message.split(separator: " ").dropLast().last ?? "") {
                                        writing.begin()
                                        report { $0.writing(part: index, written: tokens) }
                                    }
                                }
                            }
                            stats.constrained = true
                            partPeakMB = max(partPeakMB, response.peakFootprintMB)
                            stats.peakMemoryBytes = max(stats.peakMemoryBytes, response.peakFootprintMB * 1_048_576)
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
                            .map { JudgePrompt.shifted($0, window: window, lines: lines, maxShare: plan?.maxCutShare) }
                        stats.partsParsed += parsed?.count ?? 0
                        if parsed != nil, JudgePrompt.parseComplete(answer) != nil, let saved,
                           !saved.store(answer, window: window) {
                            status(saved.checkpoint.storageError ?? "Could not save this part for resuming.")
                        }
                        lastError = parsed == nil ? JudgeError.failed(ModelAnswerFailure.describe(
                            answer: answer, generatedTokens: generatedTokens,
                            limit: maxAnswerTokens)) : nil
                        // No benefit in repeating an identical greedy request: a
                        // truncated or invalid answer needs a changed input/config.
                        if parsed == nil { break }

                    } catch {
                        await chat?.cancelGeneration()
                        try Task.checkCancellation()
                        // Pass 38: iOS refused the graphics chip off screen.
                        if CoreAIAnswerText.isBackgroundGPURefusal(error) { throw JudgeError.needsForeground }
                        lastError = error
                        // ChatSession's reset does not join a cancelled generation.
                        // Do not race another request into that session.
                        break
                    }
                }

                clock.cancel()
                let wroteTokens = stats.generatedTokens - generatedBefore
                report { $0.finished(part: index, written: wroteTokens) }
                let readNow = stats.promptTokens - tokensBefore.0
                let keptNow = stats.reusedPromptTokens - tokensBefore.1
                let restarted = (await classifier?.freshEngines ?? 0) > freshBefore
                stats.partReads.append(String(format: "part %d: heat %@→%@, rested %.0f s, read %d tok (%d kept from before), wrote %d, %.0f s%@%@%@",
                                              index + 1, HeatLog.name(heat), HeatLog.name(ThermalPacing.state), rested,
                                              readNow, keptNow, stats.generatedTokens - tokensBefore.2,
                                              Date.now.timeIntervalSince(readStarted),
                                              partPeakMB > 0 ? " · memory peak \(partPeakMB.formatted()) MB" : "",
                                              restarted ? " · model started again first" : "",
                                              parsed == nil ? " · unreadable" : ""))
                if let parsed {
                    stats.classifiedPromptTokens += readNow + keptNow
                    found += parsed.compactMap { JudgePrompt.resolve($0, lines: lines) }
                } else {
                    failed.append(window.lowerBound...(window.upperBound - 1))
                    stats.failureDetails = lastError?.localizedDescription ?? "The model returned no classification."
                    if let lastError {
                        await BackgroundLog.shared.note("Core AI \(entry.name) \(partLabel) failed: \(lastError.localizedDescription)")
                    }
                }

                partsDone += 1
                let wordCount = lines[window].reduce(0) {
                    $0 + $1.text.split(whereSeparator: \.isWhitespace).count
                }
                let elapsed = Date.now.timeIntervalSince(started)
                let speed = elapsed > 0 ? Double(wordCount) / elapsed : 0
                let doneNow = meter.snapshot.fraction
                let done = partsDone
                await MainActor.run {
                    LocalJudgeMonitor.shared.advanced(doneNow, done: done, wordsPerSecond: speed)
                }
            }
            // Pass 33: it read to the end without taking the app down.
            CoreAIStability.completed(id)
            WorkMeter.remember(model: entry.id, read: stats.readTokensPerSecond, write: stats.writeTokensPerSecond,
                               load: stats.loadSeconds, answer: Double(stats.generatedTokens) / Double(max(1, windows.count - stats.reusedWindows)))

            stats.failedWindows = failed.count
            stats.finishedAt = Date()
            let heatLine = HeatLog.timeline(from: loadStarted)
            stats.heatTimeline = Array(heatLine.lines.prefix(30))
            stats.secondsByHeat = heatLine.seconds.mapValues { ($0 * 10).rounded() / 10 }

            await LocalJudgeMonitor.shared.finished(stats, error: stats.failureDetails)

            return JudgeReport(
                parts: ModelFinderMerge.merge(found),
                failedLines: failed.sorted { $0.lowerBound < $1.lowerBound },
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

    /// Pass 38: on screen, or off screen when the model doesn't use the
    /// graphics chip (or the build carries Background GPU Access).
    @MainActor private func canRun(needsScreen: Bool = true) -> Bool {
        UIApplication.shared.applicationState == .active || SignedEntitlements.backgroundGPU || !needsScreen
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

#if !targetEnvironment(simulator)
@available(iOS 27.0, *)
extension CoreAIGemmaReadiness {
    /// The gate for a catalog entry, with what is installed for it.
    static func refusal(entry: CoreAIModelDescriptor, bundle: URL?) async -> String? {
        let needsTables = await CoreAIModelLibrary.shared.needsTables(entry.id)
        #if os(iOS)
        let iOS = true
        #else
        let iOS = false
        #endif
        return refusal(needsTables: needsTables, decoderPath: entry.variant ?? "", machine: Diagnostics.deviceModel,
                       compiledCopyInstalled: bundle.map { CoreAICompiledCopy.installed(in: $0) != nil } ?? false,
                       iOS: iOS, name: entry.name)
    }
}
#endif

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
        /// Pass 43: PodSkipper was off screen when it ended. iOS ends apps in
        /// the background when it wants their memory, without a crash report,
        /// and doesn't give them the graphics chip — not the model's doing.
        var away = false
        /// Pass 43: memory iOS still allowed PodSkipper at the last part.
        var freeMB: Int?
        /// Pass 54: PodSkipper's own footprint at the last step noted, and
        /// what the graphics chip held for it then.
        var footprintMB: Int?
        var graphicsMB: Int?
    }

    static func write(id: String, name: String, episode: String = "", stage: String = "loading") {
        UserDefaults.standard.set(["id": id, "name": name, "launch": launch, "episode": episode, "stage": stage,
                                   "free": String(os_proc_available_memory() / 1_048_576)], forKey: key)
    }

    /// Where the read has got to: once a part, and (Pass 54) every one of
    /// the first 32 answer steps, with the footprint measured there.
    static func update(stage: String) {
        guard var note = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else { return }
        note["stage"] = stage
        note["free"] = String(os_proc_available_memory() / 1_048_576)
        note["footprint"] = String(CoreAIFootprint.megabytes())
        note["graphics"] = String(CoreAIFootprint.graphicsMegabytes())
        UserDefaults.standard.set(note, forKey: key)
    }

    /// Pass 43: called as PodSkipper leaves the screen and comes back.
    static func setAway(_ away: Bool) {
        guard var note = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else { return }
        if away { note["away"] = "1" } else { note.removeValue(forKey: "away") }
        UserDefaults.standard.set(note, forKey: key)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    /// An earlier launch's note, taken once: that launch ended while the
    /// model was running (iOS closed it, or the Core AI runtime crashed).
    static func staleFromEarlierLaunch() -> Note? {
        guard let note = UserDefaults.standard.dictionary(forKey: key) as? [String: String],
              note["launch"] != launch, let id = note["id"] else { return nil }
        clear()
        return Note(id: id, name: note["name"] ?? id, episode: note["episode"] ?? "", stage: note["stage"] ?? "",
                    away: note["away"] == "1", freeMB: note["free"].flatMap(Int.init),
                    footprintMB: note["footprint"].flatMap(Int.init), graphicsMB: note["graphics"].flatMap(Int.init))
    }

    /// Pass 43: what the launch after says, in plain words. His 19 Oct
    /// Diagnostics said "Core AI was most likely compiling the model" for
    /// closures in the middle of an answer, on part 5 of 5 — long after
    /// anything was compiled.
    static func launchNote(_ note: Note) -> String {
        let what = note.episode.isEmpty ? "a test" : "an episode"
        let stage = note.stage.isEmpty ? "" : " (" + note.stage + ")"
        let graphics = note.graphicsMB.map { " (graphics \($0) MB)" } ?? ""
        let memory = (note.footprintMB.map { " PodSkipper was using \($0) MB\(graphics) at the last step noted." } ?? "")
            + (note.freeMB.map { " iOS allowed it about \($0) MB more at the last part." } ?? "")
        if note.away {
            return "Last time iOS closed PodSkipper while it was in the background and Core AI \(note.name) was reading \(what)\(stage). iOS closes apps in the background when it needs their memory, and Core AI can't use the graphics chip there; this isn't counted against the model."
                + (note.episode.isEmpty ? "" : " The episode is read again when PodSkipper is open.")
        }
        let loading = note.stage == "loading" || note.stage.hasPrefix("preparing")
        let compiling = loading && !note.stage.contains("compiled for this iPhone")
        return "Last time PodSkipper closed while Core AI \(note.name) was reading \(what)\(stage)." + memory
            + (compiling
               ? " Core AI was loading the model and preparing it for this iPhone, which Apple's runtime can abort. A copy compiled for this iPhone avoids that (Models and Caches → the model → Install Compiled Copy)."
               : " iOS sends its own report of why within about a day, when it makes one (Diagnostics → Reports From iOS).")
            + (note.episode.isEmpty ? "" : " The model gets one more try on this episode on its own, from the part it reached; if it closes PodSkipper there again, the episode waits for you to tap Find Ads Again.")
    }
}

/// Pass 43: whether iOS is short of memory while Core AI reads (his 19 Oct
/// phone: 22 closures, no crash report — what iOS leaves when it ends an
/// app for memory). Less than `floorMB` still allowed to PodSkipper before a
/// part stops the read at that part boundary; the episode stays owed its read.
///
/// Pass 44: a memory warning alone no longer stops it. Mapping Qwen3 4B's
/// 2.5 GB draws one from iOS while it loads, so on his 20 Oct phone every
/// Find Ads with it stopped before the first part with 6.6 GB still free.
/// A warning counts only once reading has begun and with under
/// `warnedFloorMB` left.
enum CoreAIMemory {
    static let floorMB = 300
    static let warnedFloorMB = 1_200
    private static let lastWarning = OSAllocatedUnfairLock<Date?>(initialState: nil)
    private static let observer: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { _ in
            lastWarning.withLock { $0 = .now }
        }

    /// Starts listening (once).
    static func watch() { _ = observer }

    /// Why to stop now, or nil. `start` is when reading began (after the
    /// model loaded). `os_proc_available_memory` is 0 where iOS doesn't say
    /// (the simulator), which isn't taken as short.
    static func short(since start: Date, available: Int = Int(os_proc_available_memory() / 1_048_576),
                      warned: Date? = nil) -> String? {
        guard available > 0 else { return nil }
        if available < floorMB { return "only \(available) MB of memory was left to PodSkipper" }
        if let warning = warned ?? lastWarning.withLock({ $0 }), warning >= start, available < warnedFloorMB {
            return "iOS said it was short of memory (\(available) MB left)"
        }
        return nil
    }
}

/// Pass 33: how often each Core AI model has taken PodSkipper down on this
/// iPhone (his 9 Oct Diagnostics: Qwen3 4B four times, Gemma 4 E2B three
/// times while loading, MiniCPM5 2B once). The model stays visible and
/// selectable; its row says what happened, a test of it asks first, and
/// work nobody asked for doesn't start it.
enum CoreAIStability {
    private static let key = "coreAI.closures"

    struct Record: Codable, Sendable, Equatable {
        var count: Int
        var last: Date
        /// Where it was: "loading", or the part and how far its answer got.
        var stage: String
        var duringTest: Bool
        /// Pass 43: the way Core AI ran models when these closures happened
        /// (`policy`); nil for closures before Pass 43.
        var policy: Int? = nil
    }

    /// Pass 43: Qwen3's GPU builds moved to the sequential engine, held under
    /// 2,048 tokens. Closures under the old way don't keep the model from
    /// the work it is chosen for; the row still tells them.
    static let policy = 43

    static func record(_ note: CoreAIInFlight.Note, at date: Date = .now, defaults: UserDefaults = .standard) {
        var all = load(defaults)
        var entry = all[note.id] ?? Record(count: 0, last: date, stage: "", duringTest: false)
        if entry.policy != policy { entry.count = 0 }
        entry.count += 1
        entry.last = date
        entry.stage = note.stage
        entry.duringTest = note.episode.isEmpty
        entry.policy = policy
        all[note.id] = entry
        save(all, defaults)
    }

    static func record(for id: String, defaults: UserDefaults = .standard) -> Record? { load(defaults)[id] }

    /// Closed the app at least twice, the last time within a fortnight: not
    /// started by work he didn't ask for. A finished read clears it.
    static func avoidForAutomaticWork(_ id: String, now: Date = .now, defaults: UserDefaults = .standard) -> Bool {
        guard let entry = record(for: id, defaults: defaults), entry.policy == policy else { return false }
        return entry.count >= 2 && now.timeIntervalSince(entry.last) < 14 * 86_400
    }

    /// A read that finished: the count starts again.
    static func completed(_ id: String, defaults: UserDefaults = .standard) {
        var all = load(defaults)
        guard all[id] != nil else { return }
        all[id] = nil
        save(all, defaults)
    }

    /// One plain sentence for the model's row.
    static func summary(for id: String, defaults: UserDefaults = .standard) -> String? {
        guard let entry = record(for: id, defaults: defaults) else { return nil }
        let times = entry.count == 1 ? "once" : "\(entry.count) times"
        let when = entry.last.formatted(.relative(presentation: .named))
        let what = entry.stage == "loading" ? "while loading" : (entry.duringTest ? "during a test" : "while reading an episode")
        return "Closed PodSkipper \(times) on this iPhone, last \(when) \(what)."
    }

    /// Pass 35: the question asked before testing a model that has closed
    /// the app. One run per answer: the request clears before it starts, and
    /// the bench refuses a second test while one is running.
    @MainActor
    static func confirmation(entry: CoreAIModelDescriptor, sample: BenchSample) -> Confirmation {
        let busy = ModelBench.shared.isRunning
        return Confirmation(
            title: entry.name + " closed PodSkipper before",
            message: (summary(for: entry.id) ?? "")
                + (busy ? " Another test is running; this one can start when it finishes."
                   : " If it happens again, PodSkipper closes and reopens without this result; your earlier results are kept."),
            actionTitle: busy ? "OK" : "Run Test Anyway", destructive: false) {
            guard !busy, !ModelBench.shared.isRunning else { return }
            ModelBench.shared.clearRequestError()
            ModelBench.shared.testCoreAI(entry, sample: sample)
        }
    }

    private static func load(_ defaults: UserDefaults) -> [String: Record] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
    }

    private static func save(_ all: [String: Record], _ defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
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

    /// Recorded at launch from the in-flight note. Pass 43: counted per
    /// episode, so the first closure leaves the model one more try of its
    /// own (his 19 Oct phone: after one closure the job that resumed kept
    /// an earlier result and called the episode finished, every time).
    static func remember(_ note: CoreAIInFlight.Note, defaults: UserDefaults = .standard) {
        guard !note.episode.isEmpty else { return }
        var all = defaults.dictionary(forKey: key) as? [String: [String: String]] ?? [:]
        let before = all[note.episode].flatMap { $0["model"] == note.id ? Int($0["count"] ?? "1") : nil } ?? 0
        all[note.episode] = ["model": note.id, "name": note.name, "stage": note.stage,
                             "date": ISO8601DateFormatter().string(from: .now), "count": String(before + 1)]
        defaults.set(all, forKey: key)
    }

    /// The model that closed the app on this episode, if it is the one
    /// about to read it again, and how many times (older notes: once).
    static func closedLastTime(model: String, episode: String, defaults: UserDefaults = .standard) -> (name: String, stage: String, count: Int)? {
        guard let entry = (defaults.dictionary(forKey: key) as? [String: [String: String]])?[episode],
              entry["model"] == model else { return nil }
        return (entry["name"] ?? model, entry["stage"] ?? "", Int(entry["count"] ?? "1") ?? 1)
    }

    /// Pass 43: closed it twice here — the model waits for him on this
    /// episode; once — it tries once more on its own.
    static let triesAfterClosing = 1

    /// He asked for this episode again: the model gets another try.
    static func forget(episode: String, defaults: UserDefaults = .standard) {
        guard var all = defaults.dictionary(forKey: key) as? [String: [String: String]], all[episode] != nil else { return }
        all[episode] = nil
        defaults.set(all, forKey: key)
    }
}
