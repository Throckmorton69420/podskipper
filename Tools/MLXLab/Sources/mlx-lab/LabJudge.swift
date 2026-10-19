import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXGuidedGeneration

/// Pass 43 lab: a whole episode read the way the app reads it — the
/// stretches it is told to read (LAB_ONLY, seconds, the app's focus ranges
/// computed by phone_judge.py), widened by 15 lines and planned into parts in
/// the model's own tokens, each part held to the answer's schema, a part that
/// runs out of room read again as two halves — with the instructions chosen
/// by LAB_VARIANT. Writes the cuts the parts name (before the app's cut
/// check) to LAB_OUT as [[start, end, kind, label, sponsor]].
///
/// Variants: `app` — the app's lean instructions as they ship (the
/// reference); any other name — `LabPrompts.system(variant)` and, when it
/// has one, `LabPrompts.reminder(variant)` after the stretch.
enum LabJudge {
    static let contextLines = 15

    static func run(context: ModelContext, show: String, title: String, lines: [TimedLine],
                    env: [String: String]) async throws {
        let variant = env["LAB_VARIANT"] ?? "app"
        let budget = env["LAB_BUDGET"].flatMap(Int.init) ?? 4_000
        let profile = JudgePrompt.Profile.lean
        let system = variant == "app" ? profile.system : LabPrompts.system(variant)
        let reminder = variant == "app" ? nil : LabPrompts.reminder(variant)
        let schema = variant == "app" ? profile.schema : LabPrompts.schema(variant)
        let cap = 8 * 60 + 16
        let step = LocalJudge.prefillStep

        // The stretches to read, widened as LocalJudge.segments does.
        var ranges: [Range<Int>] = []
        if let only = env["LAB_ONLY"], !only.isEmpty {
            for part in only.split(separator: ",") {
                let b = part.split(separator: "-").compactMap { Double($0) }
                guard b.count == 2, let first = lines.firstIndex(where: { $0.end >= b[0] }),
                      let last = lines.lastIndex(where: { $0.start <= b[1] }), first <= last else { continue }
                ranges.append(first..<(last + 1))
            }
        } else {
            ranges = [0..<lines.count]
        }
        let widened = ranges.map {
            Swift.max(0, $0.lowerBound - contextLines)..<Swift.min(lines.count, $0.upperBound + contextLines)
        }.sorted { $0.lowerBound < $1.lowerBound }
        var segments: [Range<Int>] = []
        for r in widened {
            if let last = segments.last, r.lowerBound <= last.upperBound {
                segments[segments.count - 1] = last.lowerBound..<Swift.max(last.upperBound, r.upperBound)
            } else {
                segments.append(r)
            }
        }
        let formatted = lines.indices.map { JudgePrompt.line($0, lines[$0], spans: []) }
        let counts = formatted.map { context.tokenizer.encode(text: $0 + "\n", addSpecialTokens: false).count }
        let parts = windows(tokenCounts: counts, segments: segments, budget: budget, overlap: budget / 8)

        func user(_ w: Range<Int>) -> String {
            var text = JudgePrompt.userLocal(show: show, title: title, notes: "", lines: lines, window: w, spans: [])
            if let reminder { text += "\n\n" + reminder }
            return text
        }
        func tokens(_ u: String) async throws -> [Int] {
            let prepared = try await context.processor.prepare(input: UserInput(
                chat: [.system(system), .user(u)], additionalContext: ["enable_thinking": false]))
            return prepared.text.tokens.reshaped([-1]).asArray(Int.self)
        }
        var prompts: [[Int]] = []
        for w in parts { prompts.append(try await tokens(user(w))) }
        let shared = PromptPrefixCache.sharedPrefix(prompts, step: step)
        var prefix: PromptPrefixCache?
        if let shared { prefix = try PromptPrefixCache.build(shared, model: context.model, stepSize: step) }

        let vocab = TokenizerVocabExtractor.extractForGrammar(from: context.tokenizer)
        let grammarTokenizer = try GrammarTokenizer(vocab: vocab.vocab, vocabType: vocab.vocabType,
                                                    eosTokenId: Int32(context.tokenizer.eosTokenId!))
        let closing = ClosingTokenBias.compute(tokenizer: context.tokenizer, eosTokenId: context.tokenizer.eosTokenId)
        let ws = WhitespaceTokenBias.compute(tokenizer: context.tokenizer)
        let reserve = CompletionReserve.estimate(schemaJSON: schema, tokenizer: context.tokenizer) + 40

        func read(_ prompt: [Int]) throws -> (text: String, outOfRoom: Bool, written: Int) {
            var input = LMInput(tokens: MLXArray(prompt.map { Int32($0) }))
            var loop = context
            if let prefix, let suffix = prefix.suffix(of: prompt) {
                input = LMInput(tokens: MLXArray(suffix.map { Int32($0) }))
                loop = ModelContext(configuration: context.configuration,
                                    model: PrefixedLanguageModel(base: context.model, prefix: prefix),
                                    processor: context.processor, tokenizer: context.tokenizer)
            }
            let constraint = try GrammarConstraint(tokenizer: grammarTokenizer, jsonSchema: schema,
                                                   fastForward: true, hostTokenizer: context.tokenizer)
            let prefill = PrefillParameters(stepSize: step, chunking: .remainder) { _, _ in }
            var text = ""
            var pieces = 0
            do {
                let written = try GuidedGenerationLoop.run(
                    input: input, context: loop, constraint: constraint, maxTokens: cap,
                    vocabSize: grammarTokenizer.vocabSize, kvBits: 8,
                    completionReserve: reserve, closingBias: closing, whitespaceBias: ws.bias,
                    whitespaceTokenIDs: ws.tokenIDs, prefill: prefill
                ) { delta in text += delta; pieces += 1; return true }
                return (text, false, written)
            } catch GuidedGenerationError.incompleteOutput {
                return (text, true, pieces)
            }
        }

        var found: [JudgePrompt.RawPart] = []
        var written = 0
        let started = Date()
        for (i, w) in parts.enumerated() {
            let r = try read(prompts[i])
            written += r.written
            if r.outOfRoom, w.count >= 6 {
                let middle = w.lowerBound + w.count / 2
                for half in [w.lowerBound..<middle, middle..<w.upperBound] {
                    let h = try read(try await tokens(user(half)))
                    written += h.written
                    found += JudgePrompt.shifted(JudgePrompt.parse(h.text) ?? [], window: half)
                }
            } else {
                found += JudgePrompt.shifted(JudgePrompt.parse(r.text) ?? [], window: w)
            }
            print("part \(i + 1)/\(parts.count) lines \(w.lowerBound)–\(w.upperBound - 1)\(r.outOfRoom ? " · out of room" : "") · " + r.text.prefix(300))
            MLX.Memory.clearCache()
        }
        var cuts: [[String]] = []
        for p in found {
            guard p.firstLine >= 0, p.lastLine < lines.count, p.firstLine <= p.lastLine else { continue }
            let kind: String?
            switch p.label {
            case .paidAd, .hostReadAd: kind = "ad"
            case .networkPromo: kind = "crossPromo"
            case .selfPromo, .guestPlug: kind = "selfPromo"
            case .intro: kind = "intro"
            case .outro, .credits: kind = "outro"
            default: kind = nil
            }
            guard let kind else { continue }
            cuts.append([String(lines[p.firstLine].start), String(lines[p.lastLine].end), kind, p.label.rawValue, p.sponsor])
        }
        print(String(format: "%d parts · wrote %d tokens · %.0f s · %d cuts", parts.count, written,
                     Date().timeIntervalSince(started), cuts.count))
        if let out = env["LAB_OUT"] {
            try JSONSerialization.data(withJSONObject: cuts).write(to: URL(fileURLWithPath: out))
        }
    }
}
