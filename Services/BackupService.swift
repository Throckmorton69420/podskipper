import AppleArchive
import CryptoKit
import Foundation
import Observation
import SQLite3
import SwiftData
import System
import UIKit
import UniformTypeIdentifiers

/// Back up everything, restore it into a fresh install (pass 21).
///
/// His 27 Sep message: KSign now signs PodSkipper as `com.worksin.two`, so
/// it installs beside the old copy with an empty library. He wants
/// everything carried over — subscriptions, listening history, transcripts,
/// downloads, ad-finding results, diagnostics, settings — "a big file is
/// fine", or a visible folder to copy.
///
/// Both, then. A backup is one `.podskipper` file (an Apple Archive) saved in
/// the app's Documents folder, which the Files app shows as On My iPhone →
/// PodSkipper, and offered to share. It holds:
/// - the library database, copied with SQLite's own backup call so it is
///   consistent while the app is running (shows, episodes, play state and
///   history, stars, bookmarks, every cut with his edits kept apart);
/// - everything else in Application Support: transcripts, the fingerprint
///   library, diagnostics and timing logs, and — if he says so — the
///   downloaded audio;
/// - the answers saved part way through ad finding (checkpoints);
/// - the settings (the app's defaults).
///
/// Restoring unpacks the file beside the app's data, and the swap happens at
/// the next launch, before the library opens — a database can't be replaced
/// under the app while it is using it. The copy it replaces is kept once, in
/// Library/PodSkipperRestore/previous, until the next restore.
enum BackupService {
    static let fileExtension = "podskipper"
    static let type = UTType(exportedAs: "com.podskipper.backup", conformingTo: .data)

    static var appSupport: URL { URL.applicationSupportDirectory }
    static var documents: URL { URL.documentsDirectory }
    static var restoreRoot: URL { URL.libraryDirectory.appending(path: "PodSkipperRestore", directoryHint: .isDirectory) }
    static var staged: URL { restoreRoot.appending(path: "staged", directoryHint: .isDirectory) }
    static var readyMarker: URL { restoreRoot.appending(path: "ready") }
    static var checkpoints: URL {
        URL.cachesDirectory.appending(path: "DetectionCheckpoints", directoryHint: .isDirectory)
    }

    /// Explicit paths make backup/restore tests operate only on disposable data.
    struct Locations: @unchecked Sendable {
        var appSupport: URL
        var documents: URL
        var restoreRoot: URL
        var checkpoints: URL
        var defaults: UserDefaults
        var domain: String
        var staged: URL { restoreRoot.appending(path: "staged") }
        var ready: URL { restoreRoot.appending(path: "ready") }
        var ledger: URL { restoreRoot.deletingLastPathComponent().appending(path: "PodSkipperBackups.json") }
        static var live: Locations {
            Locations(appSupport: BackupService.appSupport, documents: BackupService.documents,
                      restoreRoot: BackupService.restoreRoot, checkpoints: BackupService.checkpoints,
                      defaults: .standard, domain: Bundle.main.bundleIdentifier ?? "")
        }
        var transaction: BackupRestoreTransaction.Locations {
            .init(root: restoreRoot, appSupport: appSupport, checkpoints: checkpoints,
                  defaults: defaults, domain: domain, preservedFolders: [ModelStore.folderName, "CoreAIKit/Models"])
        }
    }

    struct Manifest: Codable, Sendable {
        var formatVersion: Int? = 2
        var files: [String: Int64]?
        var checksums: [String: String]?
        var createdAt: Date
        var build: String
        var bundleID: String
        var shows: Int
        var episodes: Int
        var includesAudio: Bool
    }

    enum Failure: LocalizedError {
        case database(String), archive(String), notABackup
        var errorDescription: String? {
            switch self {
            case .database(let why): return "Couldn't copy the library: \(why)"
            case .archive(let why): return "Couldn't write or read the backup file: \(why)"
            case .notABackup: return "That file isn't a PodSkipper backup."
            }
        }
    }
}

// MARK: - Making a backup

