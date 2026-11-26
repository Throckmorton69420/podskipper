import Foundation
import Observation

/// Pass 64 (his 13 Nov request): models kept on an external drive — his
/// Samsung T9 over USB-C — instead of in the iPhone's own storage.
///
/// He picks the drive's `PodSkipper/Models` folder once in Files (Settings ›
/// Ad Skipping › a model library › External Drive). PodSkipper keeps a
/// bookmark to it and reads it with the folder's permission each launch. The
/// layout is the iPhone's own, so `Scripts/ssd_models.sh` on the Mac fills
/// it with exactly what the app would download:
///
///     Models/gguf/<file>.gguf                        CPU models
///     Models/<org>/<name>/ (+ .download.json)        MLX models
///     Models/coreai/<repo>/<revision>/<path>/        Core AI bundles (Mac-compiled copies inside)
///
/// CPU models read straight from the drive (llama.cpp maps the file; pages
/// come from the drive as they are needed) and so do MLX models (loaded into
/// memory from it). Pass 70: so does a Core AI bundle the Mac compiled for
/// this iPhone's chip — `AIModel(contentsOf:options:)` (CoreAIDelegates,
/// iOS 27.2 SDK) takes any file URL and keeps what it specializes in its own
/// `AIModelCache`, not beside the bundle; a portable build is still imported
/// (the phone prepares it). Any model can be imported, so it keeps working
/// with the drive unplugged.
enum ExternalModelKind: String, Sendable, CaseIterable {
    case gguf, mlx, coreAI
}

enum ExternalModelLibrary {
    static let bookmarkKey = "externalModels.bookmark.v1"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var resolved: URL?
    nonisolated(unsafe) private static var resolvedFrom: Data?

    /// The chosen folder, with its permission held for as long as the app
    /// runs; nil when none is chosen or the bookmark can't be read.
    static var root: URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        return lock.withLock {
            if let resolved, resolvedFrom == data { return resolved }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
                return nil
            }
            resolved?.stopAccessingSecurityScopedResource()
            _ = url.startAccessingSecurityScopedResource()
            resolved = url
            resolvedFrom = data
            if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
                resolvedFrom = fresh
            }
            return url
        }
    }

    /// The folders a model of this kind may sit in on the drive. A folder he
    /// picked one level up (`PodSkipper`) is read as its `Models` folder.
    static func folders(kind: ExternalModelKind) -> [URL] {
        guard let root else { return [] }
        let models = modelsFolder(root)
        switch kind {
        case .gguf: return [models.appending(path: "gguf", directoryHint: .isDirectory)]
        case .mlx: return [models]
        case .coreAI: return [models.appending(path: "coreai", directoryHint: .isDirectory)]
        }
    }

    static func modelsFolder(_ root: URL) -> URL {
        if root.lastPathComponent.caseInsensitiveCompare("Models") == .orderedSame { return root }
        let inner = root.appending(path: "Models", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: inner.path) ? inner : root
    }

    /// Keeps the folder he picked in Files (a security-scoped URL).
    static func choose(_ url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        lock.withLock {
            resolved?.stopAccessingSecurityScopedResource()
            resolved = nil
            resolvedFrom = nil
        }
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        lock.withLock {
            resolved?.stopAccessingSecurityScopedResource()
            resolved = nil
            resolvedFrom = nil
        }
    }

    /// Whether the drive is there now (it may be unplugged).
    static var isConnected: Bool {
        guard let root else { return false }
        return FileManager.default.fileExists(atPath: root.path)
    }

    /// Pass 70: the folder's permission is resolved again on next use — after
    /// the drive was unplugged, it can come back at another mount point.
    static func invalidate() {
        lock.withLock {
            resolved?.stopAccessingSecurityScopedResource()
            resolved = nil
            resolvedFrom = nil
        }
    }

    /// Pass 70: whether the chosen folder can be reached now (nil: none
    /// chosen). A stat of the folder, never a read of the models in it; an
    /// unreachable folder is resolved from its bookmark again.
    static func reachability() -> Bool? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        if let root, (try? root.checkResourceIsReachable()) == true { return true }
        // Unplugged, or back at another mount point: the bookmark is resolved
        // aside (never mounting anything), and the kept resolution is dropped
        // only when it finds the folder somewhere reachable — so nothing on
        // the main thread resolves a bookmark while the drive is away.
        var stale = false
        guard let fresh = try? URL(resolvingBookmarkData: data, options: [.withoutMounting], relativeTo: nil,
                                   bookmarkDataIsStale: &stale) else { return false }
        let accessing = fresh.startAccessingSecurityScopedResource()
        defer { if accessing { fresh.stopAccessingSecurityScopedResource() } }
        guard (try? fresh.checkResourceIsReachable()) == true else { return false }
        invalidate()
        return true
    }
}

