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
    /// Pass 35: when another device's changes last arrived (iCloud's own
    /// "changed externally" notice), and why — so the page can say whether
    /// anything has ever come from another device instead of "Connected".
    private(set) var lastReceived: Date?
    private(set) var lastReceivedReason: String?
    private(set) var lastSent: Date?
    /// Pass 35: the app's settings, reloaded when another device's arrive.
    weak var settings: AppSettings?
    /// Pass 35: what the last records sync did (CloudRecords).
    private(set) var lastRecords: CloudRecords.Outcome?

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
        lastReceived = UserDefaults.standard.object(forKey: "cloud.lastReceived") as? Date
        lastReceivedReason = UserDefaults.standard.string(forKey: "cloud.lastReceivedReason")
        lastSent = UserDefaults.standard.object(forKey: "cloud.lastSent") as? Date
        guard isAvailable, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: .main) { note in
                let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
                Task { @MainActor in
                    CloudSync.shared.noteReceived(reason)
                    await CloudSync.shared.pull()
                }
            }
        Task { await pull() }
    }

    private func noteReceived(_ reason: Int?) {
        lastReceived = .now
        lastReceivedReason = switch reason {
        case NSUbiquitousKeyValueStoreServerChange: "changes from another device"
        case NSUbiquitousKeyValueStoreInitialSyncChange: "first download from iCloud"
        case NSUbiquitousKeyValueStoreQuotaViolationChange: "over iCloud's 1 MB limit"
        case NSUbiquitousKeyValueStoreAccountChange: "the iCloud account changed"
        default: "unknown"
        }
        PreferenceWriter.set(lastReceived, forKey: "cloud.lastReceived")
        PreferenceWriter.set(lastReceivedReason, forKey: "cloud.lastReceivedReason")
        BackgroundLog.shared.note("iCloud: received \(lastReceivedReason ?? "")")
    }

    /// Whether the signed app carries the key-value store entitlement.
    nonisolated static var entitled: Bool {
        SignedEntitlements.present.contains("com.apple.developer.ubiquity-kvstore-identifier")
    }

    /// Signed in to iCloud on this device (says nothing about the entitlement).
    nonisolated static var signedIn: Bool { FileManager.default.ubiquityIdentityToken != nil }

    /// Settings, show settings, bookmarks, stations and corrections.
    private func syncRecords(_ context: ModelContext) {
        let outcome = CloudRecords.sync(context: context, store: store)
        lastRecords = outcome
        if outcome.settingsChanged { settings?.reload() }
        let applied = outcome.applied.values.reduce(0, +), sent = outcome.sent.values.reduce(0, +)
        if applied + sent + outcome.conflictsKeptHere > 0 {
            BackgroundLog.shared.note("iCloud: received \(applied), sent \(sent)"
                + (outcome.conflictsKeptHere > 0 ? ", kept \(outcome.conflictsKeptHere) of your corrections made here over another device's" : "")
                + (outcome.skippedForSize > 0 ? ", \(outcome.skippedForSize) oldest records left out (iCloud's 1 MB limit)" : ""))
        }
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
        syncRecords(context)
        // Pass 37: no `synchronize()` here — iCloud sends what was set when
        // it suits (Apple: rarely needed), and on his phone (14 Oct, 4fdd2b7)
        // iOS ended PodSkipper while this method's last step, a settings
        // write, waited on the system's settings service (the phone was hot,
        // writing gigabytes of Core AI preparation). Writes that only record
        // what happened go to a background queue.
        lastSynced = .now
        lastSent = .now
        let sent = lastSent
        PreferenceWriter.set(sent, forKey: "cloud.lastSent")
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
            if let played = values["played"] as? Bool { episode.isPlayed = played; if played { episode.isNew = false } }
            if let starred = values["star"] as? Bool { episode.isStarred = starred }
            episode.lastPlayedAt = theirs
        }
        try? context.save()
        syncRecords(context)
        lastSynced = .now
    }
}

/// Pass 37: settings writes that only record what happened (times, the sync
/// ledger), made on a background queue so a slow settings service can't hold
/// the main thread — iOS ends an app whose main thread doesn't answer while
/// it goes to the background or closes (his 14 Oct phone).
enum PreferenceWriter {
    private static let queue = DispatchQueue(label: "PodSkipper.preferences", qos: .utility)

    static func set(_ value: Any?, forKey key: String, in defaults: UserDefaults = .standard) {
        nonisolated(unsafe) let value = value
        nonisolated(unsafe) let defaults = defaults
        queue.async { defaults.set(value, forKey: key) }
    }

    /// Waits for the writes already queued (tests).
    static func flush() { queue.sync {} }
}
