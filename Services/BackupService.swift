import AppleArchive
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

    struct Manifest: Codable, Sendable {
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
    nonisolated static func make(manifest: Manifest,
                                 progress: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appending(path: "Backup-\(UUID().uuidString)", directoryHint: .isDirectory)
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
                if name.hasSuffix(".store") || name.hasSuffix(".sqlite") {
                    try copyDatabase(item, to: support.appending(path: name))
                } else {
                    try fm.copyItem(at: item, to: support.appending(path: name))
                }
            }
            if fm.fileExists(atPath: checkpoints.path) {
                try? fm.copyItem(at: checkpoints, to: work.appending(path: "Checkpoints"))
            }
            let defaults = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
            let plist = try PropertyListSerialization.data(fromPropertyList: defaults, format: .binary, options: 0)
            try plist.write(to: work.appending(path: "defaults.plist"))
            try JSONEncoder.iso.encode(manifest).write(to: work.appending(path: "manifest.json"))

            let stamp = manifest.createdAt.formatted(.iso8601.year().month().day().dateSeparator(.dash))
            let clock = manifest.createdAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .replacingOccurrences(of: ":", with: "")
            let file = documents.appending(path: "PodSkipper Backup \(stamp) \(clock).\(fileExtension)")
            try? fm.removeItem(at: file)
            let total = max(1, countFiles(in: work))
            try archive(work, to: file, compress: !manifest.includesAudio) { done in
                progress(0.05 + 0.95 * min(1, Double(done) / Double(total)), "Writing the backup file")
            }
            progress(1, "Done")
            return file
        }.value
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
    nonisolated static func stage(_ file: URL,
                                  progress: @escaping @Sendable (Double, String) -> Void) async throws -> Manifest {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try? fm.removeItem(at: staged)
            try? fm.removeItem(at: readyMarker)
            try fm.createDirectory(at: restoreRoot, withIntermediateDirectories: true)
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            // A file in iCloud Drive may be only a placeholder until read
            // through a coordinator, which downloads it.
            var coordinated = file
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: file, options: [.withoutChanges],
                                           error: &coordinationError) { coordinated = $0 }
            let bytes = Int64((try? coordinated.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            // Unpacking needs about the file's size again (audio doesn't
            // shrink), and a little over.
            let free = (try? URL.libraryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage) ?? Int64.max
            if free < bytes + bytes / 10 {
                throw Failure.archive("not enough free space: the backup is \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) and unpacking it needs about that much again (\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free). Free some space, or make a backup without downloads")
            }
            progress(0.02, "Unpacking \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
            let report = ExtractReport()
            // Entries aren't known up front; a rough count from the size.
            let guess = max(200, Int(bytes / 400_000))
            do {
                try extract(coordinated, into: staged, report: report) { done in
                    progress(min(0.95, 0.02 + 0.93 * Double(done) / Double(guess)), "Unpacking")
                }
            } catch {
                try? fm.removeItem(at: staged)
                throw error
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let support = staged.appending(path: "AppSupport")
            guard let data = try? Data(contentsOf: staged.appending(path: "manifest.json")),
                  let manifest = try? decoder.decode(Manifest.self, from: data),
                  fm.fileExists(atPath: support.path) else {
                let found = (try? fm.contentsOfDirectory(atPath: staged.path)) ?? []
                try? fm.removeItem(at: staged)
                throw Failure.archive("the file unpacked but has no PodSkipper manifest (found: \(found.prefix(6).joined(separator: ", ")); \(sniff(coordinated)))")
            }
            let stores = ((try? fm.contentsOfDirectory(atPath: support.path)) ?? []).filter { $0.hasSuffix(".store") }
            // (A screenshot run's library lives in memory: no database file.)
            guard !stores.isEmpty || DemoData.isEnabled else {
                try? fm.removeItem(at: staged)
                throw Failure.archive("the backup has no library database in it")
            }
            if !report.failures.isEmpty {
                let line = "Restore: \(report.failures.count) item(s) couldn't be written exactly: \(report.failures.prefix(3).joined(separator: "; "))"
                Task { @MainActor in BackgroundLog.shared.note(line) }
            }
            try Data().write(to: readyMarker)
            progress(1, "Ready")
            return manifest
        }.value
    }

    static var hasPendingRestore: Bool { FileManager.default.fileExists(atPath: readyMarker.path) }

    /// At launch, before the library opens: puts a staged backup in place.
    /// Anything that goes wrong leaves the current data where it was.
    static func applyPendingRestore() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: readyMarker.path) else { return }
        try? fm.removeItem(at: readyMarker)
        let incoming = staged.appending(path: "AppSupport")
        guard fm.fileExists(atPath: incoming.path) else { return }
        let previous = restoreRoot.appending(path: "previous", directoryHint: .isDirectory)
        try? fm.removeItem(at: previous)
        do {
            try fm.createDirectory(at: previous, withIntermediateDirectories: true)
            // The current data out of the way (kept once, in case)…
            for item in (try? fm.contentsOfDirectory(at: appSupport, includingPropertiesForKeys: nil)) ?? [] {
                try fm.moveItem(at: item, to: previous.appending(path: item.lastPathComponent))
            }
            // …and the backup's in.
            try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
            for item in try fm.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil) {
                try fm.moveItem(at: item, to: appSupport.appending(path: item.lastPathComponent))
            }
        } catch {
            // Put back what was moved; the backup stays staged for a retry.
            for item in (try? fm.contentsOfDirectory(at: previous, includingPropertiesForKeys: nil)) ?? [] {
                let home = appSupport.appending(path: item.lastPathComponent)
                try? fm.removeItem(at: home)
                try? fm.moveItem(at: item, to: home)
            }
            UserDefaults.standard.set("Restore failed: \(error.localizedDescription)", forKey: "lastRestoreResult")
            return
        }
        let savedCheckpoints = staged.appending(path: "Checkpoints")
        if fm.fileExists(atPath: savedCheckpoints.path) {
            try? fm.removeItem(at: checkpoints)
            try? fm.createDirectory(at: checkpoints.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: savedCheckpoints, to: checkpoints)
        }
        if let data = try? Data(contentsOf: staged.appending(path: "defaults.plist")),
           let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (key, value) in values { UserDefaults.standard.set(value, forKey: key) }
        }
        UserDefaults.standard.set(true, forKey: "seenOnboarding")
        UserDefaults.standard.set("Restored from backup on \(Date.now.formatted(date: .abbreviated, time: .shortened))",
                                  forKey: "lastRestoreResult")
        try? fm.removeItem(at: staged)
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
    nonisolated static func existingBackups() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == fileExtension }
            .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
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
    nonisolated static func stored() -> Stored {
        let fm = FileManager.default
        var out = Stored()
        out.backups = existingBackups()
        for file in out.backups { out.backupSizes[file] = size(of: file) }
        let docs = (try? fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []
        out.histories = docs.filter { $0.pathExtension == "csv" && $0.lastPathComponent.hasPrefix("PodSkipper Listening History") }
        out.historyBytes = out.histories.reduce(0) { $0 + size(of: $1) }
        out.previousBytes = size(of: previousRestore)
        out.stagedBytes = size(of: staged)
        out.restorePending = hasPendingRestore
        let inbox = documents.appending(path: "Inbox", directoryHint: .isDirectory)
        let handed = ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == fileExtension }
        let work = ((try? fm.contentsOfDirectory(at: fm.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Backup-") }
        out.leftovers = handed + work
        out.leftoverBytes = out.leftovers.reduce(0) { $0 + size(of: $1) }
        // His 28 Sep report: backups deleted in the Files app still showed
        // in iPhone Storage and weren't on this screen. Files' Recently
        // Deleted keeps them, for On My iPhone, in a hidden folder inside
        // the app. Everything in it came from PodSkipper's own folder.
        for trash in [documents.appending(path: ".Trash", directoryHint: .isDirectory),
                      documents.appending(path: ".Trashes", directoryHint: .isDirectory)] {
            let items = (try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? []
            out.trashed += items
        }
        out.trashedBytes = out.trashed.reduce(0) { $0 + size(of: $1) }
        // And a backup file anywhere else in the app's space (not the
        // library itself, which holds the downloads and is walked by
        // nothing here).
        let known = Set((out.backups + out.leftovers + out.trashed).map { $0.resolvingSymlinksInPath().path })
        let home = documents.deletingLastPathComponent()
        // Compared with symlinks resolved: on a phone the container is
        // /var/mobile/… in one API and /private/var/mobile/… in another.
        let skip = Set([appSupport, restoreRoot, fm.temporaryDirectory]
            .map { $0.resolvingSymlinksInPath().path })
        if let walker = fm.enumerator(at: home, includingPropertiesForKeys: [.isDirectoryKey]) {
            while let url = walker.nextObject() as? URL {
                let path = url.resolvingSymlinksInPath().path
                if skip.contains(path) || path.hasSuffix("/.Trash") || path.hasSuffix("/.Trashes") {
                    walker.skipDescendants(); continue
                }
                guard url.pathExtension == fileExtension, !known.contains(path),
                      !known.contains(where: { path.hasPrefix($0 + "/") }) else { continue }
                out.strays.append(url)
            }
        }
        out.strayBytes = out.strays.reduce(0) { $0 + size(of: $1) }
        return out
    }

    /// One backup file in PodSkipper's own folder.
    nonisolated static func deleteBackup(_ file: URL) throws {
        guard file.pathExtension == fileExtension,
              file.deletingLastPathComponent().standardizedFileURL == documents.standardizedFileURL else {
            throw Failure.archive("that file isn't one of PodSkipper's saved backups")
        }
        try FileManager.default.removeItem(at: file)
    }

    /// Deletes everything `stored()` lists and nothing else. Returns the
    /// space freed. Must not run while a backup is being made or a restore
    /// unpacked (the screen disables it then).
    nonisolated static func deleteStoredBackupData() -> Int64 {
        let fm = FileManager.default
        let before = stored()
        var failed: [String] = []
        func remove(_ url: URL) {
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
        let home = documents.deletingLastPathComponent().resolvingSymlinksInPath().path
        let hidden = (before.trashed + before.strays).map {
            $0.resolvingSymlinksInPath().path.replacingOccurrences(of: home, with: "")
        }
        if !hidden.isEmpty {
            let line = "Stored backup data outside On My iPhone → PodSkipper: \(hidden.prefix(6).joined(separator: ", "))"
            Task { @MainActor in BackgroundLog.shared.note(line) }
        }
        remove(previousRestore)
        remove(staged)
        remove(readyMarker)
        let after = stored()
        let freed = max(0, before.total - after.total)
        let line = "Deleted stored backup data: \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) freed"
            + (before.restorePending ? " (a restore waiting for the next launch was cancelled)" : "")
            + (failed.isEmpty ? "" : " · couldn't delete: \(failed.prefix(3).joined(separator: ", "))")
        Task { @MainActor in BackgroundLog.shared.note(line) }
        return freed
    }
}