/// What the drive holds that PodSkipper knows, read off the main thread.
struct ExternalModelInventory: Sendable, Equatable {
    struct Item: Sendable, Equatable, Identifiable {
        var id: String
        var name: String
        var kind: ExternalModelKind
        var source: URL
        var bytes: Int64
        /// Already in the iPhone's own storage.
        var imported: Bool
        /// Reads straight from the drive (CPU and MLX).
        var readsInPlace: Bool
        /// Pass 66: for a Core AI bundle, which graph this import brings —
        /// the copy compiled on the Mac for a chip, or the portable build
        /// (the bundle without its compiled copy).
        var graph: CoreAIGraph? = nil
        /// Pass 66: chosen on its own in Files ("Choose Model File or
        /// Folder…"): read with that file's own permission.
        var scoped = false
    }
    var folderName = ""
    var connected = false
    var items: [Item] = []
    var freeOnPhone: Int64 = 0

    static func read() async -> ExternalModelInventory {
        await Task.detached(priority: .utility) { () -> ExternalModelInventory in
            var out = ExternalModelInventory()
            guard let root = ExternalModelLibrary.root else { return out }
            out.folderName = root.lastPathComponent
            out.connected = FileManager.default.fileExists(atPath: root.path)
            out.freeOnPhone = ModelStorage.freeBytes(near: URL.applicationSupportDirectory) ?? 0
            guard out.connected else { return out }
            let fm = FileManager.default
            for folder in ExternalModelLibrary.folders(kind: .gguf) {
                for model in CPUReading.catalog {
                    let url = folder.appending(path: model.file)
                    let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                    guard size == model.bytes else { continue }
                    let local = (try? fm.attributesOfItem(atPath: model.location.path)[.size] as? NSNumber)?.int64Value ?? 0
                    out.items.append(Item(id: "gguf:" + model.id, name: model.name, kind: .gguf, source: url, bytes: size,
                                          imported: local == model.bytes, readsInPlace: true))
                }
            }
            for folder in ExternalModelLibrary.folders(kind: .mlx) {
                for spec in LocalModelSpec.all {
                    let disk = await ModelStore.readDisk(for: spec, manifest: nil, rootURL: folder)
                    guard let manifest = disk.manifest, disk.nextFile == nil else { continue }
                    let local = await ModelStore.readDisk(for: spec, manifest: nil)
                    out.items.append(Item(id: "mlx:" + spec.id, name: spec.name, kind: .mlx,
                                          source: folder.appending(path: spec.id, directoryHint: .isDirectory),
                                          bytes: manifest.total, imported: local.manifest != nil && local.nextFile == nil,
                                          readsInPlace: true))
                }
            }
            for folder in ExternalModelLibrary.folders(kind: .coreAI) {
                out.items += coreAIItems(under: folder, store: CoreAIExternal.storeDirectory)
            }
            return out
        }.value
    }

    /// Each Core AI bundle under `folder` (a folder holding metadata.json,
    /// under repo/revision/path). Pass 66 (his 16 Nov request): a bundle the
    /// Mac compiled for a chip (`Scripts/ssd_models.py --compile`) holds
    /// both graphs — the compiled one its metadata.json names, and the
    /// download's own, named by the kept metadata.portable.json — so it is
    /// offered twice: "coreai:<path>" brings the compiled copy (the default),
    /// "coreai-portable:<path>" the bundle without it.
    /// Pass 70: a compiled copy for this device's chip (`architecture`, Core
    /// AI's name for it) reads straight from the drive.
    static func coreAIItems(under folder: URL, store: URL?,
                            architecture: String? = CoreAIPreparation.deviceArchitecture) -> [Item] {
        let fm = FileManager.default
        var out: [Item] = []
        for url in ModelStorage.coreAIBundles(under: folder) {
            let relative = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
            let size = ModelStorage.size(of: url)
            let target = store?.appending(path: relative, directoryHint: .isDirectory)
            let onPhone = target.map { fm.fileExists(atPath: $0.appending(path: "metadata.json").path) } ?? false
            let phoneCompiled = target.flatMap { onPhone ? CoreAICompiledCopy.installed(in: $0) : nil }
            let name = CoreAIExternal.name(forBundlePath: relative)
            let scan = CoreAIBundleScan.scan(url)
            if let compiled = scan.compiledMain {
                let chip = CoreAIBundleLimits.aotChip(compiled) ?? "this iPhone"
                out.append(Item(id: "coreai:" + relative, name: name, kind: .coreAI, source: url, bytes: size,
                                imported: phoneCompiled == compiled,
                                readsInPlace: architecture != nil && CoreAIBundleLimits.aotChip(compiled) == architecture,
                                graph: .compiled(chip: chip)))
                if scan.portableMain != nil {
                    out.append(Item(id: "coreai-portable:" + relative, name: name + " (portable build)", kind: .coreAI,
                                    source: url, bytes: max(0, size - scan.compiledBytes),
                                    imported: onPhone && phoneCompiled == nil, readsInPlace: false, graph: .portable))
                }
            } else {
                out.append(Item(id: "coreai:" + relative, name: name, kind: .coreAI, source: url, bytes: size,
                                imported: onPhone && phoneCompiled == nil, readsInPlace: false, graph: .portable))
            }
        }
        return out
    }
}

