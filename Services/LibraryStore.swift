import Foundation
import SwiftData
import UIKit

/// The one way the app opens its library (Pass 33).
///
/// Before Pass 33 the library could be opened twice in one process: by the
/// app at launch, and by an App Intent or Spotlight/Shortcuts entity query
/// that arrived before the app had published its context — and that second
/// open used only Podcast, Episode and AdSegment. SwiftData migrates a store
/// to the model it is opened with, so a smaller model is not a harmless
/// read: see `Pass33StoreTests`. Everything now asks this one owner, which
/// opens the store once with the full schema and hands every caller the same
/// container.
///
/// A failed open never deletes, resets or replaces the store. It reports what
/// actually failed — the stage, the store file and the full error chain, not
/// SwiftData's bridged "error 1" — and the next request tries again.
@MainActor
final class LibraryStore {
    nonisolated static let schema = Schema([Podcast.self, Episode.self, AdSegment.self,
                                Bookmark.self, Chapter.self, ListeningSession.self, SmartFilter.self])

    /// The app's library, at SwiftData's default location (unchanged since
    /// the first release: Application Support/default.store).
    static let shared = LibraryStore(url: nil)

    private let url: URL?
    private var opening: Task<ModelContainer, Error>?
    private(set) var current: ModelContainer?
    /// How many real opens were started (tests: never two at once).
    private(set) var openCount = 0
    private(set) var lastFailure: OpenFailure?

    init(url: URL?) { self.url = url }

    /// The library, opening it if nobody has yet. Concurrent callers share
    /// one open; a failure is not remembered, so asking again retries.
    func container() async throws -> ModelContainer {
        if let current { return current }
        if let opening { return try await opening.value }
        openCount += 1
        let url = self.url
        let delays = retryDelays
        let task = Task.detached(priority: .userInitiated) { () throws -> Opened in
            if url == nil { try LibraryStore.applyPendingRestore() }
            var passing: [OpenFailure] = []
            while true {
                switch LibraryStore.openContainer(at: url) {
                case .success(let container): return Opened(container: container, passing: passing)
                case .failure(let failure):
                    guard passing.count < delays.count, LibraryStore.isPassing(failure.detail) else { throw failure }
                    try await Task.sleep(for: .seconds(delays[passing.count]))
                    passing.append(failure)
                }
            }
        }
        opening = Task { try await task.value.container }
        do {
            let opened = try await task.value
            current = opened.container
            opening = nil
            lastFailure = nil
            if let first = opened.passing.first {
                // Said once, with what the first failure saw (free space, the
                // store's files): the recovery log isn't written for an open
                // that got through.
                BackgroundLog.shared.note("Library opened after \(opened.passing.count) quick retr\(opened.passing.count == 1 ? "y" : "ies") "
                    + "(SQLite couldn't open it at first): "
                    + first.report.split(separator: "\n").filter { !$0.hasPrefix("Error:") && !$0.hasPrefix("Stage:") }.joined(separator: " · "))
            }
            return opened.container
        } catch {
            opening = nil
            let failure = (error as? OpenFailure)
                ?? OpenFailure(stage: .restore, storePath: Self.defaultStoreURL.path,
                               detail: Self.describe(error), report: Self.describe(error))
            lastFailure = failure
            LibraryRecoveryLog.record(failure)
            throw failure
        }
    }

    // MARK: Opening

    private struct Opened: Sendable {
        var container: ModelContainer
        var passing: [OpenFailure]
    }

    /// Pass 55 (his 30 Oct phone, build 1c40b4f): three times, after Apple's
    /// Core AI compiler aborted the app, the relaunch couldn't open the
    /// library — SQLite 4618 (SHMOPEN) on `default.store-shm` with the app
    /// active and protected data available — five to seven times in a few
    /// seconds, then opened untouched each time (one launch waited 58 s on
    /// Library Recovery). So an open that fails with a SQLite I/O, busy or
    /// lock error is tried again, about 10 s in all, on the plain opening
    /// screen and off the main thread, before Library Recovery shows.
    var retryDelays: [Double] = [0.5, 1, 2, 3, 4]

