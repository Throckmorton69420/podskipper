import Darwin
import Foundation
import UIKit
import CoreAIKit

/// Contextual ad judge backed by the selected Core AI catalog model.
///
/// The deterministic reader still runs first. This judge then reads the transcript
/// in bounded windows and uses the same benchmarked JudgePrompt rules/schema as the
/// MLX path. CoreAIKit owns model download, device-variant selection and caching.
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
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> JudgeReport {
        guard !lines.isEmpty else {
            return JudgeReport(parts: [], failedLines: [], stats: JudgeStats(model: "Core AI"))
        }

        guard UIApplication.shared.applicationState == .active || SignedEntitlements.backgroundGPU else {
            throw JudgeError.needsForeground
        }

        let id = await MainActor.run { CoreAIModelLibrary.shared.selectedID }
        guard let entry = await MainActor.run(resultType: CatalogEntry?.self) {
            CoreAIModelLibrary.shared.entries.first { $0.id == id }
        } else {
            throw JudgeError.unavailable("Core AI model \(id) isn't in the current catalog.")
        }
        guard entry.modelID != nil else {
            throw JudgeError.unavailable("\(entry.name) has no iOS model bundle.")
        }
        guard await MainActor.run(resultType: Bool.self) { CoreAIModelLibrary.shared.isDownloaded(entry) } else {
            throw JudgeError.notDownloaded
        }

        var configuration = ChatSession.Configuration()
        configuration.temperature = nil
        configuration.maxResponseTokens = maxAnswerTokens
        configuration.systemPrompt = JudgePrompt.system
        let chat: ChatSession
        do {
            chat = try await ChatSession(catalog: id, configuration: configuration)
        } catch {
            throw JudgeError.failed("Couldn't load \(entry.name): \(error.localizedDescription)")
        }

        let formatted = lines.indices.map { JudgePrompt.line($0, lines[$0], spans: evidence) }
        let windows = makeWindows(formatted)
        await MainActor.run {
            LocalJudgeMonitor.shared.started()
            LocalJudgeMonitor.shared.planned(windows.count)
        }

        var stats = JudgeStats(model: entry.name)
        stats.availableBeforeLoad = Int(os_proc_available_memory())
        var found: [JudgedPart] = []
        var failed: [ClosedRange<Int>] = []
        let started = Date.now
        stats.windows = windows.count

        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            guard UIApplication.shared.applicationState == .active || SignedEntitlements.backgroundGPU else {
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
            await chat.reset()

            for attempt in 0..<2 where parsed == nil {
                do {
                    if attempt > 0 { await chat.reset() }
                    let windowStarted = Date.now
                    let answer = try await chat.respond(to: user)
                    let elapsed = Date.now.timeIntervalSince(windowStarted)
                    let usage = await chat.stats
                    stats.promptTokens += usage.promptTokens
                    let promptSeconds = usage.ttftSeconds ?? 0
                    stats.promptSeconds += promptSeconds
                    stats.generatedTokens += usage.generatedTokens
                    stats.generateSeconds += max(0, elapsed - promptSeconds)
                    stats.answerSample = String(answer.prefix(600))
                    parsed = JudgePrompt.parse(answer)
                    stats.partsParsed += parsed?.count ?? 0
                    lastError = nil
                } catch {
                    lastError = error
                }
            }

            if let parsed {
                found += parsed.compactMap { JudgePrompt.resolve($0, lines: lines) }
            } else {
                failed.append(window.lowerBound...(window.upperBound - 1))
                if let lastError {
                    BackgroundLog.shared.note("Core AI ad judge window failed: \(lastError.localizedDescription)")
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

        await MainActor.run {
            LocalJudgeMonitor.shared.finished(stats, error: failed.isEmpty ? nil : "Some Core AI windows could not be read.")
        }

        return JudgeReport(
            parts: ModelFinderMerge.merge(found),
            failedLines: failed,
            stats: stats
        )
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
