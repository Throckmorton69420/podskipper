import Foundation
import SwiftData
import Observation

// MARK: - Podcast

@Model
final class Podcast {
    @Attribute(.unique) var feedURL: String
    var title: String
    var author: String
    var summary: String
    var artworkURL: String?
    var category: String = ""
    var dateAdded: Date
    var lastRefreshed: Date?
    var publishedFeedURL: String?
    var lastPublished: Date?

    // Per-show settings, all optional overrides of the global default
    var autoSkipEnabled: Bool?
    var playbackSpeedOverride: Double?
    var skipIntroSeconds: Double = 0
    var skipOutroSeconds: Double = 0
    var autoDownloadNew: Bool = false
    var autoQueueNew: Bool = true
    var notifyOnNewEpisodes: Bool = false
    /// 0 normal, 1 high, -1 low. Drives ordering in the library and the queue.
    var priority: Int = 0
    var isArchived: Bool = false
    var newestFirst: Bool = true
    /// nil means "use the global default". Apple Podcasts calls this
    /// "Remove Played Downloads" and keeps it per show.
    var removePlayedDownloads: Bool?

    // Per-show audio. Every one of these is optional: nil means "use whatever
    // the app default is", which is the Default / Custom split Apple Podcasts
    // uses for its own per-show playback settings.
    var voiceBoostOverride: Bool?
    var smartSpeedOverride: Bool?
    var volumeNormalizationOverride: Bool?
    /// Trim silences more or less aggressively for this show than the default.
    var smartSpeedAmountOverride: Double?
    /// Detect and skip the recurring intro and outro using the transcript,
    /// rather than the fixed second counts above. nil follows the default.
    var skipIntroOutroOverride: Bool?
    /// The show selling its own Patreon, merch or tour. Some people want
    /// their favourite show's tour dates and want the mattress ad gone, so
    /// this is a separate switch from `autoSkipEnabled`.
    var skipSelfPromoOverride: Bool?
    /// Plugs for other podcasts.
    var skipCrossPromoOverride: Bool?

    /// Brands this show has read ads for before.
    ///
    /// A show reads the same handful of sponsors for months. Recognising one
    /// is far more reliable than working it out from the words again every
    /// week, so each episode's findings are folded back in here and handed to
    /// the detector next time.
    var knownSponsors: [String] = []

    @Relationship(deleteRule: .cascade, inverse: \Episode.podcast)
    var episodes: [Episode] = []

    init(feedURL: String, title: String, author: String = "", summary: String = "",
         artworkURL: String? = nil, category: String = "") {
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.summary = summary
        self.artworkURL = artworkURL
        self.category = category
        self.dateAdded = .now
    }

    var sortedEpisodes: [Episode] {
        newestFirst
            ? episodes.sorted { $0.publishedAt > $1.publishedAt }
            : episodes.sorted { $0.publishedAt < $1.publishedAt }
    }


    var priorityLabel: String {
        switch priority {
        case 1:  return "High"
        case -1: return "Low"
        default: return "Normal"
        }
    }
}

// Kept out of the `@Model` body deliberately: the macro rewrites everything it
// finds in the class itself, and these carry attributes it has no reason to
// see. An extension is invisible to it.
extension Podcast {

    /// These three walk the whole episode relationship, and they are read from
    /// inside list rows that SwiftUI re-evaluates constantly. `CountsCache`
    /// memoises them for a fraction of a second and is invalidated by every
    /// mutation site, so the badges stay correct without the repeated walk.
    @MainActor
    var unplayedCount: Int { CountsCache.counts(for: self).unplayed }

    @MainActor
    var readyCount: Int { CountsCache.counts(for: self).ready }

    @MainActor
    var publishedCount: Int { CountsCache.counts(for: self).published }

    /// Episode order, named the way Apple Podcasts names it rather than as a
    /// bare "Newest First" switch.
    var episodeOrder: EpisodeOrder {
        get { newestFirst ? .newestToOldest : .oldestToNewest }
        set { newestFirst = (newValue == .newestToOldest) }
    }

    /// Resolve a per-show override against the app default.
    func resolved(_ override: Bool?, default fallback: Bool) -> Bool {
        override ?? fallback
    }