    /// A failure that has cleared by itself: SQLite busy (5), locked (6) or
    /// an I/O error (10 and its extended codes, 4618 among them). Damage
    /// (11), a full disk (13), a store that can't be opened at all (14 — a
    /// folder in its place, say) and every non-SQLite failure are not
    /// retried.
    nonisolated static func isPassing(_ detail: String) -> Bool {
        guard let range = detail.range(of: #"NSSQLiteErrorDomain[ =]+(\d+)"#, options: .regularExpression),
              let code = Int(detail[range].filter(\.isNumber)) else { return false }
        return [5, 6, 10].contains(code & 0xFF)
    }

    enum Stage: String, Sendable {
        /// Swapping in a backup the person chose to restore.
        case restore = "Restoring a backup"
        /// Opening the SwiftData store itself.
        case container = "Opening the library"
    }

    /// What a failed open knew. `detail` is the error itself; `report` adds
    /// the store's files, free space and data-protection state.
    struct OpenFailure: Error, LocalizedError, Sendable {
        var stage: Stage
        var storePath: String
        var detail: String
        var report: String
        var errorDescription: String? { "\(stage.rawValue) failed. \(detail)" }
    }

    nonisolated static var defaultStoreURL: URL {
        ModelConfiguration(schema: schema).url
    }

    nonisolated static func applyPendingRestore() throws {
        do { try BackupService.applyPendingRestore() } catch {
            throw OpenFailure(stage: .restore, storePath: defaultStoreURL.path,
                              detail: describe(error), report: describe(error))
        }
    }

    /// Opens the store at `url` (nil: the app's default store; in-memory for
    /// screenshot runs, exactly as before). Never creates a replacement.
    nonisolated static func openContainer(at url: URL?) -> Result<ModelContainer, OpenFailure> {
        let config: ModelConfiguration
        if let url {
            config = ModelConfiguration(schema: schema, url: url)
        } else {
            config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: DemoData.isEnabled)
        }
        do {
            return .success(try ModelContainer(for: schema, configurations: [config]))
        } catch {
            let detail = describe(error)
            let report = ["Stage: \(Stage.container.rawValue)",
                          "Store: \(config.url.path)",
                          storeFiles(at: config.url),
                          freeSpace(near: config.url),
                          sqliteMeaning(in: detail),
                          "Error: \(detail)"].compactMap { $0 }.joined(separator: "\n")
            return .failure(OpenFailure(stage: .container, storePath: config.url.path,
                                        detail: detail, report: report))
        }
    }

    /// The whole error, not its bridged code: SwiftData's error is a struct,
    /// and every Swift struct error becomes NSError code 1, so
    /// `localizedDescription` alone says "SwiftDataError error 1" whatever
    /// went wrong. Walks Cocoa underlying and detailed errors.
    nonisolated static func describe(_ error: Error) -> String {
        // Core Data's NSDetailedErrorsKey, without importing Core Data.
        let detailedErrorsKey = "NSDetailedErrors"
        var lines: [String] = [String(reflecting: error)]
        var seen = 0
        func walk(_ ns: NSError, depth: Int) {
            guard seen < 12 else { return }
            seen += 1
            let pad = String(repeating: "  ", count: depth)
            lines.append("\(pad)\(ns.domain) \(ns.code): \(ns.localizedDescription)")
            for (key, value) in ns.userInfo.sorted(by: { $0.key < $1.key })
            where key != NSUnderlyingErrorKey && key != detailedErrorsKey && key != NSLocalizedDescriptionKey {
                lines.append("\(pad)  \(key) = \(String(describing: value).prefix(300))")
            }
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                walk(underlying, depth: depth + 1)
            }
            for detailed in (ns.userInfo[detailedErrorsKey] as? [NSError]) ?? [] {
                walk(detailed, depth: depth + 1)
            }
            for underlying in ns.underlyingErrors.map({ $0 as NSError })
            where underlying !== (ns.userInfo[NSUnderlyingErrorKey] as? NSError) {
                walk(underlying, depth: depth + 1)
            }
        }
        walk(error as NSError, depth: 0)
        return lines.joined(separator: "\n")
    }

    /// Pass 35 (his 9 Oct phone: NSSQLiteErrorDomain 4618 at 22:12, with
    /// 339 MB free, a minute before 9 GB of model files were removed): what
    /// SQLite's extended result code means, in words. 4618 is
    /// SQLITE_IOERR_SHMOPEN — SQLite couldn't open or create the
    /// shared-memory file (`default.store-shm`) it needs beside the library
    /// in WAL mode; causes include no free space, file protection while the
    /// phone is locked, or another process holding the file. It names the
    /// failure, not which of those happened.
    nonisolated static func sqliteMeaning(in detail: String) -> String? {
        guard let range = detail.range(of: #"NSSQLiteErrorDomain[ =]+(\d+)"#, options: .regularExpression),
              let code = Int(detail[range].filter(\.isNumber)) else { return nil }
        let meanings: [Int: String] = [
            5: "SQLITE_BUSY: another connection held the library",
            10: "SQLITE_IOERR: a disk read or write failed",
            11: "SQLITE_CORRUPT: the library file is damaged",
            13: "SQLITE_FULL: the disk is full",
            14: "SQLITE_CANTOPEN: the library file couldn't be opened",
            23: "SQLITE_AUTH: access was refused",
            266: "SQLITE_IOERR_READ: reading the library failed",
            778: "SQLITE_IOERR_WRITE: writing the library failed",
            3850: "SQLITE_IOERR_LOCK: the library's lock couldn't be taken",
            4106: "SQLITE_IOERR_SHMSIZE: the shared-memory file couldn't be resized (often no free space)",
            4618: "SQLITE_IOERR_SHMOPEN: the shared-memory file (default.store-shm) couldn't be opened or created (often no free space, or file protection while locked)",
            4874: "SQLITE_IOERR_SHMMAP: the shared-memory file couldn't be mapped",
            6410: "SQLITE_IOERR_GETTEMPPATH: no temporary folder was available",
        ]
        return "SQLite \(code): " + (meanings[code] ?? meanings[code & 0xFF].map { $0 + " (extended code \(code))" } ?? "see sqlite.org/rescode.html")
    }

    /// Sizes and protection of the store and its SQLite companions.
    nonisolated static func storeFiles(at url: URL) -> String {
        let fm = FileManager.default
        return ["", "-wal", "-shm"].map { suffix -> String in
            let path = url.path + suffix
            guard let attributes = try? fm.attributesOfItem(atPath: path) else {
                return "\(url.lastPathComponent + suffix): missing"
            }
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            let protection = (attributes[.protectionKey] as? FileProtectionType)?.rawValue ?? "unknown"
            let type = (attributes[.type] as? FileAttributeType)?.rawValue ?? "?"
            return "\(url.lastPathComponent + suffix): \(size) bytes, \(type), protection \(protection)"
        }.joined(separator: "\n")
    }

    /// Pass 56: storage actually free when under `lowSpaceBytes`, else nil.
    /// SQLite can't make or resize the library's shared-memory file without
    /// it (his 31 Oct phone failed at 105 MB with 4.6 GB "important").
    nonisolated static let lowSpaceBytes: Int64 = 500_000_000
    nonisolated static func shortOfSpace(free: Int64? = ModelStorage.plainFreeBytes(near: defaultStoreURL)) -> Int64? {
        guard let free, free < lowSpaceBytes else { return nil }
        return free
    }

    nonisolated static func freeSpace(near url: URL) -> String {
        let folder = url.deletingLastPathComponent()
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                          .volumeAvailableCapacityKey])
        let important = values?.volumeAvailableCapacityForImportantUsage.map { "\($0 / 1_000_000) MB" } ?? "unknown"
        let plain = values?.volumeAvailableCapacity.map { "\($0 / 1_000_000) MB" } ?? "unknown"
        return "Free space: \(important) for important use, \(plain) plain"
    }
}

