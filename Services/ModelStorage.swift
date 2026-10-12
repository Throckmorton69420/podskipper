import Foundation

/// What the models and the app's scratch space take on this phone, measured
/// from the files themselves.
///
/// Pass 35 (his 9 Oct phone, build 36410ed): "Remove Unused Copies" deleted
/// every MLX model he had downloaded. MLX models live at
/// `Models/<owner>/<repo>` (the spec id has a slash), but Pass 33's
/// inventory compared only the top-level folder names (`mlx-community`,
/// `ALTICDEV`) with the full ids, so nothing ever matched and all of them
/// were filed under "Models no longer offered". The rules now:
/// - A model is found by what is inside a folder (an MLX model has a
///   `config.json`, a Core AI bundle a `metadata.json`), wherever it sits,
///   never by whether today's catalog still names it.
/// - Matching the catalog only adds a name and a status. Being chosen,
///   downloaded, in the catalog or not, are separate facts on each item.
/// - Nothing that holds a model is ever removed in bulk as "unused": every
///   model is removed only by its own Delete. Bulk removal is offered only
///   for stopped downloads and scratch files that are safe by kind.
/// - Every removal is refused outside the folders it may touch, through
///   symlinks too.
enum ModelStorage {

    // MARK: Model inventory

    struct Item: Identifiable, Sendable, Equatable {
        enum Engine: String, Sendable { case mlx = "MLX", coreAI = "Core AI" }
        enum Status: Sendable, Equatable {
            /// Complete and in this version's list.
            case installed
            /// Files for a model in this version's list, not all there yet.
            case incomplete
            /// A Core AI copy of a model in the list, but not the revision or
            /// build this version loads (an older download, or the build a
            /// newer one replaced).
            case otherVersion
            /// A whole model this version's list doesn't name. It is kept
            /// until he deletes it.
            case notInList
        }
        /// Path under the engine's root, e.g. "mlx-community/Qwen3.5-4B-MLX-4bit".
        var id: String { engine.rawValue + ":" + relativePath }
        var engine: Engine
        var relativePath: String
        var url: URL
        var bytes: Int64
        var modified: Date?
        var status: Status
        /// The LocalModelSpec id or Core AI catalog id it matches, if any.
        var catalogID: String?
        /// The revision folder of a Core AI copy, when there is one.
        var revision: String?
    }

    /// A stopped or running download's own files (not a model yet).
    struct Partial: Identifiable, Sendable, Equatable {
        var id: String { url.path }
        var url: URL
        var bytes: Int64
        var modified: Date?
        var label: String
    }

    // MARK: Scratch inventory (tmp and Caches)

    struct ScratchEntry: Identifiable, Sendable, Equatable {
        enum Kind: String, Sendable, CaseIterable {
            case compiledModels, modelCompileScratch, interruptedDownload, backupStaging,
                 shareExports, clips, systemCache, demo, unknown

            var label: String {
                switch self {
                case .compiledModels: "Compiled model copies"
                case .modelCompileScratch: "Model preparation leftovers"
                case .interruptedDownload: "Interrupted downloads"
                case .backupStaging: "Backup work files"
                case .shareExports: "Files made for sharing"
                case .clips: "Clip exports"
                case .systemCache: "System caches"
                case .demo: "Demo files"
                case .unknown: "Not identified"
                }
            }

            var explanation: String {
                switch self {
                case .compiledModels: "Core AI's prepared copy of each model for this iPhone. Removing it makes the next load prepare the model again, which takes minutes and is when Qwen3 4B has closed the app."
                case .modelCompileScratch: "Working files Core AI or Metal left while preparing a model, including ones left when the app closed mid-preparation."
                case .interruptedDownload: "Partly received files from downloads iOS stopped or the app was closed during."
                case .backupStaging: "Folders and part-written archives from making a backup. A finished backup is kept elsewhere."
                case .shareExports: "Copies made to share: Diagnostics, Results, OPML, history and backups. The originals stay."
                case .clips: "Audio clips made to share."
                case .systemCache: "Caches iOS frameworks keep for the app. They are rebuilt when needed."
                case .demo: "Files from the demo mode."
                case .unknown: "Files PodSkipper can't identify. They are inside PodSkipper's own temporary or cache folder, but what made them is unknown."
                }
            }

