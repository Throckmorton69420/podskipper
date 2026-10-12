import Foundation

/// Pass 35: a Core AI model compiled ahead of time for this iPhone's chip,
/// installed beside the download, so Core AI loads it instead of compiling
/// the model on the phone.
///
/// Why (his 9 Oct phone, 36410ed, and the Pass 33 reports before it): every
/// Qwen3 4B closure is the same abort, symbolicated against iOS 27.0.1:
/// `MTLReportFailure` inside `-[MPSGraphExecutable specializedModuleWithDevice:
/// shapedEntryPoints:…]`, from `MPSGraphDelegate.resolveCoreAI` — Core AI
/// compiling part of the model for this iPhone the first time it is used.
/// The iPhone build its publisher ships (`ios/…_static.aimodel`) is the
/// uncompiled graph; the model card itself says iOS static bundles "must be
/// AOT-compiled before device use", and only publishes that for iPhone 17
/// Pro (h18p). Compiling it for iPhone 16 Pro (h17p) on a Mac with
/// `xcrun coreai-build compile … --platform iOS --preferred-compute
/// neural-engine --architecture h17p` took 17 minutes and a 12 GB peak
/// memory footprint — more than this 8 GB iPhone has. CoreAIKit records
/// the same on-device compile abort for its 1.6 GB Whisper graph.
///
/// Installing: the compiled `<name>.<chip>.aimodelc` folder is copied into
/// the downloaded bundle (staged, then moved in one step), and the bundle's
/// `metadata.json` names it as the graph to load. The original metadata is
/// kept as `metadata.portable.json`, and the downloaded graph is never
/// touched, so removing the compiled copy restores the download exactly.
enum CoreAICompiledCopy {
    enum Failure: LocalizedError, Equatable {
        case notACompiledModel, wrongChip(String), wrongModel(String), noRoom(String), unreadable(String)
        var errorDescription: String? {
            switch self {
            case .notACompiledModel: "That folder isn't a compiled Core AI model (a folder ending in .aimodelc with metadata.json and a .mlirb inside)."
            case .wrongChip(let chip): "That copy is compiled for \(chip), not for this iPhone's chip."
            case .wrongModel(let name): "That copy is a different model (\(name)) from this download."
            case .noRoom(let message): message
            case .unreadable(let why): "Couldn't install it: \(why)"
            }
        }
    }

    static let portableMetadata = "metadata.portable.json"

    /// The compiled graph the bundle loads now, if it is one.
    static func installed(in bundle: URL) -> String? {
        guard let main = mainAsset(in: bundle), main.hasSuffix(".aimodelc"),
              FileManager.default.fileExists(atPath: bundle.appending(path: main).path) else { return nil }
        return main
    }

    /// The bundle's `assets.main`.
    static func mainAsset(in bundle: URL) -> String? {
        guard let data = try? Data(contentsOf: bundle.appending(path: "metadata.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [String: Any] else { return nil }
        return assets["main"] as? String
    }

    /// Checks `source` is a compiled copy of this bundle's model for `machine`.
    static func validate(_ source: URL, for bundle: URL, machine: String) throws {
        let fm = FileManager.default
        let name = source.lastPathComponent
        guard name.hasSuffix(".aimodelc"), !name.contains("/"),
              fm.fileExists(atPath: source.appending(path: "metadata.json").path),
              ((try? fm.contentsOfDirectory(atPath: source.path)) ?? []).contains(where: { $0.hasSuffix(".mlirb") })
        else { throw Failure.notACompiledModel }
        let chip = CoreAIBundleLimits.aotChip(name) ?? "an unknown chip"
        guard CoreAIBundleLimits.aotChip(name) != nil, CoreAIBundleLimits.runs(chip: chip, machine: machine) else {
            throw Failure.wrongChip(chip)
        }
        // The download's graph is "<stem>.aimodel"; the compiled one "<stem>.<chip>.aimodelc".
        let jit = portableMain(in: bundle) ?? mainAsset(in: bundle) ?? ""
        let stem = jit.replacingOccurrences(of: ".aimodelc", with: "").replacingOccurrences(of: ".aimodel", with: "")
        guard !stem.isEmpty, name.hasPrefix(stem + ".") else {
            throw Failure.wrongModel(String(name.prefix(while: { $0 != "." })))
        }
    }

    /// The download's own graph name, from the kept original metadata.
    static func portableMain(in bundle: URL) -> String? {
        guard let data = try? Data(contentsOf: bundle.appending(path: portableMetadata)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [String: Any] else { return nil }
        return assets["main"] as? String
    }

    /// Copies `source` into `bundle` and points the bundle at it.
    static func install(from source: URL, into bundle: URL, machine: String, free: Int64? = ModelStorage.freeBytes()) throws {
        try validate(source, for: bundle, machine: machine)
        let fm = FileManager.default
        let bytes = ModelStorage.size(of: source)
        let room = StorageGuard.check(writing: bytes, free: free)
        if case .insufficient = room { throw Failure.noRoom(StorageGuard.message(for: room, doing: "install the compiled copy") ?? "") }
        let name = source.lastPathComponent
        let staging = bundle.appending(path: ".podskipper-staging-aot-" + UUID().uuidString, directoryHint: .isDirectory)
        let destination = bundle.appending(path: name, directoryHint: .isDirectory)
        do {
            try fm.copyItem(at: source, to: staging)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: staging, to: destination)
            // Keep the download's metadata once, then name the compiled graph.
            let metadata = bundle.appending(path: "metadata.json")
            let kept = bundle.appending(path: portableMetadata)
            if !fm.fileExists(atPath: kept.path) { try fm.copyItem(at: metadata, to: kept) }
            let data = try Data(contentsOf: kept)
            guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var assets = json["assets"] as? [String: Any] else { throw Failure.unreadable("metadata.json has no assets") }
            assets["main"] = name
            json["assets"] = assets
            let updated = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try updated.write(to: metadata, options: .atomic)
        } catch {
            try? fm.removeItem(at: staging)
            if let failure = error as? Failure { throw failure }
            throw Failure.unreadable(error.localizedDescription)
        }
    }

    /// Back to the download exactly as it was: its metadata, no compiled copy.
    static func remove(from bundle: URL) throws {
        let fm = FileManager.default
        let kept = bundle.appending(path: portableMetadata)
        let compiled = installed(in: bundle)
        if fm.fileExists(atPath: kept.path) {
            let metadata = bundle.appending(path: "metadata.json")
            let data = try Data(contentsOf: kept)
            try data.write(to: metadata, options: .atomic)
            try fm.removeItem(at: kept)
        }
        if let compiled { try fm.removeItem(at: bundle.appending(path: compiled)) }
        // Any other compiled copies left beside it.
        for item in (try? fm.contentsOfDirectory(atPath: bundle.path)) ?? [] where item.hasSuffix(".aimodelc") {
            try? fm.removeItem(at: bundle.appending(path: item))
        }
    }
}