extension BackupService {
    /// Builds the backup file in Documents and returns it. Runs off the main
    /// thread; `progress` gets 0...1 and a word on the step.
    nonisolated static func make(manifest: Manifest, locations: Locations = .live,
                                 progress: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let appSupport = locations.appSupport, documents = locations.documents, checkpoints = locations.checkpoints
            let work = fm.temporaryDirectory.appending(path: "Backup-\(UUID().uuidString)", directoryHint: .isDirectory)
            markInUse(work)
            defer { unmarkInUse(work) }
            defer { try? fm.removeItem(at: work) }
            let support = work.appending(path: "AppSupport", directoryHint: .isDirectory)
            try fm.createDirectory(at: support, withIntermediateDirectories: true)

            progress(0.02, "Copying the library")
            // The databases, each through SQLite's backup call; everything
            // else in Application Support as APFS clones (instant, no space).
            let items = (try? fm.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: nil)) ?? []
            for item in items {
                let name = item.lastPathComponent
                if name.hasSuffix("-wal") || name.hasSuffix("-shm") { continue }
                if name == "Episodes", !manifest.includesAudio { continue }
                // The on-device ad model: gigabytes, and downloadable again.
                if name == ModelStore.folderName { continue }
                if name.hasSuffix(".store") || name.hasSuffix(".sqlite") {
                    try copyDatabase(item, to: support.appending(path: name))
                } else if name == "CoreAIKit" {
                    let target = support.appending(path: name)
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    for child in try fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
                        where child.lastPathComponent != "Models" {
                        try fm.copyItem(at: child, to: target.appending(path: child.lastPathComponent))
                    }
                } else {
                    try fm.copyItem(at: item, to: support.appending(path: name))
                }
            }
            if fm.fileExists(atPath: checkpoints.path) {
                try fm.copyItem(at: checkpoints, to: work.appending(path: "Checkpoints"))
            }
            let defaults = locations.defaults.persistentDomain(forName: locations.domain) ?? [:]
            let plist = try PropertyListSerialization.data(fromPropertyList: defaults, format: .binary, options: 0)
            try plist.write(to: work.appending(path: "defaults.plist"))
            var versioned = manifest
            versioned.formatVersion = 2
            versioned.files = try inventory(work)
            versioned.checksums = try checksums(work, files: versioned.files ?? [:])
            try JSONEncoder.iso.encode(versioned).write(to: work.appending(path: "manifest.json"))
            let clock = DateFormatter()
            clock.locale = Locale(identifier: "en_US_POSIX")
            clock.dateFormat = "yyyy-MM-dd HHmmss"
            let name = "PodSkipper Backup \(clock.string(from: manifest.createdAt))-\(UUID().uuidString.prefix(8)).\(fileExtension)"
            try fm.createDirectory(at: documents, withIntermediateDirectories: true)
            let file = documents.appending(path: name)
            markInUse(file)
            defer { unmarkInUse(file) }
            let total = max(1, countFiles(in: work))
            // The output must be outside the tree being archived.
            let archiveFile = fm.temporaryDirectory.appending(path: UUID().uuidString + ".partial")
            defer { try? fm.removeItem(at: archiveFile) }
            try archive(work, to: archiveFile, compress: !manifest.includesAudio) { done in
                progress(0.05 + 0.95 * min(1, Double(done) / Double(total)), "Writing the backup file")
            }
            try fm.moveItem(at: archiveFile, to: file)
            recordMade(file, locations: locations)
            progress(1, "Done")
            return file
        }.value
    }

    nonisolated static func inventory(_ root: URL) throws -> [String: Int64] {
        var files: [String: Int64] = [:]
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        while let url = walker?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw Failure.archive("symbolic links are not supported in backups") }
            if values.isRegularFile == true { files[String(url.path.dropFirst(root.path.count + 1))] = Int64(values.fileSize ?? 0) }
        }
        return files
    }

    nonisolated static func validateDatabase(_ file: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); throw Failure.database("cannot read " + file.lastPathComponent)
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK else {
            throw Failure.database("the saved database could not be checked")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0),
              String(cString: text) == "ok" else { throw Failure.database("the saved database is corrupt") }
    }

    nonisolated static func checksums(_ root: URL, files: [String: Int64]) throws -> [String: String] {
        var hashes: [String: String] = [:]
        for name in files.keys {
            let handle = try FileHandle(forReadingFrom: root.appending(path: name))
            defer { try? handle.close() }
            var digest = SHA256()
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { digest.update(data: bytes) }
            hashes[name] = digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return hashes
    }

    /// A consistent copy of a live SQLite database.
    nonisolated static func copyDatabase(_ source: URL, to destination: URL) throws {
        var from: OpaquePointer?
        var to: OpaquePointer?
        guard sqlite3_open_v2(source.path, &from, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(from)
            throw Failure.database("can't open \(source.lastPathComponent)")
        }
        defer { sqlite3_close(from) }
        guard sqlite3_open(destination.path, &to) == SQLITE_OK else {
            sqlite3_close(to)
            throw Failure.database("can't create the copy")
        }
        defer { sqlite3_close(to) }
        guard let backup = sqlite3_backup_init(to, "main", from, "main") else {
            throw Failure.database(String(cString: sqlite3_errmsg(to)))
        }
        let step = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE else { throw Failure.database(String(cString: sqlite3_errmsg(to))) }
    }

    nonisolated static func countFiles(in folder: URL) -> Int {
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        var count = 0
        while walker?.nextObject() != nil { count += 1 }
        return count
    }
}