            /// Safe to remove by kind, when not in use: Tidy Up includes it.
            var safeByKind: Bool {
                switch self {
                case .modelCompileScratch, .interruptedDownload, .backupStaging, .shareExports, .clips, .demo: true
                case .compiledModels, .systemCache, .unknown: false
                }
            }
        }

        var id: String { url.path }
        var url: URL
        var name: String
        var kind: Kind
        var bytes: Int64
        var fileCount: Int
        var modified: Date?
        /// "tmp" or "Caches".
        var area: String
        /// Recently written or used by work under way: never removed.
        var inUse: Bool
    }

    struct Report: Sendable, Equatable {
        var models: [Item] = []
        var partials: [Partial] = []
        var scratch: [ScratchEntry] = []
        /// What iOS says is free on the phone right now.
        var freeBytes: Int64?

        func models(_ engine: Item.Engine) -> [Item] { models.filter { $0.engine == engine } }
        var modelBytes: Int64 { models.reduce(0) { $0 + $1.bytes } }
        var partialBytes: Int64 { partials.reduce(0) { $0 + $1.bytes } }
        var compiledBytes: Int64 { scratch.filter { $0.kind == .compiledModels }.reduce(0) { $0 + $1.bytes } }
        var temporaryBytes: Int64 { scratch.filter { $0.area == "tmp" }.reduce(0) { $0 + $1.bytes } }
        var cacheBytes: Int64 { scratch.filter { $0.area == "Caches" }.reduce(0) { $0 + $1.bytes } }
        /// What Tidy Up removes: stopped downloads and scratch that is safe by kind and not in use.
        var tidyEntries: [ScratchEntry] { scratch.filter { $0.kind.safeByKind && !$0.inUse } }
        var tidyBytes: Int64 { tidyEntries.reduce(0) { $0 + $1.bytes } + partialBytes }
    }

    /// Where things are; replaced in tests by a throwaway folder.
    struct Locations: Sendable {
        var mlxRoot: URL
        var coreAIRoot: URL
        var caches: URL
        var temporary: URL

        var compiledCache: URL { caches.appending(path: "com.apple.e5rt.e5bundlecache", directoryHint: .isDirectory) }

        static var live: Locations {
            Locations(mlxRoot: ModelStore.root,
                      coreAIRoot: URL.applicationSupportDirectory.appending(path: "CoreAIKit/Models", directoryHint: .isDirectory),
                      caches: URL.cachesDirectory,
                      temporary: FileManager.default.temporaryDirectory)
        }
    }

    /// What the app knows when it measures (read on the main actor first).
    struct Known: Sendable {
        /// LocalModelSpec ids in this version's list.
        var mlxIDs: Set<String> = []
        /// MLX ids whose every file is there (ModelStore's own check).
        var mlxReady: Set<String> = []
        /// `repo/revision/path` of each Core AI bundle this version loads, by catalog id.
        var coreAIPaths: [String: String] = [:]
        /// Core AI repositories in the catalog, by catalog id.
        var coreAIRepos: [String: String] = [:]
        /// A model download is running, so its files are not "stopped".
        var downloadActive = false
        /// Heavy work (a job, a test, a backup) is under way: recent scratch is kept.
        var workActive = false
    }

    /// Scratch written within this long is treated as in use.
    static let recentWindow: TimeInterval = 15 * 60

    /// Measures everything. Off the main actor; walks only the app's folders.
    static func measure(_ known: Known, at locations: Locations = .live, now: Date = Date()) -> Report {
        var report = Report()
        measureMLX(known, locations, into: &report)
        measureCoreAI(known, locations, into: &report)
        report.scratch = scratch(in: locations, known: known, now: now)
        report.freeBytes = freeBytes(near: locations.mlxRoot)
        report.models.sort { ($0.engine.rawValue, $0.relativePath) < ($1.engine.rawValue, $1.relativePath) }
        return report
    }

