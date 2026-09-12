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

/// Short-lived memo for the per-show counts drawn in list rows.
///
/// `unplayedCount` and `readyCount` walk a show's whole episode relationship.
/// Drawing thirty show rows meant thirty walks, and SwiftUI re-evaluates a row
/// body far more often than once. The values are badges on a row, so a cache
/// that can lag by a fraction of a second is invisible — but a stale badge
/// after you mark something played is not, so every mutation site calls
/// `invalidate()`.
@MainActor
enum CountsCache {

    struct Counts {
        var unplayed = 0
        var ready = 0
        var published = 0
        var total = 0
    }

    private static var storage: [String: (counts: Counts, at: Date)] = [:]
    private static let maxAge: TimeInterval = 0.75

    static func counts(for podcast: Podcast) -> Counts {
        let key = podcast.feedURL
        if let entry = storage[key], Date().timeIntervalSince(entry.at) < maxAge {
            return entry.counts
        }
        var result = Counts()
        for episode in podcast.episodes {
            result.total += 1
            if !episode.isPlayed && !episode.isArchived { result.unplayed += 1 }
            if episode.processingState == .ready { result.ready += 1 }
            if episode.publishedURL != nil { result.published += 1 }
        }
        storage[key] = (result, Date())
        return result
    }

    /// Call after anything that changes played state, processing state or
    /// publication state.
    static func invalidate() {
        storage.removeAll()
    }

    static func invalidate(_ podcast: Podcast?) {
        guard let podcast else { return }
        storage[podcast.feedURL] = nil
    }
}

// MARK: - Library-wide totals

/// Totals shown on the Library and Settings screens.
///
/// These used to come from `@Query private var allEpisodes: [Episode]`, which
/// loads every episode in the store into memory and re-runs the reduce on
/// every render. Now they are computed on demand, cached, and refreshed when a
/// screen appears or after the data changes.
@MainActor
@Observable
final class LibraryTotals {

    static let shared = LibraryTotals()

    private(set) var downloaded = 0
    private(set) var starred = 0
    private(set) var unplayed = 0
    private(set) var ready = 0
    private(set) var adsRemoved = 0
    private(set) var secondsSaved: Double = 0

    @ObservationIgnored private var lastComputed: Date?

    private init() {}

    /// Recompute, but at most once a second unless forced.
    func refresh(context: ModelContext, force: Bool = false) {
        if !force, let last = lastComputed, Date().timeIntervalSince(last) < 1.0 { return }
        lastComputed = Date()

        guard let episodes = try? context.fetch(FetchDescriptor<Episode>()) else { return }

        var countDownloaded = 0
        var countStarred = 0
        var countUnplayed = 0
        var countReady = 0
        var countAds = 0
        var saved: Double = 0

        for episode in episodes {
            if episode.isDownloaded { countDownloaded += 1 }
            if episode.isStarred { countStarred += 1 }
            if !episode.isPlayed && !episode.isArchived { countUnplayed += 1 }
            if episode.processingState == .ready { countReady += 1 }
            for segment in episode.adSegments where segment.userVerdict != .notAnAd {
                countAds += 1
                saved += segment.duration
            }
        }

        downloaded = countDownloaded
        starred = countStarred
        unplayed = countUnplayed
        ready = countReady
        adsRemoved = countAds
        secondsSaved = saved
    }

    func invalidate() { lastComputed = nil }
}
