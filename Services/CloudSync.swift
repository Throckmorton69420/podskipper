import Foundation
import UIKit
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
/// Pass 47 (his request: pause on one device, carry on on the other). Where
/// you are, played and starred now sync as one record per episode with the
/// time each part last changed (`Listening`): the position's own time
/// (`Episode.playbackPositionChangedAt` — a pause, a seek, a minute of play)
/// instead of when the episode was last started, so a pause on the iPad
/// after the iPhone's moves the iPhone, and an intentional rewind wins over
/// an older, later position. The episode loaded in the player is moved too
/// while it is paused. A pause is sent at once (`notePaused`), not only when
/// the app goes to the background. Up to `listeningBudget` bytes: about
/// 1,500 episodes, most recently changed first (was 600).
///
/// Unfollowing: a show unfollowed on one device is recorded (`Key.unfollowed`)
/// so the other no longer adds it back. The other device removes it too only
/// when nothing of yours is in it there (corrections, downloads, bookmarks,
/// a started episode); otherwise it stays, and says so. Unfollowing deletes a
/// show's episodes, so a library you can't see is never emptied silently.
///
/// Pass 54: where iCloud can't connect two devices (each signed by a
/// different developer team, so each names its own store), the same records
/// go through his Cloudflare R2 bucket, sealed (`SyncRelay`). `store` is
/// whichever one this device uses; everything below reads and writes it.
@MainActor
final class CloudSync {
    static let shared = CloudSync()

    private let icloud = NSUbiquitousKeyValueStore.default
    private(set) var store: any SyncStore = NSUbiquitousKeyValueStore.default
    /// Pass 54: the relay, when this device syncs through R2.
    private(set) var relay: RelayStore?
    /// Pass 54: what went wrong with the relay last, in plain words.
    private(set) var relayProblem: String?
    private var relayUpload: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private(set) var lastSynced: Date?
    /// Pass 35: when another device's changes last arrived (iCloud's own
    /// "changed externally" notice), and why — so the page can say whether
    /// anything has ever come from another device instead of "Connected".
    private(set) var lastReceived: Date?
    private(set) var lastReceivedReason: String?
    var lastSent: Date?
    /// Pass 35: the app's settings, reloaded when another device's arrive.
    weak var settings: AppSettings?
    /// Pass 35: what the last records sync did (CloudRecords).
    private(set) var lastRecords: CloudRecords.Outcome?
    /// Pass 47: the pending send of a pause.
    var pauseSend: Task<Void, Never>?

    private enum Key {
        static let shows = "shows.v1"
        /// Builds before Pass 47; read when an episode has no newer record.
        static let episodes = "episodes.v1"
        static let listening = "listening.v2"
        static let unfollowed = "unfollowed.v2"
    }
    /// Pass 47: what the listening records may take of iCloud's 1 MB.
    static let listeningBudget = 200_000
    private static let flagsLedgerKey = "cloud.listening.flags.v2"
    /// Kept so the next unfollow notice can be told apart; why a show stayed.
    private(set) var keptUnfollowed: [String] = []

    /// Pass 47: one episode's listening, each part with when it changed
    /// (seconds since 1970; 0 = never known).
    struct Listening: Codable, Equatable {
        var p: Double            // position
        var pa: Double           // when the position was set
        var pl: Bool             // played
        var st: Bool             // starred
        var fa: Double           // when played/starred last changed
        var lp: Double?          // last started
    }

    /// Whether this build can reach iCloud's key-value store at all.
    private(set) var isAvailable = false

    var enabled: Bool {
        UserDefaults.standard.object(forKey: "iCloudSync") as? Bool ?? true
    }

