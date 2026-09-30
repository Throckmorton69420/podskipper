import Foundation

/// The on-device ad models the app can download.
///
/// All three are PrismML Bonsai builds in MLX format. The 1-bit ones need
/// PrismML's fork of mlx-swift (project.yml); Ternary Bonsai 8B is MLX's
/// ordinary 2-bit format and would run on stock mlx-swift too — the fork is
/// stock mlx-swift plus the 1-bit kernels, so it serves all three. Commits
/// are pinned so the files on the phone never change under a download that
/// was paused for days.
struct LocalModelSpec: Identifiable, Hashable, Sendable {
    /// The Hugging Face repository.
    let id: String
    let name: String
    /// The repository commit every file is downloaded from.
    let revision: String
    /// What the files text generation needs add up to, from the repository
    /// listing, for the screen before the listing has been fetched.
    let downloadBytes: Int64
    /// Free memory needed to load it and read the *smallest* window: weights,
    /// an 8-bit attention cache for that window, and working room.
    let memoryNeeded: Int64
    /// Bytes of 8-bit attention cache per token of window (0 = unknown: the
    /// full window is required and `memoryNeeded` is taken as its need).
    /// Transcript tokens per window, and how many the next window repeats.
    let kvBytesPerToken: Int64
    let windowTokens: Int
    let overlapTokens: Int
    /// Offered, but likely too big for this phone: checked against free
    /// memory before downloading as well as before loading.
    let experimental: Bool
    /// One plain line for the picker.
    let summary: String
    /// Keys added to config.json after download, for a checkpoint whose
    /// config the loader can't parse as published (pass 27g: Nemotron 3
    /// Nano 4B has no MoE layers but the loader requires the MoE fields).
    var configPatch: [String: Int] = [:]

    // Window sizes. The 8B models read larger windows: they are small enough
    // to leave room for the longer attention cache (brief update, 29 Sep).
    static let windowTokens8B = 12_000
    static let overlapTokens8B = 1_000
    static let windowTokens27B = 6_000
    static let overlapTokens27B = 800

    /// Ternary Bonsai 8B (Qwen3-8B base, weights −1/0/+1 stored as MLX 2-bit).
    /// Loaded and answered correctly on his iPhone 16 Pro in Locally AI.
    static let ternaryBonsai8B = LocalModelSpec(
        id: "prism-ml/Ternary-Bonsai-8B-mlx-2bit",
        name: "Ternary Bonsai 8B",
        revision: "9260b24298e4211e804663e9f519962cf59f34be",
        downloadBytes: 2_315_155_948,
        memoryNeeded: 2_315_155_948 + 3_000 * 83_000 + 350_000_000,
        kvBytesPerToken: 83_000,
        windowTokens: windowTokens8B,
        overlapTokens: overlapTokens8B,
        experimental: false,
        summary: "Experimental. A 2.3 GB download. On this iPhone 16 Pro it read 59 tokens a second and iOS closed the app for memory on long parts.")

    /// Bonsai 8B, 1-bit (Qwen3-8B base).
    static let bonsai8B = LocalModelSpec(
        id: "prism-ml/Bonsai-8B-mlx-1bit",
        name: "Bonsai 8B 1-bit",
        revision: "019934f87a61a654e3960ea22f53688e0d2c49ba",
        downloadBytes: 1_291_627_301,
        memoryNeeded: 1_291_627_301 + 3_000 * 83_000 + 350_000_000,
        kvBytesPerToken: 83_000,
        windowTokens: windowTokens8B,
        overlapTokens: overlapTokens8B,
        experimental: false,
        summary: "Experimental. Smaller, a little less accurate. A 1.3 GB download.")