/// Pass 66 (his 16 Nov request): one model chosen on its own in Files —
/// a CPU model's .gguf file, an MLX model's folder, a Core AI bundle (its
/// folder with metadata.json, the Mac-compiled copy inside or not), or a
/// compiled `.aimodelc` alone — matched to the model it is, so it can be
/// imported without choosing the drive's whole Models folder.
enum ChosenModel: Equatable {
    case item(ExternalModelInventory.Item)
    /// A compiled graph by itself: installed into the matching download.
    case compiledCopy(URL)
    case refused(String)

    /// `coreAIBundles`: (catalog name, "repo/revision/variant") of each Core AI model.
    static func classify(_ url: URL, coreAIBundles: [(name: String, path: String)] = []) -> ChosenModel {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isFolder) else { return .refused("PodSkipper can't read that item.") }
        let name = url.lastPathComponent
        if !isFolder.boolValue || url.pathExtension.lowercased() == "gguf" {
            guard url.pathExtension.lowercased() == "gguf" else {
                return .refused("Choose a CPU model's .gguf file, an MLX model's folder, or a Core AI model's folder.")
            }
            guard let model = CPUReading.catalog.first(where: { $0.file == name }) else {
                return .refused("\(name) isn't one of PodSkipper's CPU models (\(CPUReading.catalog.map(\.file).joined(separator: ", "))).")
            }
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size == model.bytes else {
                return .refused("That copy of \(model.name) is \(ModelStore.gigabytes(size)); the complete file is \(ModelStore.gigabytes(model.bytes)).")
            }
            return .item(.init(id: "gguf:" + model.id, name: model.name, kind: .gguf, source: url, bytes: size,
                               imported: false, readsInPlace: false, scoped: true))
        }
        if name.hasSuffix(".aimodelc") { return .compiledCopy(url) }
        if name.hasSuffix(".aimodel") {
            return .refused("Choose the folder that holds \(name) and its metadata.json (the model's bundle), not the graph inside it.")
        }
        if fm.fileExists(atPath: url.appending(path: "metadata.json").path) {
            let path = url.standardizedFileURL.path
            guard let match = coreAIBundles.first(where: { path.hasSuffix("/" + $0.path) }) else {
                return .refused("That Core AI bundle isn't in PodSkipper's catalog, or its folder isn't named repo/revision/build as the drive keeps it (Scripts/ssd_models.sh).")
            }
            let scan = CoreAIBundleScan.scan(url)
            let graph: CoreAIGraph = scan.compiledMain.map { .compiled(chip: CoreAIBundleLimits.aotChip($0) ?? "this iPhone") } ?? .portable
            return .item(.init(id: "coreai:" + match.path, name: match.name, kind: .coreAI, source: url,
                               bytes: ModelStorage.size(of: url), imported: false, readsInPlace: false, graph: graph, scoped: true))
        }
        if let spec = LocalModelSpec.all.first(where: { $0.id.split(separator: "/").last.map(String.init) == name }),
           fm.fileExists(atPath: url.appending(path: "config.json").path) {
            return .item(.init(id: "mlx:" + spec.id, name: spec.name, kind: .mlx, source: url, bytes: ModelStorage.size(of: url),
                               imported: false, readsInPlace: false, scoped: true))
        }
        return .refused("PodSkipper doesn't recognise that folder as one of its models.")
    }
}

/// Pass 70 (his 25 Nov request: Import in every model's row, drive or not):
/// the model a row's Import is for, so what is picked in Files is checked
/// against that model and nothing else.
struct ModelImportTarget: Equatable, Identifiable, Sendable {
    var kind: ExternalModelKind
    /// The catalog's id (CPU and MLX) or the Core AI entry's id.
    var modelID: String
    var name: String
    /// Core AI: "repo/revision/variant", where the drive keeps the bundle.
    var bundlePath: String? = nil
    /// Core AI: "revision/variant" — enough to know a copied build folder.
    var bundleTail: String? = nil
    /// Core AI: the model is downloaded here, so a compiled copy alone can go into it.
    var onPhone = false
    var id: String { itemID }

    /// The id the drive's (or a chosen) copy of this model has.
    var itemID: String {
        switch kind {
        case .gguf: "gguf:" + modelID
        case .mlx: "mlx:" + modelID
        case .coreAI: "coreai:" + (bundlePath ?? modelID)
        }
    }

    /// What the row asks for in Files, in words.
    var wanted: String {
        switch kind {
        case .gguf: "its .gguf file"
        case .mlx: "its MLX model folder"
        case .coreAI: "its Core AI folder (with metadata.json), or a compiled .aimodelc for it"
        }
    }
}

