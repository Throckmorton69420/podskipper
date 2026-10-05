import Foundation

/// Keep room for a useful classification, without rejecting a prompt merely
/// because the preferred maximum answer would not fit. Unknown context limits
/// retain the runtime's own enforcement.
enum ClassificationTokenBudget {
    static let preferredAnswer = 2_048
    static let minimumAnswer = 256
    static func answerTokens(input: Int, capacity: Int, minimum: Int = minimumAnswer) -> Int? {
        guard input >= 0 else { return nil }
        guard capacity > 0 else { return preferredAnswer }
        let available = capacity - input - 1 // leave room for the end token
        return available >= minimum ? min(preferredAnswer, available) : nil
    }
}

/// Pass 30: what a Core AI bundle can hold and run on this iPhone, worked
/// out from the catalog's own description of it — no package types, so the
/// simulator build and the tests can use it.
enum CoreAIBundleLimits {
    /// Apple's iOS compiler miscompiles the GPU "pipelined" engine's growing
    /// memory at 2,048 tokens and above, so CoreAIKit caps those bundles at
    /// 1,024 tokens of prompt and answer together on iPhone
    /// (apple/coreai-models#124). His 5 Oct tests: Granite, LFM2.5,
    /// MiniCPM5 and Nanbeige all stopped with "position 0 >= max context
    /// length 1024" because the prompt alone was longer.
    static let iOSPipelinedCap = 1_024

    static func isPipelined(engineHint: String?, path: String) -> Bool {
        engineHint == "pipelined" || path.contains("gpu-pipelined") || path.contains("_decode_")
    }

    static func usableContext(bundleContext: Int, engineHint: String?, path: String, iOS: Bool = true) -> Int {
        guard iOS, isPipelined(engineHint: engineHint, path: path) else { return bundleContext }
        return bundleContext > 0 ? min(bundleContext, iOSPipelinedCap) : iOSPipelinedCap
    }