// MARK: - The file itself (Apple Archive)

/// Counts entries as the archiver works through them, from its own thread.
private final class EntryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() -> Int { lock.withLock { value += 1; return value } }
}

extension BackupService {
    nonisolated static func archive(_ folder: URL, to file: URL, compress: Bool,
                                    progress: @escaping @Sendable (Int) -> Void) throws {
        guard let out = ArchiveByteStream.fileStream(path: FilePath(file.path), mode: .writeOnly,
                                                     options: [.create, .truncate],
                                                     permissions: FilePermissions(rawValue: 0o644)) else {
            throw Failure.archive("can't create \(file.lastPathComponent)")
        }
        defer { try? out.close() }
        // Audio doesn't shrink, so with downloads it's stored as is (fast);
        // without, transcripts and the database shrink several times.
        guard let packed = ArchiveByteStream.compressionStream(using: compress ? .lzfse : .none, writingTo: out) else {
            throw Failure.archive("can't start compressing")
        }
        defer { try? packed.close() }
        guard let encoder = ArchiveStream.encodeStream(writingTo: packed) else { throw Failure.archive("can't start the archive") }
        defer { try? encoder.close() }
        guard let keys = ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DEV,DAT,MOD,MTM") else {
            throw Failure.archive("bad field list")
        }
        let counter = EntryCounter()
        try encoder.writeDirectoryContents(archiveFrom: FilePath(folder.path), keySet: keys) { message, _, _ in
            if message == .encodeWriting { progress(counter.bump()) }
            return .ok
        }
        try encoder.close()
        try packed.close()
        try out.close()
    }

    /// What an extraction ran into, for a message that says what failed
    /// rather than "isn't a backup" (pass 21b: his first restore stopped at
    /// 2 % with that message and nothing else to go on).
    final class ExtractReport: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var failed: [String] = []
        func fail(_ path: String) { lock.withLock { if failed.count < 20 { failed.append(path) } } }
        var failures: [String] { lock.withLock { failed } }
    }

    /// The first bytes of the file, in words, for the error message.
    nonisolated static func sniff(_ file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file),
              let head = try? handle.read(upToCount: 4) else { return "unreadable" }
        try? handle.close()
        let text = String(decoding: head, as: UTF8.self)
        if head.starts(with: [0x50, 0x4B]) { return "a zip file (PK)" }
        return text.allSatisfy { $0.isASCII && !$0.isWhitespace } ? "starts with \"\(text)\"" : "starts with bytes \(head.map { String(format: "%02x", $0) }.joined())"
    }

    nonisolated static func extract(_ file: URL, into folder: URL, report: ExtractReport,
                                    progress: @escaping @Sendable (Int) -> Void) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func open() throws -> ArchiveByteStream {
            guard let input = ArchiveByteStream.fileStream(path: FilePath(file.path), mode: .readOnly, options: [],
                                                           permissions: FilePermissions(rawValue: 0o644)) else {
                throw Failure.archive("can't open the file (\(sniff(file)), errno \(errno))")
            }
            return input
        }
        // Every backup so far is compressed ("pbz…"); a plain archive
        // ("AA01") is read as is.
        let plain = sniff(file).contains("AA01")
        let input = try open()
        defer { try? input.close() }
        var unpacked: ArchiveByteStream?
        if !plain {
            guard let stream = ArchiveByteStream.decompressionStream(readingFrom: input) else {
                throw Failure.archive("not an Apple Archive (\(sniff(file)))")
            }
            unpacked = stream
        }
        defer { try? unpacked?.close() }
        guard let decoder = ArchiveStream.decodeStream(readingFrom: unpacked ?? input) else {
            throw Failure.archive("can't read the archive (\(sniff(file)))")
        }
        defer { try? decoder.close() }
        let counter = EntryCounter()
        // A file that can't be written (an attribute iOS won't set, say) is
        // noted and the rest carries on; what matters is checked after.
        guard let writer = ArchiveStream.extractStream(extractingTo: FilePath(folder.path), selectUsing: { message, path, _ in
            switch message {
            case .extractBegin: progress(counter.bump())
            case .extractFail, .extractAttributes, .extractXAT, .extractACL: report.fail("\(message): \(path)")
            default: break
            }
            return .ok
        }, flags: [.ignoreOperationNotPermitted]) else { throw Failure.archive("can't start unpacking") }
        defer { try? writer.close() }
        do { _ = try ArchiveStream.process(readingFrom: decoder, writingTo: writer) }
        catch {
            let where_ = report.failures.first.map { " at \($0)" } ?? ""
            throw Failure.archive("unpacking stopped after \(counter.bump() - 1) files\(where_): \(error)")
        }
    }
}

