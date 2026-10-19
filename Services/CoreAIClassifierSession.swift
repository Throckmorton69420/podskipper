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
    /// Pass 38: the same bundles on Core AI's *sequential* engine (see
    /// `CoreAIEngineRoute`). CoreAIKit read prompts of up to 3,789 tokens
    /// correctly there on an iPhone 17 Pro (MiniCPM5 2B); the miscompile
    /// starts at 2,048 positions of a growing cache on the pipelined
    /// engine. Until a phone run here shows more is right, the sequential
    /// engine is held just under that line: twice what it held before.
    static let iOSSequentialCap = 2_047

    static func isPipelined(engineHint: String?, path: String) -> Bool {
        engineHint == "pipelined" || path.contains("gpu-pipelined") || path.contains("_decode_")
    }

    /// A decode-only port: its graph takes one token per step (S=1).
    static func isDecodeOnly(path: String) -> Bool { path.contains("_decode_") }

    static func usableContext(bundleContext: Int, engineHint: String?, path: String, iOS: Bool = true) -> Int {
        guard iOS, isPipelined(engineHint: engineHint, path: path) else { return bundleContext }
        return bundleContext > 0 ? min(bundleContext, iOSPipelinedCap) : iOSPipelinedCap
    }

    /// Pass 38: what a loaded bundle holds on the engine that runs it.
    ///
    /// Pass 43: the pipelined engine's own grammar decoder (`.runtimeGrammar`)
    /// grows a dynamically sized memory to the whole prompt and answer, and
    /// has none of the iOS guard Core AI's plain `generate()` carries
    /// (coreai-models `runConstrainedCompletion`; the guard's note: iOS
    /// "miscompiles this graph class once the bound KV state's seq dim
    /// reaches 2048 — output is corrupt from the first token"). Qwen3 4B ran
    /// 2,000–4,000-token parts that way and closed PodSkipper 22 times
    /// on 19 Oct. It now holds what the guard allows: 1,024.
    static func usableContext(bundleContext: Int, route: CoreAIEngineRoute, iOS: Bool = true) -> Int {
        guard iOS else { return bundleContext }
        let cap: Int
        switch route {
        case .pipelinedPrimed, .runtimeGrammar: cap = iOSPipelinedCap
        case .sequential: cap = iOSSequentialCap
        case .staticShape: return bundleContext
        }
        return bundleContext > 0 ? min(bundleContext, cap) : cap
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

    /// Pass 32: the portable build to use when the iPhone build is compiled
    /// for another chip — the catalog's other build of the same model when it
    /// is a GPU-pipelined bundle with no chip tag (the format the iPhone
    /// compiles itself, as for Qwen3.5 and LFM2.5). Nil when there is none.
    static func portableAlternative(iOSPath: String, macPath: String?) -> String? {
        guard aotChip(iOSPath) != nil, let macPath, aotChip(macPath) == nil,
              macPath.contains("gpu-pipelined") else { return nil }
        return macPath
    }

    /// Pass 36: whether the publisher's iPhone build is already compiled for
    /// this phone's chip (then it is used as is). Their `ios` folder is the
    /// uncompiled Neural Engine graph, so: only when the path names this chip.
    static func hasPublishedBuild(for machine: String, iOSPath: String) -> Bool {
        guard let chip = aotChip(iOSPath) else { return false }
        return runs(chip: chip, machine: machine)
    }

    /// "iPhone 17 Pro" for "h18p", for the reason shown on the model's row.
    static func phoneName(chip: String) -> String {
        let number = Int(chip.dropFirst().prefix { $0.isNumber }) ?? 0
        return "iPhone \(number - 1)" + (chip.hasSuffix("p") ? " Pro" : "")
    }
}
/// Pass 38: which Core AI engine runs a bundle, and how its answer is held
/// to the answer's format. Read from the engine's source (coreai-models,
/// `CoreAIPipelinedEngine.swift`) and his phone:
///
/// - The pipelined engine's own grammar decoder (`generateConstrained` →
///   `_encodeStepForConstrainedGeneration`) binds neither a model's static
///   inputs (Gemma 4's word tables) nor its extra states (the recurrent
///   `convState` of Qwen3.5, LFM2.5, Granite 4.0 H, Nemotron 3) — "Missing
///   state view for convState" on his phone, every hybrid — and its
///   jump-forward feeds several tokens in one step, which a decode-only
///   (S=1) port can't take. Its plain `generate()` binds all of them.
/// - The *sequential* engine runs the same GPU-pipelined bundles, hands back
///   each step's scores (so PodSkipper holds the answer to its schema on
///   the CPU, as for Qwen3 4B), keeps the prompt it has read, checkpoints a
///   hybrid's recurrent state, and isn't held to 1,024 tokens on iPhone.
///   It can't bind static inputs, so Gemma 4 stays on the pipelined engine.
enum CoreAIEngineRoute: String, Sendable, Equatable {
    /// Static-shape (chunked) bundle: scores back, grammar on the CPU.
    case staticShape
    /// A dynamic bundle on the sequential engine: scores back, grammar on
    /// the CPU. Pass 43: the unhinted ones (Qwen3's GPU builds) too.
    case sequential
    /// Unhinted dynamic bundles (Qwen3's GPU builds) on the pipelined engine
    /// with its own grammar decoder — no static inputs, no extra states and
    /// a full-width graph, so the decoder's gaps don't apply (his phone:
    /// Qwen3 4B 82 % Basic this way). Pass 43: only when the sequential
    /// engine can't open one, and held to 1,024 tokens on iOS.
    case runtimeGrammar
    /// The pipelined engine's `generate()`, which binds everything: Gemma 4,
    /// and any bundle the sequential engine can't open. The answer is
    /// started for the model and checked against the schema token by token.
    case pipelinedPrimed

