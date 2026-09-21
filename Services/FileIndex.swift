import Foundation
import Observation
import SwiftData

/// An in-memory index of which episode audio files exist on disk.
///
/// `Episode.isDownloaded` used to call `FileManager.fileExists` every time it
/// was read. That read happens inside list rows, inside filters, inside the
/// "Downloaded" count on the Library screen, and inside the queue picker — so
/// scrolling a library of a few hundred episodes issued a few hundred
/// synchronous filesystem stats per frame, on the main thread. That is a large
/// part of why navigation felt heavy.
///
/// One directory listing at launch replaces all of it. Anything that adds or
/// removes a file tells the index, so it never goes stale in normal use, and
/// `refresh()` re-reads the directory if something outside the app changes it.
enum FileIndex {

    nonisolated(unsafe) private static var names: Set<String> = []
    nonisolated(unsafe) private static var loaded = false
    private static let lock = NSLock()

    /// Read the episodes directory once. Safe to call repeatedly.
    static func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !loaded else { return }
        reload()
        loaded = true
    }

    /// Force a re-read. Used after a bulk delete or a tidy-up pass.
    static func refresh() {
        lock.lock()
        defer { lock.unlock() }
        reload()
        loaded = true
    }

    /// Must be called with the lock already held.
    private static func reload() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: FileStore.episodesDirectory.path)) ?? []
        names = Set(contents)
    }

    static func contains(_ filename: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            reload()
            loaded = true
        }
        return names.contains(filename)
    }

    /// A copy of the whole set, for a background pass that checks many names.
    static func snapshot() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            reload()
            loaded = true
        }
        return names
    }

    static func insert(_ filename: String) {
        lock.lock()
        defer { lock.unlock() }
        names.insert(filename)
    }

    static func remove(_ filename: String) {
        lock.lock()
        defer { lock.unlock() }
        names.remove(filename)
    }

    static func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        names.removeAll()
        loaded = true
    }
}

// MARK: - Derived counts

/// The per-show counts drawn on rows and badges.
///
/// These used to be worked out here, on the main thread, by walking a show's
/// every episode — and expired every 0.75 s, so a screen of show rows redid it
/// continuously. With whole catalogues in the store that walk became tens of
/// thousands of rows. Now `LibraryIndex` counts everything in one background
/// pass and this only reads the result; `invalidate()` asks for a new pass,
/// coalesced so a burst of changes costs one.
@MainActor
enum CountsCache {
    typealias Counts = LibraryIndex.Counts

    static func counts(for podcast: Podcast) -> Counts {
        LibraryIndexStatus.shared.counts(for: podcast.feedURL)
    }

    static func invalidate() { LibraryIndexStatus.shared.refreshCounts() }

    static func invalidate(_ podcast: Podcast?) { LibraryIndexStatus.shared.refreshCounts() }
}

// MARK: - Library-wide totals

/// Totals shown on the Library and Settings screens, read from the same
/// background pass as the show counts.
@MainActor
@Observable
final class LibraryTotals {

    static let shared = LibraryTotals()

    private var source: LibraryIndex.Totals { LibraryIndexStatus.shared.totals }

    var downloaded: Int { source.downloaded }
    var starred: Int { source.starred }
    var unplayed: Int { source.unplayed }
    var ready: Int { source.ready }
    var adsRemoved: Int { source.adsRemoved }
    var secondsSaved: Double { source.secondsSaved }
    var published: Int { source.published }
    var feeds: Int { source.feeds }

    private init() {}

    /// Ask for a fresh count. Returns at once; the numbers follow.
    func refresh(context: ModelContext, force: Bool = false) {
        LibraryIndexStatus.shared.refreshCounts(after: force ? .zero : .milliseconds(800))
    }

    func invalidate() { LibraryIndexStatus.shared.refreshCounts() }
}