extension ChosenModel {
    /// Pass 70: what is picked in Files from one model's row — matched to
    /// that model, refused with the reason when it is another model or not
    /// a model at all. A Core AI bundle is accepted from anywhere in Files
    /// when its folders end in the build's own revision/variant (the drive
    /// keeps repo/revision/variant; a copied folder may lose the repo).
    static func classify(_ url: URL, for target: ModelImportTarget,
                         coreAIBundles: [(name: String, path: String)] = []) -> ChosenModel {
        var bundles = coreAIBundles
        if let path = target.bundlePath, !bundles.contains(where: { $0.path == path }) {
            bundles.append((target.name, path))
        }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        // A Core AI build copied without its repo folder: revision/variant is enough.
        if target.kind == .coreAI, isFolder, let path = target.bundlePath,
           FileManager.default.fileExists(atPath: url.appending(path: "metadata.json").path) {
            let tail = target.bundleTail ?? path
            let picked = url.standardizedFileURL.path
            if picked.hasSuffix("/" + path) || picked.hasSuffix("/" + tail) {
                let scan = CoreAIBundleScan.scan(url)
                guard scan.compiledMain != nil || scan.portableMain != nil else {
                    return .refused("That folder has no Core AI graph (.aimodel or .aimodelc) in it.")
                }
                let graph: CoreAIGraph = scan.compiledMain.map { .compiled(chip: CoreAIBundleLimits.aotChip($0) ?? "this iPhone") } ?? .portable
                return .item(.init(id: target.itemID, name: target.name, kind: .coreAI, source: url,
                                   bytes: ModelStorage.size(of: url), imported: false, readsInPlace: false,
                                   graph: graph, scoped: true))
            }
        }
        let choice = classify(url, coreAIBundles: bundles)
        switch choice {
        case .refused:
            return choice
        case .compiledCopy:
            guard target.kind == .coreAI else {
                return .refused("That's a compiled Core AI graph, not \(target.name). Choose \(target.wanted).")
            }
            guard target.onPhone else {
                return .refused("A compiled copy goes into \(target.name)'s download. Download or import \(target.name) first, then choose its compiled copy.")
            }
            return choice
        case .item(let item):
            guard item.kind == target.kind else {
                return .refused("That's \(ExternalModelImportText.kind(item.kind)) (\(item.name)), not \(target.name). Choose \(target.wanted).")
            }
            guard item.id == target.itemID else {
                return .refused("That's \(item.name), not \(target.name). Choose \(target.wanted).")
            }
            return choice
        }
    }
}

enum ExternalModelImportText {
    static func kind(_ kind: ExternalModelKind) -> String {
        switch kind {
        case .gguf: "a CPU model"
        case .mlx: "an MLX model"
        case .coreAI: "a Core AI model"
        }
    }
}

/// Pass 70: a Core AI build the Mac compiled for this iPhone, read straight
/// from the drive (no import). Pure; unit-tested in the simulator.
enum CoreAIDriveBundle {
    /// The drive's bundle for `path` ("repo/revision/variant") under the
    /// drive's coreai folder, when its loaded graph is a compiled copy for
    /// `architecture` and, for a model that needs them, its word tables are
    /// complete.
    static func readable(under folder: URL, path: String, architecture: String?,
                         tablesComplete: ((URL) -> Bool)? = nil) -> URL? {
        guard let architecture else { return nil }
        let bundle = folder.appending(path: path, directoryHint: .isDirectory)
        guard let compiled = CoreAICompiledCopy.installed(in: bundle),
              CoreAIBundleLimits.aotChip(compiled) == architecture else { return nil }
        if let tablesComplete, !tablesComplete(bundle) { return nil }
        return bundle
    }
}

/// Pass 66: which graph a Core AI bundle import brings.
enum CoreAIGraph: Sendable, Equatable {
    case compiled(chip: String)
    case portable
}

/// Pass 66: what a Core AI bundle folder holds, from its own files.
enum CoreAIBundleScan {
    struct Found: Equatable {
        /// The compiled graph metadata.json names (with the download's graph kept beside it).
        var compiledMain: String?
        /// The download's own graph (`.aimodel`, or what metadata.portable.json names).
        var portableMain: String?
        /// Bytes of every compiled copy in the bundle (left out of a portable import).
        var compiledBytes: Int64
    }

    static func scan(_ bundle: URL) -> Found {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: bundle.path)) ?? []
        let main = CoreAICompiledCopy.mainAsset(in: bundle)
        let compiled = main.flatMap { $0.hasSuffix(".aimodelc") && names.contains($0) ? $0 : nil }
        let kept = CoreAICompiledCopy.portableMain(in: bundle)
        var portable = compiled == nil ? main : kept
        if let p = portable, !names.contains(p) { portable = nil }
        let compiledBytes = names.filter { $0.hasSuffix(".aimodelc") }
            .reduce(Int64(0)) { $0 + ModelStorage.size(of: bundle.appending(path: $1, directoryHint: .isDirectory)) }
        return Found(compiledMain: compiled, portableMain: portable, compiledBytes: compiledBytes)
    }

    /// A portable import: every path inside a compiled copy is left out.
    static func isCompiledCopy(_ relative: String) -> Bool {
        relative.split(separator: "/").contains { $0.hasSuffix(".aimodelc") }
    }

    /// After a portable import (in its staging folder): the download's own
    /// metadata back as metadata.json, as `CoreAICompiledCopy.remove` leaves it.
    static func restorePortable(in bundle: URL) throws {
        let fm = FileManager.default
        let kept = bundle.appending(path: CoreAICompiledCopy.portableMetadata)
        guard fm.fileExists(atPath: kept.path) else { return }
        let data = try Data(contentsOf: kept)
        try data.write(to: bundle.appending(path: "metadata.json"), options: .atomic)
        try fm.removeItem(at: kept)
    }
}

