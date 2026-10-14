import Foundation
import SwiftData

/// Pass 35 (his request: pick up on the iPad where the iPhone left off):
/// more of what can't be rebuilt from the feeds, synced through iCloud's
/// key-value store alongside `CloudSync`'s shows and positions.
///
/// What syncs here: listening and sound settings (not device ones — model
/// choice, downloads, storage limits, notifications, text size), each show's
/// own settings and what it has learned from him, bookmarks, stations, and
/// the cuts of every episode he has reviewed (confirmed, rejected, moved,
/// added, locked). Media, transcripts and models never sync.
///
/// Why the key-value store and not CloudKit: it needs only the entitlement
/// his install may already have, and these records are small. Its limits are
/// 1 MB and 1,024 keys in all, so each kind is one key holding a JSON map,
/// the cuts are capped to the most recent 200 reviewed episodes, and the
/// size is checked before writing. A whole-library sync (CloudKit) would
/// need an iCloud container in his signing and isn't attempted.
///
/// Rules, per record (a show's settings, a bookmark, a station, one
/// episode's cuts): each carries the time it last changed and, when
/// removed, a tombstone. A device applies another's record only when it is
/// newer than what it last synced; a record changed on this device since
/// then is not overwritten — for cuts that means his corrections here always
/// stay, and the conflict is counted. No migration: "changed here" is found
/// by comparing each record with a digest of what was last synced.
enum CloudRecords {
    protocol Store: AnyObject {
        func data(forKey key: String) -> Data?
        func setData(_ data: Data?, forKey key: String)
    }

    struct Stamped<Value: Codable & Equatable>: Codable, Equatable {
        var at: Date
        var deleted = false
        var value: Value?
    }

    enum Kind: String, CaseIterable, Sendable {
        case settings, shows, bookmarks, stations, cuts
        var key: String { "sync.\(rawValue).v1" }
        var title: String {
            switch self {
            case .settings: "Listening and sound settings"
            case .shows: "Each show's settings and what it learned"
            case .bookmarks: "Bookmarks"
            case .stations: "Stations"
            case .cuts: "Your ad corrections"
            }
        }
    }

    struct Outcome: Equatable {
        var applied: [Kind: Int] = [:]
        var sent: [Kind: Int] = [:]
        var conflictsKeptHere = 0
        var waiting = 0          // for a show or episode not on this device yet
        var skippedForSize = 0
        var settingsChanged = false
    }

    /// Keys that describe how he listens, not this device.
    static let settingKeys: [String] = [
        "autoSkip", "resumeAfterInterruption", "sensitivity", "minConfidence", "padding",
        "skipIntro", "skipOutro", "skipSelfPromo", "skipCrossPromo", "keepHostRead", "keepComedyBits",
        "adFreeCopy", "autoQueue", "speed", "seekFwd", "seekBack", "continuous", "markPlayed",
        "startInVideo", "playUnprocessed", "playPromptCountdown", "promptSwipeCancels",
        "smartSpeed", "smartSpeedAmount", "voiceBoost", "voiceBoostAmount", "normalize", "rumble",
        "deEsser", "deEsserAmount", "mudCut", "mudCutAmount", "bassCut", "bassCutAmount",
        "harshCut", "harshCutAmount", "nasalCut", "nasalCutAmount", "brighten", "brightenAmount",
        "evenOut", "evenOutAmount", "mono", "eqOn", "eqPreset", "eqGains",
    ]

    static let cutsLimit = 200
    static let byteBudget = 800_000

    // MARK: Values

    struct ShowValue: Codable, Equatable {
        var autoSkipEnabled: Bool?, playbackSpeedOverride: Double?, skipIntroSeconds: Double, skipOutroSeconds: Double
        var voiceBoostOverride: Bool?, customSoundData: Data?, continuousPlaybackOverride: Bool?, startInVideoOverride: Bool?
        var smartSpeedOverride: Bool?, volumeNormalizationOverride: Bool?, smartSpeedAmountOverride: Double?
        var skipIntroOutroOverride: Bool?, skipIntroOverride: Bool?, skipOutroOverride: Bool?
        var skipSelfPromoOverride: Bool?, skipCrossPromoOverride: Bool?, removePlayedDownloads: Bool?
        var newestFirst: Bool, hidePlayed: Bool, episodeFilter: String, priority: Int, knownSponsors: [String]
        var correctionData: Data?

