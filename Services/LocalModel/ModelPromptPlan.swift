import Foundation

/// Pass 31 (his 6 Oct request): how one particular model is asked to find
/// ads — its instructions, how much transcript it gets at a time, how long
/// its answer may be, how its "thinking" is handled and how it samples —
/// chosen from what the model *is* (its architecture and chat template,
/// read from the downloaded files), not from its size alone.
///
/// What his iPhone's tests (6 Oct Diagnostics, 81 runs) and the Mac lab
/// (`~/Developer/mlxlab`, same weights, same templates) showed:
///
/// - The answer, not the reading, is what costs time and heat. His phone
///   reads ~150–250 tokens/s but writes ~10–30; the benchmarked answer asks
///   for nine fields a part (two eight-word quotes and a sentence of
///   reasons, ~90 tokens), and 16 of the failed tests were models writing
///   until the 1,536-token cap — then retrying and doing it again. The
///   short answer (five fields, at most eight parts) keeps the benchmarked
///   rules and costs a fifth of the tokens.
/// - Showing a JSON *schema* in the instructions made Llama 3.2, SmolLM3,
///   Phi-4 mini, MiniCPM5 and Bonsai copy the schema back
///   (`{"type": "object", "properties": …}`). The short answer is described
///   in words.
/// - LFM2.5 2.6B's chat template always opens a reasoning block (its
///   generation prompt ends in `<think>`; there is no switch), so every
///   test was 1,536 tokens of "Let me analyze…". The block is closed before
///   it writes. Templates with a switch (Qwen3/3.5, Gemma 4, MiniCPM5,
///   Nemotron, SmolLM3) get `enable_thinking: false`.
/// - Small models label the stretch they are shown as a whole ("lines
///   0–240: INTRO"); they get shorter stretches.
struct ModelPromptPlan: Sendable, Equatable {
    enum Thinking: String, Sendable {
        /// The template has no reasoning mode.
        case none
        /// `enable_thinking: false` (the template honours it).
        case templateSwitch
        /// The template always opens `<think>`: it is closed straight away.
        case closeOpenBlock
    }

    /// Plain family name, for the model screen and Diagnostics.
    var family: String
    var profile: JudgePrompt.Profile
    /// The hard cap on an answer, in tokens.
    var answerCap: Int
    /// Most transcript tokens per part for understanding (memory may make
    /// it smaller still).
    var maxWindowTokens: Int
    var thinking: Thinking
    /// Free-text retry sampling (the first try is greedy and held to the
    /// answer's grammar).
    var temperature: Float
    var topP: Float
    var topK: Int
    var repetitionPenalty: Float?
    /// What was decided and why, one line each.
    var notes: [String]

    /// The identity of the plan, for checkpoints: a saved answer is reused
    /// only if it was asked for the same way.
    var identity: String {
        [family, profile.rawValue, String(answerCap), String(maxWindowTokens), thinking.rawValue,
         String(temperature), String(topP), String(topK), repetitionPenalty.map { String($0) } ?? "-"]
            .joined(separator: "|")
    }

