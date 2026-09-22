import Foundation
import SwiftData

/// Keeps your shows and where you are in each episode the same on every
/// device signed in to your iCloud account.
///
/// Uses iCloud's key-value store, Apple's service for small amounts of
/// settings-like data. Why this and not syncing the whole database: that needs
/// every model to follow CloudKit's rules — no unique fields, every
/// relationship optional — and PodSkipper's episodes are unique by their guid.
/// Rebuilding the database around that risks the library for little gain,
/// because everything else (episodes, transcripts, found ads) is rebuilt from
/// the feeds on each device anyway. What can't be rebuilt is what you did: the
/// shows you follow, how far you got, what you finished, what you starred.
/// That is what syncs.
///
/// Needs the iCloud key-value entitlement, which needs a paid developer
/// account. Without it `synchronize()` returns false, `isAvailable` is false,
/// and nothing here does anything.
///
/// Additions only: a show unfollowed on one device is not removed from the
/// others. Deleting from a library you can't see is too easy to get wrong.
@MainActor
final class CloudSync {
    static let shared = CloudSync()

    private let store = NSUbiquitousKeyValueStore.default
    private var observer: NSObjectProtocol?
    private(set) var lastSynced: Date?

    private enum Key {
        static let shows = "shows.v1"
        static let episodes = "episodes.v1"
    }
    /// The store allows 1 MB in all; this many episodes is about 60 KB.
    private static let episodeLimit = 600

    /// Whether this build can reach iCloud's key-value store at all.
    private(set) var isAvailable = false

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: "iCloudSync") as? Bool ?? true
    }

    /// Call once the library's context exists.
    func start() {
        guard !DemoData.isEnabled else { return }
        isAvailable = store.synchronize()
        guard isAvailable, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: .main) { _ in
                Task { @MainActor in await CloudSync.shared.pull() }
            }
        Task { await pull() }
    }

    // MARK: Sending

    /// Writes this device's state. Cheap; called when the app goes to the
    /// background.
    func push() {
        guard isAvailable, enabled, let context = AppLibrary.context else { return }
        let shows = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []
        store.set(shows.map { ["feed": $0.feedURL, "title": $0.title] }, forKey: Key.shows)

        // Episodes you've done something with, most recent first.
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.lastPlayedAt != nil || $0.isStarred || $0.isPlayed },
            sortBy: [SortDescriptor(\.lastPlayedAt, order: .reverse)])
        descriptor.fetchLimit = Self.episodeLimit
        let touched = (try? context.fetch(descriptor)) ?? []
        var state: [String: [String: Any]] = (store.dictionary(forKey: Key.episodes) as? [String: [String: Any]]) ?? [:]
        for episode in touched {
            let when = (episode.lastPlayedAt ?? .distantPast).timeIntervalSince1970
            // Keep whichever is newer, so two devices don't undo each other.
            if let theirs = state[episode.guid]?["at"] as? Double, theirs > when { continue }
            state[episode.guid] = ["pos": (episode.playbackPosition * 10).rounded() / 10,
                                   "played": episode.isPlayed,
                                   "star": episode.isStarred,
                                   "at": when]
        }
        if state.count > Self.episodeLimit {
            let keep = state.sorted { ($0.value["at"] as? Double ?? 0) > ($1.value["at"] as? Double ?? 0) }
                .prefix(Self.episodeLimit)
            state = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        store.set(state, forKey: Key.episodes)
        store.synchronize()
        lastSynced = .now
    }

    // MARK: Receiving

    /// Brings in what other devices wrote: follows shows you added elsewhere
    /// and moves positions forward where another device is ahead.
    func pull() async {
        guard isAvailable, enabled, let context = AppLibrary.context else { return }
        let local = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []
        let have = Set(local.map(\.feedURL))
        let remote = (store.array(forKey: Key.shows) as? [[String: String]]) ?? []
        for entry in remote {
            guard let feed = entry["feed"], !have.contains(feed) else { continue }
            guard let parsed = try? await FeedParser.fetch(feed) else { continue }
            let podcast = Podcast(feedURL: feed, title: parsed.title, author: parsed.author,
                                  summary: parsed.summary, artworkURL: parsed.artworkURL)
            context.insert(podcast)
            await EpisodeCatalogue.fill(podcast, from: parsed, context: context)
        }

        let state = (store.dictionary(forKey: Key.episodes) as? [String: [String: Any]]) ?? [:]
        let current = PlayerEngine.shared.currentEpisode?.guid
        for (guid, values) in state where guid != current {
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
            descriptor.fetchLimit = 1
            guard let episode = try? context.fetch(descriptor).first,
                  let at = values["at"] as? Double else { continue }
            let theirs = Date(timeIntervalSince1970: at)
            guard theirs > (episode.lastPlayedAt ?? .distantPast) else { continue }
            if let position = values["pos"] as? Double { episode.playbackPosition = position }
            if let played = values["played"] as? Bool { episode.isPlayed = played }
            if let starred = values["star"] as? Bool { episode.isStarred = starred }
            episode.lastPlayedAt = theirs
        }
        try? context.save()
        lastSynced = .now
    }
}
