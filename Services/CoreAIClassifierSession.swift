import Foundation

/// Keep room for a useful classification, without rejecting a prompt merely
/// because the preferred maximum answer would not fit. Unknown context limits
/// retain the runtime's own enforcement.
enum ClassificationTokenBudget {
    static let preferredAnswer = 2_048
    static let minimumAnswer = 256
    static func answerTokens(input: Int, capacity: Int) -> Int? {
        guard input >= 0 else { return nil }
        guard capacity > 0 else { return preferredAnswer }
        let available = capacity - input - 1 // leave room for the end token
        return available >= minimumAnswer ? min(preferredAnswer, available) : nil
    }
}
#if !targetEnvironment(simulator)
import CoreAIKit
import CoreAILanguageModels
import Tokenizers

/// The kit's chat API does not expose chat-template options. Classification
/// needs the model's non-thinking template, rather than spending its answer
/// budget on hidden reasoning. Keep catalog downloads and engine selection;
/// use the public runtime only for the templated Qwen/Nemotron families.
@available(iOS 27, macOS 27, *)
actor CoreAIClassifierSession {
    struct Answer: Sendable {
        var text = ""
        var promptTokens = 0
        var generatedTokens = 0
        var promptSeconds = 0.0
        var generateSeconds = 0.0
    }

    enum ClassificationError: LocalizedError {
        case contextCapacity(String)
        var errorDescription: String? { if case .contextCapacity(let message) = self { return message }; return nil }
    }

    private let engine: any InferenceEngine
    private let tokenizer: any Tokenizer
    /// The bundle's context length in tokens (prompt + answer); 0 if unknown.
    let contextLimit: Int
    static let maxAnswerTokens = ClassificationTokenBudget.preferredAnswer

    /// Tokens in plain text, as the model counts them.
    func tokenCount(_ text: String) -> Int {
        tokenizer.encode(text: text, addSpecialTokens: false).count
    }

    /// Tokens the full chat-templated prompt takes, thinking off.
    func promptTokenCount(system: String, user: String) throws -> Int {
        try tokenizer.applyChatTemplate(
            messages: [["role": "system", "content": system], ["role": "user", "content": user]],
            tools: nil, additionalContext: ["enable_thinking": false]).count
    }

    static func supports(_ id: String) -> Bool {
        id.hasPrefix("qwen3") || id.hasPrefix("nemotron-3-nano")
    }

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
        contextLimit = bundle.maxContextLength
    }

    func respond(system: String, user: String, schema: String, maxAnswer: Int = ClassificationTokenBudget.preferredAnswer,
                 status: @escaping @Sendable (String) -> Void) async throws -> Answer {
        try Task.checkCancellation()
        let tokens = try tokenizer.applyChatTemplate(
            messages: [["role": "system", "content": system], ["role": "user", "content": user]],
            tools: nil, additionalContext: ["enable_thinking": false])
        guard let fullBudget = ClassificationTokenBudget.answerTokens(input: tokens.count, capacity: contextLimit) else {
            throw ClassificationError.contextCapacity("This sample exceeds the model's context capacity (\(tokens.count) input tokens, \(contextLimit) total capacity). Choose a model with a larger context.")
        }
        let answerBudget = min(maxAnswer, fullBudget)
        try await engine.reset()
        status("Reading sample · \(tokens.count) input tokens")
        let started = Date.now
        var answer = Answer(promptTokens: tokens.count)
        var firstToken: Date?
        do {
            // Keep the loaded engine: hybrid models need their extra states.
            // The public logits capability chooses CPU or GPU schema masking
            // without depending on the kit's package-private engine protocol.
            let strategy: any DecodingStrategy = engine.supportsLogits
                ? ConstrainedDecodingStrategy(jsonSchema: schema)
                : PipelinedConstrainedDecodingStrategy(jsonSchema: schema)
            let stream = try await strategy.decode(
                from: .tokens(tokens), tokenizer: tokenizer, inferenceEngine: engine,
                samplingConfiguration: .greedy,
                options: InferenceOptions(maxTokens: answerBudget, includeLogits: false),
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
                if answer.generatedTokens == 1 || answer.generatedTokens.isMultiple(of: 32) {
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
