import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Pass 51: PrismML's Ternary Bonsai 2 packs (`model_type:
/// prism_hadamard_qwen35`) — Qwen3.5 with every quantized projection stored
/// in a signed block-Hadamard basis. The pinned mlx-swift fork has the layers
/// (`HadamardQuantizedLinear`, `HadamardQuantizedEmbedding`), but nothing
/// registers the model type, and loading the tensors as ordinary 2-bit layers
/// returns wrong text rather than failing. PrismML ships only a Python loader
/// (the pack's `runtime/vision_artifact.py`); this is that loader in Swift:
///
/// - the language model is the stock Qwen3.5 text model, its `text_config`
///   read as published (the tied head comes from the pack's top level);
/// - each module the pack lists (`modules`: every attention, delta-net and MLP
///   projection, and the embedding) becomes the fork's Hadamard layer, its
///   signs taken from the pack's own `<module>.signs` tensor, before the
///   weights are applied — so the loader's quantize step skips them (they are
///   already `Quantized`) and the strict weight check proves every one landed;
/// - the vision tower and `.signs` tensors are dropped; the delta-net values
///   are already grouped (`gdn_activation_layout: grouped`), which is the
///   order `GatedDelta` produces, so no permutation is applied.
///
/// The embedding applies the inverse transform after lookup, and the tied
/// head (`embedTokens.asLinear`) the forward one, as the pack requires.
enum PrismBonsai2 {
    static let modelType = "prism_hadamard_qwen35"

    struct Record: Decodable {
        let path: String
        let block: Int
        let embedding: Bool
        let dtype: String
    }

    struct Pack: Decodable {
        let modelType: String
        let baseModelType: String?
        let tieWordEmbeddings: Bool?
        let gdnActivationLayout: String?
        let modules: [Record]

        enum CodingKeys: String, CodingKey {
            case modelType = "model_type", baseModelType = "base_model_type"
            case tieWordEmbeddings = "tie_word_embeddings"
            case gdnActivationLayout = "gdn_activation_layout", modules
        }
    }

    enum LoadError: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            switch self { case .unsupported(let why): "This Bonsai 2 file can't be loaded: \(why)." }
        }
    }

    /// Once per launch, before the first load.
    static func register() async {
        await LLMTypeRegistry.shared.registerModelType(modelType) { data in try make(configuration: data) }
    }

    static func make(configuration data: Data) throws -> PrismHadamardQwen35Model {
        let (args, records) = try read(configuration: data)
        return PrismHadamardQwen35Model(args, records: records)
    }

    /// The pack's configuration, checked: what the text model is built from
    /// and which modules become Hadamard layers. No MLX here, so it can be
    /// tested anywhere.
    static func read(configuration data: Data) throws -> (Qwen35TextConfiguration, [Record]) {
        let pack = try JSONDecoder().decode(Pack.self, from: data)
        guard pack.modelType == modelType, (pack.baseModelType ?? "qwen3_5") == "qwen3_5" else {
            throw LoadError.unsupported("model type \(pack.modelType)")
        }
        guard (pack.gdnActivationLayout ?? "grouped") == "grouped" else {
            throw LoadError.unsupported("delta-net layout \(pack.gdnActivationLayout ?? "")")
        }
        guard !pack.modules.isEmpty, pack.modules.allSatisfy({ $0.dtype == "float16" && [512, 1024, 2048, 4096].contains($0.block) }) else {
            throw LoadError.unsupported("an unexpected transformed module")
        }
        // The text model reads `text_config`; the tied head is declared at the
        // pack's top level only.
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var text = root["text_config"] as? [String: Any] else {
            throw LoadError.unsupported("no text configuration")
        }
        text["tie_word_embeddings"] = pack.tieWordEmbeddings ?? true
        let args = try JSONDecoder().decode(Qwen35TextConfiguration.self,
                                            from: JSONSerialization.data(withJSONObject: text))
        return (args, pack.modules)
    }

    /// The Hadamard layer for one listed module, from the pack's tensors.
    static func layer(for record: Record, weights: [String: MLXArray]) throws -> Module {
        let key = "language_model." + record.path
        guard let weight = weights[key + ".weight"], let scales = weights[key + ".scales"],
              let biases = weights[key + ".biases"], let signs = weights[key + ".signs"] else {
            throw LoadError.unsupported("missing tensors for \(record.path)")
        }
        let values = signs.asType(.float32).asArray(Float.self)
        guard values.allSatisfy({ $0 == 1 || $0 == -1 }) else { throw LoadError.unsupported("invalid signs for \(record.path)") }
        let transform = try SignedBlockHadamard(blockSize: record.block, signs: values)
        if record.embedding {
            return try HadamardQuantizedEmbedding(weight: weight, scales: scales, biases: biases,
                                                  groupSize: 128, bits: 2, transform: transform, outputDType: .float16)
        }
        return try HadamardQuantizedLinear(weight: weight, scales: scales, biases: biases,
                                           groupSize: 128, bits: 2, transform: transform)
    }
}

/// Qwen3.5's text model under `language_model`, as the pack names it, with
/// the listed modules swapped for Hadamard layers while the weights are read.
final class PrismHadamardQwen35Model: Module, LLMModel, KVCacheDimensionProvider {
    let vocabularySize: Int
    let kvHeads: [Int]
    private let records: [PrismBonsai2.Record]

    @ModuleInfo(key: "language_model") var languageModel: Qwen35TextModel

    init(_ args: Qwen35TextConfiguration, records: [PrismBonsai2.Record]) {
        let text = Qwen35TextModel(args)
        vocabularySize = text.vocabularySize
        kvHeads = text.kvHeads
        self.records = records
        _languageModel.wrappedValue = text
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        languageModel(inputs, cache: cache)
    }

    func callAsFunction(_ input: LMInput.Text, cache: [KVCache]?, state: LMOutput.State?) -> LMOutput {
        languageModel(input, cache: cache, state: state)
    }

    func newCache(parameters: GenerateParameters?) throws -> [KVCache] {
        try languageModel.newCache(parameters: parameters)
    }

    func prepare() throws { try languageModel.prepare() }

    var loraLayers: [Module] { languageModel.loraLayers }

    /// Called by the loader before quantizing and applying the weights: the
    /// listed modules become Hadamard layers here (a module that can't be
    /// built stays as it was, and the strict weight check then fails the
    /// load instead of running a model that would answer wrongly).
    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var kept = weights.filter {
            !$0.key.hasPrefix("vision_tower") && !$0.key.hasPrefix("model.visual") && !$0.key.hasPrefix("mtp.")
        }
        var updates: [(String, Module)] = []
        for record in records {
            if let layer = try? PrismBonsai2.layer(for: record, weights: kept) {
                updates.append(("language_model." + record.path, layer))
            }
            kept["language_model." + record.path + ".signs"] = nil
        }
        update(modules: ModuleChildren.unflattened(updates))
        return languageModel.sanitize(weights: kept)
    }
}