/// Where Core AI keeps downloads (CoreAIKit's store), for imports.
enum CoreAIExternal {
    static var storeDirectory: URL? {
        #if !targetEnvironment(simulator)
        return CoreAIModelLibrary.storeDirectory
        #else
        return nil
        #endif
    }

    /// "coreai:<repo>/<revision>/<path>" or "coreai-portable:…" → the bundle's place in the store.
    static func relativePath(ofItemID id: String) -> String {
        for prefix in ["coreai-portable:", "coreai:"] where id.hasPrefix(prefix) { return String(id.dropFirst(prefix.count)) }
        return id
    }

    /// "Qwen/Qwen3-4B/…/ios/…" → the repo's last part, for the list.
    static func name(forBundlePath path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count >= 2 ? String(parts[1]) : path
    }
}

/// Copies a model from the drive into the iPhone's own storage, a chunk at
/// a time, saying how far it has got and how fast (his request: "X.XX GB /
/// Y.YY GB" and MB/s on every download and import).
@MainActor @Observable
final class ExternalModelImport {
    static let shared = ExternalModelImport()

    struct Progress: Equatable {
        var itemID: String
        var name: String
        var done: Int64
        var total: Int64
        var bytesPerSecond: Double
    }

    private(set) var inventory = ExternalModelInventory()
    private(set) var reading = false
    private(set) var progress: Progress?
    private(set) var message: String?
    /// Pass 65: which model the message is about, so its row in the lists says it.
    private(set) var messageItemID: String?
    /// Pass 70: the model a row's Import opened Files for.
    var pickerTarget: ModelImportTarget?
    /// Pass 70: a Core AI row's Import, when the drive's build holds both graphs.
    var graphChoice: GraphChoice?
    /// Pass 70: how many times the drive's contents changed under a rediscovery (tests).
    private(set) var rediscoveries = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var rediscoverAgain = false
    @ObservationIgnored private var readGeneration = 0
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var lastReachable: Bool??

    var isImporting: Bool { progress != nil }

    @discardableResult
    func refresh() -> Task<Void, Never> {
        reading = true
        // Pass 70: only the newest read lands. A read started before Forget,
        // Choose Another or an unplug could finish after the next one and put
        // the old drive's models back (seen in the simulator: a row imported
        // from a drive that had just been forgotten).
        readGeneration += 1
        let generation = readGeneration
        return Task {
            let found = await ExternalModelInventory.read()
            guard generation == readGeneration else { return }
            inventory = found
            reading = false
        }
    }

    /// Pass 70 (his 25 Nov request: plug the drive in and its models are
    /// there, no Read Again): the drive is read again when PodSkipper comes
    /// to the foreground, when a model screen appears and when the folder
    /// becomes reachable or unreachable (`watchDrive`). When what it holds
    /// changed, CPU, MLX and Core AI models are looked for again with it.
    /// Replaces Pass 65's read at most every half minute on appearing.
    func rediscover() {
        guard UserDefaults.standard.data(forKey: ExternalModelLibrary.bookmarkKey) != nil else { return }
        guard !reading else { rediscoverAgain = true; return }
        let before = (inventory.connected, inventory.items)
        let reading = refresh()
        Task {
            await reading.value
            if before.0 != inventory.connected || before.1 != inventory.items { afterDriveChange() }
            if rediscoverAgain { rediscoverAgain = false; rediscover() }
        }
    }

    /// Every runtime's own idea of what is usable, after the drive changed.
    private func afterDriveChange() {
        rediscoveries += 1
        CPUModelPresence.shared.refresh()
        ModelStore.shared.refreshState()
        #if !targetEnvironment(simulator)
        CoreAIModelLibrary.shared.refreshPresence()
        #endif
    }

