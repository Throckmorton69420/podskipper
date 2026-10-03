import Foundation

/// A restore swaps directories before SwiftData opens. Every rename is
/// journaled first, so either a thrown error or termination between renames
/// can put the original library, checkpoints and settings back exactly.
struct BackupRestoreTransaction {
    struct Locations {
        var root: URL
        var appSupport: URL
        var checkpoints: URL
        var defaults: UserDefaults
        var domain: String
        var preservedFolders: [String]
        var staged: URL { root.appending(path: "staged") }
        var previous: URL { root.appending(path: "previous") }
        var ready: URL { root.appending(path: "ready") }
        var transaction: URL { root.appending(path: "transaction") }
        var journal: URL { transaction.appending(path: "journal.json") }
    }
    private struct Move: Codable { var from: URL; var to: URL }
    private struct Journal: Codable {
        var version = 1
        var moves: [Move] = []
        var committed = false
        var oldDefaults: Data
    }
    enum Failure: LocalizedError {
        case invalid(String), recovery(String)
        var errorDescription: String? {
            switch self {
            case .invalid(let why): "The restore was not applied: " + why
            case .recovery(let why): "Restore recovery needs attention: " + why
            }
        }
    }

    /// `afterMove` is a fault-injection seam for disposable-data tests.
    static func apply(_ locations: Locations, afterMove: ((Int) throws -> Void)? = nil) throws {
        let fm = FileManager.default
        try recover(locations)
        guard fm.fileExists(atPath: locations.ready.path) else { return }
        let incoming = locations.staged.appending(path: "AppSupport")
        guard fm.fileExists(atPath: incoming.path),
              let settingsData = try? Data(contentsOf: locations.staged.appending(path: "defaults.plist")),
              let savedSettings = try PropertyListSerialization.propertyList(from: settingsData, format: nil) as? [String: Any] else {
            throw Failure.invalid("the staged library or settings are missing")
        }
        let old = locations.transaction.appending(path: "previous")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        let oldSettings = locations.defaults.persistentDomain(forName: locations.domain) ?? [:]
        var journal = Journal(oldDefaults: try PropertyListSerialization.data(fromPropertyList: oldSettings, format: .binary, options: 0))
        func save() throws {
            try JSONEncoder().encode(journal).write(to: locations.journal, options: .atomic)
        }
        func move(_ from: URL, _ to: URL) throws {
            guard fm.fileExists(atPath: from.path) else { return }
            guard !fm.fileExists(atPath: to.path) else { throw Failure.invalid("a restore destination already exists") }
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            journal.moves.append(Move(from: from, to: to))
            try save() // intent is durable before the rename
            try fm.moveItem(at: from, to: to)
            try afterMove?(journal.moves.count)
        }
        try save()
        try journal.oldDefaults.write(to: old.appending(path: "defaults.plist"), options: .atomic)
        do {
            try move(locations.appSupport, old.appending(path: "AppSupport"))
            try move(incoming, locations.appSupport)
            for folder in locations.preservedFolders {
                let kept = old.appending(path: "AppSupport").appending(path: folder)
                // A current model cache stays. A legacy backup containing the
                // same cache is moved aside rather than mixed with it.
                if fm.fileExists(atPath: kept.path) {
                    try move(locations.appSupport.appending(path: folder), locations.transaction.appending(path: "backup-cache-" + folder))
                    try move(kept, locations.appSupport.appending(path: folder))
                }
            }
            try move(locations.checkpoints, old.appending(path: "Checkpoints"))
            try move(locations.staged.appending(path: "Checkpoints"), locations.checkpoints)
            locations.defaults.setPersistentDomain(savedSettings, forName: locations.domain)
            journal.committed = true
            try save() // next launch finalizes, never rolls back committed data
        } catch {
            do { try recover(locations) }
            catch { throw Failure.recovery(error.localizedDescription) }
            throw error
        }
        try finalize(locations)
    }

    /// Call before opening the database, even when no ready marker remains.
    static func recover(_ locations: Locations) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: locations.journal.path) else { return }
        var journal: Journal
        do { journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: locations.journal)) }
        catch { throw Failure.recovery("the journal cannot be read; all copies were preserved") }
        guard journal.version == 1 else { throw Failure.recovery("this journal requires a newer app") }
        // A journal is local bookkeeping, never a path supplied by an archive.
        let allowed = [locations.root, locations.appSupport, locations.checkpoints]
        func allowedPath(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            return allowed.contains { root in
                let base = root.standardizedFileURL.path
                return path == base || path.hasPrefix(base + "/")
            }
        }
        guard journal.moves.allSatisfy({ allowedPath($0.from) && allowedPath($0.to) }) else {
            throw Failure.recovery("the journal contains an unexpected path; all copies were preserved")
        }
        if journal.committed { try finalize(locations); return }
        while let move = journal.moves.last {
            let sourceExists = fm.fileExists(atPath: move.from.path)
            let destinationExists = fm.fileExists(atPath: move.to.path)
            // Both exist when an intended move failed before it happened.
            // Never delete either copy to guess what should be restored.
            if sourceExists && destinationExists { throw Failure.recovery("both copies exist at " + move.from.lastPathComponent) }
            if !sourceExists && destinationExists {
                try fm.createDirectory(at: move.from.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: move.to, to: move.from)
            }
            // Persist each reversal before reversing a parent directory.
            // Recovery is idempotent even if it too is interrupted.
            journal.moves.removeLast()
            try JSONEncoder().encode(journal).write(to: locations.journal, options: .atomic)
        }
        guard let settings = try PropertyListSerialization.propertyList(from: journal.oldDefaults, format: nil) as? [String: Any] else {
            throw Failure.recovery("the saved original settings could not be read")
        }
        locations.defaults.setPersistentDomain(settings, forName: locations.domain)
        try fm.removeItem(at: locations.transaction)
        // The ready marker and complete staged backup remain for an explicit retry.
    }

    private static func finalize(_ locations: Locations) throws {
        let fm = FileManager.default
        let old = locations.transaction.appending(path: "previous")
        let former = locations.transaction.appending(path: "former-previous")
        if fm.fileExists(atPath: old.path) {
            if fm.fileExists(atPath: locations.previous.path) {
                try fm.moveItem(at: locations.previous, to: former)
            }
            try fm.moveItem(at: old, to: locations.previous)
        }
        try Data().write(to: locations.previous.appending(path: "restored-transaction"), options: .atomic)
        if fm.fileExists(atPath: locations.ready.path) { try fm.removeItem(at: locations.ready) }
        if fm.fileExists(atPath: locations.staged.path) { try fm.removeItem(at: locations.staged) }
        try fm.removeItem(at: locations.transaction)
    }
}