    /// Bonsai 27B, 1-bit (Qwen3.6-27B base). The single safetensors file also
    /// holds the 0.46B vision tower; the loader drops those weights without
    /// reading them, so they cost disk, not memory.
    static let bonsai27B = LocalModelSpec(
        id: "prism-ml/Bonsai-27B-mlx-1bit",
        name: "Bonsai 27B 1-bit",
        revision: "ef22f239c670078e1507f9769bcaa66657332b96",
        downloadBytes: 5_149_303_327,
        memoryNeeded: 6_300_000_000,
        kvBytesPerToken: 0,
        windowTokens: windowTokens27B,
        overlapTokens: overlapTokens27B,
        experimental: true,
        summary: "Experimental — may not fit in this iPhone's memory. A 5.1 GB download.")

    // Pass 27d (his request, 30 Sep): small open models to download and
    // test one by one with Test the Model, then a Find Ads. Repos and
    // commits checked on Hugging Face on 30 Sep; every model type is one
    // mlx-swift-lm (c043fb3) loads. Attention cache per token is an
    // overestimate (layers × KV heads × head size × 2, 8-bit, +30 %); the
    // breadcrumb lowers the window if iOS closes the app anyway.
    private static func small(_ id: String, _ name: String, _ revision: String, _ bytes: Int64,
                              kv: Int64, window: Int = 8_000, _ summary: String) -> LocalModelSpec {
        LocalModelSpec(id: id, name: name, revision: revision, downloadBytes: bytes,
                       memoryNeeded: bytes + 3_000 * kv + 350_000_000, kvBytesPerToken: kv,
                       windowTokens: window, overlapTokens: min(800, window / 8), experimental: false, summary: summary)
    }

    static let qwen35_4B = small("mlx-community/Qwen3.5-4B-MLX-4bit", "Qwen3.5 4B",
        "32f3e8ecf65426fc3306969496342d504bfa13f3", 3_061_129_077, kv: 85_000,
        "Tested 30 Sep: found the ad, read 194 tok/s, wrote 18 tok/s, peak 3.1 GB. Alibaba. A 3.1 GB download.")
    static let miniCPM5_2B = small("openbmb/MiniCPM5-2B-MLX", "MiniCPM5 2B",
        "8a9ad7539ac86281d0ac2b017ba04a5de53fe9a3", 1_426_008_802, kv: 28_000,
        "Tested 30 Sep: fastest (298 tok/s) and wrote the right answer, but it was cut off; the app now reads cut-off answers — test again. A 1.4 GB download.")
    static let lfm25_2B = small("LiquidAI/LFM2.5-2.6B-MLX-4bit", "LFM2.5 2.6B",
        "04efa23776ce61ec34ec95ec34c859854c89542b", 1_601_108_840, kv: 40_000,
        "Tested 30 Sep: spent its whole answer thinking and found nothing. Liquid AI. A 1.6 GB download.")
    static let gemma4_E2B = small("mlx-community/gemma-4-e2b-it-4bit", "Gemma 4 E2B",
        "238767527555cb75a05732a84dff5d6ba0dd6809", 3_583_086_498, kv: 24_000,
        "No result recorded on 30 Sep (iOS may have closed the app). Google. A 3.6 GB download.")
    static let ministral3_3B = small("mlx-community/Ministral-3-3B-Instruct-2512-4bit", "Ministral 3 3B",
        "a962dcb09eee4169c890e544c9eb938f1113fdee", 2_779_150_244, kv: 70_000,
        "Tested 30 Sep: found the ad (plus intro/outro), read 159 tok/s, peak 2.7 GB. Mistral. A 2.8 GB download.")
    static let nemotron3_4B: LocalModelSpec = {
        var spec = small("mlx-community/NVIDIA-Nemotron-3-Nano-4B-4bit", "Nemotron 3 Nano 4B",
            "c4d79ba1901d99806ef757642a552acebb851a35", 2_254_200_328, kv: 30_000,
            "Test candidate. NVIDIA, English only. A 2.3 GB download. Its config is patched so it loads.")
        // Its layer pattern has no "E" (MoE) layers, so these are never used.
        spec.configPatch = ["moe_intermediate_size": 12_544, "moe_shared_expert_intermediate_size": 12_544,
                            "n_routed_experts": 1, "num_experts_per_tok": 1]
        return spec
    }()

