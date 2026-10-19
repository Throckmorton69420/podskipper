import Foundation

/// Pass 31 (his 6 Oct request): how one particular model is asked to find
/// ads — its instructions, how much transcript it gets at a time, how long
/// its answer may be, how its "thinking" is handled and how it samples —
/// chosen from what the model *is* (its architecture and chat template,
/// read from the downloaded files), not from its size alone.
///
/// Pass 38 (his request: per family, per architecture and per runtime, the
/// same plan for MLX and Core AI). Each family's choices below come from his
/// phone's model tests (Diagnostics 6–14 Oct, 258 runs) and the Mac lab:
///
/// - The answer, not the reading, is what costs time and heat: his phone
///   reads ~150–250 tokens/s (MLX) and writes ~10–30. The short answer
///   (five fields a part, at most eight parts) costs a fifth of the tokens.
/// - Showing a JSON *schema* in the instructions made Llama 3.2, SmolLM3,
///   Phi-4 mini, MiniCPM5 and Bonsai copy the schema back; the short answer
///   is described in words.
/// - Small models label the stretch they are shown as a whole ("lines
///   0–240: INTRO"): LFM2.5 350M, MiniCPM5 1B and Ternary Bonsai 1.7B ran
///   to the answer cap on his phone. They get shorter stretches.
/// - Free-text answers start with `{"parts":[` put in the model's mouth, so
///   it continues the list instead of writing prose, fences or a schema.
struct ModelPromptPlan: Sendable, Equatable {
    enum Thinking: String, Sendable {
        /// The template has no reasoning mode.
        case none
        /// `enable_thinking: false` (the template honours it).
        case templateSwitch
        /// The template always opens `<think>`: it is closed straight away.
        case closeOpenBlock
    }

    /// Where the model runs.
    enum Runtime: Sendable, Equatable {
        case mlx
        /// Core AI, holding `context` tokens of prompt and answer here.
        case coreAI(context: Int)
    }

    /// How the conversation is written out for the model.
    enum Turns: String, Sendable {
        /// The model's own chat template.
        case template
        /// Gemma 4's `<bos><|turn>role\n…<turn|>` turns, written directly
        /// (its tokenizer may ship without a chat template; CoreAIKit's
        /// `GemmaPromptRenderer` does the same).
        case gemma4
    }

    /// Plain family name, for the model screen and Diagnostics.
    var family: String
    /// Parameters in billions, from the model's name (nil when unknown).
    var billions: Double?
    var runtime: Runtime = .mlx
    var profile: JudgePrompt.Profile
    /// The hard cap on an answer, in tokens.
    var answerCap: Int
    /// Most transcript tokens per part for understanding (memory, and on
    /// Core AI the model's context, may make it smaller still).
    var maxWindowTokens: Int
    var thinking: Thinking
    var turns: Turns = .template
    /// Free-text retry sampling (the first try is greedy and held to the
    /// answer's grammar).
    var temperature: Float
    var topP: Float
    var topK: Int
    var repetitionPenalty: Float?
    /// A free-text answer is started with `{"parts":[`.
    var primeAnswer = true
    /// The family is known to restate a whole stretch as one cut; such a
    /// part is dropped (`JudgePrompt.restatesStretch`).
    var maxCutShare: Double?
    /// What was decided and why, one line each.
    var notes: [String]

