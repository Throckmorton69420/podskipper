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
        summary: "Recommended. A 2.3 GB download.")

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
        summary: "Smaller and faster, a little less accurate. A 1.3 GB download.")

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

    static let all: [LocalModelSpec] = [ternaryBonsai8B, bonsai8B, bonsai27B]

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