    /// Adds the missing keys to a downloaded config.json. Safe to repeat.
    nonisolated static func patchConfig(of spec: LocalModelSpec, in folder: URL) {
        guard !spec.configPatch.isEmpty else { return }
        let url = folder.appending(path: "config.json")
        guard let data = try? Data(contentsOf: url),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var changed = false
        for (key, value) in spec.configPatch where object[key] == nil || object[key] is NSNull {
            object[key] = value
            changed = true
        }
        guard changed, let out = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? out.write(to: url, options: .atomic)
    }
    static let smolLM3_3B = small("mlx-community/SmolLM3-3B-4bit", "SmolLM3 3B",
        "d3a7e0594d6642dbcfb7d149bed8b0bdf49f95ce", 1_747_378_363, kv: 48_000,
        "Tested 30 Sep: marked the whole sample as an ad — unsafe. Hugging Face. A 1.7 GB download.")

    static let qwen35_2B = small("mlx-community/Qwen3.5-2B-MLX-4bit", "Qwen3.5 2B",
        "93760be4f1f69842a46bc13dbdc0f19e291392a3", 1_749_079_691, kv: 40_000,
        "Test candidate. Alibaba, the smaller Qwen3.5. A 1.7 GB download.")
    static let miniCPM5_1B = small("openbmb/MiniCPM5-1B-MLX", "MiniCPM5 1B",
        "9879b18bf2928355fcdf4287635388a3665a40cb", 617_970_878, kv: 16_000,
        "Test candidate. OpenBMB. A 0.6 GB download.")
    static let phi4Mini = small("mlx-community/Phi-4-mini-instruct-4bit", "Phi-4 mini 3.8B",
        "ac1c269cb4222a4e136a3d09edad301056c1f36a", 2_179_993_199, kv: 80_000,
        "Test candidate. Microsoft. A 2.2 GB download.")
    static let llama32_3B = small("mlx-community/Llama-3.2-3B-Instruct-4bit", "Llama 3.2 3B",
        "7f0dc925e0d0afb0322d96f9255cfddf2ba5636e", 1_824_807_894, kv: 75_000,
        "Test candidate. Meta. A 1.8 GB download.")
    static let gemma3_4B = small("mlx-community/gemma-3-4b-it-qat-4bit", "Gemma 3 4B",
        "3d9ef289111449933c22761961f16a5df237ce2a", 3_034_683_375, kv: 90_000,
        "Test candidate. Google. A 3.0 GB download.")
    static let graniteMicro = small("mlx-community/granite-4.0-h-micro-4bit", "Granite 4.0 H Micro",
        "0a29e17503da7de371af61a0a532853810637627", 1_806_620_464, kv: 30_000,
        "Test candidate. IBM. A 1.8 GB download.")
    static let granite1B = small("mlx-community/granite-4.0-h-1b-4bit", "Granite 4.0 H 1B",
        "a5a21e23f01a461f501dcd2b7a34c9efc6fba6a6", 833_194_668, kv: 20_000,
        "Test candidate. IBM. A 0.8 GB download.")
    static let lfm25_350M = small("LiquidAI/LFM2.5-350M-MLX-4bit", "LFM2.5 350M",
        "f6cb4e006bb7a2d8a6afa14ec0a53e0586f65a5b", 226_571_069, kv: 10_000,
        "Test candidate. Liquid AI, tiny. A 0.2 GB download.")
    static let ternaryBonsai4B = small("prism-ml/Ternary-Bonsai-4B-mlx-2bit", "Ternary Bonsai 4B",
        "e1374ad6bf9b1b56afd743936b8faa33c409a75f", 1_143_060_456, kv: 80_000,
        "Test candidate. PrismML. A 1.1 GB download.")
    static let ternaryBonsai1_7B = small("prism-ml/Ternary-Bonsai-1.7B-mlx-2bit", "Ternary Bonsai 1.7B",
        "5f3e306330f636cfc6c6241b4850fae6711c5985", 495_529_363, kv: 62_000,
        "Test candidate. PrismML. A 0.5 GB download.")