        init(_ p: Podcast) {
            autoSkipEnabled = p.autoSkipEnabled; playbackSpeedOverride = p.playbackSpeedOverride
            skipIntroSeconds = p.skipIntroSeconds; skipOutroSeconds = p.skipOutroSeconds
            voiceBoostOverride = p.voiceBoostOverride; customSoundData = p.customSoundData
            continuousPlaybackOverride = p.continuousPlaybackOverride; startInVideoOverride = p.startInVideoOverride
            smartSpeedOverride = p.smartSpeedOverride; volumeNormalizationOverride = p.volumeNormalizationOverride
            smartSpeedAmountOverride = p.smartSpeedAmountOverride; skipIntroOutroOverride = p.skipIntroOutroOverride
            skipIntroOverride = p.skipIntroOverride; skipOutroOverride = p.skipOutroOverride
            skipSelfPromoOverride = p.skipSelfPromoOverride; skipCrossPromoOverride = p.skipCrossPromoOverride
            removePlayedDownloads = p.removePlayedDownloads; newestFirst = p.newestFirst; hidePlayed = p.hidePlayed
            episodeFilter = p.episodeFilter; priority = p.priority; knownSponsors = p.knownSponsors
            correctionData = p.correctionData
        }

        func apply(to p: Podcast) {
            p.autoSkipEnabled = autoSkipEnabled; p.playbackSpeedOverride = playbackSpeedOverride
            p.skipIntroSeconds = skipIntroSeconds; p.skipOutroSeconds = skipOutroSeconds
            p.voiceBoostOverride = voiceBoostOverride; p.customSoundData = customSoundData
            p.continuousPlaybackOverride = continuousPlaybackOverride; p.startInVideoOverride = startInVideoOverride
            p.smartSpeedOverride = smartSpeedOverride; p.volumeNormalizationOverride = volumeNormalizationOverride
            p.smartSpeedAmountOverride = smartSpeedAmountOverride; p.skipIntroOutroOverride = skipIntroOutroOverride
            p.skipIntroOverride = skipIntroOverride; p.skipOutroOverride = skipOutroOverride
            p.skipSelfPromoOverride = skipSelfPromoOverride; p.skipCrossPromoOverride = skipCrossPromoOverride
            p.removePlayedDownloads = removePlayedDownloads; p.newestFirst = newestFirst; p.hidePlayed = hidePlayed
            p.episodeFilter = episodeFilter; p.priority = priority; p.knownSponsors = knownSponsors
            p.correctionData = correctionData
        }
    }

    struct BookmarkValue: Codable, Equatable {
        var guid: String, timestamp: Double, note: String, createdAt: Date, episodeTitle: String, showTitle: String
    }

    struct StationValue: Codable, Equatable {
        var name, iconName, colorHex: String
        var order: Int
        var onlyUnplayed, onlyDownloaded, onlyAdFree, onlyStarred: Bool
        var withinDays, maxMinutes, minMinutes: Int
        var showFeedURLs: [String]
        var sortRaw: String
        var perShow: Int
        var groupByShow: Bool
        var manualEpisodeGUIDs: [String]

        init(_ f: SmartFilter) {
            name = f.name; iconName = f.iconName; colorHex = f.colorHex; order = f.order
            onlyUnplayed = f.onlyUnplayed; onlyDownloaded = f.onlyDownloaded; onlyAdFree = f.onlyAdFree; onlyStarred = f.onlyStarred
            withinDays = f.withinDays; maxMinutes = f.maxMinutes; minMinutes = f.minMinutes
            showFeedURLs = f.showFeedURLs; sortRaw = f.sortRaw; perShow = f.perShow; groupByShow = f.groupByShow
            manualEpisodeGUIDs = f.manualEpisodeGUIDs
        }

        func apply(to f: SmartFilter) {
            f.iconName = iconName; f.colorHex = colorHex; f.order = order
            f.onlyUnplayed = onlyUnplayed; f.onlyDownloaded = onlyDownloaded; f.onlyAdFree = onlyAdFree; f.onlyStarred = onlyStarred
            f.withinDays = withinDays; f.maxMinutes = maxMinutes; f.minMinutes = minMinutes
            f.showFeedURLs = showFeedURLs; f.sortRaw = sortRaw; f.perShow = perShow; f.groupByShow = groupByShow
            f.manualEpisodeGUIDs = manualEpisodeGUIDs
        }
    }

