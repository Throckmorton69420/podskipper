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
        let task = Task.detached(priority: .userInitiated) { () throws -> ModelContainer in
            if url == nil { try LibraryStore.applyPendingRestore() }
            switch LibraryStore.openContainer(at: url) {
            case .success(let container): return container
            case .failure(let failure): throw failure
            }
        }
        opening = task
        do {
            let container = try await task.value
            current = container
            opening = nil
            lastFailure = nil
            return container
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
                          "Error: \(detail)"].joined(separator: "\n")
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
            try? data.write(to: url, options: .atomic)
        }
        BackgroundLog.shared.note("Library could not be opened (\(failure.stage.rawValue); app \(state), "
            + "protected data \(app.isProtectedDataAvailable ? "available" : "locked")): "
            + failure.detail.split(separator: "\n").prefix(3).joined(separator: " · "))
    }

    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }
}