    /// Call once the library's context exists.
    func start() {
        guard !DemoData.isEnabled else { return }
        lastReceived = UserDefaults.standard.object(forKey: "cloud.lastReceived") as? Date
        lastReceivedReason = UserDefaults.standard.string(forKey: "cloud.lastReceivedReason")
        lastSent = UserDefaults.standard.object(forKey: "cloud.lastSent") as? Date
        if startRelay() {
            Task { await pull() }
            return
        }
        isAvailable = icloud.synchronize()
        guard isAvailable, observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: icloud, queue: .main) { note in
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

    // MARK: Pass 54: through his Cloudflare storage

    /// Whether this device syncs through R2 rather than iCloud.
    var usesRelay: Bool { relay != nil }

    /// Starts the relay from the setup in the Keychain; false if there is none.
    @discardableResult
    private func startRelay() -> Bool {
        guard let setup = SyncRelaySetup.load(), let credentials = setup.credentials ?? R2Credentials.load() else { return false }
        let file = URL.applicationSupportDirectory.appending(path: "SyncRelay/store.json")
        let relay = RelayStore(transport: R2RelayTransport(uploader: R2Uploader(credentials: credentials), folder: setup.folder),
                               key: setup.sealKey, deviceID: Self.deviceID, file: file)
        self.relay = relay
        store = relay
        isAvailable = true
        relayWhileActive(UIApplication.shared.applicationState != .background)
        return true
    }

    /// Turns the relay on with `setup` (new here, or pasted from the other
    /// device), and sends and receives at once.
    func useRelay(_ setup: SyncRelaySetup) throws {
        try setup.save()
        if R2Credentials.load() == nil, let credentials = setup.credentials { try R2Credentials.save(credentials) }
        relayProblem = nil
        guard startRelay() else { throw R2SetupMissing() }
        BackgroundLog.shared.note("Sync: now through your Cloudflare storage")
        // What the other device has comes in first and is merged here; then
        // the union goes out.
        Task {
            await pull()
            push()
        }
    }

    struct R2SetupMissing: LocalizedError {
        var errorDescription: String? { "Set up publishing to your Cloudflare storage first: syncing uses the same storage." }
    }

    /// Back to iCloud (what was synced stays on this device).
    func stopRelay() {
        SyncRelaySetup.clear()
        relayUpload?.cancel()
        relayWhileActive(false)
        relay = nil
        relayProblem = nil
        store = icloud
        isAvailable = icloud.synchronize()
    }

    /// Uploads this device's view, holding the app open briefly in the
    /// background for it.
    private func sendThroughRelay() {
        guard let relay else { return }
        relayUpload?.cancel()
        let kind = UIDevice.current.model
        relayUpload = Task { @MainActor in
            let id = UIApplication.shared.beginBackgroundTask(withName: "PodSkipper sync") {}
            defer { UIApplication.shared.endBackgroundTask(id) }
            do {
                try await relay.send(kind: kind)
                relayProblem = nil
                lastSent = .now
                PreferenceWriter.set(lastSent, forKey: "cloud.lastSent")
            } catch {
                relayProblem = "Couldn't send: " + error.localizedDescription
                BackgroundLog.shared.note("Sync through your Cloudflare storage: couldn't send — \(error.localizedDescription)")
            }
        }
    }

    /// Downloads what the other devices sent; true if anything changed.
    private func receiveThroughRelay() async -> Bool {
        guard let relay else { return false }
        do {
            let changed = try await relay.receive()
            relayProblem = nil
            guard !changed.isEmpty else { return false }
            lastReceived = .now
            lastReceivedReason = "changes from your other device"
            PreferenceWriter.set(lastReceived, forKey: "cloud.lastReceived")
            PreferenceWriter.set(lastReceivedReason, forKey: "cloud.lastReceivedReason")
            BackgroundLog.shared.note("Sync through your Cloudflare storage: received \(changed.count) changed item\(changed.count == 1 ? "" : "s")")
            return true
        } catch {
            relayProblem = "Couldn't receive: " + error.localizedDescription
            BackgroundLog.shared.note("Sync through your Cloudflare storage: couldn't receive — \(error.localizedDescription)")
            return false
        }
    }

    /// The other devices the relay heard from last, newest first.
    var relayDevices: [Presence] {
        (relay?.devices ?? [:]).map { Presence(kind: $0.value.kind, build: "", system: "", at: $0.value.sent) }
            .sorted { $0.at > $1.at }
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
            // Pass 55 (his 30 Oct export said "iCloud" for these while they
            // went through Cloudflare): named by the service, kind by kind.
            let kinds = CloudRecords.Kind.allCases.compactMap { kind -> String? in
                let a = outcome.applied[kind] ?? 0, s = outcome.sent[kind] ?? 0
                return a + s == 0 ? nil : "\(kind.title.lowercased()) \(a)↓ \(s)↑"
            }.joined(separator: ", ")
            BackgroundLog.shared.note("\(transportName): received \(applied), sent \(sent) (\(kinds))"
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

        pushListening(context: context)
        syncRecords(context)
        notePresence()
        // Pass 37: no `synchronize()` here — iCloud sends what was set when
        // it suits (Apple: rarely needed), and on his phone (14 Oct, 4fdd2b7)
        // iOS ended PodSkipper while this method's last step, a settings
        // write, waited on the system's settings service (the phone was hot,
        // writing gigabytes of Core AI preparation). Writes that only record
        // what happened go to a background queue.
        lastSynced = .now
        if relay != nil { sendThroughRelay(); return }
        lastSent = .now
        let sent = lastSent
        PreferenceWriter.set(sent, forKey: "cloud.lastSent")
    }

    // MARK: Which devices share this store

    /// Pass 53 (his 28 Oct export: "received 0" on every sync for ten days):
    /// each device writes its own small key, so whether another device uses
    /// this same iCloud store is seen directly, not inferred from silence.
    /// A key per device: one shared dictionary would lose a device's entry
    /// whenever both wrote it.
    static let presencePrefix = "device."

    struct Presence: Equatable {
        var kind: String
        var build: String
        var system: String
        var at: Date
    }

    nonisolated static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "cloud.deviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "cloud.deviceID")
        return id
    }

    private func notePresence() {
        store.set(["kind": UIDevice.current.model, "build": BuildInfo.commit,
                   "system": UIDevice.current.systemVersion, "at": Date.now.timeIntervalSince1970],
                  forKey: Self.presencePrefix + Self.deviceID)
    }

    /// Other devices that have written to iCloud's store, newest first
    /// (Pass 55: always iCloud's, also while the relay carries sync; the
    /// relay's are `relayDevices`).
    var otherDevices: [Presence] {
        Self.otherDevices(in: icloud.dictionaryRepresentation, me: Self.deviceID)
    }

    nonisolated static func otherDevices(in all: [String: Any], me: String) -> [Presence] {
        all.compactMap { key, value -> Presence? in
            guard key.hasPrefix(presencePrefix), key != presencePrefix + me,
                  let d = value as? [String: Any], let at = d["at"] as? Double else { return nil }
            return Presence(kind: d["kind"] as? String ?? "Device", build: d["build"] as? String ?? "",
                            system: d["system"] as? String ?? "", at: Date(timeIntervalSince1970: at))
        }.sorted { $0.at > $1.at }
    }

    // MARK: Receiving

    /// Brings in what other devices wrote: follows shows you added elsewhere
    /// and moves positions forward where another device is ahead.
    func pull() async {
        guard isAvailable, enabled, AppLibrary.context != nil else { return }
        // Pass 54: what the other devices sent, before it is merged here.
        if relay != nil { _ = await receiveThroughRelay() }
        await merge()
    }

    /// Pass 55: while the app is open, the relay is checked every minute —
    /// iCloud says when something arrives, the relay can't — and merged only
    /// when another device's file changed something (a check is one listing
    /// and the changed files; no library work when nothing came).
    func relayWhileActive(_ active: Bool) {
        relayPolling?.cancel()
        relayPolling = nil
        guard active, relay != nil else { return }
        relayPolling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.relayCheckSeconds))
                guard let self, !Task.isCancelled, self.isAvailable, self.enabled, self.relay != nil,
                      AppLibrary.context != nil else { return }
                if await self.receiveThroughRelay() { await self.merge() }
            }
        }
    }

    static let relayCheckSeconds: Double = 60
    private var relayPolling: Task<Void, Never>?

    /// Pass 55: which service carries sync now, for the log and Settings.
    var transportName: String { relay != nil ? "Cloudflare sync" : "iCloud" }

    private func merge() async {
        guard let context = AppLibrary.context else { return }
        let local = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []
        let have = Set(local.map(\.feedURL))
        let remote = (store.array(forKey: Key.shows) as? [[String: String]]) ?? []
        let gone = (store.dictionary(forKey: Key.unfollowed) as? [String: Double]) ?? [:]
        for entry in remote {
            guard let feed = entry["feed"], !have.contains(feed) else { continue }
            // Pass 47: unfollowed on a device since: not added back.
            if gone[feed] != nil { continue }
            guard let parsed = try? await FeedParser.fetch(feed) else { continue }
            let podcast = Podcast(feedURL: feed, title: parsed.title, author: parsed.author,
                                  summary: parsed.summary, artworkURL: parsed.artworkURL)
            context.insert(podcast)
            await EpisodeCatalogue.fill(podcast, from: parsed, context: context)
        }

        pullListening(context: context)
        applyUnfollows(context: context)
        try? context.save()
        syncRecords(context)
        lastSynced = .now
    }
}