/// Every failed library open, kept beside (never inside) the library, so the
/// next Diagnostics export can say what happened. Last 20.
enum LibraryRecoveryLog {
    struct Entry: Codable, Sendable {
        var date: Date
        var stage: String
        var appState: String
        var protectedDataAvailable: Bool
        var report: String
    }

    static var url: URL { Diagnostics.folder.appending(path: "library-recovery.json") }

    @MainActor
    static func record(_ failure: LibraryStore.OpenFailure) {
        let app = UIApplication.shared
        let state: String = switch app.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        let entry = Entry(date: .now, stage: failure.stage.rawValue, appState: state,
                          protectedDataAvailable: app.isProtectedDataAvailable, report: failure.report)
        var entries = load()
        entries.insert(entry, at: 0)
        if entries.count > 20 { entries.removeLast(entries.count - 20) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try data.write(to: url, options: .atomic)
                UserDefaults.standard.removeObject(forKey: fallbackKey)
            } catch {
                // Pass 56: his 30–31 Oct exports had no recovery entries
                // although the background log recorded the failures — with
                // storage full, the file can't be written either. The newest
                // entries are kept in the app's settings instead.
                UserDefaults.standard.set(try? encoder.encode(Array(entries.prefix(5))), forKey: fallbackKey)
            }
        }
        BackgroundLog.shared.note("Library could not be opened (\(failure.stage.rawValue); app \(state), "
            + "protected data \(app.isProtectedDataAvailable ? "available" : "locked")): "
            + failure.detail.split(separator: "\n").prefix(3).joined(separator: " · "))
    }

    private static let fallbackKey = "libraryRecovery.unwritten"

    static func load() -> [Entry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([Entry].self, from: $0) } ?? []
        let unwritten = UserDefaults.standard.data(forKey: fallbackKey).flatMap { try? decoder.decode([Entry].self, from: $0) } ?? []
        return (unwritten + file.filter { entry in !unwritten.contains { $0.date == entry.date } })
            .sorted { $0.date > $1.date }
    }
}
