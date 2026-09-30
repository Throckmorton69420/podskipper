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
                              kv: Int64, _ summary: String) -> LocalModelSpec {
        LocalModelSpec(id: id, name: name, revision: revision, downloadBytes: bytes,
                       memoryNeeded: bytes + 3_000 * kv + 350_000_000, kvBytesPerToken: kv,
                       windowTokens: 8_000, overlapTokens: 800, experimental: false, summary: summary)
    }

    static let qwen35_4B = small("mlx-community/Qwen3.5-4B-MLX-4bit", "Qwen3.5 4B",
        "32f3e8ecf65426fc3306969496342d504bfa13f3", 3_061_129_077, kv: 85_000,
        "Test candidate. Alibaba, 4-bit. A 3.1 GB download (includes vision weights the app doesn't load).")
    static let miniCPM5_2B = small("openbmb/MiniCPM5-2B-MLX", "MiniCPM5 2B",
        "8a9ad7539ac86281d0ac2b017ba04a5de53fe9a3", 1_426_008_802, kv: 28_000,
        "Test candidate. OpenBMB, made for phones. A 1.4 GB download.")
    static let lfm25_2B = small("LiquidAI/LFM2.5-2.6B-MLX-4bit", "LFM2.5 2.6B",
        "04efa23776ce61ec34ec95ec34c859854c89542b", 1_601_108_840, kv: 40_000,
        "Test candidate. Liquid AI, made for phones; it always thinks before answering, which may slow it. A 1.6 GB download.")
    static let gemma4_E2B = small("mlx-community/gemma-4-e2b-it-4bit", "Gemma 4 E2B",
        "238767527555cb75a05732a84dff5d6ba0dd6809", 3_583_086_498, kv: 24_000,
        "Test candidate. Google, made for phones. A 3.6 GB download (includes vision/audio weights).")
    static let ministral3_3B = small("mlx-community/Ministral-3-3B-Instruct-2512-4bit", "Ministral 3 3B",
        "a962dcb09eee4169c890e544c9eb938f1113fdee", 2_779_150_244, kv: 70_000,
        "Test candidate. Mistral. A 2.8 GB download (includes vision weights).")
    static let nemotron3_4B = small("mlx-community/NVIDIA-Nemotron-3-Nano-4B-4bit", "Nemotron 3 Nano 4B",
        "c4d79ba1901d99806ef757642a552acebb851a35", 2_254_200_328, kv: 30_000,
        "Test candidate. NVIDIA, English only. A 2.3 GB download.")
    static let smolLM3_3B = small("mlx-community/SmolLM3-3B-4bit", "SmolLM3 3B",
        "d3a7e0594d6642dbcfb7d149bed8b0bdf49f95ce", 1_747_378_363, kv: 48_000,
        "Test candidate. Hugging Face. A 1.7 GB download.")

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

    static let all: [LocalModelSpec] = [qwen35_4B, miniCPM5_2B, lfm25_2B, gemma4_E2B, ministral3_3B,
                                        nemotron3_4B, smolLM3_3B, ternaryBonsai8B, bonsai8B, bonsai27B]

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
