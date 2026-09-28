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
        guard let keys = ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DEV,DAT,MOD,FLG,MTM,BTM,CTM") else {
            throw Failure.archive("bad field list")
        }
        let counter = EntryCounter()
        try encoder.writeDirectoryContents(archiveFrom: FilePath(folder.path), keySet: keys) { message, _, _ in
            if message == .encodeWriting { progress(counter.bump()) }
            return .ok
        }
    }

    nonisolated static func extract(_ file: URL, into folder: URL,
                                    progress: @escaping @Sendable (Int) -> Void) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let input = ArchiveByteStream.fileStream(path: FilePath(file.path), mode: .readOnly, options: [],
                                                       permissions: FilePermissions(rawValue: 0o644)) else {
            throw Failure.archive("can't open \(file.lastPathComponent)")
        }
        defer { try? input.close() }
        guard let unpacked = ArchiveByteStream.decompressionStream(readingFrom: input),
              let decoder = ArchiveStream.decodeStream(readingFrom: unpacked) else { throw Failure.notABackup }
        defer { try? unpacked.close(); try? decoder.close() }
        let counter = EntryCounter()
        guard let writer = ArchiveStream.extractStream(extractingTo: FilePath(folder.path), selectUsing: { message, _, _ in
            if message == .extractBegin { progress(counter.bump()) }
            return .ok
        }, flags: [.ignoreOperationNotPermitted]) else { throw Failure.archive("can't unpack") }
        defer { try? writer.close() }
        do { _ = try ArchiveStream.process(readingFrom: decoder, writingTo: writer) }
        catch { throw Failure.notABackup }
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
            let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            progress(0.02, "Unpacking \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
            // Entries aren't known up front; a rough count from the size.
            let guess = max(200, bytes / 400_000)
            try extract(file, into: staged) { done in
                progress(min(0.95, 0.02 + 0.93 * Double(done) / Double(guess)), "Unpacking")
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: staged.appending(path: "manifest.json")),
                  let manifest = try? decoder.decode(Manifest.self, from: data),
                  fm.fileExists(atPath: staged.appending(path: "AppSupport").path) else {
                try? fm.removeItem(at: staged)
                throw Failure.notABackup
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
    static func existingBackups() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == fileExtension }
            .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
    }
}
