import Foundation
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon
import MLXGuidedGeneration

/// Pass 40 MLX lab: the app's MLX read path on his transcripts.
///
///   mlx-lab <model folder> <results.json> <episode index> <mode>
///   LAB_ONLY="4600-5228,2100-2450"   stretches to read (seconds)
///   LAB_BUDGET=3300                   transcript tokens per part
///   LAB_STEP=256                      prefill chunk (prefix aligned to it)
///   LAB_CAP=320                       answer tokens (lean profile)
/// Modes: compare — each part read whole and from the shared prefix, the
/// two answers compared token for token; split — a part whose answer runs
/// out of room is read again as two halves (the app's Pass 40 rule).
@main
struct MLXLab {
    struct Episode: Decodable { var show: String; var title: String; var transcript: [TimedLine] }
    struct Results: Decodable { var episodes: [Episode] }

    struct Read { var sampled = 0; var forced = 0; var whitespace = 0; var text = ""; var tokens = 0; var prompt = 0; var promptSeconds = 0.0; var writeSeconds = 0.0; var outOfRoom = false }

    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let args = CommandLine.arguments
        guard args.count >= 5 else { print("usage: mlx-lab <model> <results.json> <episode> <compare|split>"); return }
        let env = ProcessInfo.processInfo.environment
        let results = try JSONDecoder().decode(Results.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let episode = results.episodes[Int(args[3])!]
        let mode = args[4]
        let lines = episode.transcript
        let budget = env["LAB_BUDGET"].flatMap(Int.init) ?? 3_300
        let cap = env["LAB_CAP"].flatMap(Int.init) ?? JudgePrompt.Profile.lean.answerTokens
        let step = LocalJudge.prefillStep
        Memory.cacheLimit = 64 * 1024 * 1024   // the app's gpuCacheLimit

        let loadStart = Date()
        let context = try await LLMModelFactory.shared.load(from: URL(fileURLWithPath: args[1]), using: LocalTokenizerLoader())
        print("\(episode.show) · \(episode.title) · \(lines.count) lines · model loaded in \(String(format: "%.1f", Date().timeIntervalSince(loadStart))) s · step \(step) · cap \(cap)")

        var segments = [0..<lines.count]
        if let only = env["LAB_ONLY"] {
            segments = only.split(separator: ",").compactMap { part in
                let b = part.split(separator: "-").compactMap { Double($0) }
                guard b.count == 2, let first = lines.firstIndex(where: { $0.end >= b[0] }),
                      let last = lines.lastIndex(where: { $0.start <= b[1] }), first <= last else { return nil }
                return first..<(last + 1)
            }
        }
        let formatted = lines.indices.map { JudgePrompt.line($0, lines[$0], spans: []) }
        let counts = formatted.map { context.tokenizer.encode(text: $0 + "\n", addSpecialTokens: false).count }
        let parts = windows(tokenCounts: counts, segments: segments, budget: budget, overlap: min(800, budget / 8))
        let profile = JudgePrompt.Profile.lean
        let system = profile.system
        func user(_ w: Range<Int>) -> String {
            JudgePrompt.userLocal(show: episode.show, title: episode.title, notes: "", lines: lines, window: w, spans: [])
        }
        func tokens(_ u: String) async throws -> [Int] {
            let prepared = try await context.processor.prepare(input: UserInput(
                chat: [.system(system), .user(u)], additionalContext: ["enable_thinking": false]))
            return prepared.text.tokens.reshaped([-1]).asArray(Int.self)
        }
        var prompts: [[Int]] = []
        for w in parts { prompts.append(try await tokens(user(w))) }
        let shared = PromptPrefixCache.sharedPrefix(prompts, step: step)
        print("\(parts.count) parts · prompts \(prompts.map(\.count)) · shared prefix \(shared?.count ?? 0)")

        let vocab = TokenizerVocabExtractor.extractForGrammar(from: context.tokenizer)
        let grammarTokenizer = try GrammarTokenizer(vocab: vocab.vocab, vocabType: vocab.vocabType,
                                                    eosTokenId: Int32(context.tokenizer.eosTokenId!))
        let closing = ClosingTokenBias.compute(tokenizer: context.tokenizer, eosTokenId: context.tokenizer.eosTokenId)
        let ws = WhitespaceTokenBias.compute(tokenizer: context.tokenizer)
        let reserve = CompletionReserve.estimate(schemaJSON: profile.schema, tokenizer: context.tokenizer) + 40

        func read(_ prompt: [Int], prefix: PromptPrefixCache?, compact: Bool = env["LAB_COMPACT"] == "1") throws -> Read {
            var r = Read()
            var input = LMInput(tokens: MLXArray(prompt.map { Int32($0) }))
            var loop = context
            if let prefix, let suffix = prefix.suffix(of: prompt) {
                input = LMInput(tokens: MLXArray(suffix.map { Int32($0) }))
                loop = ModelContext(configuration: context.configuration,
                                    model: PrefixedLanguageModel(base: context.model, prefix: prefix),
                                    processor: context.processor, tokenizer: context.tokenizer)
            }
            r.prompt = input.text.tokens.size
            let constraint = compact
                ? try GrammarConstraint(tokenizer: grammarTokenizer, grammar: env["LAB_SPACED"] == "1" ? JudgePrompt.compactGrammar(maxParts: 8, labels: ["PAID_AD", "HOST_READ_AD", "NETWORK_PROMO", "SELF_PROMO", "GUEST_PLUG", "INTRO", "OUTRO", "CREDITS", "MOCK_AD", "SHOW"], sponsor: 40, why: nil, funny: true, spaced: true) : JudgePrompt.compactGrammar(maxParts: 8, labels: ["PAID_AD", "HOST_READ_AD", "NETWORK_PROMO", "SELF_PROMO", "GUEST_PLUG", "INTRO", "OUTRO", "CREDITS", "MOCK_AD", "SHOW"], sponsor: 40, why: nil, funny: true),
                                        fastForward: true, hostTokenizer: context.tokenizer)
                : try GrammarConstraint(tokenizer: grammarTokenizer, jsonSchema: profile.schema,
                                        fastForward: true, hostTokenizer: context.tokenizer)
            let prefill = PrefillParameters(stepSize: step, chunking: .remainder) { _, _ in }
            let started = Date()
            var first: Date?
            var pieces = 0
            let sink = GuidedGenerationDiagnosticSink()
            defer {
                r.sampled = sink.sampledTokenIDs.count; r.forced = sink.fastForwardTokenIDs.count
                r.whitespace = sink.sampledTokenIDs.filter { ws.tokenIDs.contains($0) }.count
            }
            do {
                r.tokens = try GuidedGenerationDiagnosticSink.$current.withValue(sink) { try GuidedGenerationLoop.run(
                    input: input, context: loop, constraint: constraint, maxTokens: cap,
                    vocabSize: grammarTokenizer.vocabSize, kvBits: 8,
                    completionReserve: reserve, closingBias: closing, whitespaceBias: ws.bias,
                    whitespaceTokenIDs: ws.tokenIDs, prefill: prefill
                ) { delta in
                    if first == nil { first = Date() }
                    r.text += delta; pieces += 1
                    return true
                } }
            } catch GuidedGenerationError.incompleteOutput {
                r.outOfRoom = true; r.tokens = pieces
            }
            r.promptSeconds = (first ?? Date()).timeIntervalSince(started)
            r.writeSeconds = Date().timeIntervalSince(started) - r.promptSeconds
            return r
        }
        func show(_ label: String, _ r: Read) {
            print(String(format: "  %@: read %d in %.1f s (%.0f tok/s) · wrote %d in %.1f s (sampled %d, forced %d, whitespace %d)%@ · %@", label, r.prompt, r.promptSeconds,
                         Double(r.prompt) / max(0.01, r.promptSeconds), r.tokens, r.writeSeconds, r.sampled, r.forced, r.whitespace,
                         r.outOfRoom ? " · RAN OUT OF ROOM" : "", String(r.text.prefix(400))))
        }

        var prefix: PromptPrefixCache?
        if let shared {
            let t = Date()
            prefix = try PromptPrefixCache.build(shared, model: context.model, stepSize: step)
            print(String(format: "prefix %d tokens read in %.1f s", shared.count, Date().timeIntervalSince(t)))
        }
        let limit = env["LAB_PARTS"].flatMap(Int.init) ?? parts.count
        var same = 0, compared = 0, schemaTokens = 0, compactTokens = 0
        for (i, w) in parts.prefix(limit).enumerated() {
            print("part \(i + 1): lines \(w.lowerBound)–\(w.upperBound - 1) (\(Int(lines[w.lowerBound].start))–\(Int(lines[w.upperBound - 1].end)) s), \(prompts[i].count) tokens")
            switch mode {
            case "format":
                let schema = try read(prompts[i], prefix: prefix, compact: false)
                show("schema ", schema)
                let compact = try read(prompts[i], prefix: prefix, compact: true)
                show("compact", compact)
                func key(_ r: Read) -> [String] {
                    (JudgePrompt.parse(r.text) ?? []).map { "\($0.firstLine)-\($0.lastLine) \($0.label.rawValue) \($0.sponsor.lowercased())" }
                }
                let a = key(schema), b = key(compact)
                compared += 1
                schemaTokens += schema.tokens; compactTokens += compact.tokens
                if a == b { same += 1 } else { print("  PARTS DIFFER\n    schema : \(a)\n    compact: \(b)") }
            case "compare":
                let whole = try read(prompts[i], prefix: nil)
                show("whole ", whole)
                let kept = try read(prompts[i], prefix: prefix)
                show("prefix", kept)
                compared += 1
                if whole.text == kept.text { same += 1 } else { print("  DIFFERENT") }
            default:
                let r = try read(prompts[i], prefix: prefix)
                show("held  ", r)
                if r.outOfRoom {
                    let middle = w.lowerBound + w.count / 2
                    for (h, half) in [w.lowerBound..<middle, middle..<w.upperBound].enumerated() {
                        let hr = try read(try await tokens(user(half)), prefix: prefix)
                        show("half \(h + 1)", hr)
                    }
                }
            }
            MLX.Memory.clearCache()
        }
        if mode == "compare" { print("identical answers: \(same) of \(compared)") }
        if mode == "format" { print("same parts: \(same) of \(compared) · answer tokens schema \(schemaTokens) → compact \(compactTokens)") }
    }
}