    /// The architecture name in the model's own config.json.
    static func modelType(in folder: URL?) -> String {
        guard let folder,
              let data = try? Data(contentsOf: folder.appending(path: "config.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let type = object["model_type"] as? String { return type }
        if let text = object["text_config"] as? [String: Any], let type = text["model_type"] as? String { return type }
        return ""
    }

    /// The chat template's text (its own file, or inside tokenizer_config).
    static func template(in folder: URL?) -> String {
        guard let folder else { return "" }
        if let text = try? String(contentsOf: folder.appending(path: "chat_template.jinja"), encoding: .utf8) { return text }
        if let data = try? Data(contentsOf: folder.appending(path: "tokenizer_config.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = object["chat_template"] as? String { return text }
        return ""
    }

    /// One line for the model list: how PodSkipper asks it.
    var summary: String {
        var parts = ["Asked as \(family)"]
        parts.append(profile == .leanReasoned ? "short answer with a reason" : "short answer")
        switch thinking {
        case .templateSwitch: parts.append("thinking off")
        case .closeOpenBlock: parts.append("thinking block closed")
        case .none: break
        }
        parts.append("\(maxWindowTokens.formatted())-token stretches")
        return parts.joined(separator: " · ")
    }

    nonisolated(unsafe) private static var cache: [String: ModelPromptPlan] = [:]
    private static let cacheLock = NSLock()

    /// Read once per model per launch (two small files), not every redraw.
    static func cached(for spec: LocalModelSpec) -> ModelPromptPlan {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let plan = cache[spec.id] { return plan }
        let plan = plan(for: spec, folder: ModelStore.folder(for: spec))
        cache[spec.id] = plan
        return plan
    }

    static func plan(for spec: LocalModelSpec, folder: URL?) -> ModelPromptPlan {
        plan(id: spec.id, modelType: modelType(in: folder), template: template(in: folder),
             downloadBytes: spec.downloadBytes)
    }

    /// Decided from the architecture and the template; the parameter count
    /// only sets how long a stretch a small model is shown.
    static func plan(id: String, modelType: String, template: String, downloadBytes: Int64) -> ModelPromptPlan {
        let type = modelType.lowercased()
        let lowerID = id.lowercased()
        var notes: [String] = []

        // Thinking.
        let thinking: Thinking
        if template.contains("enable_thinking") {
            thinking = .templateSwitch
            notes.append("Its chat template has a thinking switch; it is turned off (the answer is a short list).")
        } else if template.contains("<think>"), !template.contains("enable_thinking") {
            thinking = .closeOpenBlock
            notes.append("Its chat template always opens a thinking block, with no switch; the block is closed before it answers.")
        } else {
            thinking = .none
        }

        // Family, for the screen, and what the lab and his phone showed.
        let family: String
        var temperature: Float = 0.2, topP: Float = 0.95, topK = 20
        var penalty: Float? = nil
        switch true {
        case type.hasPrefix("qwen3_5") || lowerID.contains("qwen3.5"): family = "Qwen3.5"
        case type.hasPrefix("qwen3") || lowerID.contains("bonsai"): family = "Qwen3"
        case type.hasPrefix("gemma4") || lowerID.contains("gemma-4"): family = "Gemma 4"
        case type.hasPrefix("gemma3") || lowerID.contains("gemma-3"): family = "Gemma 3"
        case type.hasPrefix("lfm2"):
            family = "LFM2.5"
            // Liquid's own generation settings (generation_config.json).
            temperature = 0.1; topK = 50; penalty = 1.05
        case type.hasPrefix("minicpm"): family = "MiniCPM"
        case type.hasPrefix("granite"):
            family = "Granite 4.0 H"
            penalty = 1.1
            notes.append("Its micro version looped on numbers on his phone; a repetition penalty on the retry.")
        case type.hasPrefix("phi3") || type.hasPrefix("phi"):
            family = "Phi"
        case type.hasPrefix("mistral") || type.hasPrefix("ministral"):
            family = "Ministral"
            temperature = 0.1
        case type.hasPrefix("llama"): family = lowerID.contains("dolphin") ? "Llama 3.2 (Dolphin)" : "Llama 3.2"
        case type.hasPrefix("smollm"): family = "SmolLM3"
        case type.hasPrefix("nemotron"): family = "Nemotron"
        default: family = modelType.isEmpty ? "Unknown" : modelType
        }

        // How long a stretch, by size on disk (a 4-bit model's bytes are
        // roughly its parameters ÷ 2): small models label whole stretches.
        let gigabytes = Double(downloadBytes) / 1_000_000_000
        let window: Int
        // The lab measured every model on ~3,500-token stretches; longer
        // stretches are untested, cost more memory and make small models
        // label the stretch as a whole.
        if gigabytes < 1.0 {
            window = 3_000
            notes.append("A small model: it reads about 3,000 tokens at a time.")
        } else {
            window = 4_000
        }

        // The answer's shape, by family, from the Mac lab on his episodes.
        let profile: JudgePrompt.Profile
        if family.hasPrefix("Gemma") {
            profile = .leanReasoned
            notes.append("Gemma writes a few words of evidence before each label: in the lab (E4B) it found more of the ad time that way, 79 % against 70 %, with fewer wrong cuts.")
        } else {
            profile = .lean
        }
        notes.append("Short answer: five fields a part, at most eight parts, described in words rather than a schema.")
        return ModelPromptPlan(family: family, profile: profile, answerCap: profile.answerTokens, maxWindowTokens: window,
                               thinking: thinking, temperature: temperature, topP: topP, topK: topK,
                               repetitionPenalty: penalty, notes: notes)
    }
}