    static func choose(engineHint: String?, path: String, hasStaticInputs: Bool) -> CoreAIEngineRoute {
        if hasStaticInputs { return .pipelinedPrimed }
        switch engineHint {
        case "static-shape": return .staticShape
        default:
            // Pass 43: every dynamic bundle reads on the sequential engine —
            // the pipelined-hinted ones since Pass 38, and now the unhinted
            // ones (Qwen3's GPU builds) too. MiniCPM5 2B read his 14 episodes
            // this way on 19 Oct without closing PodSkipper once; Qwen3 4B on
            // the pipelined engine's own decoder closed it 22 times. The Mac
            // lab ran Qwen3's GPU build (0.6B, same exporter) here: it opens,
            // keeps the shared prompt between parts and answers in format.
            return .sequential
        }
    }

    /// The route to try when this one's engine can't open the bundle: for a
    /// pipelined-hinted bundle the pipelined engine's `generate()` (Pass 38);
    /// for an unhinted one its own decoder, held to 1,024 tokens on iOS.
    func fallback(engineHint: String?, path: String) -> CoreAIEngineRoute? {
        guard self == .sequential else { return nil }
        return CoreAIBundleLimits.isPipelined(engineHint: engineHint, path: path) ? .pipelinedPrimed : .runtimeGrammar
    }

    /// `EngineOptions.variant`; nil lets Core AI pick from the graph.
    var variant: String? {
        switch self {
        case .staticShape: return "static-shape"
        case .sequential: return "coreai-sequential"
        case .pipelinedPrimed: return "coreai-pipelined"
        case .runtimeGrammar: return nil
        }
    }

    /// For Diagnostics.
    var description: String {
        switch self {
        case .staticShape: return "answer held to the format as it is written"
        case .sequential: return "sequential engine, answer held to the format as it is written"
        case .runtimeGrammar: return "Core AI's own answer format"
        case .pipelinedPrimed: return "answer started as the list and checked as it is written"
        }
    }
}

/// Pass 38: the families whose layers carry a recurrent state beside the
/// attention cache (Mamba/conv/GDN hybrids). Their state can't be wound back
/// to an earlier token, so a shared prompt is kept with a checkpoint.
enum CoreAIArchitecture {
    static func isHybrid(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["qwen3.5", "qwen3_5", "lfm2", "granite-4.0-h", "granite_4_0_h", "nemotron-3", "nemotron_3",
                "nemotron_h", "falcon-h", "falcon_h", "jamba", "mamba"].contains { lower.contains($0) }
    }
}

/// Pass 38: how a prompt is written out for a model whose tokenizer may
/// carry no chat template.
enum CoreAIPromptFormat {
    /// Gemma 4's turns (CoreAIKit `GemmaPromptRenderer`; his downloaded
    /// E2B revision's own template renders exactly this). `<bos>` is written
    /// here: the tokenizer doesn't add one.
    static func gemma4(system: String, user: String) -> String {
        "<bos><|turn>system\n\(system)<turn|>\n<|turn>user\n\(user)<turn|>\n<|turn>model\n"
    }

    /// The opening put in the model's mouth on the free-running routes.
    static let opening = "{\"parts\":["
}

/// Pass 38: whether a Core AI bundle runs on the graphics chip, read from
/// what is actually installed rather than from its name. iOS refuses GPU
/// work from a backgrounded app (no Background GPU Access here); the Neural
/// Engine and the CPU are not refused. A copy compiled for this iPhone lists
/// its delegates (`<graph>.aimodelc/<arch>-delegates/<kind>/`); his h17p
/// copies of Qwen3 4B — compiled with `--preferred-compute neural-engine`
/// — and Gemma 4 E2B both hold only `MPSGraph`, i.e. the GPU. Without a
/// compiled copy, Core AI prepares the graph on the phone and its delegates
/// can't be read, so it counts as the GPU.
enum CoreAIComputeUnits {
    static let gpuDelegates: Set<String> = ["MPSGraph", "Metal", "GPU", "MPS"]

    /// The delegate kinds of the compiled copy installed in `bundle`, or nil
    /// when there is none.
    static func delegates(inBundle bundle: URL) -> [String]? {
        guard let compiled = CoreAICompiledCopy.installed(in: bundle) else { return nil }
        return delegates(inCompiled: bundle.appending(path: compiled))
    }

    static func delegates(inCompiled asset: URL) -> [String] {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(atPath: asset.path)) ?? []).filter { $0.hasSuffix("-delegates") }
        return folders.flatMap { (try? fm.contentsOfDirectory(atPath: asset.appending(path: $0).path)) ?? [] }
            .filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Runs only where iOS lets a backgrounded app run it: a compiled copy
    /// whose delegates are all known and none is a GPU one.
    static func runsWithoutGPU(delegates: [String]?) -> Bool {
        guard let delegates, !delegates.isEmpty else { return false }
        return !delegates.contains { gpuDelegates.contains($0) }
    }
}

