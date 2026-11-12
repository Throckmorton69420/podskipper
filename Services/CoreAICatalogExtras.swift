import Foundation

// Pass 63 (his 10 Nov request: the Core AI models he asked for — GPT-OSS,
// Mistral, Mixtral, Muse Glimmer, Qwen3.5 4B and its Instruct, Qwen3.5 2B,
// LFM3 1.7B, Nanbeige4.2 3B, Gemma 4 E2B, Qwen2.5 — shown with what this
// iPhone can really do with each).
//
// What the audit found (11 Nov 2026, the Core AI kit's live catalog and the
// publishers' repositories on Hugging Face):
//
// - **In the catalog with an iPhone build:** Qwen3.5 2B, Nanbeige4.2 3B,
//   Gemma 4 E2B (needs a copy compiled for this iPhone), LFM3 1.7B — whose
//   iPhone build is compiled for one chip only ("architectures": ["h19p"]).
//   The kit this app links (0.7.3) drops that field, so PodSkipper offered
//   that build to an iPhone 16 Pro as if it ran there. `CoreAICatalogDetails`
//   reads the field; the portable GPU build of the same model is used.
// - **In the catalog for the Mac only:** Mistral 7B v0.3, Gemma 3 4B, LFM2.5
//   2.6B and others. The app listed only models with an iPhone build, so
//   these never appeared. They are listed now: with the Mac's GPU build
//   where its weights fit in what iOS lets PodSkipper hold (as Qwen3 4B
//   already runs here from its Mac build), and as too large where not.
// - **Published as Core AI but not in the catalog:** Qwen3.5 4B, GPT-OSS
//   20B, Muse Glimmer 30B, Qwen2.5 1.5B Instruct (`CoreAIExtraModels`).
// - **Not published as Core AI by anyone:** Mixtral, Qwen3.5 4B Instruct
//   (`CoreAIExtraModels.notPublished`).

/// What the catalog says of each build that the kit's `CatalogEntry` doesn't
/// carry: the chips an iPhone build is compiled for, and its own engine.
struct CoreAICatalogDetails: Decodable, Sendable {
    struct Variant: Decodable, Sendable {
        var path: String
        var engine: String?
        var architectures: [String]?
    }
    struct Model: Decodable, Sendable {
        var id: String
        var variants: [String: Variant]
    }
    var models: [Model]

    func variant(_ id: String, _ platform: String) -> Variant? {
        models.first { $0.id == id }?.variants[platform]
    }

    static let empty = CoreAICatalogDetails(models: [])
    static let address = URL(string: "https://raw.githubusercontent.com/john-rocky/coreai-kit/main/catalog.json")!
    private static var cacheURL: URL { URL.cachesDirectory.appending(path: "coreai-catalog-details.json") }

    /// The live catalog's details; the last copy read when the network is
    /// slow or away (8 s), nothing when there has never been one.
    static func load() async -> CoreAICatalogDetails {
        var request = URLRequest(url: address)
        request.timeoutInterval = 8
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
           let parsed = try? JSONDecoder().decode(CoreAICatalogDetails.self, from: data) {
            try? data.write(to: cacheURL, options: .atomic)
            return parsed
        }
        if let data = try? Data(contentsOf: cacheURL),
           let parsed = try? JSONDecoder().decode(CoreAICatalogDetails.self, from: data) { return parsed }
        return .empty
    }
}

/// Which build of a Core AI model this iPhone uses, and whether it can.
enum CoreAICompatibility {
    struct Build: Equatable, Sendable {
        var path: String
        var sizeMB: Int?
        /// Chips the build is compiled for (the catalog's "architectures");
        /// empty: any, or named in the path.
        var architectures: [String] = []
    }

    struct Resolution: Equatable, Sendable {
        /// The folder to download and load; nil when there is none to use.
        var path: String?
        var sizeMB: Int?
        var compatible: Bool
        /// The Mac's (portable GPU) build stands in for the iPhone's.
        var usesMacBuild = false
        /// Why it can't run here.
        var reason: String?
        /// What he should know before downloading it.
        var note: String?
    }

    /// Megabytes of weights PodSkipper can hold: what iOS allows this app
    /// (about 84 % of the iPhone's memory with the increased limit his
    /// builds carry, about half without) less working room for the read.
    static func weightBudgetMB(physicalMB: Int, increasedLimit: Bool) -> Int {
        Int(Double(physicalMB) * (increasedLimit ? 0.84 : 0.5)) - 600
    }

    /// The chip a build is compiled for that this iPhone isn't: named in its
    /// path ("ios-h18p/…") or listed by the catalog; nil when it runs here.
    static func foreignChip(_ build: Build, machine: String) -> String? {
        if let chip = CoreAIBundleLimits.aotChip(build.path) {
            return CoreAIBundleLimits.runs(chip: chip, machine: machine) ? nil : chip
        }
        guard !build.architectures.isEmpty else { return nil }
        return build.architectures.contains { CoreAIBundleLimits.runs(chip: $0, machine: machine) } ? nil : build.architectures[0]
    }

    static func gigabytes(_ megabytes: Int) -> String { String(format: "%.1f GB", Double(megabytes) / 1_000) }