    /// The show description with its HTML removed.
    ///
    /// Feeds put markup in `<description>`, so the show page was rendering a
    /// literal `<p>` in front of every summary. Episodes already had this via
    /// `plainDescription`; shows never did.
    var plainSummary: String {
        if let cached = DerivedCache.summaries[feedURL] { return cached }
        let result = HTMLText.strip(summary)
        DerivedCache.summaries[feedURL] = result
        return result
    }
}

// MARK: - Episode

@Model
final class Episode {
    @Attribute(.unique) var guid: String
    var title: String
    var episodeDescription: String
    var audioURL: String
    var publishedAt: Date
    var duration: Double
    var artworkURL: String?
    var seasonNumber: Int = 0
    var episodeNumber: Int = 0
    /// The enclosure's MIME type. Empty for everything that existed before
    /// video was supported, which is correct: they are all audio.
    var mediaType: String = ""

    // Local state
    var localFilename: String?
    /// Set when a video episode's audio has been pulled out into its own
    /// file, because transcription and the silence pass read audio only.
    var extractedAudioFilename: String?
    var playbackPosition: Double = 0
    var isPlayed: Bool = false
    var isArchived: Bool = false
    var isInQueue: Bool = false
    var queueOrder: Int = 0
    var lastPlayedAt: Date?
    var isStarred: Bool = false
    /// Seconds of the episode actually listened to, for stats.
    var secondsListened: Double = 0
    /// Quick per-episode override for intro and outro skipping, set from the
    /// player. nil falls through to the show, then to the app default.
    var skipIntroOutroOverride: Bool?

    // Processing
    var processingState: ProcessingState = ProcessingState.notStarted
    var transcriptText: String?
    /// Timed transcript, JSON-encoded, for the tap-to-seek transcript view.
    var transcriptData: Data?
    var lastProcessedAt: Date?
    var processingError: String?

    /// Silence stretches found during analysis, stored as flattened
    /// [start, end, start, end…]. Smart Speed shortens these at playback.
    var silenceData: Data?
    /// Gain multiplier that brings this episode to a common loudness.
    var normalizationGain: Double = 1.0

    // Publishing
    var publishedURL: String?
    var publishedByteCount: Int = 0
    var publishedDuration: Double = 0
    var publishedAdVersion: String?

    var podcast: Podcast?

    @Relationship(deleteRule: .cascade, inverse: \AdSegment.episode)
    var adSegments: [AdSegment] = []

    @Relationship(deleteRule: .cascade, inverse: \Chapter.episode)
    var chapters: [Chapter] = []

    init(guid: String, title: String, episodeDescription: String, audioURL: String,
         publishedAt: Date, duration: Double, artworkURL: String? = nil) {
        self.guid = guid
        self.title = title
        self.episodeDescription = episodeDescription
        self.audioURL = audioURL
        self.publishedAt = publishedAt
        self.duration = duration
        self.artworkURL = artworkURL
    }

    // MARK: Derived

    /// Every detected segment the user hasn't rejected, regardless of kind.
    ///
    /// Used where the question is "what did we find" — the timeline, the
    /// published feed, the counts. What actually gets jumped during playback
    /// is `skipRanges(settings:)`, which consults the per-kind switches.
    var skipRanges: [ClosedRange<Double>] {
        adSegments
            .filter { $0.userVerdict != .notAnAd }
            .map { $0.start...$0.end }
            .sorted { $0.lowerBound < $1.lowerBound }
    }

