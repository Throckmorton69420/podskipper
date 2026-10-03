import Foundation
import CryptoKit

/// Completed Apple Intelligence replies for one episode. A resumed job only
/// reuses answers whose request key identifies its current prompt and runtime.
/// Legacy reply files remain readable history; unverifiable replies are not
/// promoted into the current cache.
final class DetectionCheckpoint: @unchecked Sendable {
    private let url: URL
    private let write: @Sendable (Data, URL) throws -> Void
    private let remove: @Sendable (URL) throws -> Void
    private let lock = NSLock()
    private var answers: [String: String] = [:]
    private var unsaved = 0
    private var discarded = false
    private var readable = true
    private var lastStorageError: String?

    /// Version 2 separates verified request keys from legacy prompt-only files.
    /// The existing JSON dictionary format stays readable by inspection.
    static func fileURL(guid: String, cacheDirectory: URL = URL.cachesDirectory) -> URL {
        directory(in: cacheDirectory).appendingPathComponent(Self.digest(guid) + "-v2.json")
    }

    static func legacyFileURL(guid: String, cacheDirectory: URL = URL.cachesDirectory) -> URL {
        directory(in: cacheDirectory).appendingPathComponent(Self.digest(guid) + ".json")
    }

    /// Explicit transcript deletion must also discard its legacy answer history.
    static func fileURLs(guid: String, cacheDirectory: URL = URL.cachesDirectory) -> [URL] {
        [fileURL(guid: guid, cacheDirectory: cacheDirectory),
         legacyFileURL(guid: guid, cacheDirectory: cacheDirectory)]
    }

    init(guid: String, cacheDirectory: URL = URL.cachesDirectory,
         write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
         remove: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        url = Self.fileURL(guid: guid, cacheDirectory: cacheDirectory)
        self.write = write
        self.remove = remove
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                answers = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
            } catch {
                if !Self.isMissingFile(error) {
                    // Do not replace an unreadable or future-format file with
                    // an empty cache. New work may proceed without caching.
                    readable = false
                    lastStorageError = "Could not read saved model replies: \(error.localizedDescription)"
                }
            }
        } catch {
            readable = false
            lastStorageError = "Could not open saved model replies: \(error.localizedDescription)"
        }
    }

    var reused: Int { lock.withLock { discarded ? 0 : answers.count } }
    var storageError: String? { lock.withLock { lastStorageError } }

    /// Mutation and automatic flush share the same lock as save/discard. A
    /// caller retaining this pair after job completion cannot resurrect it.
    var cache: (get: (String) -> String?, set: (String, String) -> Void) {
        (get: { [self] key in
            lock.withLock { discarded || !readable ? nil : answers[Self.digest(key)] }
        }, set: { [self] key, value in
            lock.withLock {
                guard !discarded, readable else { return }
                answers[Self.digest(key)] = value
                unsaved += 1
                if unsaved >= 8 { _ = saveLocked() }
            }
        })
    }

    /// A failed write retains its dirty state, so a later save can retry.
    @discardableResult
    func save() -> Bool { lock.withLock { saveLocked() } }

    /// Permanent for this instance, including when unlink fails. The caller
    /// may report the error; later responses still cannot write to this file.
    /// Legacy history remains until explicit transcript cleanup.
    @discardableResult
    func discard() -> Bool {
        lock.withLock {
            discarded = true
            answers.removeAll()
            unsaved = 0
            guard readable else { return false }
            do {
                try remove(url)
                lastStorageError = nil
                return true
            } catch {
                if Self.isMissingFile(error) {
                    lastStorageError = nil
                    return true
                }
                lastStorageError = "Could not remove saved model replies: \(error.localizedDescription)"
                return false
            }
        }
    }

    /// Called only while holding lock, including the actual atomic write.
    private func saveLocked() -> Bool {
        guard !discarded, readable else { return false }
        guard unsaved > 0 else { return true }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try write(encoder.encode(answers), url)
            unsaved = 0
            lastStorageError = nil
            return true
        } catch {
            lastStorageError = "Could not save model replies: \(error.localizedDescription)"
            return false
        }
    }

    private static func directory(in cacheDirectory: URL) -> URL {
        cacheDirectory.appendingPathComponent("DetectionCheckpoints", isDirectory: true)
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