    static let qwen35_4B_instruct = small("ALTICDEV/Qwen3.5-4B-Instruct-MLX-Q6", "Qwen3.5 4B Instruct (6-bit)",
        "00a036421c2f892d998408e53a38cbb332d56d7a", 3_438_518_507, kv: 85_000,
        "Test candidate. Qwen3.5 4B, text only, instruct chat template, 6-bit (community conversion). A 3.4 GB download.")
    static let gemma4_E4B = small("mlx-community/gemma-4-e4b-it-4bit", "Gemma 4 E4B",
        "475b9088d29754a3379866cf5aeb6b41acd313c2", 5_179_239_349, kv: 45_000,
        "Test candidate, likely too big: about 3.4 GB is free for the app on this phone. A 5.2 GB download.")
    static let phi3Mini = small("mlx-community/Phi-3-mini-4k-instruct-4bit", "Phi-3 mini 3.8B",
        "5b3819ed6317784fb20eddeae9bed984f778d0d0", 2_151_578_230, kv: 260_000, window: 3_000,
        "Test candidate. Microsoft, older; reads at most 4,000 tokens at once. A 2.2 GB download.")
    static let dolphinLlama3B = small("mlx-community/dolphin3.0-llama3.2-3B-4Bit", "Dolphin 3.0 Llama 3.2 3B",
        "cdc777b578ff86a69f1b05c9bc00df0cdc2f52d1", 1_824_808_562, kv: 75_000,
        "Test candidate. A Llama 3.2 3B fine-tune. A 1.8 GB download.")

    /// Windows tried from largest to smallest until one fits in free memory.
    static let windowSteps = [12_000, 8_000, 6_000, 4_000, 3_000]

    /// Qwen3-8B: 36 layers × 8 KV heads × 128 dims × (K+V) at 8 bits ≈ 74 KB a
    /// token, ~83 KB with quantisation scales. Working room: activations,
    /// tokenizer, the prompt's own tokens, 350 MB.
    func memoryNeeded(window: Int) -> Int64 {
        guard kvBytesPerToken > 0 else { return memoryNeeded }
        return downloadBytes + Int64(window) * kvBytesPerToken + 350_000_000
    }

    /// The largest window (≤ this model's own) that fits in `available`
    /// bytes, keeping 5 % spare; nil when even the smallest doesn't.
    func windowThatFits(available: Int64) -> Int? {
        let usable = available * 95 / 100
        guard kvBytesPerToken > 0 else { return usable >= memoryNeeded ? windowTokens : nil }
        return Self.windowSteps.filter { $0 <= windowTokens }.first { memoryNeeded(window: $0) <= usable }
    }

    static let all: [LocalModelSpec] = [qwen35_4B, qwen35_4B_instruct, qwen35_2B, miniCPM5_2B, miniCPM5_1B, ministral3_3B,
                                        phi4Mini, phi3Mini, nemotron3_4B, llama32_3B, dolphinLlama3B, gemma4_E2B, gemma4_E4B, gemma3_4B, graniteMicro, granite1B,
                                        lfm25_2B, lfm25_350M, smolLM3_3B, ternaryBonsai4B, ternaryBonsai1_7B,
                                        ternaryBonsai8B, bonsai8B, bonsai27B]

    /// The model used until he picks another. The one-line switch.
    static let preferred: LocalModelSpec = .ternaryBonsai8B

    static func named(_ id: String?) -> LocalModelSpec {
        all.first { $0.id == id } ?? preferred
    }

    /// Only what text generation reads, the same patterns mlx-swift-lm's own
    /// downloader uses (`*.safetensors`, `*.json`, `*.jinja`), minus the
    /// image and video settings the 27B's vision tower would need.
    static func isNeeded(_ path: String) -> Bool {
        guard !path.contains("/") else { return false }
        let visionOnly: Set<String> = ["preprocessor_config.json", "processor_config.json",
                                       "video_preprocessor_config.json"]
        if visionOnly.contains(path) { return false }
        return path.hasSuffix(".safetensors") || path.hasSuffix(".json") || path.hasSuffix(".jinja")
    }
}