    /// The identity of the plan, for checkpoints: a saved answer is reused
    /// only if it was asked for the same way.
    var identity: String {
        [family, profile.rawValue, String(answerCap), String(maxWindowTokens), thinking.rawValue, turns.rawValue,
         String(temperature), String(topP), String(topK), repetitionPenalty.map { String($0) } ?? "-",
         primeAnswer ? "primed" : "-", maxCutShare.map { String($0) } ?? "-"]
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
        switch profile {
        case .leanReasoned: parts.append("short answer with a reason")
        case .candidate: parts.append("shortest rules and answer")
        case .listener: parts.append("short answer, task repeated after each stretch")
        case .compact: parts.append("short rules and answer")
        default: parts.append("short answer")
        }
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

    // MARK: Size

    /// Parameters in billions from a model's id or name: "Qwen3.5-0.8B",
    /// "LFM2.5-350M", "gemma-4-e2b" (2), "granite-4.0-h-micro" (3).
    static func billions(in name: String) -> Double? {
        let lower = name.lowercased()
        if lower.contains("granite") && lower.contains("micro") { return 3 }
        let pattern = #"(?<![a-z0-9.])e?(\d+(?:\.\d+)?)\s*([bm])(?![a-z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = lower as NSString
        var best: Double?
        for match in regex.matches(in: lower, range: NSRange(location: 0, length: ns.length)) {
            guard let value = Double(ns.substring(with: match.range(at: 1))) else { continue }
            let unit = ns.substring(with: match.range(at: 2))
            let b = unit == "m" ? value / 1_000 : value
            // "3.0" in "dolphin3.0-llama3.2-3B" has no unit; the first size with one wins.
            if best == nil { best = b }
        }
        return best
    }

    // MARK: Plans

    /// Decided from the architecture and the template; the parameter count
    /// only sets how long a stretch a small model is shown.
    static func plan(id: String, modelType: String, template: String, downloadBytes: Int64,
                     runtime: Runtime = .mlx) -> ModelPromptPlan {
        let type = modelType.lowercased()
        let lowerID = id.lowercased()
        var notes: [String] = []
        // A 4-bit model's bytes are roughly its parameters ÷ 2 when the name says nothing.
        let size = billions(in: id) ?? (downloadBytes > 0 ? Double(downloadBytes) / 550_000_000 : nil)

        // Thinking, from the template.
        var thinking: Thinking
        if template.contains("enable_thinking") {
            thinking = .templateSwitch
            notes.append("Its chat template has a thinking switch; it is turned off (the answer is a short list).")
        } else if template.contains("<think>") {
            thinking = .closeOpenBlock
            notes.append("Its chat template always opens a thinking block, with no switch; the block is closed before it answers.")
        } else {
            thinking = .none
        }

        var family: String
        var temperature: Float = 0.2, topP: Float = 0.95, topK = 20
        var penalty: Float? = nil
        var profile: JudgePrompt.Profile = .lean
        var turns: Turns = .template
        var maxCutShare: Double?
        // Stretch lengths on MLX, by family and size (tokens of transcript).
        var window = 4_000
        let b = size ?? 4

        switch true {
        case type.hasPrefix("qwen3_5") || lowerID.contains("qwen3.5") || lowerID.contains("qwen3_5"):
            family = "Qwen3.5"
            window = b <= 1.0 ? 1_800 : (b <= 2.5 ? 3_000 : 4_000)
            if b <= 1.0 {
                notes.append("Under 1B parameters: it reads 1,800-token stretches around what the reader and the audio flagged; on longer ones it labels conversation as ads.")
            }
            // Pass 43: measured on the 4B only; the smaller ones keep the
            // rules they were tested with.
            if b > 2.5 {
                profile = .listener
                notes.append("Told what a listener would skip, with the task said again after each stretch: on 14 of his hand-labelled episodes it let through 48 s of ads an hour instead of 58, and cut less of the show.")
            }
        case lowerID.contains("bonsai"):
            // Bonsai and Ternary Bonsai are Qwen3 at 1 or 2 bits.
            family = lowerID.contains("ternary") ? "Ternary Bonsai" : "Bonsai"
            window = b <= 2 ? 1_800 : 3_000
            maxCutShare = 0.6
            notes.append("On his phone it marked whole stretches as one ad (8B: lines 0–212); a cut over 60 % of a several-minute stretch is dropped.")
        case type.hasPrefix("qwen3") || lowerID.contains("qwen3"):
            family = "Qwen3"
            window = b <= 1.0 ? 1_800 : 4_000
        case type.hasPrefix("gemma4") || lowerID.contains("gemma-4") || lowerID.contains("gemma4"):
            family = "Gemma 4"
            turns = .gemma4
            profile = .leanReasoned
            window = b <= 2.5 ? 3_000 : 4_000
            notes.append("Its turns are written out as Gemma 4's own <|turn> markers, whether or not its tokenizer carries a chat template.")
            notes.append("Gemma writes a few words of evidence before each label: in the lab (E4B) it found more of the ad time that way, 79 % against 70 %, with fewer wrong cuts.")
        case type.hasPrefix("gemma3") || lowerID.contains("gemma-3"):
            family = "Gemma 3"
            profile = .leanReasoned
            window = 4_000
            notes.append("Gemma writes a few words of evidence before each label (79 % against 70 % of the ad time in the lab).")
        case type.hasPrefix("lfm2") || lowerID.contains("lfm2"):
            family = "LFM2.5"
            // Liquid's own generation settings (generation_config.json).
            temperature = 0.1; topK = 50; penalty = 1.05
            window = b < 0.5 ? 1_500 : (b < 2 ? 2_000 : 3_000)
            if thinking == .none, lowerID.contains("lfm2.5") || type.hasPrefix("lfm2") {
                // Its generation prompt ends in <think> even where the template
                // text read here doesn't say so (Core AI ships it in the tokenizer).
                thinking = .closeOpenBlock
            }
            notes.append("Liquid's sampling (temperature 0.1, top-k 50, repetition penalty 1.05). Line numbers must be whole numbers: its 350M and 1.2B wrote words into them on his phone, and such a part is dropped.")
        case type.hasPrefix("minicpm") || lowerID.contains("minicpm"):
            family = "MiniCPM5"
            window = b <= 1.2 ? 2_000 : 3_000
            notes.append("Its labels are read whatever their case or spelling (\"paid_ad\", \"Host Read Ad\"); on his phone the 1B ran to the answer cap on 4,000-token stretches.")
        case type.hasPrefix("granite") || lowerID.contains("granite"):
            family = "Granite 4.0 H"
            penalty = 1.1
            window = b <= 1.5 ? 2_500 : 3_000
            notes.append("Its micro version looped on numbers and wrote prose instead of the list on his phone; a repetition penalty, and a free answer starts as the list.")
        case type.hasPrefix("phi3") || type.hasPrefix("phi") || lowerID.contains("phi-"):
            family = "Phi"
            // Phi-3 mini holds 4,096 tokens in all: ~1,100 of rules, 320 of answer.
            window = lowerID.contains("4k") ? 2_500 : 3_000
            notes.append("It wraps its JSON in ``` fences; the reader takes the list from inside them.")
        case type.hasPrefix("mistral") || type.hasPrefix("ministral") || lowerID.contains("ministral"):
            family = "Ministral"
            temperature = 0.1
            window = 3_000
            notes.append("It wraps its JSON in ``` fences and writes labels in its own case; both are read.")
        case type.hasPrefix("llama") || lowerID.contains("llama"):
            family = lowerID.contains("dolphin") ? "Llama 3.2 (Dolphin)" : "Llama 3.2"
            window = 3_000
            maxCutShare = 0.6
            notes.append("On his phone it restated whole stretches as one cut; a cut over 60 % of a several-minute stretch is dropped.")
        case type.hasPrefix("smollm") || lowerID.contains("smollm"):
            family = "SmolLM3"
            penalty = 1.1
            window = 3_000
            notes.append("It fell into character loops on his phone (\"/&/&/&\"): a repetition penalty, and the answer stops when it repeats.")
        case type.hasPrefix("nemotron") || lowerID.contains("nemotron"):
            family = "Nemotron"
            window = 4_000
        case lowerID.contains("nanbeige"):
            family = "Nanbeige"
            window = 3_000
        case lowerID.contains("youtu"):
            family = "Youtu"
            window = 3_000
        default:
            family = modelType.isEmpty ? "Unknown" : modelType
            window = b <= 1.0 ? 2_000 : 4_000
        }

        // The runtime: Core AI tells us how much the model holds here.
        if case .coreAI(let context) = runtime, context > 0 {
            let fitted = JudgePrompt.Profile.forContext(context)
            if fitted == .candidate || fitted == .compact {
                profile = fitted
                notes.append(fitted == .candidate
                    ? "Holds \(context.formatted()) tokens here: the shortest rules (about 140 tokens) and a three-part answer, so each stretch holds 650–700 tokens of transcript."
                    : "Holds \(context.formatted()) tokens here: short rules and a four-part answer.")
            }
            // The stretch itself is planned in the model's own tokens from
            // what is left; this is only its ceiling.
            window = min(window, max(0, context - 300))
        }
        notes.append("Short answer: at most \(profile == .candidate ? "three" : profile == .compact ? "four" : "eight") parts, described in words rather than a schema; a free answer starts as the list.")
        return ModelPromptPlan(family: family, billions: size, runtime: runtime, profile: profile,
                               answerCap: profile.answerTokens, maxWindowTokens: window,
                               thinking: thinking, turns: turns, temperature: temperature, topP: topP, topK: topK,
                               repetitionPenalty: penalty, primeAnswer: true, maxCutShare: maxCutShare, notes: notes)
    }

    /// Pass 38: the plan for a Core AI catalog model, the same families as
    /// MLX, from its catalog id and name and the bundle's own chat template.
    static func coreAI(id: String, name: String, template: String, context: Int) -> ModelPromptPlan {
        plan(id: id + " " + name, modelType: "", template: template, downloadBytes: 0, runtime: .coreAI(context: context))
    }
}