// MARK: - Restoring

extension BackupService {
    /// Unpacks a backup beside the app's data and checks it. The swap
    /// itself waits for the next launch (`applyPendingRestore`).
    nonisolated static func stage(_ file: URL, locations: Locations = .live,
                                  availableCapacity: Int64? = nil,
                                  progress: @escaping @Sendable (Double, String) -> Void) async throws -> Manifest {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let root = locations.restoreRoot
            markInUse(root)
            markInUse(file)
            defer { unmarkInUse(file); unmarkInUse(root) }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let candidate = root.appending(path: "staging-" + UUID().uuidString)
            defer { try? fm.removeItem(at: candidate) }
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            let report = ExtractReport()
            var coordinationError: NSError?
            var extraction: Result<Void, Error> = .failure(Failure.archive("the backup could not be coordinated"))
            NSFileCoordinator().coordinate(readingItemAt: file, options: [.withoutChanges], error: &coordinationError) { coordinated in
                extraction = Result {
                    let bytes = Int64((try coordinated.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    let free = availableCapacity ?? (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                        .volumeAvailableCapacityForImportantUsage) ?? Int64.max
                    guard free >= bytes + bytes / 10 else { throw Failure.archive("not enough free space to unpack this backup") }
                    progress(0.02, "Unpacking")
                    let guess = max(200, Int(bytes / 400_000))
                    try extract(coordinated, into: candidate, report: report) { done in
                        progress(min(0.95, 0.02 + 0.93 * Double(done) / Double(guess)), "Unpacking")
                    }
                }
            }
            if let coordinationError { throw coordinationError }
            try extraction.get()
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let support = candidate.appending(path: "AppSupport")
            guard let data = try? Data(contentsOf: candidate.appending(path: "manifest.json")),
                  let manifest = try? decoder.decode(Manifest.self, from: data),
                  (1...2).contains(manifest.formatVersion ?? 1), fm.fileExists(atPath: support.path) else {
                throw Failure.archive("the file has no supported PodSkipper manifest")
            }
            if let expected = manifest.files {
                let actual = try inventory(candidate)
                for (name, size) in expected where actual[name] != size {
                    throw Failure.archive("the saved file is missing or incomplete: " + name)
                }
                if let hashes = manifest.checksums {
                    guard Set(hashes.keys) == Set(expected.keys),
                          try checksums(candidate, files: expected) == hashes else {
                        throw Failure.archive("a saved file did not pass its integrity check")
                    }
                } else if manifest.formatVersion == 2 { throw Failure.archive("the backup has no integrity checks") }
            } else if manifest.formatVersion == 2 {
                throw Failure.archive("the backup has no file inventory")
            }
            guard let settingsData = try? Data(contentsOf: candidate.appending(path: "defaults.plist")),
                  (try? PropertyListSerialization.propertyList(from: settingsData, format: nil)) is [String: Any] else {
                throw Failure.archive("the saved settings are missing or corrupt")
            }
            let stores = try fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "store" || $0.pathExtension == "sqlite" }
            guard !stores.isEmpty || DemoData.isEnabled else { throw Failure.archive("the backup has no library database") }
            for store in stores { try validateDatabase(store) }
            let former = root.appending(path: "replaced-staged-" + UUID().uuidString)
            if fm.fileExists(atPath: locations.staged.path) { try fm.moveItem(at: locations.staged, to: former) }
            do {
                try fm.moveItem(at: candidate, to: locations.staged)
                try Data().write(to: locations.ready, options: .atomic)
            } catch {
                if fm.fileExists(atPath: locations.staged.path) { try? fm.moveItem(at: locations.staged, to: candidate) }
                if fm.fileExists(atPath: former.path) { try? fm.moveItem(at: former, to: locations.staged) }
                throw error
            }
            try? fm.removeItem(at: former)
            progress(1, "Ready")
            return manifest
        }.value
    }

    static var hasPendingRestore: Bool { FileManager.default.fileExists(atPath: readyMarker.path) }