/// Pass 38: Gemma 4 E2B on an iPhone runs only from a graph already compiled
/// for its chip — the publisher's (iPhone 17 Pro) or a copy compiled on a
/// Mac and installed under the model. Core AI compiling the portable decoder
/// on the phone closed PodSkipper twice on his iPhone 16 Pro (14 Oct, a trap
/// in CoreAIRuntime at the first prompt token), as CoreAIKit records:
/// "the plain bundle's ~2 GB of graph constants crash the on-device GPU
/// specializer". That crash can't be caught, so it isn't started.
enum CoreAIGemmaReadiness {
    static func refusal(needsTables: Bool, decoderPath: String, machine: String,
                        compiledCopyInstalled: Bool, iOS: Bool = true, name: String = "Gemma 4 E2B") -> String? {
        guard iOS, needsTables, !CoreAIBundleLimits.hasPublishedBuild(for: machine, iOSPath: decoderPath) else { return nil }
        // Pass 39 (his 15 Oct Diagnostics on b457c86): with the iPhone 16 Pro
        // compiled copy installed, Gemma still closed PodSkipper twice — the
        // same assertion inside Apple's CoreAIRuntime while it read the first
        // part's prompt one token at a time (`processChunkedInput`). Not the
        // on-device compile, then, and nothing PodSkipper can change: off the
        // publisher's own iPhone build it isn't started.
        if compiledCopyInstalled {
            return "\(name) can't run on this iPhone yet: even compiled for it, Apple's Core AI stops while reading the first part, which closes PodSkipper. It runs on iPhone 17 Pro, which has the publisher's own build."
        }
        return "\(name) needs a copy compiled for this iPhone. Core AI can't prepare this model on the phone itself — trying closes PodSkipper. In Settings › Models and Caches, touch and hold \(name) and choose Install Compiled Copy."
    }
}

/// Pass 34 (his 9 Oct Diagnostics on 8bbe5dd): Core AI Qwen3 4B closed the
/// app three more times, each while *reading* a ~1,952-token prompt, each an
/// abort inside MPSGraph under Core AI's GPU delegate — never while writing.
/// The static-shape engine reads a long prompt with its 64-token-wide
/// `prompt_opt` graphs and writes with its 8-token-wide ones. Upstream
/// (apple/coreai-models #27, #201) iOS 27's MPSGraph scratch heap overflows
/// on multi-token prefill and aborts with signal 6, the overflowing buffer
/// growing with the chunk's width; it isn't every run, as here (the same
/// test passed at 09:45 and crashed at 09:18 and 20:24). So the prompt is
/// read through the narrow graphs that have never crashed: fed to the engine
/// a step at a time, each step no wider than the narrowest graph. Same
/// tokens, same cache, same answer.
enum StaticPrefill {
    /// The narrowest query the Qwen3 4B static bundle was built with
    /// (graphs 8, 16 and 64 wide). A bundle whose narrowest is wider still
    /// works: the engine aligns each step to its own graph.
    static let width = 8

    static func usesSteps(engineName: String) -> Bool { engineName.contains("StaticShape") }

    /// Where each feeding step ends, leaving the last ≤ `width` tokens for
    /// the first answer step (which needs the scores at the prompt's end).
    static func stepEnds(promptCount: Int, alreadyRead: Int = 0, width: Int = width) -> [Int] {
        guard width > 0 else { return [] }
        var ends: [Int] = []
        var done = max(0, alreadyRead)
        while promptCount - done > width {
            done = (done / width + 1) * width
            ends.append(done)
        }
        return ends
    }
}

/// Pass 32: plain-text helpers for the Core AI reader, outside the
/// device-only code so the simulator's tests can check them.
enum CoreAIAnswerText {
    /// The GPU grammar decoder's complaint about a hybrid model's state.
    static func isMissingStateView(_ error: Error) -> Bool {
        let text = String(describing: error) + " " + error.localizedDescription
        return text.contains("Missing state view")
    }

    /// Pass 38: iOS refused GPU work because the app isn't on screen
    /// (`kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`).
    static func isBackgroundGPURefusal(_ error: Error) -> Bool {
        let text = String(describing: error) + " " + error.localizedDescription
        return text.contains("BackgroundExecutionNotPermitted") || text.contains("Background Execution Not Permitted")
            || (text.contains("IOGPU") && text.lowercased().contains("background"))
    }

    /// Pass 38: a free-running answer cut short (the model left the format,
    /// or ran out of room) kept to its finished parts and closed:
    /// `{"parts":[{…},{…},{"first_li` → `{"parts":[{…},{…}]}`. Nil when not a
    /// single part was finished.
    static func salvage(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        var depth = 0, inString = false, escaped = false
        var lastPartEnd: Int?
        var listOpen = false
        for (i, c) in bytes.enumerated() {
            if inString {
                if escaped { escaped = false } else if c == 0x5C { escaped = true } else if c == 0x22 { inString = false }
                continue
            }
            switch c {
            case 0x22: inString = true
            case 0x7B, 0x5B:
                depth += 1
                if c == 0x5B, depth == 2 { listOpen = true }
            case 0x7D, 0x5D:
                if c == 0x7D, depth == 3, listOpen { lastPartEnd = i }
                depth -= 1
                if depth == 0 { return String(decoding: bytes[...i], as: UTF8.self) }
            default: break
            }
        }
        if let end = lastPartEnd { return String(decoding: bytes[...end], as: UTF8.self) + "]}" }
        // Not one part finished: no answer (the part counts as failed and
        // the reader's cuts stand), never an empty list it didn't write.
        return nil
    }