    static func freeBytes(near url: URL = URL.applicationSupportDirectory) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        return (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    private static func measureMLX(_ known: Known, _ locations: Locations, into report: inout Report) {
        let fm = FileManager.default
        let root = locations.mlxRoot
        // A model folder is one holding config.json, at any depth up to two
        // (flat "<id>" from older builds, or "<owner>/<repo>").
        func visit(_ folder: URL, depth: Int) {
            let name = folder.lastPathComponent
            let relative = relativePath(of: folder, under: root)
            if name.hasPrefix(".") {
                if !known.downloadActive {
                    report.partials.append(Partial(url: folder, bytes: size(of: folder), modified: modified(folder),
                                                   label: "MLX download files"))
                }
                return
            }
            let isModel = fm.fileExists(atPath: folder.appending(path: "config.json").path)
                || fm.fileExists(atPath: folder.appending(path: ".download.json").path)
                || known.mlxIDs.contains(relative)
            if isModel {
                let status: Item.Status
                if known.mlxIDs.contains(relative) {
                    status = known.mlxReady.contains(relative) ? .installed
                        : (known.downloadActive ? .installed : .incomplete)
                } else {
                    status = .notInList
                }
                report.models.append(Item(engine: .mlx, relativePath: relative, url: folder, bytes: size(of: folder),
                                          modified: modified(folder), status: status,
                                          catalogID: known.mlxIDs.contains(relative) ? relative : nil))
                return
            }
            guard depth < 2 else {
                // Files that aren't a model, two levels down: shown as such, kept.
                report.models.append(Item(engine: .mlx, relativePath: relative, url: folder, bytes: size(of: folder),
                                          modified: modified(folder), status: .notInList))
                return
            }
            let children = self.children(of: folder)
            if children.isEmpty { return }
            for child in children where isDirectory(child) { visit(child, depth: depth + 1) }
            // Loose files beside model folders: each its own item, so removing
            // one can never take the folder (and the models) around it.
            for file in children where !isDirectory(file) && !file.lastPathComponent.hasPrefix(".") {
                report.models.append(Item(engine: .mlx, relativePath: relativePath(of: file, under: root), url: file,
                                          bytes: size(of: file), modified: modified(file), status: .notInList))
            }
        }
        for child in children(of: root) where isDirectory(child) { visit(child, depth: 1) }
    }

    private static func measureCoreAI(_ known: Known, _ locations: Locations, into report: inout Report) {
        let fm = FileManager.default
        let root = locations.coreAIRoot
        let inUse = Dictionary(known.coreAIPaths.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        let byRepo = Dictionary(known.coreAIRepos.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        // CoreAIKit: <owner>/<repo>/<revision>/<variant path…>/metadata.json
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let url as URL in walker {
            let name = url.lastPathComponent
            let relative = relativePath(of: url, under: root)
            if name.hasPrefix(".staging-") || name.hasPrefix(".podskipper-staging-") {
                walker.skipDescendants()
                if !known.downloadActive {
                    report.partials.append(Partial(url: url, bytes: size(of: url), modified: modified(url),
                                                   label: "Core AI download files"))
                }
                continue
            }
            guard fm.fileExists(atPath: url.appending(path: "metadata.json").path) else { continue }
            walker.skipDescendants()
            let parts = relative.split(separator: "/").map(String.init)
            let repo = parts.count >= 2 ? parts[0] + "/" + parts[1] : relative
            let status: Item.Status
            let catalogID: String?
            if let id = inUse[relative] {
                status = .installed; catalogID = id
            } else if let id = byRepo[repo] {
                status = .otherVersion; catalogID = id
            } else {
                status = .notInList; catalogID = nil
            }
            report.models.append(Item(engine: .coreAI, relativePath: relative, url: url, bytes: size(of: url),
                                      modified: modified(url), status: status, catalogID: catalogID,
                                      revision: parts.count >= 3 ? parts[2] : nil))
        }
    }

    // MARK: Scratch

    static func scratch(in locations: Locations, known: Known, now: Date = Date()) -> [ScratchEntry] {
        var entries: [ScratchEntry] = []
        for (area, folder) in [("tmp", locations.temporary), ("Caches", locations.caches)] {
            for url in children(of: folder) {
                let name = url.lastPathComponent
                let kind = classify(name: name, area: area)
                let (bytes, count, newest) = measureTree(url)
                let recent = newest.map { now.timeIntervalSince($0) < recentWindow } ?? false
                let busy = (kind == .interruptedDownload && known.downloadActive)
                    || (known.workActive && recent)
                    || (kind == .compiledModels && known.workActive)
                entries.append(ScratchEntry(url: url, name: name, kind: kind, bytes: bytes, fileCount: count,
                                            modified: newest, area: area, inUse: recent || busy))
            }
        }
        return entries.sorted { $0.bytes > $1.bytes }
    }

    /// What made a top-level entry of tmp or Caches, by its name. Unknown
    /// names stay unknown rather than being guessed safe.
    static func classify(name: String, area: String) -> ScratchEntry.Kind {
        let lower = name.lowercased()
        if lower == "com.apple.e5rt.e5bundlecache" { return .compiledModels }
        if lower.hasPrefix("cfnetworkdownload_") || lower.hasSuffix(".download") || lower.hasPrefix("com.apple.nsurlsessiond") {
            return .interruptedDownload
        }
        if lower.contains("e5rt") || lower.contains("mpsgraph") || lower.contains("mlir") || lower.contains("coreai")
            || lower.hasPrefix("com.apple.metal") || lower.contains("aimodel") || lower.hasSuffix(".metallib")
            || lower.hasPrefix("mtlcompiler") || lower.hasPrefix("llvm") {
            return .modelCompileScratch
        }
        if lower.hasPrefix("backup-") || (area == "tmp" && lower.hasSuffix(".partial")) { return .backupStaging }
        if lower.hasPrefix("podskipper") || lower.hasSuffix(".opml") || lower.hasSuffix(".csv")
            || lower.hasSuffix(".podskipperbackup") || lower.hasSuffix(".zip") || lower.hasSuffix(".aar") {
            return .shareExports
        }
        if lower == "clips" { return .clips }
        if lower.hasPrefix("demo-") || lower.hasPrefix("missing-demo") { return .demo }
        if area == "Caches" && (lower.hasPrefix("com.apple.") || lower == "fsCachedData".lowercased()
            || lower.hasPrefix("app.") || lower.hasPrefix("com.")) {
            return .systemCache
        }
        return .unknown
    }

    // MARK: Removal

    /// Removes these items. Each must be inside one of `allowed` (resolved
    /// through symlinks) and not be one of those roots; anything else is refused.
    @discardableResult
    static func remove(_ urls: [URL], allowedRoots: [URL]) -> (freed: Int64, failures: [String]) {
        var failures: [String] = []
        var freed: Int64 = 0
        for url in urls {
            guard isInside(url, anyOf: allowedRoots) else {
                failures.append("Refused \(url.lastPathComponent): outside PodSkipper's model and scratch folders")
                continue
            }
            let bytes = size(of: url)
            do {
                try FileManager.default.removeItem(at: url)
                freed += bytes
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (freed, failures)
    }

    /// Model folders: the MLX and Core AI roots.
    static func removeModelFiles(_ urls: [URL], at locations: Locations = .live) -> (freed: Int64, failures: [String]) {
        let result = remove(urls, allowedRoots: [locations.mlxRoot, locations.coreAIRoot])
        removeEmptyFolders(under: locations.coreAIRoot)
        removeEmptyFolders(under: locations.mlxRoot)
        return result
    }

    /// Scratch entries: tmp and Caches only, never the roots themselves.
    static func removeScratch(_ entries: [ScratchEntry], at locations: Locations = .live) -> (freed: Int64, failures: [String]) {
        let kept = entries.filter(\.inUse)
        var result = remove(entries.filter { !$0.inUse }.map(\.url), allowedRoots: [locations.temporary, locations.caches])
        result.failures += kept.map { "\($0.name) is in use and was kept" }
        return result
    }

    /// Pass 33's repository-wide removal when a Core AI model is deleted.
    @discardableResult
    static func remove(_ urls: [URL], at locations: Locations = .live) -> [String] {
        removeModelFiles(urls, at: locations).failures
    }

    /// Everything one Core AI catalog model left under its repository —
    /// every revision and variant — for when it is deleted.
    static func repositoryFolder(repo: String, at locations: Locations = .live) -> URL? {
        guard !repo.isEmpty, !repo.contains(".."), repo.split(separator: "/").count == 2 else { return nil }
        let url = locations.coreAIRoot.appending(path: repo, directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Core AI rebuilds what it needs the next time a model loads.
    static func clearCompiledCache(at locations: Locations = .live) throws {
        guard FileManager.default.fileExists(atPath: locations.compiledCache.path) else { return }
        try FileManager.default.removeItem(at: locations.compiledCache)
    }

    // MARK: Helpers

    static func isInside(_ url: URL, anyOf roots: [URL]) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard !path.split(separator: "/").contains("..") else { return false }
        return roots.contains { root in
            let base = root.standardizedFileURL.resolvingSymlinksInPath().path
            return path.hasPrefix(base + "/") && path.count > base.count + 1
        }
    }

    static func isInsideModelFolders(_ url: URL, _ locations: Locations) -> Bool {
        isInside(url, anyOf: [locations.mlxRoot, locations.coreAIRoot])
    }

    static func relativePath(of url: URL, under root: URL) -> String {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
    }

    private static func children(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Bytes allocated, files, and the newest modification inside.
    static func measureTree(_ url: URL) -> (Int64, Int, Date?) {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .contentModificationDateKey]
        func values(_ u: URL) -> URLResourceValues? { try? u.resourceValues(forKeys: Set(keys)) }
        guard let top = values(url) else { return (0, 0, nil) }
        if top.isRegularFile == true {
            return (Int64(top.totalFileAllocatedSize ?? top.fileAllocatedSize ?? 0), 1, top.contentModificationDate)
        }
        var total: Int64 = 0, count = 0
        var newest = top.contentModificationDate
        if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let file as URL in walker {
                guard let v = values(file) else { continue }
                if let date = v.contentModificationDate, date > (newest ?? .distantPast) { newest = date }
                guard v.isRegularFile == true else { continue }
                total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                count += 1
            }
        }
        return (total, count, newest)
    }

    /// Bytes actually allocated (what iPhone Storage counts), not file lengths.
    static func size(of url: URL) -> Int64 { measureTree(url).0 }

    private static func removeEmptyFolders(under root: URL) {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        let folders = walker.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path.count > $1.path.count }
        for folder in folders where (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? fm.removeItem(at: folder)
        }
    }
}

/// Pass 35: free space checks before work that writes gigabytes. His 9 Oct
/// phone had 339 MB free when the library failed to open (SQLite 4618, the
/// shared-memory file couldn't be created) and Core AI aborted while
/// preparing Qwen3 4B; both write to disk before anything else can fail.
enum StorageGuard {
    /// Below this, the app warns everywhere it shows storage.
    static let lowThreshold: Int64 = 2_000_000_000
    /// Below this, nothing large is started.
    static let criticalThreshold: Int64 = 1_000_000_000

    enum Verdict: Equatable {
        case ok
        case low(free: Int64)
        case insufficient(free: Int64, needed: Int64)
    }

    /// Whether work that writes about `bytes` can start, keeping a margin
    /// for the library and the system.
    static func check(writing bytes: Int64, free: Int64? = ModelStorage.freeBytes()) -> Verdict {
        guard let free else { return .ok }
        let needed = bytes + criticalThreshold
        if free < needed { return .insufficient(free: free, needed: needed) }
        if free < lowThreshold { return .low(free: free) }
        return .ok
    }

    static func message(for verdict: Verdict, doing what: String) -> String? {
        let f = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        switch verdict {
        case .ok: return nil
        case .low(let free): return "Only \(f(free)) is free on this iPhone. Free some space in Downloads & Storage soon."
        case .insufficient(let free, let needed):
            return "Not enough space to \(what): \(f(free)) is free and it needs about \(f(needed)), including room for your library. Free some space in Downloads & Storage first."
        }
    }
}