    /// At launch, before the library opens: puts a staged backup in place.
    /// Anything that goes wrong leaves the current data where it was.
    static func applyPendingRestore(locations: Locations = .live) throws {
        let pending = FileManager.default.fileExists(atPath: locations.ready.path)
        try BackupRestoreTransaction.apply(locations.transaction)
        if pending {
            locations.defaults.set(true, forKey: "seenOnboarding")
            locations.defaults.set("Restored from backup on \(Date.now.formatted(date: .abbreviated, time: .shortened))",
                                   forKey: "lastRestoreResult")
        }
    }

}

// MARK: - Listening history, readable

extension BackupService {
    /// Every episode of every show with whether and how far he listened,
    /// as a spreadsheet-friendly CSV in Documents. OPML has no place for
    /// this (it lists feeds only), so this sits beside it (his 27 Sep ask).
    nonisolated static func writeHistory(container: ModelContainer) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<Episode>(sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
            let episodes = try context.fetch(descriptor)
            let day = Date.ISO8601FormatStyle().year().month().day()
            let stamp = Date.ISO8601FormatStyle()
            func cell(_ text: String) -> String {
                text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" })
                    ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
            }
            var rows = ["Show,Episode,Published,Length (min),Status,Position (min),Listened (min),Last Played,Starred,Ads Found,Feed,GUID"]
            rows.reserveCapacity(episodes.count + 1)
            for e in episodes {
                let status = e.isPlayed ? "Played" : (e.playbackPosition > 1 ? "In progress" : "Unplayed")
                rows.append([
                    cell(e.podcast?.title ?? ""), cell(e.title), e.publishedAt.formatted(day),
                    String(format: "%.1f", e.duration / 60), status,
                    String(format: "%.1f", e.playbackPosition / 60), String(format: "%.1f", e.secondsListened / 60),
                    e.lastPlayedAt.map { $0.formatted(stamp) } ?? "", e.isStarred ? "Yes" : "",
                    e.processingState == .ready ? "Yes" : "", cell(e.podcast?.feedURL ?? ""), cell(e.guid),
                ].joined(separator: ","))
            }
            let file = documents.appending(path: "PodSkipper Listening History \(Date.now.formatted(day)).csv")
            try rows.joined(separator: "\n").data(using: .utf8)?.write(to: file, options: .atomic)
            return file
        }.value
    }

    /// Backups already in Documents, newest first.
    nonisolated static func existingBackups(locations: Locations = .live) -> [URL] {
        let documents = locations.documents
        let files = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == fileExtension && isRegularStoredFile($0) }
            .sorted { backupDate($0) > backupDate($1) }
    }
}

// MARK: - What backups keep on the phone (pass 22)
//
// His 28 Sep report: backups keep a lot of data and there was no way to
// delete it short of removing the app. What the code actually keeps:
//
// 1. Every "Back Up Everything" writes a new file to Documents (On My
//    iPhone → PodSkipper), named by the minute, and none is ever removed.
//    With downloads included each one is a second full copy of the audio.
// 2. Every listening-history export writes a CSV beside them (one a day).
// 3. Each restore moves the data it replaced to Library/PodSkipperRestore/
//    previous — downloads included — and keeps it, invisible, until the
//    next restore.
// 4. A restore unpacked but not yet put in place ("Later") waits in
//    Library/PodSkipperRestore/staged, as big as the backup.
// 5. Leftovers: a backup's work folder in tmp if the app was closed while
//    making one; a backup another app handed over as a copy (Documents/Inbox).
//
// None of that is the library, the transcripts or the downloads, which live
// in Application Support and are not touched here. Copies he saved or
// shared somewhere else (iCloud Drive, AirDrop, another app) are outside
// the app and are not touched either.

extension BackupService {
    struct Stored: Sendable, Equatable {
        var backups: [URL] = []
        var backupSizes: [URL: Int64] = [:]
        var histories: [URL] = []
        var historyBytes: Int64 = 0
        var previousBytes: Int64 = 0
        var stagedBytes: Int64 = 0
        var restorePending = false
        var leftovers: [URL] = []
        var leftoverBytes: Int64 = 0
        /// Deleted in the Files app but kept by its Recently Deleted, which
        /// for On My iPhone lives inside the app (Documents/.Trash) for 30
        /// days and still counts in iPhone Storage (pass 22).
        var trashed: [URL] = []
        var trashedBytes: Int64 = 0
        /// Backup files anywhere else in the app's own space.
        var strays: [URL] = []
        var strayBytes: Int64 = 0

        var backupBytes: Int64 { backupSizes.values.reduce(0, +) }
        var total: Int64 { backupBytes + historyBytes + previousBytes + stagedBytes + leftoverBytes + trashedBytes + strayBytes }
        var isEmpty: Bool {
            total == 0 && backups.isEmpty && histories.isEmpty && leftovers.isEmpty && trashed.isEmpty && strays.isEmpty
        }
    }

