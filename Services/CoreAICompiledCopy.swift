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
        case notACompiledModel, wrongChip(String), wrongModel(String), wrongSource, noRoom(String), unreadable(String), inUse(String)
        var errorDescription: String? {
            switch self {
            case .notACompiledModel: "That folder isn't a compiled Core AI model (a folder ending in .aimodelc with metadata.json and a .mlirb inside)."
            case .wrongChip(let chip): "That copy is compiled for \(chip), not for this iPhone's chip."
            case .wrongModel(let name): "That copy is a different model (\(name)) from this download."
            case .wrongSource: "That copy was compiled from a different version of this model than the one downloaded here, so it isn't used. Download the matching version, or compile this download again."
            case .inUse(let name): "\(name) is being used or prepared right now; try again when that has finished."
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

    /// Pass 36: the SHA-256 Core AI records for a graph's source. A source
    /// `.aimodel` keeps it in `main.hash` (32 bytes, the hash of its
    /// `main.mlirb`); `coreai-build compile` writes the same value into the
    /// compiled copy's `metadata.json` as `sourceHash` (checked on the Mac
    /// with Qwen3 0.6B: both 9752CAF7…). Upper-case hex.
    static func sourceHash(ofSource asset: URL) -> String? {
        guard let data = try? Data(contentsOf: asset.appending(path: "main.hash")), data.count == 32 else { return nil }
        return data.map { String(format: "%02X", $0) }.joined()
    }

    static func sourceHash(ofCompiled asset: URL) -> String? {
        guard let data = try? Data(contentsOf: asset.appending(path: "metadata.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["sourceHash"] as? String)?.uppercased()
    }

    /// Checks `source` is a compiled copy of this bundle's model for this
    /// device. Pass 36: the chip is compared with the name Core AI gives this
    /// device (`AIModel.deviceArchitectureName`) where it can be read, and
    /// the copy must come from exactly the downloaded graph (`sourceHash`)
    /// when it records one.
    static func validate(_ source: URL, for bundle: URL, machine: String,
                         architecture: String? = CoreAIPreparation.deviceArchitecture) throws {
        let fm = FileManager.default
        let name = source.lastPathComponent
        guard name.hasSuffix(".aimodelc"), !name.contains("/"),
              fm.fileExists(atPath: source.appending(path: "metadata.json").path),
              ((try? fm.contentsOfDirectory(atPath: source.path)) ?? []).contains(where: { $0.hasSuffix(".mlirb") })
        else { throw Failure.notACompiledModel }
        let chip = CoreAIBundleLimits.aotChip(name) ?? "an unknown chip"
        let chipFits = architecture.map { chip == $0 } ?? CoreAIBundleLimits.runs(chip: chip, machine: machine)
        guard CoreAIBundleLimits.aotChip(name) != nil, chipFits else {
            throw Failure.wrongChip(chip)
        }
        // The download's graph is "<stem>.aimodel"; the compiled one "<stem>.<chip>.aimodelc".
        let jit = portableMain(in: bundle) ?? mainAsset(in: bundle) ?? ""
        let stem = jit.replacingOccurrences(of: ".aimodelc", with: "").replacingOccurrences(of: ".aimodel", with: "")
        guard !stem.isEmpty, name.hasPrefix(stem + ".") else {
            throw Failure.wrongModel(String(name.prefix(while: { $0 != "." })))
        }
        if let compiledFrom = sourceHash(ofCompiled: source), let downloaded = sourceHash(ofSource: bundle.appending(path: jit)),
           compiledFrom != downloaded {
            throw Failure.wrongSource
        }
    }

    /// Whether the installed copy was checked against the download's graph.
    static func matchesDownload(in bundle: URL) -> Bool? {
        guard let compiled = installed(in: bundle), let jit = portableMain(in: bundle),
              let from = sourceHash(ofCompiled: bundle.appending(path: compiled)),
              let downloaded = sourceHash(ofSource: bundle.appending(path: jit)) else { return nil }
        return from == downloaded
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

    // MARK: Pass 36: from iCloud Drive

    /// His 13 Oct note: he put the copy compiled on the Mac in iCloud Drive
    /// and couldn't see how to get it onto the iPhone. A copy chosen in Files
    /// can be in iCloud Drive and not yet on the phone (only its names are).
    /// This brings every file down first, reporting bytes on the phone of
    /// the total, and fails plainly if iCloud stops sending. Files already on
    /// the phone are left as they are.
    static func materialize(_ files: [URL], progress: @escaping @Sendable (_ done: Int64, _ total: Int64) -> Void,
                            stallLimit: TimeInterval = 600) async throws {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .fileSizeKey,
                                         .ubiquitousItemDownloadingErrorKey]
        func state(_ url: URL) -> (ready: Bool, bytes: Int64, error: String?) {
            var fresh = url
            fresh.removeAllCachedResourceValues()
            guard let values = try? fresh.resourceValues(forKeys: keys) else { return (true, 0, nil) }
            let bytes = Int64(values.fileSize ?? 0)
            guard values.isUbiquitousItem == true else { return (true, bytes, nil) }
            return (values.ubiquitousItemDownloadingStatus == .current, bytes, values.ubiquitousItemDownloadingError?.localizedDescription)
        }
        for file in files where !state(file).ready { try fm.startDownloadingUbiquitousItem(at: file) }
        var lastDone: Int64 = -1
        var lastMoved = Date.now
        while true {
            try Task.checkCancellation()
            let states = files.map(state)
            let total = states.reduce(0) { $0 + $1.bytes }
            let done = states.filter(\.ready).reduce(0) { $0 + $1.bytes }
            progress(done, total)
            if states.allSatisfy(\.ready) { return }
            if let error = states.compactMap(\.error).first { throw Failure.unreadable("iCloud couldn't download it: " + error) }
            if done != lastDone { lastDone = done; lastMoved = .now }
            if Date.now.timeIntervalSince(lastMoved) > stallLimit {
                throw Failure.unreadable("iCloud hasn't sent any of it for \(Int(stallLimit / 60)) minutes. Check the connection, or open it in Files once so iCloud downloads it, then try again.")
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    /// Every file inside a chosen copy.
    static func files(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    /// Checks, downloads from iCloud if needed, and installs. The small files
    /// come first, so a copy for another chip or another version is refused
    /// before gigabytes are downloaded.
    static func installFromFiles(_ source: URL, into bundle: URL, machine: String,
                                 progress: @escaping @Sendable (_ done: Int64, _ total: Int64) -> Void) async throws {
        let all = files(in: source)
        guard !all.isEmpty else { throw Failure.notACompiledModel }
        let small = all.filter { ($0.lastPathComponent == "metadata.json") || $0.pathExtension == "json" || $0.lastPathComponent.hasSuffix(".hash") }
        try await materialize(small, progress: { _, _ in })
        try validate(source, for: bundle, machine: machine)
        try await materialize(all, progress: progress)
        try install(from: source, into: bundle, machine: machine)
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