    /// The ranges to jump for this listener, right now.
    ///
    /// Each kind resolves episode → show → app default independently, so
    /// someone can keep their favourite show's tour dates and still lose the
    /// mattress ad in the same episode.
    func skipRanges(settings: AppSettings) -> [ClosedRange<Double>] {
        adSegments
            .filter { $0.userVerdict != .notAnAd && skips($0.kind, settings: settings) }
            .map { $0.start...$0.end }
            .sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Decoded once and kept. This used to run a JSON decode on every single
    /// render — including every tick of the playhead — which is most of why
    /// scrolling and playback stuttered.
    var silenceRanges: [ClosedRange<Double>] {
        if let cached = DerivedCache.silence[guid] { return cached }
        guard let silenceData,
              let flat = try? JSONDecoder().decode([Double].self, from: silenceData)
        else {
            DerivedCache.silence[guid] = []
            return []
        }
        let ranges = stride(from: 0, to: flat.count - 1, by: 2)
            .compactMap { flat[$0] < flat[$0 + 1] ? flat[$0]...flat[$0 + 1] : nil }
        DerivedCache.silence[guid] = ranges
        return ranges
    }

    func storeSilence(_ ranges: [ClosedRange<Double>]) {
        let flat = ranges.flatMap { [$0.lowerBound, $0.upperBound] }
        silenceData = try? JSONEncoder().encode(flat)
        DerivedCache.silence[guid] = ranges
    }

    var timedTranscript: [TimedLine] {
        if let cached = DerivedCache.transcript[guid] { return cached }
        guard let transcriptData,
              let lines = try? JSONDecoder().decode([TimedLine].self, from: transcriptData)
        else {
            DerivedCache.transcript[guid] = []
            return []
        }
        DerivedCache.transcript[guid] = lines
        return lines
    }

    func storeTranscript(_ lines: [TimedLine]) {
        transcriptData = try? JSONEncoder().encode(lines)
        DerivedCache.transcript[guid] = lines
    }

    var localFileURL: URL? {
        guard let localFilename else { return nil }
        return FileStore.episodesDirectory.appendingPathComponent(localFilename)
    }

    /// Whether the audio is on disk.
    ///
    /// This used to stat the filesystem on every read, and it is read from
    /// inside scrolling rows, filters and counts — hundreds of synchronous
    /// stats per frame. `FileIndex` answers the same question from a set that
    /// is built once and kept in step by whoever writes or deletes a file.
    var isDownloaded: Bool {
        guard let localFilename else { return false }
        return FileIndex.contains(localFilename)
    }

    var adSecondsRemoved: Double {
        adSegments.filter { $0.userVerdict != .notAnAd }.reduce(0) { $0 + $1.duration }
    }

    /// How much of the episode is left, ads already discounted.
    var remainingSeconds: Double {
        let total = duration > 0 ? duration : publishedDuration
        return max(0, total - playbackPosition - adSecondsRemoved)
    }

    var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, playbackPosition / duration)
    }

    /// Stripping HTML with four regex passes, on every render of every row in
    /// a scrolling list, is exactly as slow as it sounds. Done once now.
    var plainDescription: String {
        if let cached = DerivedCache.notes[guid] { return cached }
        let result = HTMLText.strip(episodeDescription)
        DerivedCache.notes[guid] = result
        return result
    }

    /// True when this episode is a video.
    ///
    /// The feed's declared type decides it, falling back to the file
    /// extension — plenty of feeds omit the type, and a few get it wrong.
    var isVideo: Bool {
        if mediaType.hasPrefix("video") { return true }
        if mediaType.hasPrefix("audio") { return false }
        let name = (localFilename ?? audioURL).lowercased()
        // Extension only after stripping any query string, or a URL ending
        // "?format=mp3&x=y.mp4" would read as video.
        let path = name.components(separatedBy: "?").first ?? name
        return ["mp4", "m4v", "mov", "webm"].contains { path.hasSuffix(".\($0)") }
    }

    /// The file the transcriber and the silence pass should read.
    ///
    /// For video that is the extracted audio track, because `AVAudioFile`
    /// cannot open an mp4 at all. For audio it is just the episode.
    var analysableFileURL: URL? {
        if let extractedAudioFilename {
            return FileStore.episodesDirectory.appendingPathComponent(extractedAudioFilename)
        }
        return localFileURL
    }

    /// Episode beats show beats app default.
    ///
    /// Three scopes, resolved in one place so the player, the show sheet and
    /// Settings can never disagree about what is actually in effect.
    func skipsIntroOutro(default fallback: Bool) -> Bool {
        if let mine = skipIntroOutroOverride { return mine }
        if let show = podcast, let theirs = show.skipIntroOutroOverride { return theirs }
        return fallback
    }

    func skipsAds(default fallback: Bool) -> Bool {
        // Flattened by hand. The show's value is itself optional, so a single
        // ?? against a Bool would infer Bool? and not match the return type.
        let showPreference: Bool? = podcast.flatMap { $0.autoSkipEnabled }
        return showPreference ?? fallback
    }

    func skipsSelfPromotion(default fallback: Bool) -> Bool {
        let showPreference: Bool? = podcast.flatMap { $0.skipSelfPromoOverride }
        return showPreference ?? fallback
    }

    func skipsCrossPromotion(default fallback: Bool) -> Bool {
        let showPreference: Bool? = podcast.flatMap { $0.skipCrossPromoOverride }
        return showPreference ?? fallback
    }

    /// The single place that decides whether a detected segment gets cut.
    ///
    /// Every kind resolves episode → show → app default through its own
    /// three-scope accessor, so the player, the episode menu, the show sheet
    /// and Settings cannot disagree about what is in effect.
    func skips(_ kind: SegmentKind, settings: AppSettings) -> Bool {
        switch kind {
        case .ad:
            return skipsAds(default: settings.autoSkipEnabled)
        case .selfPromo:
            return skipsSelfPromotion(default: settings.skipSelfPromo)
        case .crossPromo:
            return skipsCrossPromotion(default: settings.skipCrossPromo)
        case .intro, .outro:
            return skipsIntroOutro(default: settings.skipIntroOutro)
        }
    }
}