    struct CutValue: Codable, Equatable {
        var start, end: Double
        var kindRaw, sponsor, origin, deliveryRaw, detailRaw, detectedKindRaw, containsRaw: String
        var verdict: String
        var locked: Bool
        var detectedStart, detectedEnd: Double
        var confidence: Int

        init(_ s: AdSegment) {
            start = s.start; end = s.end; kindRaw = s.kindRaw; sponsor = s.sponsor; origin = s.origin
            deliveryRaw = s.deliveryRaw; detailRaw = s.detailRaw; detectedKindRaw = s.detectedKindRaw
            containsRaw = s.containsRaw; verdict = s.userVerdict.rawValue; locked = s.isLocked
            detectedStart = s.detectedStart; detectedEnd = s.detectedEnd; confidence = s.confidence
        }

        func make() -> AdSegment {
            let s = AdSegment(start: start, end: end, sponsor: sponsor, confidence: confidence)
            s.kindRaw = kindRaw; s.origin = origin; s.deliveryRaw = deliveryRaw; s.detailRaw = detailRaw
            s.detectedKindRaw = detectedKindRaw; s.containsRaw = containsRaw
            s.userVerdict = UserVerdict(rawValue: verdict) ?? .unreviewed
            s.isLocked = locked; s.detectedStart = detectedStart; s.detectedEnd = detectedEnd
            return s
        }
    }

    struct CutsValue: Codable, Equatable {
        var cuts: [CutValue]
        var correctionLog: Data?
    }

    // MARK: Sync