    nonisolated static var previousRestore: URL { restoreRoot.appending(path: "previous", directoryHint: .isDirectory) }

    /// Space a file or folder takes on disk.
    nonisolated static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
        while let item = walker?.nextObject() as? URL {
            let v = try? item.resourceValues(forKeys: keys)
            if v?.isDirectory != true { total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0) }
        }
        return total
    }

    /// Everything above, measured.
    nonisolated static func stored(locations: Locations = .live, temporaryDirectory: URL? = nil) -> Stored {
        let fm = FileManager.default
        let documents = locations.documents, appSupport = locations.appSupport, restoreRoot = locations.restoreRoot
        let previousRestore = restoreRoot.appending(path: "previous"), staged = locations.staged
        let temporaryDirectory = temporaryDirectory ?? fm.temporaryDirectory
        var out = Stored()
        out.backups = existingBackups(locations: locations)
        for file in out.backups { out.backupSizes[file] = size(of: file) }
        let docs = (try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
        out.histories = docs.filter { isHistoryExport($0) && isRegularStoredFile($0) }
        out.historyBytes = out.histories.reduce(0) { $0 + size(of: $1) }
        out.previousBytes = size(of: previousRestore)
        out.stagedBytes = size(of: staged)
        out.restorePending = fm.fileExists(atPath: locations.ready.path)
        let inbox = documents.appending(path: "Inbox", directoryHint: .isDirectory)
        let handed = ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == fileExtension && isRegularStoredFile($0) }
        let work = ((try? fm.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Backup-") && UUID(uuidString: String($0.lastPathComponent.dropFirst(7))) != nil }
        out.leftovers = handed + work
        out.leftoverBytes = out.leftovers.reduce(0) { $0 + size(of: $1) }
        // Recently Deleted can contain any file the listener saved in
        // Documents. Only backup/history files belong to this cleanup;
        // unknown files and their enclosing trash folders stay untouched.
        for trash in [documents.appending(path: ".Trash", directoryHint: .isDirectory),
                      documents.appending(path: ".Trashes", directoryHint: .isDirectory)] {
            guard trash.resolvingSymlinksInPath().deletingLastPathComponent().path == documents.resolvingSymlinksInPath().path else { continue }
            if let walker = fm.enumerator(at: trash, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
                while let file = walker.nextObject() as? URL {
                    let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                          file.pathExtension == fileExtension || isHistoryExport(file) else { continue }
                    out.trashed.append(file)
                }
            }
        }
        out.trashedBytes = out.trashed.reduce(0) { $0 + size(of: $1) }
        // And a backup file anywhere else in the app's space (not the
        // library itself, which holds the downloads and is walked by
        // nothing here).
        let known = Set((out.backups + out.leftovers + out.trashed).map { $0.resolvingSymlinksInPath().path })
        let home = documents.deletingLastPathComponent()
        let homePath = home.resolvingSymlinksInPath().path
        // Compared with symlinks resolved: on a phone the container is
        // /var/mobile/… in one API and /private/var/mobile/… in another.
        let skip = Set([appSupport, restoreRoot, temporaryDirectory]
            .map { $0.resolvingSymlinksInPath().path })
        if let walker = fm.enumerator(at: home, includingPropertiesForKeys: [.isDirectoryKey]) {
            while let url = walker.nextObject() as? URL {
                let path = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(homePath + "/") else { walker.skipDescendants(); continue }
                if skip.contains(path) || path.hasSuffix("/.Trash") || path.hasSuffix("/.Trashes") {
                    walker.skipDescendants(); continue
                }
                guard url.pathExtension == fileExtension, isRegularStoredFile(url), !known.contains(path),
                      !known.contains(where: { path.hasPrefix($0 + "/") }) else { continue }
                out.strays.append(url)
            }
        }
        out.strayBytes = out.strays.reduce(0) { $0 + size(of: $1) }
        return out
    }

    /// One backup file in PodSkipper's own folder.
    nonisolated static func deleteBackup(_ file: URL, locations: Locations = .live) throws {
        guard file.pathExtension == fileExtension,
              file.deletingLastPathComponent().standardizedFileURL == locations.documents.standardizedFileURL,
              !inUse.contains(file) else {
            throw Failure.archive("that file isn't one of PodSkipper's saved backups")
        }
        try FileManager.default.removeItem(at: file)
    }

    /// Deletes everything `stored()` lists and nothing else. Returns the
    /// space freed. Must not run while a backup is being made or a restore
    /// unpacked (the screen disables it then).
    nonisolated static func deleteStoredBackupData(locations: Locations = .live, temporaryDirectory: URL? = nil,
                                                  log: (@Sendable (String) -> Void)? = nil) -> Int64 {
        guard !inUse.hasPaths else {
            let line = "Stored backup cleanup was skipped because a backup or restore is using its files. Try again when it finishes."
            if let log { log(line) } else { Task { @MainActor in BackgroundLog.shared.note(line) } }
            return 0
        }
        let fm = FileManager.default
        let before = stored(locations: locations, temporaryDirectory: temporaryDirectory)
        var failed: [String] = []
        func remove(_ url: URL) {
            guard !inUse.hasPaths else { failed.append(url.lastPathComponent); return }
            guard !inUse.contains(url) else { failed.append(url.lastPathComponent); return }
            guard fm.fileExists(atPath: url.path) else { return }
            do { try fm.removeItem(at: url) } catch { failed.append(url.lastPathComponent) }
        }
        before.backups.forEach(remove)
        before.histories.forEach(remove)
        before.leftovers.forEach(remove)
        before.trashed.forEach(remove)
        before.strays.forEach(remove)
        // Where the hidden ones were, so Diagnostics says (his 28 Sep
        // question: iPhone Storage counted backups the app didn't show).
        let home = locations.documents.deletingLastPathComponent().resolvingSymlinksInPath().path
        let hidden = (before.trashed + before.strays).map {
            $0.resolvingSymlinksInPath().path.replacingOccurrences(of: home, with: "")
        }
        if !hidden.isEmpty {
            let line = "Stored backup data outside On My iPhone → PodSkipper: \(hidden.prefix(6).joined(separator: ", "))"
            if let log { log(line) } else { Task { @MainActor in BackgroundLog.shared.note(line) } }
        }
        remove(locations.restoreRoot.appending(path: "previous"))
        remove(locations.staged)
        remove(locations.ready)
        let after = stored(locations: locations, temporaryDirectory: temporaryDirectory)
        let freed = max(0, before.total - after.total)
        let line = "Deleted stored backup data: \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) freed"
            + (before.restorePending ? " (a restore waiting for the next launch was cancelled)" : "")
            + (failed.isEmpty ? "" : " · couldn't delete: \(failed.prefix(3).joined(separator: ", "))")
        if let log { log(line) } else { Task { @MainActor in BackgroundLog.shared.note(line) } }
        return freed
    }

    private nonisolated static func isHistoryExport(_ file: URL) -> Bool {
        file.pathExtension == "csv" && file.lastPathComponent.hasPrefix("PodSkipper Listening History")
    }

    private nonisolated static func isRegularStoredFile(_ file: URL) -> Bool {
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }
}

// MARK: - Keeping only the newest backups (cloud task 03)
//
// Each "Back Up Everything" adds a file and nothing took them away, so they
// piled up. After each backup the app now removes its own older ones beyond
// the number chosen on the backup screen.
//
// "Its own" is strict: a file named the way the app names backups, sitting
// directly in the app's Documents folder, and recorded in a list the app
// keeps of the backups it made. Copies saved or shared anywhere else (Files,
// iCloud Drive, AirDrop, a backup handed over into Documents/Inbox) are never
// looked at. The backup just made, and any file a restore is reading, are
// never removed.

/// Paths a restore is reading right now.
private final class PathsInUse: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String: Int] = [:]
    var hasPaths: Bool { lock.withLock { !paths.isEmpty } }
    func insert(_ url: URL) { lock.withLock { paths[url.standardizedFileURL.path, default: 0] += 1 } }
    func remove(_ url: URL) {
        lock.withLock {
            let key = url.standardizedFileURL.path
            if let count = paths[key], count > 1 { paths[key] = count - 1 }
            else { paths[key] = nil }
        }
    }
    func contains(_ url: URL) -> Bool { lock.withLock { paths[url.standardizedFileURL.path] != nil } }
}