// MARK: - HTML

/// Turns the markup podcast feeds put in their descriptions into plain text.
///
/// Shared by episodes and shows. Feeds are inconsistent about this: some send
/// clean text, some send a full HTML document, and plenty send a single
/// `<p>…</p>` that used to be printed verbatim.
enum HTMLText {

    static func strip(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        var text = html

        // Block-level tags become line breaks before everything else is
        // dropped, otherwise paragraphs run together into one wall of text.
        for pattern in ["<br\\s*/?>", "</p\\s*>", "</div\\s*>", "</li\\s*>"] {
            text = text.replacingOccurrences(of: pattern, with: "\n",
                                             options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<li\\s*[^>]*>", with: "• ",
                                         options: [.regularExpression, .caseInsensitive])
        // Anything inside a script or style block is not readable content.
        text = text.replacingOccurrences(of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>", with: "",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        text = decodeEntities(text)

        // Collapse the runs of blank lines the tag removal leaves behind.
        text = text.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedEntities: [String: String] = [
        "&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&apos;": "'",
        "&lt;": "<", "&gt;": ">", "&hellip;": "…", "&mdash;": "—",
        "&ndash;": "–", "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}",
        "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}", "&bull;": "•",
        "&trade;": "™", "&copy;": "©", "&reg;": "®", "&deg;": "°"
    ]

    private static func decodeEntities(_ input: String) -> String {
        var text = input
        for (entity, replacement) in namedEntities {
            text = text.replacingOccurrences(of: entity, with: replacement,
                                             options: .caseInsensitive)
        }
        guard text.contains("&#") else { return text }

        // Numeric entities, decimal and hex: &#8217; and &#x2019;
        var output = ""
        output.reserveCapacity(text.count)
        var remainder = Substring(text)
        while let start = remainder.range(of: "&#") {
            output += remainder[remainder.startIndex..<start.lowerBound]
            let afterMarker = remainder[start.upperBound...]
            guard let semicolon = afterMarker.firstIndex(of: ";") else {
                output += remainder[start.lowerBound...]
                return output
            }
            let digits = afterMarker[afterMarker.startIndex..<semicolon]
            let isHex = digits.first == "x" || digits.first == "X"
            let number = isHex ? digits.dropFirst() : digits
            if let value = UInt32(number, radix: isHex ? 16 : 10),
               let scalar = Unicode.Scalar(value) {
                output.append(Character(scalar))
            } else {
                output += remainder[start.lowerBound...semicolon]
            }
            remainder = afterMarker[afterMarker.index(after: semicolon)...]
        }
        output += remainder
        return output
    }
}

struct TimedLine: Codable, Hashable, Identifiable {
    var text: String
    var start: Double
    var end: Double
    var id: Double { start }
}

/// Small in-memory caches for values that are expensive to derive and never
/// change unless the episode is re-processed.
enum DerivedCache {
    nonisolated(unsafe) static var silence: [String: [ClosedRange<Double>]] = [:]
    nonisolated(unsafe) static var transcript: [String: [TimedLine]] = [:]
    nonisolated(unsafe) static var notes: [String: String] = [:]
    nonisolated(unsafe) static var summaries: [String: String] = [:]

    static func clear(_ guid: String) {
        silence[guid] = nil
        transcript[guid] = nil
        notes[guid] = nil
    }
}

enum ProcessingState: String, Codable {
    case notStarted, downloading, transcribing, detecting, analyzing, ready, failed
}

enum EpisodeOrder: String, CaseIterable, Identifiable {
    case newestToOldest = "Newest to Oldest"
    case oldestToNewest = "Oldest to Newest"
    var id: String { rawValue }
}

// MARK: - Ad segment

@Model
final class AdSegment {
    var start: Double
    var end: Double
    var sponsor: String
    var confidence: Int
    var userVerdict: UserVerdict = UserVerdict.unreviewed
    /// Stored as a string so an unrecognised value from a future version
    /// reads back as an ad rather than failing to load the store at all.
    var kindRaw: String = SegmentKind.ad.rawValue
    var episode: Episode?

    init(start: Double, end: Double, sponsor: String = "",
         confidence: Int = 0, kind: SegmentKind = .ad) {
        self.start = start
        self.end = end
        self.sponsor = sponsor
        self.confidence = confidence
        self.kindRaw = kind.rawValue
    }

    var kind: SegmentKind {
        get { SegmentKind(rawValue: kindRaw) ?? .ad }
        set { kindRaw = newValue.rawValue }
    }

    var duration: Double { max(0, end - start) }
}

enum UserVerdict: String, Codable {
    case unreviewed, confirmed, notAnAd
}

/// What a detected stretch of audio actually is.
///
/// The app used to have one bucket, "ad", and a host spending four minutes on
/// their own tour dates went straight through it — which is the thing you
/// most want cut on a comedy show. Separating the kinds is what lets each one
/// have its own switch.
enum SegmentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A paid third-party spot.
    case ad
    /// The show selling its own things: Patreon, merch, tour, bonus feed.
    case selfPromo
    /// A plug for somebody else's podcast.
    case crossPromo
    /// The opening of the episode itself.
    case intro
    /// The sign-off and credits.
    case outro

    var id: String { rawValue }

    var name: String {
        switch self {
        case .ad:         return "Ads"
        case .selfPromo:  return "Self-Promotion"
        case .crossPromo: return "Other Shows"
        case .intro:      return "Intros"
        case .outro:      return "Outros"
        }
    }

    /// Singular, for labelling one segment on the timeline.
    var label: String {
        switch self {
        case .ad:         return "Ad"
        case .selfPromo:  return "Promo"
        case .crossPromo: return "Other Show"
        case .intro:      return "Intro"
        case .outro:      return "Outro"
        }
    }

    var detail: String {
        switch self {
        case .ad:         return "Paid sponsor reads, including host-read ones."
        case .selfPromo:  return "Patreon, merch, tour dates, bonus feeds, the hosts' other projects."
        case .crossPromo: return "Plugs for podcasts that aren't theirs."
        case .intro:      return "The theme and the opening of the episode."
        case .outro:      return "The sign-off, thanks and credits."
        }
    }

    var symbol: String {
        switch self {
        case .ad:         return "megaphone"
        case .selfPromo:  return "heart.text.square"
        case .crossPromo: return "arrow.triangle.branch"
        case .intro:      return "text.line.first.and.arrowtriangle.forward"
        case .outro:      return "text.line.last.and.arrowtriangle.forward"
        }
    }

    /// The kinds that get their own switch in Settings, in the order they
    /// appear there. Intro and outro share one, because nobody wants to skip
    /// one and keep the other.
    static var switchable: [SegmentKind] { [.ad, .selfPromo, .crossPromo, .intro] }

    /// Maps whatever the model returned onto a case, tolerantly.
    init?(modelLabel: String) {
        switch modelLabel.lowercased().replacingOccurrences(of: " ", with: "") {
        case "advertisement", "ad", "advert":         self = .ad
        case "selfpromotion", "selfpromo":            self = .selfPromo
        case "crosspromotion", "crosspromo":          self = .crossPromo
        case "introduction", "intro":                 self = .intro
        case "outro", "outroorcredits", "credits":    self = .outro
        default:                                      return nil   // content
        }
    }
}

// MARK: - File storage

enum FileStore {
    /// Resolved once. The old version called `createDirectory` on every access,
    /// and `localFileURL` reads this — so every episode row was issuing a
    /// filesystem call just to build a path.
    nonisolated(unsafe) private static var cachedDirectory: URL?
    private static let directoryLock = NSLock()

    static var episodesDirectory: URL {
        directoryLock.lock()
        defer { directoryLock.unlock() }
        if let cachedDirectory { return cachedDirectory }
        let base = URL.applicationSupportDirectory
            .appendingPathComponent("Episodes", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        cachedDirectory = base
        return base
    }

    /// Delete one episode's audio and keep `FileIndex` in step.
    @discardableResult
    static func deleteAudio(named filename: String) -> Bool {
        let url = episodesDirectory.appendingPathComponent(filename)
        let removed = (try? FileManager.default.removeItem(at: url)) != nil
        FileIndex.remove(filename)

        // A video episode leaves an extracted audio track beside it. Deleting
        // the video and keeping that would quietly hold onto a second copy of
        // every video you ever played.
        let companion = MediaExtractor.audioFilename(for: filename)
        if companion != filename {
            let companionURL = episodesDirectory.appendingPathComponent(companion)
            try? FileManager.default.removeItem(at: companionURL)
            FileIndex.remove(companion)
        }
        return removed
    }
}

// MARK: - Settings

@Observable
final class AppSettings {

    // Ad skipping
    var autoSkipEnabled: Bool { didSet { save(autoSkipEnabled, "autoSkip") } }
    var minimumConfidence: Int { didSet { save(minimumConfidence, "minConfidence") } }
    var boundaryPadding: Double { didSet { save(boundaryPadding, "padding") } }
    /// Find the show's recurring opening and closing from the transcript and
    /// jump them, rather than trimming a fixed number of seconds.
    var skipIntroOutro: Bool { didSet { save(skipIntroOutro, "skipIntroOutro") } }
    /// The show's own Patreon, merch, tour dates and bonus feed. On by
    /// default: to a listener this is an ad, and it is the one the old
    /// single-bucket detector waved straight through.
    var skipSelfPromo: Bool { didSet { save(skipSelfPromo, "skipSelfPromo") } }
    /// Plugs for other people's podcasts.
    var skipCrossPromo: Bool { didSet { save(skipCrossPromo, "skipCrossPromo") } }

    // Processing
    var processOnlyWhileCharging: Bool { didSet { save(processOnlyWhileCharging, "chargingOnly") } }
    var autoQueueNewEpisodes: Bool { didSet { save(autoQueueNewEpisodes, "autoQueue") } }
    var analyzeSilence: Bool { didSet { save(analyzeSilence, "analyzeSilence") } }

    // Playback
    var defaultPlaybackSpeed: Double { didSet { save(defaultPlaybackSpeed, "speed") } }
    var seekForwardSeconds: Double { didSet { save(seekForwardSeconds, "seekFwd") } }
    var seekBackwardSeconds: Double { didSet { save(seekBackwardSeconds, "seekBack") } }
    var continuousPlayback: Bool { didSet { save(continuousPlayback, "continuous") } }
    var markPlayedAtEnd: Bool { didSet { save(markPlayedAtEnd, "markPlayed") } }

    // Audio effects
    var smartSpeedEnabled: Bool { didSet { save(smartSpeedEnabled, "smartSpeed") } }
    /// Fraction of each silence that gets removed. 1.0 strips it entirely.
    var smartSpeedAggressiveness: Double { didSet { save(smartSpeedAggressiveness, "smartSpeedAmount") } }
    var voiceBoostEnabled: Bool { didSet { save(voiceBoostEnabled, "voiceBoost") } }
    var volumeNormalizationEnabled: Bool { didSet { save(volumeNormalizationEnabled, "normalize") } }
    var deEsserEnabled: Bool { didSet { save(deEsserEnabled, "deEsser") } }
    var rumbleFilterEnabled: Bool { didSet { save(rumbleFilterEnabled, "rumble") } }
    var monoDownmix: Bool { didSet { save(monoDownmix, "mono") } }
    var equalizerEnabled: Bool { didSet { save(equalizerEnabled, "eqOn") } }
    var equalizerPreset: String { didSet { save(equalizerPreset, "eqPreset") } }
    /// Ten band gains in dB, low to high.
    var equalizerGains: [Double] {
        didSet { UserDefaults.standard.set(equalizerGains, forKey: "eqGains") }
    }

    // Downloads
    /// Gigabytes of episode audio to keep before the oldest played ones are
    /// deleted. 0 means never clean up.
    var storageLimitGB: Double { didSet { save(storageLimitGB, "storageLimit") } }
    var deletePlayedAfterDays: Int { didSet { save(deletePlayedAfterDays, "deletePlayed") } }
    /// Delete the audio as soon as an episode is marked played. Default for
    /// shows that haven't set their own preference.
    var removePlayedDownloads: Bool { didSet { save(removePlayedDownloads, "removePlayed") } }

    // Notifications
    var notificationsEnabled: Bool { didSet { save(notificationsEnabled, "notify") } }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "autoSkip": true, "minConfidence": 60, "padding": 0.4,
            "skipIntroOutro": true,
            // On by default. Off by default would mean the thing the user
            // actually complained about — four minutes of tour dates — still
            // plays until they go looking for a switch.
            "skipSelfPromo": true,
            "skipCrossPromo": true,
            "chargingOnly": true, "autoQueue": true, "analyzeSilence": true,
            "speed": 1.0, "seekFwd": 30.0, "seekBack": 15.0,
            "continuous": true, "markPlayed": true,
            "smartSpeed": false, "smartSpeedAmount": 0.7,
            "voiceBoost": false, "normalize": true, "deEsser": false,
            "rumble": true, "mono": false, "eqOn": false, "eqPreset": "Flat",
            "notify": false, "storageLimit": 8.0, "deletePlayed": 7,
            "removePlayed": false
        ])
        autoSkipEnabled = d.bool(forKey: "autoSkip")
        minimumConfidence = d.integer(forKey: "minConfidence")
        boundaryPadding = d.double(forKey: "padding")
        skipIntroOutro = d.bool(forKey: "skipIntroOutro")
        skipSelfPromo = d.bool(forKey: "skipSelfPromo")
        skipCrossPromo = d.bool(forKey: "skipCrossPromo")
        processOnlyWhileCharging = d.bool(forKey: "chargingOnly")
        autoQueueNewEpisodes = d.bool(forKey: "autoQueue")
        analyzeSilence = d.bool(forKey: "analyzeSilence")
        defaultPlaybackSpeed = d.double(forKey: "speed")
        seekForwardSeconds = d.double(forKey: "seekFwd")
        seekBackwardSeconds = d.double(forKey: "seekBack")
        continuousPlayback = d.bool(forKey: "continuous")
        markPlayedAtEnd = d.bool(forKey: "markPlayed")
        smartSpeedEnabled = d.bool(forKey: "smartSpeed")
        smartSpeedAggressiveness = d.double(forKey: "smartSpeedAmount")
        voiceBoostEnabled = d.bool(forKey: "voiceBoost")
        volumeNormalizationEnabled = d.bool(forKey: "normalize")
        deEsserEnabled = d.bool(forKey: "deEsser")
        rumbleFilterEnabled = d.bool(forKey: "rumble")
        monoDownmix = d.bool(forKey: "mono")
        equalizerEnabled = d.bool(forKey: "eqOn")
        equalizerPreset = d.string(forKey: "eqPreset") ?? "Flat"
        equalizerGains = (d.array(forKey: "eqGains") as? [Double]) ?? EQPreset.flat.gains
        storageLimitGB = d.double(forKey: "storageLimit")
        deletePlayedAfterDays = d.integer(forKey: "deletePlayed")
        removePlayedDownloads = d.bool(forKey: "removePlayed")
        notificationsEnabled = d.bool(forKey: "notify")
    }
}

// MARK: - Equalizer presets

struct EQPreset: Identifiable, Hashable {
    let name: String
    let gains: [Double]
    var id: String { name }

    /// Ten ISO bands: 32, 64, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz.
    static let flat        = EQPreset(name: "Flat",          gains: Array(repeating: 0, count: 10))
    static let voice       = EQPreset(name: "Voice",         gains: [-4, -3, -1,  1,  2,  3,  4,  3,  0, -2])
    static let podcast     = EQPreset(name: "Podcast",       gains: [-6, -4, -1,  0,  1,  2,  3,  2, -1, -3])
    static let bassReduce  = EQPreset(name: "Bass Reduce",   gains: [-8, -6, -4, -2,  0,  0,  0,  0,  0,  0])
    static let trebleBoost = EQPreset(name: "Treble Boost",  gains: [ 0,  0,  0,  0,  0,  1,  2,  4,  5,  4])
    static let night       = EQPreset(name: "Night",         gains: [-5, -4, -2,  0,  2,  3,  3,  1, -1, -3])

    static let all: [EQPreset] = [flat, voice, podcast, bassReduce, trebleBoost, night]
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    static func named(_ name: String) -> EQPreset { all.first { $0.name == name } ?? flat }
}