    /// The chip an ahead-of-time-compiled bundle was built for ("h18p" is
    /// the iPhone 17 Pro's), or nil for a portable bundle the phone compiles
    /// itself. His 5 Oct phone: Gemma 4 E2B (`…_aotc_h18p`) and Nemotron 3
    /// Nano (`ios-h18p/…`) failed to load with AIModelError 0 on an iPhone
    /// 16 Pro (iPhone17,1).
    static func aotChip(_ path: String) -> String? {
        guard let range = path.range(of: #"(?<![a-z0-9])h1[0-9]p?(?![a-z0-9])"#, options: .regularExpression)
        else { return nil }
        return String(path[range])
    }

    /// Whether this phone can run a bundle compiled for `chip`. A chip tag
    /// follows the phone's model number: "h18p" is iPhone18,x Pro.
    static func runs(chip: String?, machine: String) -> Bool {
        guard let chip else { return true }
        guard machine.hasPrefix("iPhone"),
              let chipNumber = Int(chip.dropFirst().prefix { $0.isNumber }),
              let phone = Int(machine.drop { !$0.isNumber }.prefix { $0.isNumber }) else { return false }
        return phone == chipNumber
    }

    /// "iPhone 17 Pro" for "h18p", for the reason shown on the model's row.
    static func phoneName(chip: String) -> String {
        let number = Int(chip.dropFirst().prefix { $0.isNumber }) ?? 0
        return "iPhone \(number - 1)" + (chip.hasSuffix("p") ? " Pro" : "")
    }
}
#if !targetEnvironment(simulator)
import CoreAIKit
import CoreAILanguageModels
import Tokenizers

/// The kit's chat API does not expose chat-template options. Classification
/// needs the model's non-thinking template, rather than spending its answer
/// budget on hidden reasoning. Keep catalog downloads and engine selection;
/// run the public runtime directly.
///
/// Pass 30 (his 5 Oct phone: Qwen3 4B took 25 min on a 66-min episode):
/// - every catalog model comes through here, held to the JSON schema, so a
///   small model can't write an answer that doesn't parse;
/// - engines that hand back each step's scores (the static-shape engine Qwen3
///   4B uses) are driven directly: the grammar is built once per load, not
///   once per part, the answer is written without spaces and line breaks,
///   and the prompt the parts share (rules, show, notes) is read once and
///   kept, so each part reads only its own lines;
/// - the GPU-pipelined engines keep the runtime's own constrained decoder.
@available(iOS 27, macOS 27, *)
actor CoreAIClassifierSession {
    struct Answer: Sendable {
        var text = ""
        var promptTokens = 0
        var generatedTokens = 0
        var promptSeconds = 0.0
        var generateSeconds = 0.0
        /// Prompt tokens kept from the part before instead of read again.
        var reusedTokens = 0
    }

    enum ClassificationError: LocalizedError {
        case contextCapacity(String)
        case noScores
        var errorDescription: String? {
            switch self {
            case .contextCapacity(let message): return message
            case .noScores: return "The model returned no scores for its next word."
            }
        }
    }

    private let engine: any InferenceEngine
    private let tokenizer: any Tokenizer
    /// Tokens this model can hold here (prompt + answer); 0 if unknown.
    /// On iPhone a GPU-pipelined bundle holds 1,024 whatever it was built for.
    let contextLimit: Int
    /// The bundle's own context, before the iPhone cap.
    let bundleContext: Int
    let pipelined: Bool
    static let maxAnswerTokens = ClassificationTokenBudget.preferredAnswer

    /// The prompt of the part before, to keep what this one shares with it.
    private var lastPrompt: [Int32] = []
    /// How the last part's prompt reuse went, for the lab.
    private(set) var reuseNote = ""
    private var grammars: [String: CompiledGrammar] = [:]
    private var tokenizerInfo: TokenizerInfo?
    private var vocabularySize = 0
    private var stopTokens: Set<Int32> = []

    /// Tokens in plain text, as the model counts them.
    func tokenCount(_ text: String) -> Int {
        tokenizer.encode(text: text, addSpecialTokens: false).count
    }

    /// Tokens the full chat-templated prompt takes, thinking off.
    func promptTokenCount(system: String, user: String) throws -> Int {
        try template(system: system, user: user).count
    }

    private func template(system: String, user: String) throws -> [Int] {
        try tokenizer.applyChatTemplate(
            messages: [["role": "system", "content": system], ["role": "user", "content": user]],
            tools: nil, additionalContext: ["enable_thinking": false])
    }

    /// Pass 30: every catalog chat model (it was Qwen3 and Nemotron only).
    static func supports(_ id: String) -> Bool { true }

    init(bundleAt url: URL, engineHint: String?) async throws {
        // Decode-only zoo ports accept one prefill token per step, as in
        // CoreAIKit 0.7.3's ModelRuntime. Preserve an explicit runtime override.
        if (engineHint == "pipelined" || url.lastPathComponent.contains("_decode_")),
           getenv("COREAI_CHUNK_THRESHOLD") == nil {
            setenv("COREAI_CHUNK_THRESHOLD", "1", 1)
        }
        let bundle = try LanguageBundle(at: url)
        let variant: String?
        switch engineHint {
        case "pipelined": variant = "coreai-pipelined"
        case "sequential": variant = "coreai-sequential"
        case "static-shape": variant = "static-shape"
        default: variant = nil
        }
        let runner = CoreAIRunner(bundle: bundle, variant: variant)
        async let loadedEngine = runner.makeInferenceEngine()
        async let loadedTokenizer = bundle.loadTokenizer()
        (engine, tokenizer) = try await (loadedEngine, loadedTokenizer)
        bundleContext = bundle.maxContextLength
        pipelined = CoreAIBundleLimits.isPipelined(engineHint: engineHint, path: url.path)
        #if os(iOS)
        let iOS = true
        #else
        let iOS = ProcessInfo.processInfo.environment["COREAI_LAB_IOS_CAP"] == "1"
        #endif
        contextLimit = CoreAIBundleLimits.usableContext(bundleContext: bundle.maxContextLength,
                                                        engineHint: engineHint, path: url.path, iOS: iOS)
    }

    func respond(system: String, user: String, schema: String, maxAnswer: Int = ClassificationTokenBudget.preferredAnswer,
                 minimumAnswer: Int = ClassificationTokenBudget.minimumAnswer,
                 status: @escaping @Sendable (String) -> Void) async throws -> Answer {
        try Task.checkCancellation()
        let tokens = try template(system: system, user: user)
        guard let fullBudget = ClassificationTokenBudget.answerTokens(input: tokens.count, capacity: contextLimit,
                                                                      minimum: min(minimumAnswer, maxAnswer)) else {
            throw ClassificationError.contextCapacity("This sample exceeds the model's context capacity (\(tokens.count) input tokens, \(contextLimit) total capacity). Choose a model with a larger context.")
        }
        let answerBudget = min(maxAnswer, fullBudget)
        if engine.supportsLogits {
            return try await respondDirectly(tokens.map(Int32.init), schema: schema, budget: answerBudget, status: status)
        }
        return try await respondPipelined(tokens, schema: schema, budget: answerBudget, status: status)
    }

    // MARK: Engines that return scores: driven here

    private func respondDirectly(_ tokens: [Int32], schema: String, budget: Int,
                                 status: @escaping @Sendable (String) -> Void) async throws -> Answer {
        var answer = Answer(promptTokens: tokens.count)
        // The part before shared its opening (rules, show, notes) with this
        // one: keep that much of the engine's memory and read only the rest.
        // Not on hybrid models, whose recurrent state can't be wound back.
        let shared = zip(lastPrompt, tokens).prefix { $0 == $1 }.count
        if shared >= 32, !engine.supportsCheckpoint, engine.processedTokenCount >= shared, shared < tokens.count {
            try await engine.reset(to: shared)
            answer.reusedTokens = shared
        } else {
            try await engine.reset()
        }
        reuseNote = "shared \(shared) · engine \(type(of: engine)) · checkpoint \(engine.supportsCheckpoint) · processed \(engine.processedTokenCount)"
        lastPrompt = tokens
        status("Reading sample · \(tokens.count - answer.reusedTokens) input tokens")

        let grammar = try compiledGrammar(schema)
        let matcher = GrammarMatcher(compiledGrammar: grammar, maxRollbackTokens: 0)
        var bitmask = [Int32](repeating: 0, count: (vocabularySize + 31) / 32)
        let options = InferenceOptions(maxTokens: 1, includeLogits: true)
        let started = Date.now
        var firstToken: Date?
        var input = tokens
        var generated: [Int32] = []
        do {
            while generated.count < budget {
                try Task.checkCancellation()
                var scores: [LogitsScalarType]?
                for try await output in try await engine.generate(with: input, samplingConfiguration: .greedy,
                                                                  inferenceOptions: options) {
                    scores = output.logits
                    break
                }
                guard let scores else { throw ClassificationError.noScores }
                if firstToken == nil { firstToken = .now }
                let constrained = bitmask.withUnsafeMutableBufferPointer { matcher.fillNextTokenBitmask($0.baseAddress!) }
                if constrained, !bitmask.contains(where: { $0 != 0 }) { break }
                guard let next = Self.best(scores, allowed: constrained ? bitmask : nil) else { break }
                if stopTokens.contains(next) { break }
                guard matcher.acceptToken(next) else { break }
                generated.append(next)
                input.append(next)
                if generated.count == 1 || generated.count.isMultiple(of: 16) {
                    status("Writing classification · \(generated.count) tokens")
                }
                if matcher.isTerminated || matcher.isCompleted { break }
            }
        } catch {
            try? await engine.cancel()
            lastPrompt = []
            throw error
        }
        answer.text = tokenizer.decode(tokens: generated.map(Int.init))
        answer.generatedTokens = generated.count
        answer.promptSeconds = (firstToken ?? .now).timeIntervalSince(started)
        answer.generateSeconds = max(0, Date.now.timeIntervalSince(started) - answer.promptSeconds)
        return answer
    }

    /// The highest-scoring token the grammar allows (greedy).
    private static func best(_ scores: [LogitsScalarType], allowed bitmask: [Int32]?) -> Int32? {
        var bestIndex = -1
        var bestScore = -LogitsScalarType.greatestFiniteMagnitude
        guard let bitmask else {
            for (i, s) in scores.enumerated() where s > bestScore { bestScore = s; bestIndex = i }
            return bestIndex >= 0 ? Int32(bestIndex) : nil
        }
        let count = scores.count
        for (word, bits) in bitmask.enumerated() where bits != 0 {
            let base = word * 32
            var remaining = UInt32(bitPattern: bits)
            while remaining != 0 {
                let bit = remaining.trailingZeroBitCount
                remaining &= remaining - 1
                let i = base + bit
                if i < count, scores[i] > bestScore { bestScore = scores[i]; bestIndex = i }
            }
        }
        return bestIndex >= 0 ? Int32(bestIndex) : nil
    }

    /// The schema's grammar, compiled once per load (it used to be rebuilt,
    /// with the 150,000-word vocabulary, for every part). No free spaces:
    /// pretty-printed JSON cost Qwen3 a third more tokens per answer.
    private func compiledGrammar(_ schema: String) throws -> CompiledGrammar {
        if let cached = grammars[schema] { return cached }
        let info: TokenizerInfo
        if let tokenizerInfo { info = tokenizerInfo } else {
            vocabularySize = Self.vocabularySize(tokenizer)
            var vocabulary: [String] = []
            vocabulary.reserveCapacity(vocabularySize)
            for i in 0..<vocabularySize { vocabulary.append(tokenizer.convertIdToToken(i) ?? "") }
            let sentencePiece = vocabulary.prefix(4_000).contains { $0.hasPrefix("▁") }
            info = TokenizerInfo(vocabulary: vocabulary, vocabType: sentencePiece ? .byteFallback : .byteLevel)
            tokenizerInfo = info
            stopTokens = Set(["<end_of_turn>", "<|im_end|>", "<|eot_id|>", "<turn|>", "<|endoftext|>", "</s>", "<eos>"]
                .compactMap { tokenizer.convertTokenToId($0) }.map(Int32.init))
            if let eos = tokenizer.eosTokenId { stopTokens.insert(Int32(eos)) }
        }
        let compiled = try GrammarCompiler(tokenizerInfo: info).compileJSONSchema(schema, anyWhitespace: false, strictMode: true)
        grammars[schema] = compiled
        return compiled
    }

    private static func vocabularySize(_ tokenizer: any Tokenizer) -> Int {
        var low = 0, high = 524_288
        while low < high {
            let mid = (low + high) / 2
            if tokenizer.convertIdToToken(mid) != nil { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: GPU-pipelined engines: the runtime's own constrained decoder

    private func respondPipelined(_ tokens: [Int], schema: String, budget: Int,
                                  status: @escaping @Sendable (String) -> Void) async throws -> Answer {
        try await engine.reset()
        lastPrompt = []
        status("Reading sample · \(tokens.count) input tokens")
        let started = Date.now
        var answer = Answer(promptTokens: tokens.count)
        var firstToken: Date?
        do {
            let strategy = PipelinedConstrainedDecodingStrategy(jsonSchema: schema)
            let stream = try await strategy.decode(
                from: .tokens(tokens), tokenizer: tokenizer, inferenceEngine: engine,
                samplingConfiguration: .greedy,
                options: InferenceOptions(maxTokens: budget, includeLogits: false),
                stopSequences: StopSequences(for: tokenizer, additionalSequences:
                    ["<end_of_turn>", "<|im_end|>", "<|eot_id|>", "<turn|>"].compactMap { marker in
                        guard let id = tokenizer.convertTokenToId(marker),
                              tokenizer.convertIdToToken(id) == marker else { return nil }
                        return [Int32(id)]
                    }))
            for try await chunk in stream {
                try Task.checkCancellation()
                if firstToken == nil { firstToken = .now }
                answer.text += chunk.text
                answer.generatedTokens += 1
                if answer.generatedTokens == 1 || answer.generatedTokens.isMultiple(of: 16) {
                    status("Writing classification · \(answer.generatedTokens) tokens")
                }
            }
            try await engine.cancel()
            try Task.checkCancellation()
        } catch {
            // Pipelined cancellation joins its producer task. Keep the shared
            // heavy-work lease until GPU work really has unwound.
            try? await engine.cancel()
            throw error
        }
        answer.promptSeconds = (firstToken ?? .now).timeIntervalSince(started)
        answer.generateSeconds = max(0, Date.now.timeIntervalSince(started) - answer.promptSeconds)
        return answer
    }
}
#endif