    /// Pass 70: while a model screen is on screen, whether the folder can be
    /// reached is checked every few seconds off the main thread (a stat, not
    /// a read of the drive); a change reads the drive again. iOS has no
    /// public notice for a USB drive arriving, so this is how plugging it in
    /// shows its models. Counted, so nested screens share one watch.
    func watchDrive() {
        watchers += 1
        guard watchTask == nil else { return }
        // The baseline is what was last read, so a drive that came or went
        // before the first check is read again too.
        lastReachable = .some(inventory.connected)
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                let now = await Task.detached(priority: .utility) { ExternalModelLibrary.reachability() }.value
                guard let self, !Task.isCancelled else { return }
                if let last = self.lastReachable, last != now { self.rediscover() }
                self.lastReachable = now
                try? await Task.sleep(for: .seconds(Self.watchInterval))
            }
        }
    }

    func unwatchDrive() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        watchTask?.cancel()
        watchTask = nil
        lastReachable = nil
    }

    /// Seconds between reachability checks (shorter in tests).
    static var watchInterval: Double = 3

    /// Pass 70 (his 25 Nov request): Import beside Download in every model's
    /// row. The drive's copy when the linked drive holds this model (for a
    /// Core AI build holding both graphs, he chooses which); otherwise Files
    /// opens for this model, anywhere — On My iPhone, iCloud Drive, another
    /// provider or a drive.
    func importFromRow(_ target: ModelImportTarget, drive: ExternalModelInventory.Item?,
                       portable: ExternalModelInventory.Item? = nil) {
        guard progress == nil else { return }
        if let drive, let portable, drive.graph != .portable {
            graphChoice = GraphChoice(name: target.name, compiled: drive, portable: portable)
            return
        }
        if let item = drive ?? portable { importItem(item); return }
        message = nil
        messageItemID = target.itemID
        pickerTarget = target
    }

    /// What was picked in Files from a row, checked against that row's model.
    func importPicked(_ url: URL, for target: ModelImportTarget) {
        message = nil
        messageItemID = target.itemID
        let accessing = url.startAccessingSecurityScopedResource()
        var bundles: [(name: String, path: String)] = []
        #if !targetEnvironment(simulator)
        bundles = CoreAIModelLibrary.shared.entries.compactMap { entry in
            guard let revision = entry.revision, let variant = entry.variant else { return nil }
            return (entry.name, entry.repo + "/" + revision + "/" + variant)
        }
        #endif
        let choice = ChosenModel.classify(url, for: target, coreAIBundles: bundles)
        if accessing { url.stopAccessingSecurityScopedResource() }
        switch choice {
        case .refused(let why):
            message = why
            messageItemID = target.itemID
        case .item(let item):
            importItem(item)
        case .compiledCopy(let source):
            installCompiled(source, only: target)
        }
    }

    /// Whether `id` (an item's, a portable build's or a compiled copy's) is about this row's model.
    func concerns(_ id: String?, _ target: ModelImportTarget) -> Bool {
        guard let id else { return false }
        if id == target.itemID { return true }
        guard target.kind == .coreAI, let path = target.bundlePath else { return false }
        return id == "coreai-portable:" + path
    }

    func isImporting(_ target: ModelImportTarget) -> Bool { concerns(progress?.itemID, target) }
    func message(for target: ModelImportTarget) -> String? { concerns(messageItemID, target) ? message : nil }

    struct GraphChoice: Identifiable, Equatable {
        var name: String
        var compiled: ExternalModelInventory.Item
        var portable: ExternalModelInventory.Item
        var id: String { compiled.id }
    }

    /// Pass 65 (his 15 Nov request: import or download, model by model): the
    /// drive's complete copy of a catalog model, for that model's row.
    func item(gguf id: String) -> ExternalModelInventory.Item? { item("gguf:" + id) }
    func item(mlx id: String) -> ExternalModelInventory.Item? { item("mlx:" + id) }
    func item(coreAIRepo repo: String, revision: String?, variant: String?) -> ExternalModelInventory.Item? {
        guard let revision, let variant else { return nil }
        return item("coreai:" + repo + "/" + revision + "/" + variant)
    }
    /// Pass 66: the same bundle without its compiled copy, when the drive's holds one.
    func portableItem(coreAIRepo repo: String, revision: String?, variant: String?) -> ExternalModelInventory.Item? {
        guard let revision, let variant else { return nil }
        return item("coreai-portable:" + repo + "/" + revision + "/" + variant)
    }
    private func item(_ id: String) -> ExternalModelInventory.Item? {
        inventory.connected ? inventory.items.first { $0.id == id } : nil
    }

    func choose(_ url: URL) {
        do {
            try ExternalModelLibrary.choose(url)
            message = nil
        } catch {
            message = "Couldn't keep that folder: " + error.localizedDescription
        }
        afterChange()
    }

    func forget() {
        ExternalModelLibrary.forget()
        afterChange()
    }

    private func afterChange() {
        afterDriveChange()
        refresh()
    }

    func stop() {
        task?.cancel()
    }

    /// Pass 66: "Choose Model File or Folder…" in External Drive.
    func importChosen(_ url: URL) {
        message = nil
        messageItemID = nil
        let accessing = url.startAccessingSecurityScopedResource()
        var bundles: [(name: String, path: String)] = []
        #if !targetEnvironment(simulator)
        bundles = CoreAIModelLibrary.shared.entries.compactMap { entry in
            guard let revision = entry.revision, let variant = entry.variant else { return nil }
            return (entry.name, entry.repo + "/" + revision + "/" + variant)
        }
        #endif
        let choice = ChosenModel.classify(url, coreAIBundles: bundles)
        if accessing { url.stopAccessingSecurityScopedResource() }
        switch choice {
        case .refused(let why):
            message = why
        case .item(let item):
            importItem(item)
        case .compiledCopy(let source):
            installCompiled(source)
        }
    }

    /// A compiled graph chosen by itself goes into the download it was
    /// compiled from (`CoreAICompiledCopy.validate` picks it), with the same
    /// checks as Models and Caches' Install Compiled Copy.
    private func installCompiled(_ source: URL, only target: ModelImportTarget? = nil) {
        #if !targetEnvironment(simulator)
        let library = CoreAIModelLibrary.shared
        let machine = Diagnostics.deviceModel
        // Pass 70: never into a bundle read from the drive — only this iPhone's own downloads.
        let bundles = library.entries.filter { target == nil || $0.id == target?.modelID }
            .compactMap { entry in library.localBundle(for: entry.id).map { (entry, $0) } }
        guard progress == nil else { return }
        progress = Progress(itemID: target?.itemID ?? ("compiled:" + source.lastPathComponent), name: source.lastPathComponent, done: 0,
                            total: ModelStorage.size(of: source), bytesPerSecond: 0)
        if let target { messageItemID = target.itemID }
        task = Task {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let target = await Task.detached(priority: .utility) { () -> (CoreAIModelDescriptor, URL)? in
                bundles.first { (try? CoreAICompiledCopy.validate(source, for: $0.1, machine: machine)) != nil }
            }.value
            guard let (entry, bundle) = target else {
                message = "No model on this iPhone matches \(source.lastPathComponent) (it must be compiled for this iPhone from a model downloaded here). Download or import the model first."
                progress = nil; task = nil
                return
            }
            messageItemID = "coreai:" + entry.repo + "/" + (entry.revision ?? "") + "/" + (entry.variant ?? "")
            do {
                try await CoreAICompiledCopy.installFromFiles(source, into: bundle, machine: machine) { done, total in
                    Task { @MainActor in
                        guard var p = ExternalModelImport.shared.progress else { return }
                        p.done = done; p.total = max(p.total, total)
                        ExternalModelImport.shared.progress = p
                    }
                }
                BackgroundLog.shared.note("Installed the compiled copy \(source.lastPathComponent) into \(entry.name)")
                message = "\(entry.name) now loads the compiled copy."
            } catch is CancellationError {
                message = "Stopped; the download is as it was."
            } catch {
                message = "Couldn't install it: " + error.localizedDescription
            }
            progress = nil
            task = nil
            library.storeChanged()
            refresh()
        }
        #else
        message = "Core AI models run on iPhone only."
        #endif
    }

    func importItem(_ item: ExternalModelInventory.Item) {
        guard progress == nil else { return }
        message = nil
        messageItemID = item.id
        let free = inventory.freeOnPhone
        guard free == 0 || item.bytes + 1_000_000_000 < free else {
            message = "\(item.name) needs \(ModelStore.gigabytes(item.bytes)) and this iPhone has \(ModelStore.gigabytes(free)) free (1 GB is kept spare)."
            return
        }
        progress = Progress(itemID: item.id, name: item.name, done: 0, total: item.bytes, bytesPerSecond: 0)
        let destination: URL?
        switch item.kind {
        case .gguf:
            destination = CPUReading.catalog.first { "gguf:" + $0.id == item.id }?.location
        case .mlx:
            destination = LocalModelSpec.all.first { "mlx:" + $0.id == item.id }.map { ModelStore.folder(for: $0) }
        case .coreAI:
            destination = CoreAIExternal.storeDirectory?.appending(path: CoreAIExternal.relativePath(ofItemID: item.id),
                                                                  directoryHint: .isDirectory)
        }
        guard let destination else {
            progress = nil
            message = "PodSkipper doesn't know where \(item.name) goes."
            return
        }
        let source = item.source
        let portable = item.kind == .coreAI && item.graph == .portable
        // Pass 66: a file or folder chosen on its own in Files carries its
        // own permission, held for exactly as long as the copy runs.
        let scoped = item.scoped && source.startAccessingSecurityScopedResource()
        task = Task {
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let report: @Sendable (Int64, Double) -> Void = { done, speed in
                Task { @MainActor in
                    guard var p = ExternalModelImport.shared.progress, p.itemID == item.id else { return }
                    p.done = done
                    p.bytesPerSecond = speed
                    ExternalModelImport.shared.progress = p
                }
            }
            do {
                // Pass 66 audit: a detached task doesn't inherit cancellation,
                // so Stop (which cancels `task`) never reached the copy loop's
                // check — the import ran to the end and said it had worked.
                // Stop now cancels the copy itself.
                let copier = Task.detached(priority: .userInitiated) {
                    if portable {
                        try ModelCopier.copy(source, to: destination, total: item.bytes, report: report,
                                             skip: CoreAIBundleScan.isCompiledCopy, finish: CoreAIBundleScan.restorePortable)
                    } else {
                        try ModelCopier.copy(source, to: destination, total: item.bytes, report: report)
                    }
                }
                try await withTaskCancellationHandler { try await copier.value } onCancel: { copier.cancel() }
                BackgroundLog.shared.note("Imported \(item.name) from the external drive (\(ModelStore.gigabytes(item.bytes)))")
                message = "\(item.name) is on this iPhone now."
            } catch is CancellationError {
                message = "Import stopped; nothing was kept."
            } catch {
                message = "Couldn't import \(item.name): " + error.localizedDescription
            }
            progress = nil
            task = nil
            switch item.kind {
            case .gguf: CPUModelPresence.shared.refresh()
            case .mlx: ModelStore.shared.refreshState()
            case .coreAI:
                #if !targetEnvironment(simulator)
                CoreAIModelLibrary.shared.storeChanged()
                #endif
            }
            refresh()
        }
    }
}