    /// Whether `{"parts":[ … ]}` has been closed (strings respected).
    static func listClosed(_ text: String) -> Bool {
        var depth = 0, inString = false, escaped = false, opened = false
        for c in text.utf8 {
            if inString {
                if escaped { escaped = false } else if c == 0x5C { escaped = true } else if c == 0x22 { inString = false }
                continue
            }
            switch c {
            case 0x22: inString = true
            case 0x7B, 0x5B: depth += 1; opened = true
            case 0x7D, 0x5D: depth -= 1; if opened && depth == 0 { return true }
            default: break
            }
        }
        return false
    }
}

#if !targetEnvironment(simulator)
import CoreAIKit
import CoreAILanguageModels
import Metal
import Tokenizers

/// The kit's chat API does not expose chat-template options. Classification
/// needs the model's non-thinking template, rather than spending its answer
/// budget on hidden reasoning. Keep catalog downloads and engine selection;
/// run the public runtime directly.
///
/// Pass 30 (his 5 Oct phone: Qwen3 4B took 25 min on a 66-min episode):
/// - every catalog model comes through here, held to the JSON schema, so a
///   small model can't write an answer that doesn't parse;
/// - engines that hand back each step's scores are driven directly: the
///   grammar is built once per load, not once per part, and the answer is
///   written without spaces and line breaks.
///
/// Pass 38: which engine and how the answer is held — `CoreAIEngineRoute`.
/// The prompt the parts share (rules, show, sponsors) is read once and kept
/// on the sequential engine (a hybrid's recurrent state by a checkpoint), so
/// each part reads only its own lines.
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
        /// Pass 38: the free-running answer left the format and was cut back
        /// to its finished parts.
        var salvaged = false
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
    let contextLimit: Int
    /// The bundle's own context, before the iPhone cap.
    let bundleContext: Int
    /// Pass 38: the engine running it and how its answer is held.
    let route: CoreAIEngineRoute
    /// Held to ~1,000 tokens (the pipelined engine on iPhone).
    var pipelined: Bool { route == .pipelinedPrimed || route == .runtimeGrammar }
    /// The runtime engine Core AI chose for this bundle, for Diagnostics.
    let engineName: String
    /// Pass 35: loaded from a compiled copy for this iPhone (CoreAICompiledCopy).
    let precompiled: Bool
    /// Pass 37: Gemma's word tables, "in memory" or "read from storage".
    let tablesMode: String?
    /// Pass 38: a hybrid (recurrent-state) model.
    let hybrid: Bool
    private let steps: Bool
    /// The chat template's text, so the prompt plan can follow the family.
    let chatTemplate: String
    /// Pass 38: written out as Gemma 4's own turns.
    let gemmaTurns: Bool
    /// Pass 38: free-running sampling for this family (LFM2.5's own
    /// settings); greedy for everyone else.
    var sampling: SamplingConfiguration = .greedy
    static let maxAnswerTokens = ClassificationTokenBudget.preferredAnswer
    /// Pass 32: a runtime-grammar engine that says "Missing state view"
    /// writes freely from then on (a backstop: Pass 38 routes the known
    /// hybrids to the sequential engine before they get there).
    private(set) var grammarUnsupported = false
    private var freeStopTokens: Set<Int32> = []
    /// Pass 32: keeping the parts' shared opening in the engine between
    /// parts. Pass 38: on for the sequential engine (Core AI's own rewind
    /// and checkpoint, as CoreAIKit's TypedDecisions uses it). Still off for
    /// the static-shape engine on iPhone: Qwen3 4B closed the app twice
    /// after a kept prompt (7 Oct, an abort in MPSGraph). The lab may force it.
    var reusesSharedPrompt: Bool {
        #if os(iOS)
        return route == .sequential
        #else
        let env = ProcessInfo.processInfo.environment
        if env["COREAI_LAB_NOREUSE"] == "1" { return false }
        return route == .sequential || env["COREAI_LAB_REUSE"] == "1"
        #endif
    }

    /// The tokens the engine has consumed (the prompt and what was fed back
    /// of the answer), so the next part keeps what it shares.
    private var fed: [Int32] = []
    /// The shared opening a hybrid's checkpoint holds.
    private var checkpointed: [Int32] = []
    /// How the last part's prompt reuse went, for the lab and Diagnostics.
    private(set) var reuseNote = ""
    private var grammars: [String: CompiledGrammar] = [:]
    private var tokenizerInfo: TokenizerInfo?
    private var vocabularySize = 0
    private var stopTokens: Set<Int32> = []
    /// Pass 38: we set COREAI_CHUNK_THRESHOLD (a process-wide setting) for a
    /// decode-only port, and clear it again for any other bundle, so a
    /// full-width graph loaded later isn't fed one token at a time.
    nonisolated(unsafe) private static var setChunkThreshold = false

    /// Tokens in plain text, as the model counts them.
    func tokenCount(_ text: String) -> Int {
        tokenizer.encode(text: text, addSpecialTokens: false).count
    }

    /// Tokens the full prompt takes, thinking off.
    func promptTokenCount(system: String, user: String) throws -> Int {
        try template(system: system, user: user).count
    }

    private func template(system: String, user: String) throws -> [Int] {
        if gemmaTurns {
            return tokenizer.encode(text: CoreAIPromptFormat.gemma4(system: system, user: user), addSpecialTokens: false)
        }
        var tokens = try tokenizer.applyChatTemplate(
            messages: [["role": "system", "content": system], ["role": "user", "content": user]],
            tools: nil, additionalContext: ["enable_thinking": false])
        // Pass 38: a template that always opens a reasoning block (LFM2.5)
        // has it closed before the model writes, as on MLX.
        let tail = tokenizer.decode(tokens: Array(tokens.suffix(6)))
        if tail.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("<think>") {
            tokens += tokenizer.encode(text: "\n</think>\n\n", addSpecialTokens: false)
        }
        return tokens
    }

    /// Pass 30: every catalog chat model (it was Qwen3 and Nemotron only).
    static func supports(_ id: String) -> Bool { true }

    /// - Parameter tablesURL: Pass 37 — Gemma 4's per-layer word tables
    ///   (`embed_per_layer.i8` + `.scale.f32`), bound to the decoder's two
    ///   table inputs, as CoreAIKit's `GemmaRuntime` does.
    /// - Parameter family: Pass 38 — the catalog id and name, for the
    ///   family's sampling and whether its state is recurrent.
    init(bundleAt url: URL, engineHint: String?, tablesURL: URL? = nil, family: String = "") async throws {
        var route = CoreAIEngineRoute.choose(engineHint: engineHint, path: url.path, hasStaticInputs: tablesURL != nil)
        // Decode-only zoo ports (`_decode_`) take one prompt token per step;
        // on the pipelined engine every pipelined-hinted bundle is fed that
        // way (CoreAIKit 0.7.3's ModelRuntime and TypedDecisions).
        Self.setSingleTokenPrefill(url.lastPathComponent.contains("_decode_")
            || (route == .pipelinedPrimed && engineHint == "pipelined"))
        let bundle = try LanguageBundle(at: url)
        if let tablesURL {
            let buffers = try CoreAIGemmaTables.buffers(at: tablesURL)
            tablesMode = buffers.mode
            let config = ModelConfig(name: bundle.name, tokenizer: bundle.tokenizer, vocabSize: bundle.vocabSize,
                                     maxContextLength: bundle.maxContextLength,
                                     serializedModel: [bundle.modelAssetPath], function: "main")
            async let loadedEngine = EngineFactory.createEngine(
                config: try JSONEncoder().encode(config),
                modelURL: try bundle.requireModelURL(for: "main"),
                options: EngineOptions(variant: "coreai-pipelined", staticInputBuffers: buffers.inputs))
            async let loadedTokenizer = bundle.loadTokenizer()
            (engine, tokenizer) = try await (loadedEngine, loadedTokenizer)
        } else {
            tablesMode = nil
            var loaded: (any InferenceEngine)?
            do {
                loaded = try await CoreAIRunner(bundle: bundle, variant: route.variant).makeInferenceEngine()
            } catch let error where route.fallback(engineHint: engineHint, path: url.path) != nil {
                // Pass 38: a pipelined-hinted bundle the sequential engine
                // can't open is run on the pipelined engine's generate(),
                // never its grammar decoder; Pass 43: an unhinted one on the
                // decoder it used before, at 1,024 tokens on iOS.
                try Task.checkCancellation()
                let first = error
                guard let fallback = route.fallback(engineHint: engineHint, path: url.path) else { throw first }
                route = fallback
                Self.setSingleTokenPrefill(url.lastPathComponent.contains("_decode_") || engineHint == "pipelined")
                loaded = try await CoreAIRunner(bundle: bundle, variant: fallback.variant).makeInferenceEngine()
            }
            guard let loaded else { throw ClassificationError.noScores }
            engine = loaded
            tokenizer = try await bundle.loadTokenizer()
        }
        // An engine that hands back scores is driven directly whatever was asked.
        if engine.supportsLogits, route != .staticShape { route = .sequential }
        self.route = route
        let runtimeEngine = String(describing: type(of: engine))
        // Pass 35: a copy compiled for this iPhone has every graph built, so
        // nothing is compiled on the phone and the prompt is read at the
        // engine's own widths. Without one, the 8-token steps stay: they use
        // only the narrow graphs (static-shape engine only).
        precompiled = CoreAICompiledCopy.installed(in: url) != nil
        steps = StaticPrefill.usesSteps(engineName: runtimeEngine) && !precompiled
        hybrid = CoreAIArchitecture.isHybrid(family + " " + url.lastPathComponent) || engine.supportsCheckpoint
        engineName = runtimeEngine
            + (precompiled ? " · compiled for this iPhone" : " · compiled on this iPhone when first used")
            + (tablesMode.map { " · word tables \($0)" } ?? "")
            + (steps ? " · prompt in \(StaticPrefill.width)-token steps" : "")
            + " · " + route.description
        chatTemplate = Self.templateText(in: url)
        bundleContext = bundle.maxContextLength
        gemmaTurns = tablesURL != nil || family.lowercased().contains("gemma-4") || family.lowercased().contains("gemma 4")
        #if os(iOS)
        let iOS = true
        #else
        let iOS = ProcessInfo.processInfo.environment["COREAI_LAB_IOS_CAP"] == "1"
        #endif
        contextLimit = CoreAIBundleLimits.usableContext(bundleContext: bundle.maxContextLength, route: route, iOS: iOS)
        // LFM2.5's own generation settings; on the pipelined engine a
        // repetition penalty needs a temperature above 0. Everyone else is
        // read greedily. (The sequential engine's answers are always greedy
        // and held to the schema.)
        if family.lowercased().contains("lfm2") {
            sampling = SamplingConfiguration(temperature: 0.1, topK: 50, repetitionPenalty: 1.05)
        }
    }

    /// COREAI_CHUNK_THRESHOLD is read by every engine in the process; it is
    /// set for a bundle that needs one-token prefill and cleared again (if
    /// PodSkipper set it) for one that doesn't.
    private static func setSingleTokenPrefill(_ single: Bool) {
        if single {
            if getenv("COREAI_CHUNK_THRESHOLD") == nil {
                setenv("COREAI_CHUNK_THRESHOLD", "1", 1)
                setChunkThreshold = true
            }
        } else if setChunkThreshold {
            unsetenv("COREAI_CHUNK_THRESHOLD")
            setChunkThreshold = false
        }
    }

    func respond(system: String, user: String, schema: String, sharedUser: String? = nil,
                 maxAnswer: Int = ClassificationTokenBudget.preferredAnswer,
                 minimumAnswer: Int = ClassificationTokenBudget.minimumAnswer,
                 status: @escaping @Sendable (String) -> Void) async throws -> Answer {
        try Task.checkCancellation()
        let tokens = try template(system: system, user: user)
        let primedExtra = route == .pipelinedPrimed || grammarUnsupported ? 6 : 0
        guard let fullBudget = ClassificationTokenBudget.answerTokens(input: tokens.count + primedExtra, capacity: contextLimit,
                                                                      minimum: min(minimumAnswer, maxAnswer)) else {
            throw ClassificationError.contextCapacity("This sample exceeds the model's context capacity (\(tokens.count) input tokens, \(contextLimit) total capacity). Choose a model with a larger context.")
        }
        let answerBudget = min(maxAnswer, fullBudget)
        // The shared opening: how much of this prompt every part repeats.
        var sharedCount = 0
        if let sharedUser, let head = try? template(system: system, user: sharedUser) {
            sharedCount = zip(head, tokens).prefix { $0 == $1 }.count
        }
        switch route {
        case .staticShape, .sequential:
            return try await respondDirectly(tokens.map(Int32.init), sharedCount: sharedCount, schema: schema,
                                             budget: answerBudget, status: status)
        case .pipelinedPrimed:
            return try await respondPrimed(tokens, schema: schema, budget: answerBudget, status: status)
        case .runtimeGrammar:
            if grammarUnsupported {
                return try await respondPrimed(tokens, schema: schema, budget: answerBudget, status: status)
            }
            do {
                return try await respondPipelined(tokens, schema: schema, budget: answerBudget, status: status)
            } catch let error where Self.isMissingStateView(error) {
                try Task.checkCancellation()
                grammarUnsupported = true
                return try await respondPrimed(tokens, schema: schema, budget: answerBudget, status: status)
            }
        }
    }

    static func isMissingStateView(_ error: Error) -> Bool { CoreAIAnswerText.isMissingStateView(error) }

    /// The chat template shipped with a bundle (its tokenizer folder).
    static func templateText(in url: URL) -> String {
        for folder in [url.appending(path: "tokenizer"), url] {
            if let text = try? String(contentsOf: folder.appending(path: "chat_template.jinja"), encoding: .utf8) { return text }
            if let data = try? Data(contentsOf: folder.appending(path: "tokenizer_config.json")),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let text = object["chat_template"] as? String { return text }
        }
        return ""
    }

    // MARK: Pipelined engine, written freely: started, checked, cut back

    /// Pass 32/38: the pipelined engine's `generate()` (every input and state
    /// bound — Gemma 4's tables included). The answer is started for the
    /// model — `{"parts":[` after its turn opens — so it continues the list
    /// rather than chatting. Pass 38: each token is checked against the
    /// answer's schema as it arrives; the first token the schema can't take
    /// ends the answer, which keeps its finished parts (`salvage`) — no
    /// writing to the cap in prose or fences. Also stops at the end of its
    /// turn, the cap, a closed list, or a loop.
    private func respondPrimed(_ tokens: [Int], schema: String, budget: Int,
                               status: @escaping @Sendable (String) -> Void) async throws -> Answer {
        try await engine.reset()
        fed = []
        checkpointed = []
        if freeStopTokens.isEmpty {
            freeStopTokens = Set(["<end_of_turn>", "<|im_end|>", "<|eot_id|>", "<turn|>", "<|endoftext|>", "</s>", "<eos>"]
                .compactMap { tokenizer.convertTokenToId($0) }.map(Int32.init))
            if let eos = tokenizer.eosTokenId { freeStopTokens.insert(Int32(eos)) }
        }
        let opening = CoreAIPromptFormat.opening
        let openingTokens = tokenizer.encode(text: opening, addSpecialTokens: false)
        let primed = tokens + openingTokens
        // The schema, as a check (not a mask: this engine samples on the GPU).
        var matcher: GrammarMatcher?
        if let grammar = try? compiledGrammar(schema) {
            let candidate = GrammarMatcher(compiledGrammar: grammar, maxRollbackTokens: 0)
            // The opening's own tokens must pass, or the check is skipped
            // (a tokenizer that splits `{"parts":[` differently).
            if openingTokens.allSatisfy({ candidate.acceptToken(Int32($0)) }) { matcher = candidate }
        }
        status("Reading sample · \(primed.count) input tokens")
        var answer = Answer(promptTokens: primed.count)
        let started = Date.now
        var firstToken: Date?
        var generated: [Int] = []
        var leftFormat = false
        do {
            let sequence = try await engine.generate(with: primed.map(Int32.init), samplingConfiguration: sampling,
                                                     inferenceOptions: InferenceOptions(maxTokens: budget))
            for try await output in sequence {
                try Task.checkCancellation()
                if firstToken == nil { firstToken = .now }
                if freeStopTokens.contains(output.tokenId) { break }
                if let matcher, !matcher.acceptToken(output.tokenId) { leftFormat = true; break }
                generated.append(Int(output.tokenId))
                if generated.count == 1 || generated.count.isMultiple(of: 16) {
                    status("Writing classification · \(generated.count) tokens")
                }
                if let matcher, matcher.isCompleted || matcher.isTerminated { break }
                if generated.count.isMultiple(of: 6) {
                    let text = opening + tokenizer.decode(tokens: generated)
                    if Self.listClosed(text) { break }
                    if AnswerLoop.isLooping(text) { leftFormat = true; break }
                }
                if generated.count >= budget { break }
            }
            try? await engine.cancel()
        } catch {
            try? await engine.cancel()
            throw error
        }
        let text = opening + tokenizer.decode(tokens: generated)
        if leftFormat || !Self.listClosed(text), let kept = CoreAIAnswerText.salvage(text) {
            answer.text = kept
            answer.salvaged = kept != text
        } else {
            answer.text = text
        }
        answer.generatedTokens = generated.count
        answer.promptSeconds = (firstToken ?? .now).timeIntervalSince(started)
        answer.generateSeconds = max(0, Date.now.timeIntervalSince(started) - answer.promptSeconds)
        return answer
    }

    static func listClosed(_ text: String) -> Bool { CoreAIAnswerText.listClosed(text) }

    // MARK: Engines that return scores: driven here

    /// The answer held to the schema on the CPU, one step at a time (the
    /// static-shape engine; Pass 38: the sequential engine too).
    ///
    /// The part before shared its opening (rules, show, sponsors) with this
    /// one: that much of the engine's memory is kept and only the rest read.
    /// On a hybrid, whose recurrent state can't be wound back, the opening is
    /// read on its own first and checkpointed (CoreAIKit's TypedDecisions:
    /// bit-identical to reading it again, Mac, 24 Sep), and each later part
    /// returns to the checkpoint.
    private func respondDirectly(_ tokens: [Int32], sharedCount: Int, schema: String, budget: Int,
                                 status: @escaping @Sendable (String) -> Void) async throws -> Answer {
        var answer = Answer(promptTokens: tokens.count)
        let started = Date.now
        do {
            if reusesSharedPrompt {
                if engine.supportsCheckpoint, sharedCount >= 32, sharedCount < tokens.count {
                    let prefix = Array(tokens[..<sharedCount])
                    if prefix != checkpointed {
                        status("Reading sample · \(prefix.count) shared input tokens")
                        _ = try await rewind(keeping: prefix)
                        try await feed(prefix)
                        try await engine.checkpoint()
                        checkpointed = prefix
                    }
                }
                answer.reusedTokens = try await rewind(keeping: tokens)
            } else {
                try await engine.reset()
                fed = []
            }
        } catch {
            try? await engine.cancel()
            fed = []; checkpointed = []
            throw error
        }
        reuseNote = "shared \(sharedCount) · kept \(answer.reusedTokens) · engine \(type(of: engine)) · checkpoint \(engine.supportsCheckpoint) · processed \(engine.processedTokenCount)"
        status("Reading sample · \(tokens.count - answer.reusedTokens) input tokens")
        if steps {
            // Pass 34: the prompt through the narrow graphs (see StaticPrefill).
            let feedOptions = InferenceOptions(maxTokens: 1, includeLogits: false)
            do {
                for end in StaticPrefill.stepEnds(promptCount: tokens.count, alreadyRead: answer.reusedTokens) {
                    try Task.checkCancellation()
                    for try await _ in try await engine.generate(with: Array(tokens[..<end]), samplingConfiguration: .greedy,
                                                                 inferenceOptions: feedOptions) { break }
                }
            } catch {
                try? await engine.cancel()
                fed = []
                throw error
            }
        }

        let grammar = try compiledGrammar(schema)
        let matcher = GrammarMatcher(compiledGrammar: grammar, maxRollbackTokens: 0)
        var bitmask = [Int32](repeating: 0, count: (vocabularySize + 31) / 32)
        let options = InferenceOptions(maxTokens: 1, includeLogits: true)
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
                // The engine consumed exactly `input`; the token it sampled
                // was never fed back.
                fed = input
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
            fed = []; checkpointed = []
            throw error
        }
        answer.text = tokenizer.decode(tokens: generated.map(Int.init))
        answer.generatedTokens = generated.count
        answer.promptSeconds = (firstToken ?? .now).timeIntervalSince(started)
        answer.generateSeconds = max(0, Date.now.timeIntervalSince(started) - answer.promptSeconds)
        return answer
    }

    /// Winds the engine back to what `tokens` shares with what it has read
    /// (never all of it: the last token is read again for its scores). On a
    /// hybrid that means the checkpoint, or the start. Returns what was kept.
    private func rewind(keeping tokens: [Int32]) async throws -> Int {
        let wanted = min(zip(fed, tokens).prefix { $0 == $1 }.count, max(0, tokens.count - 1), engine.processedTokenCount)
        let kept: Int
        if wanted <= 0 {
            try await engine.reset(to: 0)
            kept = 0
        } else {
            do {
                try await engine.reset(to: wanted)
                kept = engine.processedTokenCount
            } catch InferenceRuntimeError.invalidState {
                // A hybrid below its checkpoint: read it all again.
                try await engine.reset(to: 0)
                kept = 0
            }
        }
        if kept < checkpointed.count { checkpointed = [] }
        fed = Array(tokens.prefix(kept))
        return kept
    }

    /// Reads `tokens` into the engine without asking for scores.
    private func feed(_ tokens: [Int32]) async throws {
        for try await _ in try await engine.generate(with: tokens, samplingConfiguration: .greedy,
                                                     inferenceOptions: InferenceOptions(maxTokens: 1, includeLogits: false)) { break }
        fed = tokens
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

    // MARK: Unhinted pipelined engines: the runtime's own constrained decoder

    private func respondPipelined(_ tokens: [Int], schema: String, budget: Int,
                                  status: @escaping @Sendable (String) -> Void) async throws -> Answer {
        try await engine.reset()
        fed = []
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

/// Pass 37: Gemma 4's two per-layer word tables as the constant buffers its
/// decoder reads (adapted from CoreAIKit 0.7.3 `GemmaRuntime`, Apache-2.0).
/// A copy in memory when there is room for it and the model's own working
/// memory (fast: ~30 words/s on an iPhone 17 Pro); otherwise read from
/// storage copy-on-write (clean pages iOS can drop; ~9 words/s there).
enum CoreAIGemmaTables {
    /// Decoder input → file in the tables folder.
    static let files = [("ple_table", "embed_per_layer.i8"), ("ple_scale", "embed_per_layer.scale.f32")]

    struct Loaded { var inputs: [String: StaticInputBuffer]; var mode: String }

    static func buffers(at folder: URL) throws -> Loaded {
        guard let device = MTLCreateSystemDefaultDevice() else { throw CoreAIGemmaError.noGraphics }
        var urls: [(String, URL)] = []
        for (input, file) in files {
            let url = folder.appending(path: file)
            guard FileManager.default.fileExists(atPath: url.path) else { throw CoreAIGemmaError.missingTable(file) }
            urls.append((input, url))
        }
        let total = urls.reduce(0) { $0 + ((try? $1.1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        if roomForCopy(totalBytes: total) {
            var owned: [String: StaticInputBuffer] = [:]
            do {
                for (input, url) in urls { owned[input] = StaticInputBuffer(try ownedBuffer(url, device)) }
                return Loaded(inputs: owned, mode: "in memory")
            } catch {
                // Not enough memory after all: read them from storage.
            }
        }
        var mapped: [String: StaticInputBuffer] = [:]
        for (input, url) in urls { mapped[input] = StaticInputBuffer(try mappedBuffer(url, device)) }
        return Loaded(inputs: mapped, mode: "read from storage")
    }

    /// The copy plus ~2.6 GB for the rest of the model's peak (CoreAIKit's
    /// device measurement for E2B).
    static func roomForCopy(totalBytes: Int, available: Int64? = nil) -> Bool {
        #if os(iOS)
        let free = available ?? Int64(os_proc_available_memory())
        if free == 0 { return true }
        return free - Int64(totalBytes) > 2_600_000_000
        #else
        return true
        #endif
    }

    private static func ownedBuffer(_ url: URL, _ device: any MTLDevice) throws -> any MTLBuffer {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw CoreAIGemmaError.missingTable(url.lastPathComponent) }
        defer { close(fd) }
        let size = Int(lseek(fd, 0, SEEK_END))
        _ = lseek(fd, 0, SEEK_SET)
        guard size > 0, let buffer = device.makeBuffer(length: size, options: .storageModeShared) else {
            throw CoreAIGemmaError.noMemory(url.lastPathComponent)
        }
        var done = 0
        while done < size {
            let n = read(fd, buffer.contents() + done, min(1 << 27, size - done))
            guard n > 0 else { throw CoreAIGemmaError.noMemory(url.lastPathComponent) }
            done += n
        }
        return buffer
    }

    private static func mappedBuffer(_ url: URL, _ device: any MTLDevice) throws -> any MTLBuffer {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw CoreAIGemmaError.missingTable(url.lastPathComponent) }
        defer { close(fd) }
        let size = Int(lseek(fd, 0, SEEK_END))
        guard size > 0 else { throw CoreAIGemmaError.noMemory(url.lastPathComponent) }
        let page = Int(getpagesize())
        let length = (size + page - 1) & ~(page - 1)
        // Copy-on-write and never written: the pages stay clean, so iOS can
        // drop them under pressure instead of counting them against the app.
        let mapped = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0)
        guard let mapped, mapped != MAP_FAILED else { throw CoreAIGemmaError.noMemory(url.lastPathComponent) }
        guard let buffer = device.makeBuffer(bytesNoCopy: mapped, length: length, options: .storageModeShared,
                                             deallocator: { pointer, length in _ = munmap(pointer, length) }) else {
            munmap(mapped, length)
            throw CoreAIGemmaError.noMemory(url.lastPathComponent)
        }
        return buffer
    }
}

enum CoreAIGemmaError: LocalizedError {
    case noGraphics, missingTable(String), noMemory(String)
    var errorDescription: String? {
        switch self {
        case .noGraphics: return "No graphics chip is available for Gemma's word tables."
        case .missingTable(let file): return "Gemma's word tables are incomplete (\(file) is missing). Download the model again."
        case .noMemory(let file): return "There isn't enough memory to load Gemma's word tables (\(file))."
        }
    }
}
#endif