// MARK: - Pass 47: listening state and unfollows

extension CloudSync {
    /// A pause, sent at once (a second later, so a run of taps is one write).
    func notePaused(_ episode: Episode) {
        guard isAvailable, enabled, let context = AppLibrary.context else { return }
        pauseSend?.cancel()
        let guid = episode.guid
        pauseSend = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
            descriptor.fetchLimit = 1
            guard let episode = try? context.fetch(descriptor).first else { return }
            self.pushListening(context: context, only: [episode])
            self.sendThroughRelay()
        }
    }

    /// This device's record for `episode`, with `flags` the last played and
    /// starred this device sent or received, and when.
    static func record(_ episode: Episode, flags: (pl: Bool, st: Bool, fa: Double)?, now: Date = .now) -> Listening {
        let started = episode.lastPlayedAt?.timeIntervalSince1970
        let positionAt = episode.playbackPositionChangedAt?.timeIntervalSince1970 ?? started ?? 0
        var flagsAt = flags?.fa ?? 0
        if let flags, flags.pl != episode.isPlayed || flags.st != episode.isStarred { flagsAt = now.timeIntervalSince1970 }
        return Listening(p: (episode.playbackPosition * 10).rounded() / 10, pa: positionAt,
                         pl: episode.isPlayed, st: episode.isStarred, fa: flagsAt, lp: started)
    }

    /// Merges a local and a remote record, part by part: the newer wins.
    static func merged(local: Listening, remote: Listening?) -> Listening {
        guard let remote else { return local }
        var out = local
        if remote.pa > local.pa { out.p = remote.p; out.pa = remote.pa }
        if remote.fa > local.fa { out.pl = remote.pl; out.st = remote.st; out.fa = remote.fa }
        out.lp = [local.lp, remote.lp].compactMap { $0 }.max()
        return out
    }

    private func flagsLedger() -> [String: [Double]] {
        (UserDefaults.standard.dictionary(forKey: Self.flagsLedgerKey) as? [String: [Double]]) ?? [:]
    }

    private func remoteListening() -> [String: Listening] {
        guard let data = store.data(forKey: Key.listening) else { return [:] }
        return (try? JSONDecoder().decode([String: Listening].self, from: data)) ?? [:]
    }

    /// Writes this device's records (all it has touched, or `only`), merged
    /// with what is there, within the budget.
    func pushListening(context: ModelContext, only: [Episode]? = nil) {
        let episodes: [Episode]
        if let only { episodes = only } else {
            var descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate { $0.lastPlayedAt != nil || $0.isStarred || $0.isPlayed || $0.playbackPositionChangedAt != nil },
                sortBy: [SortDescriptor(\.lastPlayedAt, order: .reverse)])
            descriptor.fetchLimit = 3_000
            episodes = (try? context.fetch(descriptor)) ?? []
        }
        var remote = remoteListening()
        var ledger = flagsLedger()
        var changed = false
        let now = Date.now
        for episode in episodes {
            let known = ledger[episode.guid].flatMap { $0.count == 3 ? (pl: $0[0] != 0, st: $0[1] != 0, fa: $0[2]) : nil }
            let local = Self.record(episode, flags: known, now: now)
            let next = Self.merged(local: local, remote: remote[episode.guid])
            ledger[episode.guid] = [next.pl ? 1 : 0, next.st ? 1 : 0, next.fa]
            if remote[episode.guid] != next { remote[episode.guid] = next; changed = true }
        }
        UserDefaults.standard.set(ledger, forKey: Self.flagsLedgerKey)
        guard changed else { return }
        store.set(Self.encodeWithinBudget(remote), forKey: Key.listening)
        guard relay == nil else { return }   // the relay says when it has really sent
        lastSent = .now
        PreferenceWriter.set(lastSent, forKey: "cloud.lastSent")
    }

    /// The most recently changed records that fit `listeningBudget`.
    static func encodeWithinBudget(_ records: [String: Listening], budget: Int = listeningBudget) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var kept = records
        while let data = try? encoder.encode(kept), data.count > budget, kept.count > 1 {
            let sorted = kept.sorted { max($0.value.pa, $0.value.fa) > max($1.value.pa, $1.value.fa) }
            kept = Dictionary(uniqueKeysWithValues: sorted.prefix(sorted.count * 9 / 10).map { ($0.key, $0.value) })
        }
        return (try? encoder.encode(kept)) ?? Data()
    }

    /// Applies newer records from other devices; the episode in the player
    /// moves too when it is paused.
    func pullListening(context: ModelContext) {
        var remote = remoteListening()
        // Builds before Pass 47 wrote "episodes.v1" (position by start time).
        if let old = store.dictionary(forKey: Key.episodes) as? [String: [String: Any]] {
            for (guid, values) in old where remote[guid] == nil {
                guard let at = values["at"] as? Double else { continue }
                remote[guid] = Listening(p: values["pos"] as? Double ?? 0, pa: at, pl: values["played"] as? Bool ?? false,
                                         st: values["star"] as? Bool ?? false, fa: at, lp: at)
            }
        }
        guard !remote.isEmpty else { return }
        var ledger = flagsLedger()
        let player = PlayerEngine.shared
        let now = Date.now
        for (guid, theirs) in remote {
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
            descriptor.fetchLimit = 1
            guard let episode = try? context.fetch(descriptor).first else { continue }
            let known = ledger[guid].flatMap { $0.count == 3 ? (pl: $0[0] != 0, st: $0[1] != 0, fa: $0[2]) : nil }
            let local = Self.record(episode, flags: known, now: now)
            let loaded = player.currentEpisode?.guid == guid
            if theirs.pa > local.pa + 1, abs(theirs.p - episode.playbackPosition) > 1 {
                // Playing here: this device's listening is the newer intent.
                if !(loaded && player.isPlaying) {
                    episode.setPosition(theirs.p, at: Date(timeIntervalSince1970: theirs.pa))
                    if loaded { player.adoptRemotePosition(theirs.p) }
                }
            }
            if theirs.fa > local.fa {
                episode.isPlayed = theirs.pl
                if theirs.pl { episode.isNew = false }
                episode.isStarred = theirs.st
                ledger[guid] = [theirs.pl ? 1 : 0, theirs.st ? 1 : 0, theirs.fa]
            }
            if let started = theirs.lp, started > (episode.lastPlayedAt?.timeIntervalSince1970 ?? 0) {
                episode.lastPlayedAt = Date(timeIntervalSince1970: started)
            }
        }
        UserDefaults.standard.set(ledger, forKey: Self.flagsLedgerKey)
    }

    /// Records an unfollow here so other devices don't add the show back.
    func noteUnfollowed(feed: String) {
        guard isAvailable, enabled else { return }
        var gone = (store.dictionary(forKey: Key.unfollowed) as? [String: Double]) ?? [:]
        gone[feed] = Date.now.timeIntervalSince1970
        // A year of unfollows is plenty to have reached every device.
        let yearAgo = Date.now.addingTimeInterval(-365 * 86_400).timeIntervalSince1970
        gone = gone.filter { $0.value > yearAgo }
        store.set(gone, forKey: Key.unfollowed)
        var shows = (store.array(forKey: Key.shows) as? [[String: String]]) ?? []
        shows.removeAll { $0["feed"] == feed }
        store.set(shows, forKey: Key.shows)
    }

    /// Unfollows another device made, mirrored only where nothing of his is
    /// in the show here; a show followed again since stays.
    func applyUnfollows(context: ModelContext) {
        let gone = (store.dictionary(forKey: Key.unfollowed) as? [String: Double]) ?? [:]
        guard !gone.isEmpty else { return }
        keptUnfollowed = []
        for (feed, at) in gone {
            var descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == feed })
            descriptor.fetchLimit = 1
            guard let show = try? context.fetch(descriptor).first,
                  show.dateAdded.timeIntervalSince1970 < at else { continue }
            if Self.holdsYourWork(show) {
                keptUnfollowed.append(show.title)
                continue
            }
            if PlayerEngine.shared.currentEpisode?.podcast?.feedURL == feed { continue }
            context.delete(show)
            BackgroundLog.shared.note("\(transportName): unfollowed \(show.title), as on your other device")
        }
    }

    /// Corrections, downloads, a saved or a started episode in `show`
    /// (bookmarks are kept by episode id and survive an unfollow anyway).
    static func holdsYourWork(_ show: Podcast) -> Bool {
        show.episodes.contains { e in
            e.correctionLogData != nil || e.isDownloaded || e.playbackPosition > 1 || e.isStarred
        }
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