/// A file or folder copied in 8 MB chunks into a staging place beside its
/// destination, then moved there in one step (an interrupted copy leaves
/// nothing half-written where the app looks).
enum ModelCopier {
    static let chunk = 8 << 20

    /// `skip` (a path relative to a copied folder) leaves files out; `finish`
    /// runs on the staged copy before it moves into place (Pass 66: a Core AI
    /// bundle imported without its compiled copy).
    static func copy(_ source: URL, to destination: URL, total: Int64,
                     report: @Sendable (Int64, Double) -> Void,
                     skip: (String) -> Bool = { _ in false },
                     finish: ((URL) throws -> Void)? = nil) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appending(path: ".import-" + destination.lastPathComponent, directoryHint: .notDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let started = Date()
        var done: Int64 = 0
        var lastReport = Date.distantPast
        func tick(_ n: Int) throws {
            done += Int64(n)
            if Task.isCancelled { throw CancellationError() }
            let now = Date()
            if now.timeIntervalSince(lastReport) >= 0.25 {
                lastReport = now
                report(done, Double(done) / max(0.001, now.timeIntervalSince(started)))
            }
        }
        do {
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isFolder) else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path])
            }
            if isFolder.boolValue {
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                let keys: [URLResourceKey] = [.isDirectoryKey]
                // Pass 66 audit: this used to return "copied" with nothing copied (and the staging folder left).
                guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: keys) else {
                    throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: source.path])
                }
                let base = source.standardizedFileURL.path
                for case let url as URL in walker {
                    let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
                    if skip(relative) { continue }
                    let target = staging.appending(path: relative)
                    if (try? url.resourceValues(forKeys: Set(keys)).isDirectory) == true {
                        try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    } else {
                        try copyFile(url, to: target, tick: tick)
                    }
                }
            } else {
                try copyFile(source, to: staging, tick: tick)
            }
            try finish?(staging)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: staging, to: destination)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            var excluded = destination
            try? excluded.setResourceValues(values)
            report(done, Double(done) / max(0.001, Date().timeIntervalSince(started)))
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    private static func copyFile(_ source: URL, to target: URL, tick: (Int) throws -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: target.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        while let data = try input.read(upToCount: chunk), !data.isEmpty {
            try output.write(contentsOf: data)
            try tick(data.count)
        }
    }
}