extension BackupService {
    /// The choices on the backup screen. 0 means keep them all.
    static let keepChoices = [1, 2, 3, 5, 10, 0]

    fileprivate static let inUse = PathsInUse()

    /// Marks a file as being read by a restore, so cleanup leaves it alone.
    nonisolated static func markInUse(_ file: URL) { inUse.insert(file) }
    nonisolated static func unmarkInUse(_ file: URL) { inUse.remove(file) }

    /// The list of backup files the app made, by name. In Library, outside
    /// both Documents and Application Support, so neither the Files app nor a
    /// restore changes it.
    nonisolated static var ledgerURL: URL { URL.libraryDirectory.appending(path: "PodSkipperBackups.json") }

    /// How the app names a backup: "PodSkipper Backup 2026-09-29 1430.podskipper".
    nonisolated static func hasBackupName(_ file: URL) -> Bool {
        file.lastPathComponent.range(of: #"^PodSkipper Backup \d{4}-\d{2}-\d{2} \d{4}(?:\d{2})?(?:-[A-Fa-f0-9]{8})?\.podskipper$"#,
                                     options: .regularExpression) != nil
    }

    /// Names in the ledger. The first time there is no ledger, the backups
    /// already in Documents with the app's naming are taken as the app's own:
    /// before this list existed, making a backup was the only way the app put
    /// files like that there.
    nonisolated static func madeBackups(locations: Locations = .live) -> Set<String> {
        let ledgerURL = locations.ledger
        if FileManager.default.fileExists(atPath: ledgerURL.path) {
            guard let data = try? Data(contentsOf: ledgerURL),
                  let names = try? JSONDecoder().decode([String].self, from: data) else {
                // An unreadable ownership record cannot authorize deletion.
                // Preserve it for diagnosis and leave every backup alone.
                return []
            }
            return Set(names.filter { hasBackupName(URL(fileURLWithPath: $0)) && !$0.contains("/") })
        }
        let adopted = Set(existingBackups(locations: locations).filter(hasBackupName).map(\.lastPathComponent))
        return writeLedger(adopted, locations: locations) ? adopted : []
    }

