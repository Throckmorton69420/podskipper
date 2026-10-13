import Foundation

/// Pass 36: every removal of models, temporary files or caches, item by item
/// — what each was, why it was thought to be that, its size, and whether it
/// went — kept beside the library so a later Diagnostics export can say
/// exactly what a cleanup removed.
///
/// Why (his 12 Oct Diagnostics): "Temporary files: Removed 11 items, freeing
/// 36.8 GB" was the only record of a cleanup after which Qwen3 4B had to be
/// prepared again; nothing said what the 11 items were. Last 200 operations.
enum CleanupLog {
    struct Item: Codable, Sendable, Equatable {
        var name: String
        /// "tmp", "Caches", "Core AI models", "MLX models", "Core AI cache".
        var area: String
        /// What PodSkipper took it to be (the scratch kind or "model").
        var kind: String
        /// Why it was taken to be that.
        var evidence: String
        var bytes: Int64
        /// "removed", "kept: …", or "failed: …".
        var result: String
    }

    struct Operation: Codable, Sendable, Equatable {
        var date: Date
        /// Where it was asked for: "Temporary Files", "Model deletion", "Tidy Up"…
        var context: String
        var items: [Item]
        /// Free space before and after, as iOS reported it.
        var freeBefore: Int64?
        var freeAfter: Int64?
        var build: String = BuildInfo.commit
    }

    static var url: URL { Diagnostics.folder.appending(path: "cleanup-log.json") }
    static let limit = 200

    static func load(from url: URL = url) -> [Operation] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Operation].self, from: data)) ?? []
    }

    /// Adds one operation (newest first). Safe from any thread; writes are
    /// serialised.
    static func record(_ operation: Operation, to url: URL = url) {
        lock.withLock {
            var all = load(from: url)
            all.insert(operation, at: 0)
            if all.count > limit { all.removeLast(all.count - limit) }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(all) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private static let lock = NSLock()
}