    static func resolve(ios: Build?, mac: Build?, machine: String, weightBudgetMB budget: Int) -> Resolution {
        func memory(_ build: Build) -> (fits: Bool, note: String?) {
            guard let size = build.sizeMB else { return (true, nil) }
            if size > budget { return (false, nil) }
            // Within a gigabyte of the most it can hold: said before he downloads it.
            return (true, size > budget - 1_000
                    ? "Its \(gigabytes(size)) of weights are close to the most iOS lets PodSkipper hold on this iPhone (about \(gigabytes(budget))); it may close PodSkipper while it reads."
                    : nil)
        }
        func tooLarge(_ build: Build) -> Resolution {
            Resolution(path: nil, sizeMB: build.sizeMB, compatible: false,
                       reason: "Too large for this iPhone: \(build.sizeMB.map(gigabytes) ?? "its") of weights, and iOS lets PodSkipper hold about \(gigabytes(budget))")
        }
        // The Mac's build is one the iPhone can prepare itself when it is a
        // GPU build with no chip in its name.
        let portableMac = mac.flatMap { CoreAIBundleLimits.aotChip($0.path) == nil ? $0 : nil }
        if let ios {
            if let chip = foreignChip(ios, machine: machine) {
                let phone = CoreAIBundleLimits.phoneName(chip: chip)
                guard let portable = portableMac, portable.path.contains("gpu-pipelined") else {
                    return Resolution(path: nil, sizeMB: ios.sizeMB, compatible: false,
                                      reason: "Built only for the \(phone)’s chip")
                }
                let room = memory(portable)
                guard room.fits else { return tooLarge(portable) }
                return Resolution(path: portable.path, sizeMB: portable.sizeMB, compatible: true, usesMacBuild: true,
                                  note: ["The iPhone build is compiled only for the \(phone)’s chip, so PodSkipper uses the portable build of the same model, which Core AI prepares on this iPhone the first time it loads (slower first start).", room.note]
                                    .compactMap { $0 }.joined(separator: " "))
            }
            let room = memory(ios)
            guard room.fits else { return tooLarge(ios) }
            return Resolution(path: ios.path, sizeMB: ios.sizeMB, compatible: true, note: room.note)
        }
        guard let portable = portableMac else {
            return Resolution(path: nil, sizeMB: mac?.sizeMB, compatible: false, reason: "Not published for iPhone")
        }
        let room = memory(portable)
        guard room.fits else { return tooLarge(portable) }
        return Resolution(path: portable.path, sizeMB: portable.sizeMB, compatible: true, usesMacBuild: true,
                          note: ["Published for the Mac only. PodSkipper uses that GPU build, which Core AI prepares on this iPhone the first time it loads. Not yet tested on this iPhone.", room.note]
                            .compactMap { $0 }.joined(separator: " "))
    }
}

/// Core AI models their publishers host that the kit's catalog doesn't list
/// (11 Nov 2026), each pinned to the commit its files were measured at.
struct CoreAIExtraModel: Sendable, Equatable {
    var id: String
    var name: String
    var repo: String
    var revision: String
    var ios: CoreAICompatibility.Build?
    var mac: CoreAICompatibility.Build?
    var engine: String?
    var thinking: Bool?
}

enum CoreAIExtraModels {
    static let list: [CoreAIExtraModel] = [
        CoreAIExtraModel(id: "qwen3.5-4b", name: "Qwen3.5 4B", repo: "mlboydaisuke/qwen3.5-4B-CoreAI",
                         revision: "338a6d1c1ca923c60173557cda2539a36830d073", ios: nil,
                         mac: .init(path: "gpu-pipelined-b2/qwen3_5_4b_decode_int8hu_block32_sym", sizeMB: 5_771),
                         engine: "pipelined", thinking: true),
        CoreAIExtraModel(id: "qwen2.5-1.5b-instruct", name: "Qwen2.5 1.5B Instruct", repo: "kevinqz/Qwen2.5-1.5B-Instruct-CoreAI",
                         revision: "f903417cb9ac4b3c4c53c16aefd7f097cc6b8338",
                         ios: .init(path: "int8", sizeMB: 1_657), mac: .init(path: "int8", sizeMB: 1_657),
                         engine: nil, thinking: nil),
        CoreAIExtraModel(id: "gpt-oss-20b", name: "GPT-OSS 20B", repo: "mlboydaisuke/gpt-oss-20b-CoreAI-official",
                         revision: "a4a19ce3f9d4581c8fe1b4087482807ca18819df", ios: nil,
                         mac: .init(path: "macos", sizeMB: 13_789), engine: nil, thinking: true),
        CoreAIExtraModel(id: "muse-glimmer-30b", name: "Muse Glimmer 30B", repo: "mlboydaisuke/Muse-Glimmer-30B-CoreAI",
                         revision: "7f3d8a991feec5eeb701f6642aaccfb1cab67827", ios: nil,
                         mac: .init(path: "gpu-pipelined/muse_glimmer_30b_decode_int4hu_block32_sym", sizeMB: 16_375),
                         engine: "pipelined", thinking: nil),
    ]

    /// Asked for, and published as Core AI by nobody (searched 11 Nov 2026).
    static let notPublished = ["Mixtral", "Qwen3.5 4B Instruct"]

    static var notPublishedNote: String {
        "No Core AI build of " + notPublished.joined(separator: " or ") + " has been published, so they can’t be offered here; their MLX builds, where there is one, are under Open-source models."
    }
}
