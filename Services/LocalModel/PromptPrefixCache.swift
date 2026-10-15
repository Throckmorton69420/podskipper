import Foundation
import MLX
import MLXNN
import MLXLMCommon

/// Pass 39 (his 15 Oct: the phone runs hot): the rules and the episode's
/// header — about 1,300 of every part's ~3,300 prompt tokens — are read once
/// per episode, not once per part.
///
/// Every part's prompt is the same chat — system rules, then "Show: …,
/// Episode: …, sponsors…" — up to where its own lines begin. The longest
/// token run all parts share is prefilled once into a cache; each part
/// starts from a copy of it and reads only its own lines. The answer is the
/// one the whole prompt would have given (the Mac lab compared them token for
/// token on his episodes, and the cache holds exactly what reading those
/// tokens leaves: attention keys and values and the linear layers' state).
/// Lab, Qwen3.5 4B 4-bit, six parts of We Might Be Drunk and Stavvy's #202:
/// prefix ≈1,200 of 1,900–3,300 tokens; prefill 30–55 % shorter.
struct PromptPrefixCache {
    let tokens: [Int]
    let cache: [KVCache]

    /// The token run every prompt starts with, when it is worth keeping.
    /// Cut to a whole number of `step`-token chunks, so the prefix and each
    /// part are read in exactly the chunks the whole prompt would be (with
    /// `.remainder` chunking): the same sums in the same order, so the same
    /// answer to the bit, not merely a close one.
    static func sharedPrefix(_ prompts: [[Int]], minimum: Int = 256, step: Int = LocalJudge.prefillStep) -> [Int]? {
        guard prompts.count >= 2, var shared = prompts.first else { return nil }
        for prompt in prompts.dropFirst() {
            var n = 0
            while n < shared.count, n < prompt.count, shared[n] == prompt[n] { n += 1 }
            shared.removeSubrange(n...)
        }
        // At least one token of each part must be its own, to read and answer from.
        let shortest = prompts.map(\.count).min() ?? 0
        if shared.count >= shortest { shared.removeLast(shared.count - shortest + 1) }
        shared.removeLast(shared.count % step)
        return shared.count >= minimum ? shared : nil
    }

    /// Reads `tokens` into a fresh cache (unquantized, as the generation
    /// loops quantize only after their own prefill).
    static func build(_ tokens: [Int], model: any LanguageModel, stepSize: Int = LocalJudge.prefillStep) throws -> PromptPrefixCache {
        let cache = try model.newCache(parameters: nil)
        var start = 0
        while start < tokens.count {
            let end = Swift.min(tokens.count, start + stepSize)
            let chunk = MLXArray(tokens[start..<end].map { Int32($0) })
            _ = model(LMInput.Text(tokens: chunk)[text: .newAxis], cache: cache, state: nil)
            eval(cache.flatMap(\.state))
            start = end
            try Task.checkCancellation()
        }
        return PromptPrefixCache(tokens: tokens, cache: cache)
    }

    /// The part's own tokens, after the shared run, or nil when this prompt
    /// doesn't start with it.
    func suffix(of prompt: [Int]) -> [Int]? {
        guard prompt.count > tokens.count, Array(prompt[0..<tokens.count]) == tokens else { return nil }
        return Array(prompt[tokens.count...])
    }

    /// A fresh copy for one part; the original stays as read.
    func copies() -> [KVCache] { cache.map { $0.copy() } }
}

/// The loaded model, except that its new caches start as a copy of the
/// shared prefix. Lets the held-to-the-format loop (which makes its own
/// cache) start part-way into the prompt without changing the library.
final class PrefixedLanguageModel: Module, LanguageModel {
    /// Not a child module: holding the model in a plain box keeps it out of
    /// this wrapper's parameter tree.
    private final class Box { let base: any LanguageModel; let prefix: PromptPrefixCache
        init(_ base: any LanguageModel, _ prefix: PromptPrefixCache) { self.base = base; self.prefix = prefix } }
    private let box: Box

    init(base: any LanguageModel, prefix: PromptPrefixCache) {
        box = Box(base, prefix)
        super.init()
    }

    var toolCallFormat: ToolCallFormat? { box.base.toolCallFormat }
    var reasoningConfig: ReasoningConfig? { box.base.reasoningConfig }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] { box.base.sanitize(weights: weights) }
    func sanitize(weights: [String: MLXArray], metadata: [String: String]) -> [String: MLXArray] {
        box.base.sanitize(weights: weights, metadata: metadata)
    }

    func prepare(_ input: LMInput, cache: [KVCache], state: LMOutput.State?, prefill: PrefillParameters) throws -> PrepareResult {
        try box.base.prepare(input, cache: cache, state: state, prefill: prefill)
    }

    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) -> LMOutput {
        box.base.callAsFunction(input, cache: cache, state: state)
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        box.base.callAsFunction(inputs, cache: cache)
    }

    func newCache(parameters: GenerateParameters?) throws -> [KVCache] { box.prefix.copies() }
}