    /// Brings in what other devices changed, then sends what changed here.
    @MainActor
    static func sync(context: ModelContext, store: Store, defaults: UserDefaults = .standard,
                     now: Date = .now) -> Outcome {
        var outcome = Outcome()
        let ledger = Ledger(defaults: defaults)
        // Counted by the apply closures (merge() holds `outcome` while they run).
        var waiting = 0, keptHere = 0, settingsChanged = false

        // Settings: one record.
        merge(.settings, local: settingsSnapshot(defaults).map { ["app": $0] } ?? [:],
              store: store, ledger: ledger, now: now, outcome: &outcome,
              conflictKeepsLocal: false) { _, value in
            guard let value else { return true }
            applySettings(value, defaults)
            settingsChanged = true
            return true
        }

        let podcasts = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []
        let byFeed = Dictionary(podcasts.map { ($0.feedURL, $0) }, uniquingKeysWith: { a, _ in a })
        merge(.shows, local: byFeed.mapValues(ShowValue.init), store: store, ledger: ledger, now: now,
              outcome: &outcome, conflictKeepsLocal: false, tombstones: false) { feed, value in
            guard let value else { return true }
            guard let show = byFeed[feed] else { waiting += 1; return false }
            value.apply(to: show)
            return true
        }

        let bookmarks = (try? context.fetch(FetchDescriptor<Bookmark>())) ?? []
        func bookmarkID(_ guid: String, _ t: Double) -> String { guid + "@" + String(format: "%.1f", t) }
        let bookmarkMap = Dictionary(bookmarks.map { (bookmarkID($0.episodeGUID, $0.timestamp), $0) }, uniquingKeysWith: { a, _ in a })
        merge(.bookmarks, local: bookmarkMap.mapValues {
            BookmarkValue(guid: $0.episodeGUID, timestamp: $0.timestamp, note: $0.note, createdAt: $0.createdAt,
                          episodeTitle: $0.episodeTitle, showTitle: $0.showTitle)
        }, store: store, ledger: ledger, now: now, outcome: &outcome, conflictKeepsLocal: false) { id, value in
            if let value {
                if let existing = bookmarkMap[id] { existing.note = value.note; return true }
                guard let episode = episode(value.guid, context) else { waiting += 1; return false }
                let bookmark = Bookmark(timestamp: value.timestamp, note: value.note, episode: episode)
                bookmark.createdAt = value.createdAt
                context.insert(bookmark)
            } else if let existing = bookmarkMap[id] {
                context.delete(existing)
            }
            return true
        }

        let stations = (try? context.fetch(FetchDescriptor<SmartFilter>())) ?? []
        let stationMap = Dictionary(stations.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        merge(.stations, local: stationMap.mapValues(StationValue.init), store: store, ledger: ledger, now: now,
              outcome: &outcome, conflictKeepsLocal: false) { name, value in
            if let value {
                if let existing = stationMap[name] { value.apply(to: existing) } else {
                    let station = SmartFilter(name: value.name)
                    value.apply(to: station)
                    context.insert(station)
                }
            } else if let existing = stationMap[name] {
                context.delete(existing)
            }
            return true
        }

        // Cuts of reviewed episodes, most recent first, capped.
        var reviewed = FetchDescriptor<Episode>(predicate: #Predicate { $0.correctionLogData != nil },
                                                sortBy: [SortDescriptor(\.lastProcessedAt, order: .reverse)])
        reviewed.fetchLimit = cutsLimit
        let reviewedEpisodes = ((try? context.fetch(reviewed)) ?? []).filter { $0.adSegments.contains(where: \.isReviewed) }
        let cuts = Dictionary(reviewedEpisodes.map { ($0.guid, CutsValue(cuts: $0.adSegments.sorted { $0.start < $1.start }.map(CutValue.init),
                                                                         correctionLog: $0.correctionLogData)) },
                              uniquingKeysWith: { a, _ in a })
        merge(.cuts, local: cuts, store: store, ledger: ledger, now: now, outcome: &outcome,
              conflictKeepsLocal: true, tombstones: false) { guid, value in
            guard let value else { return true }
            guard let target = episode(guid, context) else { waiting += 1; return false }
            // Never over his corrections made here (merge() checks they
            // haven't changed since the last sync; this guards the first one).
            if target.adSegments.contains(where: \.isReviewed), cuts[guid] == nil {
                keptHere += 1
                return true
            }
            for segment in target.adSegments { context.delete(segment) }
            for cut in value.cuts {
                let segment = cut.make()
                segment.episode = target
                context.insert(segment)
            }
            target.correctionLogData = value.correctionLog
            return true
        }

        try? context.save()
        ledger.save()
        outcome.waiting += waiting
        outcome.conflictsKeptHere += keptHere
        outcome.settingsChanged = settingsChanged
        return outcome
    }

    /// One kind: apply newer remote records not changed here, then send
    /// records changed here. `apply` returns false to try again later.
    @MainActor
    private static func merge<Value: Codable & Equatable>(
        _ kind: Kind, local: [String: Value], store: Store, ledger: Ledger, now: Date, outcome: inout Outcome,
        conflictKeepsLocal: Bool, tombstones: Bool = true,
        apply: (String, Value?) -> Bool
    ) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var remote = store.data(forKey: kind.key).flatMap { try? decoder.decode([String: Stamped<Value>].self, from: $0) } ?? [:]
        var remoteChanged = false
        for id in Set(remote.keys).union(local.keys).union(ledger.ids(kind)) {
            let current = local[id]
            let known = ledger.entry(kind, id)
            let digest = current.map(Ledger.digest)
            let changedHere = known == nil ? current != nil : known?.digest != digest
            if let theirs = remote[id], theirs.at > (known?.at ?? .distantPast) {
                // First sync on this device: the cloud's record is the
                // history, except corrections made here, which stay.
                let editedHere = known == nil ? (current != nil && conflictKeepsLocal) : changedHere
                if editedHere, current != nil {
                    // Both changed since the last sync: this device's stays.
                    if conflictKeepsLocal { outcome.conflictsKeptHere += 1 }
                } else {
                    if apply(id, theirs.deleted ? nil : theirs.value) {
                        ledger.set(kind, id, digest: theirs.value.map(Ledger.digest), at: theirs.at)
                        outcome.applied[kind, default: 0] += 1
                    }
                    continue
                }
            }
            guard changedHere else { continue }
            if current == nil && !tombstones { ledger.remove(kind, id); continue }
            remote[id] = Stamped(at: now, deleted: current == nil, value: current)
            ledger.set(kind, id, digest: digest, at: now)
            remoteChanged = true
            outcome.sent[kind, default: 0] += 1
        }
        // Tombstones older than a month have reached every device that syncs.
        let monthAgo = now.addingTimeInterval(-30 * 86_400)
        let before = remote.count
        remote = remote.filter { !$0.value.deleted || $0.value.at > monthAgo }
        if remote.count != before { remoteChanged = true }
        guard remoteChanged else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(remote) else { return }
        // Within iCloud's limits: the oldest records go first if too big.
        if data.count > byteBudget / (kind == .cuts ? 1 : 4) {
            let sorted = remote.sorted { $0.value.at > $1.value.at }
            var kept = sorted
            while let encoded = try? encoder.encode(Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })),
                  encoded.count > byteBudget / (kind == .cuts ? 1 : 4), kept.count > 1 {
                kept.removeLast(max(1, kept.count / 10))
                data = encoded
            }
            outcome.skippedForSize += sorted.count - kept.count
            data = (try? encoder.encode(Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) }))) ?? data
        }
        store.setData(data, forKey: kind.key)
    }

    @MainActor
    private static func episode(_ guid: String, _ context: ModelContext) -> Episode? {
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// A setting's value, typed so the same settings always encode the same.
    enum SettingValue: Codable, Equatable {
        case bool(Bool), number(Double), text(String), numbers([Double])

        init?(_ any: Any) {
            switch any {
            case let v as Bool where CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID(): self = .bool(v)
            case let v as NSNumber: self = .number(v.doubleValue)
            case let v as String: self = .text(v)
            case let v as [Double]: self = .numbers(v)
            case let v as [NSNumber]: self = .numbers(v.map(\.doubleValue))
            default: return nil
            }
        }

        var object: Any {
            switch self {
            case .bool(let v): v
            case .number(let v): v
            case .text(let v): v
            case .numbers(let v): v
            }
        }
    }

    private static func settingsSnapshot(_ defaults: UserDefaults) -> [String: SettingValue]? {
        var values: [String: SettingValue] = [:]
        for key in settingKeys { if let raw = defaults.object(forKey: key), let value = SettingValue(raw) { values[key] = value } }
        return values.isEmpty ? nil : values
    }

    private static func applySettings(_ values: [String: SettingValue], _ defaults: UserDefaults) {
        for key in settingKeys { if let value = values[key] { defaults.set(value.object, forKey: key) } }
    }

    /// What this device last synced, per record: a digest and the time.
    final class Ledger {
        struct Entry: Codable { var digest: String?; var at: Date }
        private let defaults: UserDefaults
        private var all: [String: [String: Entry]]
        private static let key = "cloudRecords.ledger.v1"

        /// Pass 37: the ledger as last saved, so a save still queued for
        /// the settings store (`PreferenceWriter`) is what the next sync reads.
        /// Only for the app's own settings store; others (tests) are written
        /// and read directly.
        nonisolated(unsafe) private static var saved: [String: [String: Entry]]?

        init(defaults: UserDefaults) {
            self.defaults = defaults
            if defaults === UserDefaults.standard, let saved = Self.saved {
                all = saved
            } else {
                let decoder = JSONDecoder()
                all = defaults.data(forKey: Self.key).flatMap { try? decoder.decode([String: [String: Entry]].self, from: $0) } ?? [:]
            }
        }
        func ids(_ kind: Kind) -> Set<String> { Set(all[kind.rawValue]?.keys.map { $0 } ?? []) }
        func entry(_ kind: Kind, _ id: String) -> Entry? { all[kind.rawValue]?[id] }
        func set(_ kind: Kind, _ id: String, digest: String?, at: Date) { all[kind.rawValue, default: [:]][id] = Entry(digest: digest, at: at) }
        func remove(_ kind: Kind, _ id: String) { all[kind.rawValue]?[id] = nil }
        func save() {
            let data = try? JSONEncoder().encode(all)
            if defaults === UserDefaults.standard {
                Self.saved = all
                PreferenceWriter.set(data, forKey: Self.key)
            } else {
                defaults.set(data, forKey: Self.key)
            }
        }

        static func digest<Value: Encodable>(_ value: Value) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(value) else { return "" }
            // FNV-1a, 64 bits: a change detector, not security.
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
            return String(hash, radix: 16) + ":" + String(data.count)
        }
    }
}

extension NSUbiquitousKeyValueStore: CloudRecords.Store {
    func setData(_ data: Data?, forKey key: String) { set(data, forKey: key) }
}
