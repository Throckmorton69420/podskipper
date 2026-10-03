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

        var errorDescription: String? {
            switch self {
            case .notDownloaded:
                return "The selected Core AI model isn't downloaded yet."
            case .needsForeground:
                return "Core AI ad detection needs PodSkipper open on screen."
            case .unavailable(let message), .failed(let message):
                return message
            }
        }
    }

    private let maxWindowCharacters = 9_500
    private let overlapCharacters = 1_000
    private let maxAnswerTokens = 512

    func judgeReport(
        lines: [TimedLine],
        show: String,
        title: String,
        notes: String,
        evidence: [EvidenceSpan],
        corrections: String,
        modelID: String? = nil,
        progress: @escaping @Sendable (Double) -> Void,
        status: @escaping @Sendable (String) -> Void = { _ in },
        requireCompleteAnswer: Bool = false,
        expectedModel: CoreAIModelDescriptor? = nil
    ) async throws -> JudgeReport {
        #if !targetEnvironment(simulator)
        let maxAnswerTokens = requireCompleteAnswer ? CoreAIClassifierSession.maxAnswerTokens : self.maxAnswerTokens
        guard !lines.isEmpty else {
            return JudgeReport(parts: [], failedLines: [], stats: JudgeStats(model: "Core AI"))
        }

        guard await canRun() else {
            throw JudgeError.needsForeground
        }

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
        status("Loading " + entry.name)
        let availableBeforeLoad = Int(os_proc_available_memory())
        let loadStarted = Date.now
        let classifier: CoreAIClassifierSession?
        let chat: ChatSession?
        do {
            // The guided runtime is being evaluated by benchmarks. Its Mac
            // probes complete but fail classification quality; do not promote
            // that path into episode cutting before quality acceptance.
            if requireCompleteAnswer && CoreAIClassifierSession.supports(id) {
                guard let cached = await CoreAIModelLibrary.shared.cachedBundle(for: id) else {
                    throw JudgeError.notDownloaded
                }
                classifier = try await CoreAIClassifierSession(bundleAt: cached.url, engineHint: cached.engineHint)
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

        let formatted = lines.indices.map { JudgePrompt.line($0, lines[$0], spans: evidence) }
        let windows = makeWindows(formatted)
        await MainActor.run {
            LocalJudgeMonitor.shared.started()
            LocalJudgeMonitor.shared.planned(windows.count)
        }

        var stats = JudgeStats(model: entry.name)
        stats.availableBeforeLoad = availableBeforeLoad
        stats.loadSeconds = Date.now.timeIntervalSince(loadStarted)
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

                let user = JudgePrompt.user(
                    show: show,
                    title: title,
                    notes: notes,
                    lines: lines,
                    window: window,
                    formatted: formatted,
                    corrections: corrections
                )

                var parsed: [JudgePrompt.RawPart]?
                var lastError: Error?

                // Each transcript window is an independent classification problem.
                // ChatSession normally retains history for multi-turn chat, which would
                // otherwise make later windows grow the context with earlier windows.
                await chat?.reset()

                for attempt in 0..<2 where parsed == nil {
                    do {
                        if attempt > 0 { await chat?.reset() }
                        let windowStarted = Date.now
                        status("Reading sample · part \(index + 1) of \(windows.count)")
                        let answer: String
                        let generatedTokens: Int
                        if let classifier {
                            let response = try await classifier.respond(system: JudgePrompt.system, user: user,
                                                                        schema: JudgePrompt.schema, status: status)
                            stats.constrained = true
                            answer = response.text
                            generatedTokens = response.generatedTokens
                            stats.promptTokens += response.promptTokens
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
                                    status(reasoningCharacters > 0 && text.isEmpty
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
                        parsed = requireCompleteAnswer ? JudgePrompt.parseComplete(answer) : JudgePrompt.parse(answer)
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

                if let parsed {
                    found += parsed.compactMap { JudgePrompt.resolve($0, lines: lines) }
                } else {
                    failed.append(window.lowerBound...(window.upperBound - 1))
                    stats.failureDetails = lastError?.localizedDescription ?? "The model returned no classification."
                    if let lastError {
                        await BackgroundLog.shared.note("Core AI ad judge window failed: \(lastError.localizedDescription)")
                    }
                }

                let done = Double(index + 1) / Double(max(1, windows.count))
                let wordCount = lines[window].reduce(0) {
                    $0 + $1.text.split(whereSeparator: \.isWhitespace).count
                }
                let elapsed = Date.now.timeIntervalSince(started)
                let speed = elapsed > 0 ? Double(wordCount) / elapsed : 0
                await MainActor.run {
                    LocalJudgeMonitor.shared.advanced(done, done: index + 1, wordsPerSecond: speed)
                }
                progress(done)
            }

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