    @discardableResult
    nonisolated static func writeLedger(_ names: Set<String>, locations: Locations = .live) -> Bool {
        let ledgerURL = locations.ledger
        do {
            try FileManager.default.createDirectory(at: ledgerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(names.sorted()).write(to: ledgerURL, options: .atomic)
            return true
        } catch {
            let message = "Backup retention skipped: its ownership record could not be saved. " + error.localizedDescription
            Task { @MainActor in BackgroundLog.shared.note(message) }
            return false
        }
    }

    /// Adds a backup the app just made to the ledger.
    nonisolated static func recordMade(_ file: URL, locations: Locations = .live) {
        var names = madeBackups(locations: locations)
        // Do not replace a corrupt record with a partial new one.
        if FileManager.default.fileExists(atPath: locations.ledger.path),
           (try? JSONDecoder().decode([String].self, from: Data(contentsOf: locations.ledger))) == nil { return }
        names.insert(file.lastPathComponent)
        writeLedger(names, locations: locations)
    }

    struct Cleanup: Sendable {
        var removed = 0
        var freed: Int64 = 0

        /// "Removed 2 older backups, 1.4 GB freed", or nil when nothing went.
        var note: String? {
            guard removed > 0 else { return nil }
            let size = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
            return "Removed \(removed) older backup\(removed == 1 ? "" : "s"), \(size) freed"
        }
    }

    /// Deletes the app's own backups beyond the newest `keep` (0 keeps all).
    /// `justMade` always stays, whatever its date says.
    nonisolated static func removeOldBackups(keeping keep: Int, justMade: URL, locations: Locations = .live) -> Cleanup {
        let documents = locations.documents
        var result = Cleanup()
        guard keep > 0 else { return result }
        let fm = FileManager.default
        let docs = documents.standardizedFileURL
        var ledger = madeBackups(locations: locations)
        let ours = existingBackups(locations: locations).filter {
            $0.deletingLastPathComponent().standardizedFileURL == docs
                && hasBackupName($0)
                && ledger.contains($0.lastPathComponent)
        }
        // Newest first by when the file was made: the name's clock can be
        // 12-hour on some phones, so it doesn't sort reliably.
        let justMadePath = justMade.standardizedFileURL.path
        let others = ours.filter { $0.standardizedFileURL.path != justMadePath }
            .sorted { backupDate($0) > backupDate($1) }
        // The one just made counts as one of the kept.
        for file in others.dropFirst(max(0, keep - 1)) {
            if inUse.contains(file) { continue }
            let bytes = size(of: file)
            do {
                try fm.removeItem(at: file)
                ledger.remove(file.lastPathComponent)
                result.removed += 1
                result.freed += bytes
            } catch {
                let line = "Backup cleanup couldn't remove \(file.lastPathComponent): \(error.localizedDescription)"
                Task { @MainActor in BackgroundLog.shared.note(line) }
            }
        }
        // Forget names whose files are gone (deleted by hand, say).
        ledger = ledger.filter { fm.fileExists(atPath: documents.appending(path: $0).path) }
        if !ours.isEmpty { writeLedger(ledger, locations: locations) }
        return result
    }

    nonisolated static func backupDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
    }
}
