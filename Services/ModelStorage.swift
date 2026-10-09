import Foundation

/// What the models take on this phone, measured from the files themselves
/// (Pass 33, his report: deleting a model didn't free the iPhone's storage
/// straight away).
///
/// Three things made the space PodSkipper used and the space iPhone Storage
/// showed drift apart, all found in his 9 Oct Diagnostics and in the code:
/// - CoreAIKit's delete removes one revision's one variant
///   (`<repo>/<revision>/<path>`). An older revision, or the iPhone build of
///   a model that Pass 32 swapped for its portable build, stayed on disk
///   with nothing in the app pointing at it.
/// - Core AI compiles a model on the phone the first time it loads and keeps
///   the result in the app's Caches (`com.apple.e5rt.e5bundlecache`). His
///   MetricKit: the app's caches went 2.6 → 14.1 → 0 → 2.6 GB over four
///   days, and one session wrote 17 GB, most of it from Core AI's GPU
///   engine starting up. Deleting a model never touched that, and iOS
///   empties Caches only when it decides to — the "it frees up later".
/// - Nothing in the app showed any of it.
///
/// Everything here stays inside the folders PodSkipper's own model code
/// writes: the MLX model folders, CoreAIKit's model store, and the compiled
/// model cache. Episodes, transcripts, corrections and the library are never
/// touched.
enum ModelStorage {
    struct Report: Sendable, Equatable {
        /// MLX models the app knows, by id.
        var mlx: [String: Int64] = [:]
        /// MLX folders for no model the app offers any more.
        var mlxStray: [URL] = []
        var mlxStrayBytes: Int64 = 0
        /// Core AI bundles the app currently points at, by relative path.
        var coreAI: [String: Int64] = [:]
        /// Core AI copies nothing points at (old revisions, a variant no
        /// longer used).
        var coreAIStray: [URL] = []
        var coreAIStrayBytes: Int64 = 0
        /// Downloads that stopped part way and are not being continued.
        var partial: [URL] = []
        var partialBytes: Int64 = 0
        /// Core AI's on-phone compiled copies of models.
        var compiledBytes: Int64 = 0
        /// The app's temporary folder.
        var temporaryBytes: Int64 = 0
        /// What iOS says is free on the phone right now.
        var freeBytes: Int64?

        var modelBytes: Int64 { mlx.values.reduce(0, +) + coreAI.values.reduce(0, +) }
        var reclaimableBytes: Int64 { mlxStrayBytes + coreAIStrayBytes + partialBytes }
    }

    /// Where things are; replaced in tests by a throwaway folder.
    struct Locations: Sendable {
        var mlxRoot: URL
        var coreAIRoot: URL
        var compiledCache: URL
        var temporary: URL

        static var live: Locations {
            let support = URL.applicationSupportDirectory
            return Locations(mlxRoot: ModelStore.root,
                             coreAIRoot: support.appending(path: "CoreAIKit/Models", directoryHint: .isDirectory),
                             compiledCache: URL.cachesDirectory.appending(path: "com.apple.e5rt.e5bundlecache",
                                                                          directoryHint: .isDirectory),
                             temporary: FileManager.default.temporaryDirectory)
        }
    }

    /// Measures everything. Off the main actor; walks only model folders.
    /// - Parameters:
    ///   - mlxIDs: model ids the app offers (each is a folder under the MLX root).
    ///   - coreAIPaths: `repo/revision/path` of every Core AI bundle the app
    ///     would load (the chosen variant of each catalog entry).
    ///   - downloadActive: a model download is running, so the folders it
    ///     is writing are not "stopped part way".
    static func measure(mlxIDs: Set<String>, coreAIPaths: Set<String>, downloadActive: Bool = false,
                        at locations: Locations = .live) -> Report {
        let fm = FileManager.default
        var report = Report()

        for folder in children(of: locations.mlxRoot) {
            let name = folder.lastPathComponent
            let bytes = size(of: folder)
            if name.hasPrefix(".") {
                if !downloadActive { report.partial.append(folder); report.partialBytes += bytes }
            } else if mlxIDs.contains(name) {
                report.mlx[name] = bytes
            } else {
                report.mlxStray.append(folder); report.mlxStrayBytes += bytes
            }
        }

        // CoreAIKit: <repo owner>/<repo name>/<revision>/<variant path…>/metadata.json
        let root = locations.coreAIRoot.standardizedFileURL.path
        if let walker = fm.enumerator(at: locations.coreAIRoot, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in walker {
                let name = url.lastPathComponent
                let relative = String(url.standardizedFileURL.path.dropFirst(root.count + 1))
                if name.hasPrefix(".staging-") || name.hasPrefix(".podskipper-staging-") {
                    walker.skipDescendants()
                    if !downloadActive { report.partial.append(url); report.partialBytes += size(of: url) }
                    continue
                }
                guard fm.fileExists(atPath: url.appending(path: "metadata.json").path) else { continue }
                walker.skipDescendants()
                let bytes = size(of: url)
                if coreAIPaths.contains(relative) {
                    report.coreAI[relative] = bytes
                } else {
                    report.coreAIStray.append(url); report.coreAIStrayBytes += bytes
                }
            }
        }

        report.compiledBytes = size(of: locations.compiledCache)
        report.temporaryBytes = size(of: locations.temporary)
        report.freeBytes = (try? locations.mlxRoot.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        return report
    }

    /// Removes what nothing points at: stray copies and stopped downloads.
    /// Each path must be inside a model folder; anything else is refused.
    @discardableResult
    static func remove(_ urls: [URL], at locations: Locations = .live) -> [String] {
        var failures: [String] = []
        for url in urls {
            guard isInsideModelFolders(url, locations) else {
                failures.append("Refused \(url.lastPathComponent): not a model folder")
                continue
            }
            do { try FileManager.default.removeItem(at: url) } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        removeEmptyFolders(under: locations.coreAIRoot)
        return failures
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

    static func isInsideModelFolders(_ url: URL, _ locations: Locations) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return [locations.mlxRoot, locations.coreAIRoot].contains { root in
            let base = root.standardizedFileURL.resolvingSymlinksInPath().path
            return path.hasPrefix(base + "/") && path.count > base.count + 1
        }
    }

    private static func children(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    /// Bytes actually allocated (what iPhone Storage counts), not file lengths.
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        func allocated(_ u: URL) -> Int64 {
            guard let v = try? u.resourceValues(forKeys: keys), v.isRegularFile == true else { return 0 }
            return Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        guard isDirectory.boolValue else { return allocated(url) }
        var total: Int64 = 0
        if let walker = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
            for case let file as URL in walker { total += allocated(file) }
        }
        return total
    }

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