/// Pass 64: bytes a second from a transfer's running total, smoothed over
/// the last few seconds (a download's progress arrives in bursts).
struct TransferMeter: Sendable, Equatable {
    private var lastBytes: Int64 = 0
    private var lastAt: Date?
    private(set) var bytesPerSecond: Double = 0

    mutating func note(done: Int64, at now: Date = .now) {
        guard let lastAt else { self.lastAt = now; lastBytes = done; return }
        let dt = now.timeIntervalSince(lastAt)
        guard dt >= 0.5 else { return }
        let rate = Double(max(0, done - lastBytes)) / dt
        bytesPerSecond = bytesPerSecond == 0 ? rate : bytesPerSecond * 0.6 + rate * 0.4
        self.lastAt = now
        lastBytes = done
    }
}

/// "1.23 GB / 2.58 GB · 412.0 MB/s" for downloads and imports alike.
enum TransferText {
    static func line(done: Int64, total: Int64, bytesPerSecond: Double) -> String {
        let gb = { (b: Int64) in String(format: "%.2f GB", Double(b) / 1_000_000_000) }
        var text = gb(done) + " / " + gb(max(total, done))
        if bytesPerSecond > 0 { text += String(format: " · %.1f MB/s", bytesPerSecond / 1_000_000) }
        if bytesPerSecond > 0, total > done {
            let left = Double(total - done) / bytesPerSecond
            text += " · " + Duration.seconds(max(1, left.rounded())).formatted(.time(pattern: .minuteSecond)) + " left"
        }
        return text
    }
}
