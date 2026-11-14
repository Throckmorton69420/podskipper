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
/// memory from it). Core AI bundles are imported (copied) first: Core AI
/// keeps its prepared copy beside the bundle and needs it in the app's own
/// container. Any model can be imported, so it keeps working with the drive
/// unplugged.
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
                // Each bundle is a folder holding metadata.json, under repo/revision/path.
                for url in ModelStorage.coreAIBundles(under: folder) {
                    let relative = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
                    let size = ModelStorage.size(of: url)
                    let target = CoreAIExternal.storeDirectory?.appending(path: relative, directoryHint: .isDirectory)
                    out.items.append(Item(id: "coreai:" + relative, name: CoreAIExternal.name(forBundlePath: relative), kind: .coreAI,
                                          source: url, bytes: size,
                                          imported: target.map { fm.fileExists(atPath: $0.appending(path: "metadata.json").path) } ?? false,
                                          readsInPlace: false))
                }
            }
            return out
        }.value
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
    @ObservationIgnored private var task: Task<Void, Never>?

    var isImporting: Bool { progress != nil }

    func refresh() {
        reading = true
        Task {
            let found = await ExternalModelInventory.read()
            inventory = found
            reading = false
        }
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
        CPUModelPresence.shared.refresh()
        ModelStore.shared.refreshState()
        refresh()
    }

    func stop() {
        task?.cancel()
    }

    func importItem(_ item: ExternalModelInventory.Item) {
        guard progress == nil else { return }
        message = nil
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
            destination = CoreAIExternal.storeDirectory?.appending(path: String(item.id.dropFirst("coreai:".count)), directoryHint: .isDirectory)
        }
        guard let destination else {
            progress = nil
            message = "PodSkipper doesn't know where \(item.name) goes."
            return
        }
        let source = item.source
        task = Task {
            let report: @Sendable (Int64, Double) -> Void = { done, speed in
                Task { @MainActor in
                    guard var p = ExternalModelImport.shared.progress, p.itemID == item.id else { return }
                    p.done = done
                    p.bytesPerSecond = speed
                    ExternalModelImport.shared.progress = p
                }
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ModelCopier.copy(source, to: destination, total: item.bytes, report: report)
                }.value
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

    static func copy(_ source: URL, to destination: URL, total: Int64,
                     report: @Sendable (Int64, Double) -> Void) throws {
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
                guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: keys) else { return }
                let base = source.standardizedFileURL.path
                for case let url as URL in walker {
                    let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
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
