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
    /// Tokens read (prompts) and the time spent reading them.
    var promptTokens = 0
    var promptSeconds = 0.0
    /// Tokens written (answers) and the time spent writing them.
    var generatedTokens = 0
    var generateSeconds = 0.0
    var loadSeconds = 0.0
    /// Windows read on the CPU because the app was in the background.
    var cpuWindows = 0
    /// Whether answers were held to the JSON schema while being written.
    var constrained = false
    var peakMemoryBytes = 0
    var finishedAt = Date.distantPast

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

    fileprivate func started() { isRunning = true; progress = 0; lastError = nil }
    fileprivate func advanced(_ value: Double) { progress = value }
    fileprivate func finished(_ stats: JudgeStats?, error: String?) {
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
/// Background: iOS gives a sideloaded app no GPU while it isn't on screen.
/// PrismML's MLX fork does run its 1-bit matrix kernels on the CPU, so a
/// window read while the app is in the background runs on the CPU, and the
/// next one read with the app open goes back to the GPU. See the PR for the
/// evidence and what is unconfirmed (the CPU speed).
actor LocalJudge {
    static let shared = LocalJudge()

    // Window sizes are per model (`LocalModelSpec.windowTokens8B` etc.):
    // tokens per window, and how many the next window repeats so a part cut
    // by a window edge is still seen whole once.

    /// Lines read either side of each range in the "check the suspicious
    /// stretches" mode.
    static let contextLines = 40
    /// The answer is a short JSON list; this stops a runaway one.
    static let maxAnswerTokens = 1_536
    /// The attention cache in 8 bits: half the memory of full precision,
    /// which is what lets an 8B model read a 12,000-token window on an 8 GB
    /// phone, for a loss too small to change a JSON answer.
    static let kvBits = 8
    /// Low: the job loads, runs and lets go, so there is nothing worth
    /// caching between windows, and the memory is better left free.
    static let gpuCacheLimit = 64 * 1024 * 1024

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
    ///   - progress: fraction of windows done.
    /// - Throws: `JudgeError.someWindowsFailed` carrying what was found when
    ///   a window couldn't be read; the other errors when nothing could run.
    func judge(lines: [TimedLine], show: String, title: String, notes: String,
               evidence: [EvidenceSpan], only ranges: [Range<Int>]?,
               progress: @escaping @Sendable (Double) -> Void) async throws -> [JudgedPart] {
        let report = try await judgeReport(lines: lines, show: show, title: title, notes: notes,
                                           evidence: evidence, only: ranges, progress: progress)
        if !report.failedLines.isEmpty {
            throw JudgeError.someWindowsFailed(found: report.parts, failedLines: report.failedLines)
        }
        return report.parts
    }

    func judgeReport(lines: [TimedLine], show: String, title: String, notes: String,
                     evidence: [EvidenceSpan], only ranges: [Range<Int>]?,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> JudgeReport {
        let (spec, folder) = await MainActor.run { (ModelStore.shared.selected, ModelStore.shared.readyFolder) }
        var stats = JudgeStats(model: spec.name)
        guard !lines.isEmpty else { return JudgeReport(parts: [], failedLines: [], stats: stats) }
        guard let folder else { throw JudgeError.notDownloaded }

        // Refuse up front rather than be killed by iOS half way through loading.
        let available = os_proc_available_memory()
        guard available >= Int(spec.memoryNeeded) else {
            throw JudgeError.notEnoughMemory(available: available, needed: Int(spec.memoryNeeded))
        }

        await MainActor.run { LocalJudgeMonitor.shared.started() }
        Memory.cacheLimit = Self.gpuCacheLimit
        // The model lives only inside `run`; once it returns, its memory can go.
        defer { Memory.clearCache() }
        do {
            let report = try await run(lines: lines, show: show, title: title, notes: notes,
                                       evidence: evidence, ranges: ranges, folder: folder,
                                       spec: spec, stats: &stats, progress: progress)
            let final = report.stats
            await MainActor.run { LocalJudgeMonitor.shared.finished(final, error: nil) }
            return report
        } catch {
            let message = error.localizedDescription
            let partial = stats
            await MainActor.run { LocalJudgeMonitor.shared.finished(partial.windows > 0 ? partial : nil, error: message) }
            throw error
        }
    }

    private func run(lines: [TimedLine], show: String, title: String, notes: String,
                     evidence: [EvidenceSpan], ranges: [Range<Int>]?, folder: URL,
                     spec: LocalModelSpec, stats: inout JudgeStats,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> JudgeReport {
        Memory.peakMemory = 0

        // Load on whichever processor is allowed right now. An MLX error
        // (including the GPU being refused in the background) becomes a Swift
        // error here instead of ending the app.
        let loadStart = Date.now
        let startsInBackground = await Self.inBackground()
        let context: ModelContext
        do {
            context = try await withError {
                try await Device.withDefaultDevice(startsInBackground ? Device.cpu : Device.gpu) {
                    try await LLMModelFactory.shared.load(from: folder, using: LocalTokenizerLoader())
                }
            }
        } catch {
            throw JudgeError.loadFailed(error.localizedDescription)
        }
        stats.loadSeconds = Date.now.timeIntervalSince(loadStart)

        // Every line formatted once; windows are planned in the model's own tokens.
        let formatted = lines.indices.map { JudgePrompt.line($0, lines[$0], spans: evidence) }
        let tokenCounts = formatted.map { context.tokenizer.encode(text: $0 + "\n", addSpecialTokens: false).count }
        let windows = Self.windows(tokenCounts: tokenCounts,
                                   segments: Self.segments(ranges, lineCount: lines.count),
                                   budget: spec.windowTokens, overlap: spec.overlapTokens)
        stats.windows = windows.count

        // The answer held to the schema while it is written, when the grammar
        // engine takes it; otherwise free text read leniently.
        let grammar = Self.grammarTokenizer(for: context)
        stats.constrained = grammar != nil

        var found: [JudgedPart] = []
        var failed: [ClosedRange<Int>] = []
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            let user = JudgePrompt.user(show: show, title: title, notes: notes, lines: lines,
                                        window: window, formatted: formatted)
            var parts: [JudgePrompt.RawPart]?
            // One retry, and the retry writes freely: a constrained answer is
            // greedy, so asking the same way again would give the same text.
            for attempt in 0..<2 where parts == nil {
                let background = await Self.inBackground()
                if background { stats.cpuWindows += 1 }
                do {
                    let answer = try await ask(context: context, system: JudgePrompt.system, user: user,
                                               grammar: attempt == 0 ? grammar : nil, onCPU: background)
                    stats.promptTokens += answer.promptTokens
                    stats.promptSeconds += answer.promptSeconds
                    stats.generatedTokens += answer.generatedTokens
                    stats.generateSeconds += answer.generateSeconds
                    parts = JudgePrompt.parse(answer.text)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Typically the GPU refused because the app just went to the
                    // background; the retry runs on the CPU.
                    parts = nil
                }
            }
            if let parts {
                found += parts.compactMap { JudgePrompt.resolve($0, lines: lines) }
            } else {
                failed.append(window.lowerBound...(window.upperBound - 1))
            }
            stats.failedWindows = failed.count
            let done = Double(index + 1) / Double(Swift.max(1, windows.count))
            progress(done)
            await MainActor.run { LocalJudgeMonitor.shared.advanced(done) }
        }

        stats.peakMemoryBytes = Memory.peakMemory
        stats.finishedAt = .now
        return JudgeReport(parts: Self.merge(found), failedLines: failed, stats: stats)
    }

    /// What one prompt cost, and the answer.
    private struct Answer {
        var text = ""
        var promptTokens = 0
        var promptSeconds = 0.0
        var generatedTokens = 0
        var generateSeconds = 0.0
    }

    /// One prompt, one answer.
    private func ask(context: ModelContext, system: String, user: String, grammar: GrammarTokenizer?,
                     onCPU: Bool) async throws -> Answer {
        // On the CPU, Qwen3.5's linear-attention step must not use its custom
        // Metal kernel (MLX refuses custom kernels off the GPU). mlx-swift-lm
        // uses the plain-ops version of that step when the module is in
        // training mode, and nothing else in these models reads the flag.
        context.model.train(onCPU)
        return try await withError {
            try await Device.withDefaultDevice(onCPU ? Device.cpu : Device.gpu) {
                // Thinking off: the answer is short, and a reasoning model
                // would otherwise spend the token budget before answering.
                let input = try await context.processor.prepare(input: UserInput(
                    chat: [.system(system), .user(user)],
                    additionalContext: ["enable_thinking": false]))
                var answer = Answer()
                answer.promptTokens = input.text.tokens.size

                if let grammar {
                    let constraint = try GrammarConstraint(tokenizer: grammar, jsonSchema: JudgePrompt.schema,
                                                           fastForward: true, hostTokenizer: context.tokenizer)
                    var text = ""
                    var firstToken: Date?
                    let started = Date.now
                    let written = try GuidedGenerationLoop.run(
                        input: input, context: context, constraint: constraint,
                        maxTokens: Self.maxAnswerTokens, vocabSize: grammar.vocabSize,
                        kvBits: Self.kvBits
                    ) { delta in
                        if firstToken == nil { firstToken = .now }
                        text += delta
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

                let parameters = GenerateParameters(maxTokens: Self.maxAnswerTokens, kvBits: Self.kvBits,
                                                    temperature: 0.2, topP: 0.95, topK: 20)
                let stream = try MLXLMCommon.generate(input: input, parameters: parameters, context: context)
                for await item in stream {
                    switch item {
                    case .chunk(let piece):
                        answer.text += piece
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
