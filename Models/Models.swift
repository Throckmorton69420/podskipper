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
    /// Hosts named in the feed, "role:Name" joined with "|".
    var people: String = ""
    var dateAdded: Date
    var lastRefreshed: Date?
    /// When the whole feed was last merged in by `LibraryIndex`. Nil means the
    /// back catalogue has not been indexed yet.
    var catalogueIndexedAt: Date?
    var publishedFeedURL: String?
    var lastPublished: Date?

    /// The last time this show's episode list was on screen.
    ///
    /// This is what makes "new" mean something. The library used to label every
    /// show with its unplayed count, so following a show with a back catalogue
    /// said "100 new" — technically true and completely useless, since none of
    /// it was new, it was just old and unheard. Counting against the last time
    /// you looked gives the number back its meaning: three episodes have
    /// arrived since you were last here.
    var lastSeenAt: Date?

    /// Which episode filter this show is showing.
    ///
    /// Stored here rather than in the view, because SwiftUI discards a view's
    /// `@State` when it leaves the navigation stack — which is exactly why
    /// choosing "Unplayed" and coming back a minute later silently put you on
    /// "All Episodes" again. It is the show's setting, so it lives on the show.
    var episodeFilter: String = "All Episodes"
    /// Apple's "Hide Played Episodes", per show.
    var hidePlayed: Bool = false
    /// The show's official YouTube channel ID (UC…), for "Watch on YouTube".
    var youtubeChannel: String = ""

    // MARK: - Freshness

    /// What the library row says under the title. Both halves come from the
    /// background count (see `LibraryIndex`) — worked out here, each tile
    /// walked its show's every episode three times per redraw.
    ///
    /// Apple leads with the date and treats the count as a suffix, which is the
    /// right way round: the date is always meaningful, the count often is not.
    /// The separator is the one Apple uses in this exact position — a middle
    /// dot with three-per-em spaces around it, not a plain space, which reads
    /// noticeably tighter at small sizes.
    @MainActor
    var freshnessLine: String {
        guard let updated = lastUpdatedAt else { return "No episodes yet" }
        let when = RelativeDate.short(updated)
        let count = newSinceLastSeen
        guard count > 0 else { return when }
        return "\(when)\u{2004}·\u{2004}\(count) new"
    }

    /// Record that the list has been seen. Called when a show page appears.
    func markSeen() { lastSeenAt = .now }

    // Per-show settings, all optional overrides of the global default
    var autoSkipEnabled: Bool?
    var playbackSpeedOverride: Double?
    var skipIntroSeconds: Double = 0
    var skipOutroSeconds: Double = 0
    var autoDownloadNew: Bool = false
    /// Automatic download rule for this show. nil follows the app default.
    /// Stored as raw strings so adding a choice later is not a migration.
    var autoDownloadModeRaw: String?
    var autoDownloadLimitRaw: String?
    /// Find ads in what was downloaded, straight away. nil follows the default.
    var autoDownloadFindAds: Bool?
    /// Skip anything shorter than this many minutes — trailers, bonus clips.
    var autoDownloadMinMinutes: Int = 0
    /// Skip titles containing any of these, comma-separated.
    var autoDownloadExcludeWords: String = ""
    /// When "Only New" was switched on, so it means new from then.
    var autoDownloadSince: Date?
    var autoQueueNew: Bool = true
    var notifyOnNewEpisodes: Bool = false
    /// 0 normal, 1 high, -1 low. Drives ordering in the library and the queue.
    var priority: Int = 0
    var isArchived: Bool = false
    var newestFirst: Bool = true
    /// nil means "use the global default". Apple Podcasts calls this
    /// "Remove Played Downloads" and keeps it per show.
    var removePlayedDownloads: Bool?
    /// Publish each episode to this show's ad-free feed as soon as its ads
    /// have been found.
    var autoPublish: Bool = false

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
    ///
    /// Superseded by the two separate switches below, and kept because it is
    /// what existing shows have stored. It is still consulted, after them.
    var skipIntroOutroOverride: Bool?
    /// The cold open alone. nil follows the combined switch, then the default.
    var skipIntroOverride: Bool?
    /// The closing alone.
    var skipOutroOverride: Bool?
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

    /// What the listener has told us we got wrong — or right — on this show.
    ///
    /// The thumbs on the "what was skipped" page used to be close to
    /// decoration: a thumbs-down set `userVerdict` on one segment, which
    /// stopped that one segment being skipped in that one episode, and nothing
    /// carried into next week. This is where a correction is kept so it can be
    /// handed to the detector the next time this show is processed, exactly the
    /// way `knownSponsors` already is — and that mechanism demonstrably works,
    /// which is the argument for reusing it rather than inventing something.
    ///
    /// Optional `Data` rather than an array of a model type, so an older store
    /// opens without a migration.
    var correctionData: Data?

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

    /// What the listener has corrected on this show, newest last.
    var corrections: [DetectionCorrection] {
        guard let correctionData,
              let decoded = try? JSONDecoder().decode([DetectionCorrection].self,
                                                      from: correctionData)
        else { return [] }
        return decoded
    }

    /// Records one correction, replacing any earlier one about the same words.
    ///
    /// Capped at twenty-four. These are going into a prompt, and a prompt that
    /// grows without limit eventually crowds out the passage being judged —
    /// which would make the feedback actively harmful rather than merely
    /// useless. The newest survive.
    func recordCorrection(_ correction: DetectionCorrection) {
        guard !correction.excerpt.isEmpty else { return }
        var all = corrections.filter { $0.excerpt != correction.excerpt }
        all.append(correction)
        // Passages and edge lessons are capped separately, so a run of
        // handle drags can't push out the show's worked examples.
        let passages = all.filter { $0.boundary == nil }.suffix(24)
        let edges = all.filter { $0.boundary != nil }.suffix(16)
        all = (Array(passages) + Array(edges)).sorted { $0.addedAt < $1.addedAt }
        correctionData = try? JSONEncoder().encode(all)
    }

    func forgetCorrection(excerpt: String) {
        let key = DetectionCorrection.normalise(excerpt)
        let all = corrections.filter { $0.excerpt != key }
        correctionData = all.isEmpty ? nil : (try? JSONEncoder().encode(all))
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

    /// Episodes published since the last time this show was opened.
    @MainActor
    var newSinceLastSeen: Int { CountsCache.counts(for: self).newSinceSeen }

    /// When the feed last had something new in it.
    @MainActor
    var lastUpdatedAt: Date? { CountsCache.counts(for: self).newest }

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
    /// A separate video version of this episode, when the feed offers one
    /// (`podcast:alternateEnclosure`). Nil for most feeds: the video Apple
    /// Podcasts shows for big shows is delivered to Apple privately and is
    /// not in the public feed any app can read.
    var videoURL: String?
    /// A picture found somewhere other than the feed (see
    /// `VideoSourceResolver`): today, a host's own open HLS stream that
    /// Apple's public episode page links to. Used only when the feed has none.
    var publicVideoURL: String?
    /// Which source the picture comes from: "rssHLS", "rssFile", "publicHLS",
    /// "youtube", or empty when nothing has been looked for.
    var videoSourceRaw: String = ""
    /// The matching upload on the show's YouTube channel, when one was found.
    var youtubeVideoID: String?
    /// When the resolver last looked, so it doesn't ask again every play.
    var videoResolvedAt: Date?
    /// People named on the episode, "role:Name" joined with "|".
    var people: String = ""
    /// The feed's `itunes:explicit`, for the episode or, failing that, the show.
    var isExplicit: Bool = false
    /// `itunes:episodeType`: "full" (or empty), "bonus" or "trailer".
    var episodeType: String = ""

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
    /// Downloaded by a rule rather than by hand, so the rule may also remove it.
    var wasAutoDownloaded: Bool = false
    /// Seconds of the episode actually listened to, for stats.
    var secondsListened: Double = 0
    /// Quick per-episode override for intro and outro skipping, set from the
    /// player. nil falls through to the show, then to the app default.
    var skipIntroOutroOverride: Bool?
    /// Per-episode override for the cold open alone.
    var skipIntroOverride: Bool?
    /// Per-episode override for the closing alone.
    var skipOutroOverride: Bool?

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
            .filter { $0.userVerdict != .notAnAd && skips($0.kind, settings: settings)
                      && !$0.keptByDelivery(settings) }
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
            DerivedCache.rememberTranscript([], for: guid)
            return []
        }
        DerivedCache.rememberTranscript(lines, for: guid)
        return lines
    }

    /// Decodes the transcript off the main thread and caches it, so the first
    /// view to show it doesn't. With word times a two-hour transcript is
    /// several megabytes of JSON, and decoding it where it was first read —
    /// in a view's body — held the screen while it did.
    @MainActor
    func prewarmTranscript() {
        guard DerivedCache.transcript[guid] == nil, let data = transcriptData else { return }
        let guid = self.guid
        Task.detached(priority: .utility) {
            let lines = (try? JSONDecoder().decode([TimedLine].self, from: data)) ?? []
            await MainActor.run {
                if DerivedCache.transcript[guid] == nil { DerivedCache.rememberTranscript(lines, for: guid) }
            }
        }
    }

    /// Ads that were stitched into the audio rather than read by the host —
    /// the ones a video version of the same episode usually doesn't have.
    var insertedAdRanges: [(start: Double, end: Double)] {
        adSegments
            .filter { $0.kind == .ad && $0.deliveryRaw != "host" && $0.userVerdict != .notAnAd }
            .map { (start: $0.start, end: $0.end) }
            .sorted { $0.start < $1.start }
    }

    func storeTranscript(_ lines: [TimedLine], encoded: Data? = nil) {
        transcriptData = encoded ?? (try? JSONEncoder().encode(lines))
        DerivedCache.rememberTranscript(lines, for: guid)
    }

    /// The transcript lines that overlap a stretch of the episode. Lines are
    /// in time order, so this halves to the first candidate rather than
    /// filtering thousands of lines for a stretch of a few seconds.
    func lines(in range: ClosedRange<Double>) -> [TimedLine] {
        let all = timedTranscript
        guard !all.isEmpty else { return [] }
        // First line starting within a minute before the stretch: a line is
        // never longer than that, so nothing overlapping starts earlier.
        let from = range.lowerBound - 60
        var low = 0, high = all.count
        while low < high {
            let mid = (low + high) / 2
            if all[mid].start < from { low = mid + 1 } else { high = mid }
        }
        var out: [TimedLine] = []
        var i = low
        while i < all.count, all[i].start < range.upperBound {
            if all[i].end > range.lowerBound { out.append(all[i]) }
            i += 1
        }
        return out
    }

    /// What was said inside a stretch, as one string. Empty for music or
    /// silence, which is a useful thing to be able to tell.
    /// The picture to play: the feed's own, else one the resolver found.
    var pictureURL: String? { videoURL ?? publicVideoURL }

    /// The words spoken in a stretch, cut at word times when the transcript
    /// has them (pass 13 onward) and at line edges when it doesn't.
    func exactWords(in range: ClosedRange<Double>) -> [String] {
        var out: [String] = []
        for line in lines(in: range) {
            if let words = line.words, !words.isEmpty {
                out += words.filter { $0.end > range.lowerBound && $0.start < range.upperBound }.map(\.text)
            } else {
                out += line.text.split(separator: " ").map(String.init)
            }
        }
        return out
    }

    /// Nearest word edge to `time` within `reach` seconds: a start for a cut's
    /// start, an end for its end. Falls back to line edges.
    func snapToWord(_ time: Double, start: Bool, reach: Double = 0.4) -> Double {
        let lines = lines(in: (time - 3)...(time + 3))
        var edges: [Double] = []
        for line in lines {
            if let words = line.words, !words.isEmpty {
                edges += words.map { start ? $0.start : $0.end }
            } else {
                edges.append(start ? line.start : line.end)
            }
        }
        guard let best = edges.min(by: { abs($0 - time) < abs($1 - time) }), abs(best - time) <= reach else { return time }
        return best
    }

    /// An edge moved by hand, as something the detector learns from.
    ///
    /// The words the listener cut away from an edge were lead-in or lead-out;
    /// the words they pulled in were part of it. Both are filed against the
    /// show as boundary lessons, which the edge questions read next time
    /// (see `SegmentDetector.lessons`). The corrected passage itself is filed
    /// as a confirmed example of its kind, as a thumbs-up would be: fixing a
    /// cut's edges says the cut was real.
    func recordEdit(_ segment: AdSegment, from old: ClosedRange<Double>) {
        guard let show = podcast else { return }
        func file(_ words: [String], _ boundary: String, keepLast: Bool) {
            let picked = keepLast ? Array(words.suffix(12)) : Array(words.prefix(12))
            guard picked.count >= 2 else { return }
            let correction = DetectionCorrection(excerpt: picked.joined(separator: " "), kind: segment.kind,
                                                 boundary: boundary)
            show.recordCorrection(correction)
        }
        // A cut the listener added started somewhere arbitrary; only its
        // finished passage says anything.
        if segment.isAdded {
        } else if segment.start > old.lowerBound + 0.3 {
            file(exactWords(in: old.lowerBound...segment.start), "outsideStart", keepLast: true)
        } else if segment.start < old.lowerBound - 0.3 {
            file(exactWords(in: segment.start...old.lowerBound), "insideStart", keepLast: false)
        }
        if segment.isAdded {
        } else if segment.end < old.upperBound - 0.3 {
            file(exactWords(in: segment.end...old.upperBound), "outsideEnd", keepLast: false)
        } else if segment.end > old.upperBound + 0.3 {
            file(exactWords(in: old.upperBound...segment.end), "insideEnd", keepLast: true)
        }
        let passage = words(in: segment.start...segment.end)
        if passage.count >= 12 {
            let correction = DetectionCorrection(excerpt: passage, kind: segment.kind)
            show.recordCorrection(correction)
            GlobalCorrections.record(correction)
        }
    }

    func words(in range: ClosedRange<Double>) -> String {
        lines(in: range).map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The single place a thumbs-up or thumbs-down is applied.
    ///
    /// It does two things, and the second is the one that was missing: it sets
    /// the verdict on this segment — which is what stops it being skipped in
    /// *this* episode — and it files the passage against the *show*, which is
    /// what makes the next episode of the same show come out differently.
    /// Every caller goes through here so the two cannot drift apart.
    func apply(_ verdict: UserVerdict, to segment: AdSegment) {
        segment.userVerdict = verdict
        guard let show = podcast else { return }
        let excerpt = words(in: segment.start...segment.end)
        // Nothing was said, so there is nothing to teach anyone with. The
        // verdict still applies to this episode.
        guard excerpt.count >= 12 else { return }
        switch verdict {
        case .notAnAd:
            let correction = DetectionCorrection(excerpt: excerpt, kind: nil)
            show.recordCorrection(correction)
            GlobalCorrections.record(correction)
        case .confirmed:
            let correction = DetectionCorrection(excerpt: excerpt, kind: segment.kind)
            show.recordCorrection(correction)
            GlobalCorrections.record(correction)
        case .unreviewed:
            show.forgetCorrection(excerpt: excerpt)
            GlobalCorrections.forget(excerpt: excerpt)
        }
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

    /// The cold open, resolved episode → show → app default.
    ///
    /// Split from the outro because they are separate decisions. Plenty of
    /// people want to lose a ninety-second theme and keep the credits, or the
    /// other way round; one switch for both made that impossible. The combined
    /// override still wins where someone set it, so nobody's existing choice
    /// silently changes meaning.
    func skipsIntro(default fallback: Bool) -> Bool {
        if let mine = skipIntroOverride { return mine }
        if let show = podcast, let theirs = show.skipIntroOverride { return theirs }
        if let mine = skipIntroOutroOverride { return mine }
        if let show = podcast, let theirs = show.skipIntroOutroOverride { return theirs }
        return fallback
    }

    /// The closing — credits, sign-off, next-week tease.
    func skipsOutro(default fallback: Bool) -> Bool {
        if let mine = skipOutroOverride { return mine }
        if let show = podcast, let theirs = show.skipOutroOverride { return theirs }
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
        case .intro:
            return skipsIntro(default: settings.skipIntro)
        case .outro:
            return skipsOutro(default: settings.skipOutro)
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
    /// Each word's own time, kept so that detecting again on a stored
    /// transcript can still cut mid-line. Nil for transcripts made before
    /// pass 13.
    var words: [TranscriptWord]? = nil
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
        transcriptOrder.removeAll { $0 == guid }
        notes[guid] = nil
    }

    /// Transcripts are kept for the few most recently used episodes, not for
    /// every episode opened in the session: with word times each can be
    /// megabytes.
    nonisolated(unsafe) private static var transcriptOrder: [String] = []
    static func rememberTranscript(_ lines: [TimedLine], for guid: String) {
        transcript[guid] = lines
        transcriptOrder.removeAll { $0 == guid }
        transcriptOrder.append(guid)
        while transcriptOrder.count > 4 {
            let oldest = transcriptOrder.removeFirst()
            transcript[oldest] = nil
        }
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
    /// "host" or "produced"; empty when unknown. See `AdDetector.classifyStyle`.
    var deliveryRaw: String = ""
    /// The host doing a bit with the ad rather than simply reading it.
    var isComedyBit: Bool = false

    // What the detector said, kept apart from what the listener made of it.
    // -1 / empty on segments made before pass 13, which read as "unchanged".
    var detectedStart: Double = -1
    var detectedEnd: Double = -1
    var detectedKindRaw: String = ""
    /// "detected", or "added" for a cut the listener made themselves.
    var origin: String = "detected"
    /// Locked: finding ads again never changes or removes it, and its edges
    /// can't be dragged by accident.
    var isLocked: Bool = false
    /// How sure the detector was about each edge, 0–100.
    var startConfidence: Int = 0
    var endConfidence: Int = 0
    /// Why it thinks this, in plain English, joined with " · ".
    var evidenceText: String = ""

    /// Not sure enough to be left alone: the listener is asked to look.
    var needsReview: Bool {
        guard !isReviewed else { return false }
        if confidence > 0, confidence < 70 { return true }
        let edges = [startConfidence, endConfidence].filter { $0 > 0 }
        return !edges.isEmpty && edges.min()! < 50
    }

    var originalStart: Double { detectedStart >= 0 ? detectedStart : start }
    var originalEnd: Double { detectedEnd >= 0 ? detectedEnd : end }
    var originalKind: SegmentKind { SegmentKind(rawValue: detectedKindRaw) ?? kind }
    var isAdded: Bool { origin == "added" }
    var isEdited: Bool {
        !isAdded && (abs(originalStart - start) > 0.05 || abs(originalEnd - end) > 0.05 || originalKind != kind)
    }
    /// Anything the listener has had a say in. Finding ads again keeps these.
    var isReviewed: Bool { isLocked || isAdded || isEdited || userVerdict != .unreviewed }

    /// One word for where this cut stands.
    var status: String {
        if isLocked { return "Locked" }
        if needsReview { return "Worth a look" }
        if userVerdict == .notAnAd { return "Rejected" }
        if isAdded { return "Added by you" }
        if isEdited { return "Edited" }
        if userVerdict == .confirmed { return "Confirmed" }
        return "Unreviewed"
    }

    /// Back to what the detector found.
    func revertToDetected() {
        start = originalStart
        end = originalEnd
        kind = originalKind
    }

    /// Kept by the listener's delivery settings, whatever its kind's switch.
    func keptByDelivery(_ settings: AppSettings) -> Bool {
        guard kind == .ad, userVerdict != .confirmed else { return false }
        if settings.keepComedyBitAds && isComedyBit { return true }
        if settings.keepHostReadAds && deliveryRaw == "host" { return true }
        return false
    }

    init(start: Double, end: Double, sponsor: String = "",
         confidence: Int = 0, kind: SegmentKind = .ad) {
        self.start = start
        self.end = end
        self.sponsor = sponsor
        self.confidence = confidence
        self.kindRaw = kind.rawValue
        self.detectedStart = start
        self.detectedEnd = end
        self.detectedKindRaw = kind.rawValue
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

    /// How eager detection is, in words rather than a number.
    ///
    /// "Minimum confidence: 60" told a listener nothing — it asked them to have
    /// an opinion about a machine-learning score. The three named settings mean
    /// exactly the same thing underneath, and the number is still there on the
    /// advanced screen for anyone who wants it.
    var detectionSensitivity: String { didSet { save(detectionSensitivity, "sensitivity") } }

    var minimumConfidence: Int { didSet { save(minimumConfidence, "minConfidence") } }
    var boundaryPadding: Double { didSet { save(boundaryPadding, "padding") } }

    /// The show's recurring opening, found from the transcript rather than
    /// trimmed as a fixed number of seconds.
    var skipIntro: Bool { didSet { save(skipIntro, "skipIntro") } }
    /// The closing. Separate from the intro because they are separate
    /// decisions: plenty of people want to lose the cold open and keep the
    /// credits, or the other way round.
    var skipOutro: Bool { didSet { save(skipOutro, "skipOutro") } }

    /// Both, for callers that do not care which. Setting it sets both.
    var skipIntroOutro: Bool {
        get { skipIntro || skipOutro }
        set { skipIntro = newValue; skipOutro = newValue }
    }
    /// The show's own Patreon, merch, tour dates and bonus feed. On by
    /// default: to a listener this is an ad, and it is the one the old
    /// single-bucket detector waved straight through.
    var skipSelfPromo: Bool { didSet { save(skipSelfPromo, "skipSelfPromo") } }
    /// Plugs for other people's podcasts.
    var skipCrossPromo: Bool { didSet { save(skipCrossPromo, "skipCrossPromo") } }
    /// Keep ads the host reads themselves; skip only produced spots.
    var keepHostReadAds: Bool { didSet { save(keepHostReadAds, "keepHostRead") } }
    /// Keep ad reads the host turns into a comedy bit.
    var keepComedyBitAds: Bool { didSet { save(keepComedyBitAds, "keepComedyBits") } }

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

    /// How many episodes ahead to download and find ads in while the current
    /// one plays, so autoplay does not stop to think. Zero switches it off.
    var preprocessAhead: Int { didSet { save(preprocessAhead, "preprocessAhead") } }

    /// The app-wide text and icon size, a `UIScale` step id. 0 is Default.
    var interfaceSize: Int { didSet { save(interfaceSize, UIScale.key) } }

    /// App-wide automatic download rule; shows can override it.
    var autoDownloadMode: String { didSet { save(autoDownloadMode, "autoDownloadMode") } }
    var autoDownloadLimit: String { didSet { save(autoDownloadLimit, "autoDownloadLimit") } }
    var autoDownloadFindAds: Bool { didSet { save(autoDownloadFindAds, "autoDownloadFindAds") } }
    /// Only over Wi-Fi.
    var autoDownloadWiFiOnly: Bool { didSet { save(autoDownloadWiFiOnly, "autoDownloadWiFi") } }

    /// What pressing play on an unprocessed episode does when nobody answers
    /// the prompt. Playing is the safe default: waiting for a transcription is
    /// never what someone who just pressed play wanted.
    var playUnprocessedByDefault: Bool { didSet { save(playUnprocessedByDefault, "playUnprocessed") } }

    /// Seconds the prompt waits before taking the default.
    var playPromptCountdown: Double { didSet { save(playPromptCountdown, "playPromptCountdown") } }

    /// What swiping the prompt away means. On: nothing plays — the swipe is
    /// how you say "not now". Off: a swipe plays it, as the countdown would.
    var promptSwipeCancels: Bool { didSet { save(promptSwipeCancels, "promptSwipeCancels") } }

    // Audio effects
    var smartSpeedEnabled: Bool { didSet { save(smartSpeedEnabled, "smartSpeed") } }
    /// Fraction of each silence that gets removed. 1.0 strips it entirely.
    var smartSpeedAggressiveness: Double { didSet { save(smartSpeedAggressiveness, "smartSpeedAmount") } }
    var voiceBoostEnabled: Bool { didSet { save(voiceBoostEnabled, "voiceBoost") } }
    var volumeNormalizationEnabled: Bool { didSet { save(volumeNormalizationEnabled, "normalize") } }
    var rumbleFilterEnabled: Bool { didSet { save(rumbleFilterEnabled, "rumble") } }

    // Speech repairs. Each is one band in the graph, switched and set
    // independently, and each is named for the problem it fixes rather than
    // the filter it uses — a listener knows a voice sounds harsh, not that
    // they want 6 dB off a bell at 7 kHz.

    /// Harsh S, SH and T sounds.
    var deEsserEnabled: Bool { didSet { save(deEsserEnabled, "deEsser") } }
    var deEsserStrength: Double { didSet { save(deEsserStrength, "deEsserAmount") } }

    /// Muddy, boxy, congested midrange.
    var mudReductionEnabled: Bool { didSet { save(mudReductionEnabled, "mudCut") } }
    var mudReductionStrength: Double { didSet { save(mudReductionStrength, "mudCutAmount") } }

    /// Boomy, chesty, bass-heavy voices.
    var bassReductionEnabled: Bool { didSet { save(bassReductionEnabled, "bassCut") } }
    var bassReductionStrength: Double { didSet { save(bassReductionStrength, "bassCutAmount") } }

    /// Muffled or distant voices — "talking into a pillow".
    var clarityEnabled: Bool { didSet { save(clarityEnabled, "clarity") } }
    var clarityStrength: Double { didSet { save(clarityStrength, "clarityAmount") } }

    /// Upper-mid glare that gets tiring over a long session.
    var harshnessReductionEnabled: Bool { didSet { save(harshnessReductionEnabled, "harshCut") } }
    var harshnessReductionStrength: Double { didSet { save(harshnessReductionStrength, "harshCutAmount") } }
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
            "sensitivity": DetectionSensitivity.balanced.rawValue,
            "skipIntro": true, "skipOutro": true,
            "preprocessAhead": 2,
            "autoDownloadMode": "off", "autoDownloadLimit": "recent3",
            "autoDownloadFindAds": true, "autoDownloadWiFi": true,
            "playUnprocessed": true, "playPromptCountdown": 5.0, "promptSwipeCancels": true,
            "deEsserAmount": 6.0, "mudCut": false, "mudCutAmount": 5.0,
            "bassCut": false, "bassCutAmount": 6.0,
            "clarity": false, "clarityAmount": 3.0,
            "harshCut": false, "harshCutAmount": 4.0,
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
        detectionSensitivity = d.string(forKey: "sensitivity") ?? DetectionSensitivity.balanced.rawValue
        minimumConfidence = d.integer(forKey: "minConfidence")
        boundaryPadding = d.double(forKey: "padding")
        // Migrate the single combined switch. Someone who had it on keeps both.
        let legacyIntroOutro = d.object(forKey: "skipIntroOutro") as? Bool
        skipIntro = legacyIntroOutro ?? d.bool(forKey: "skipIntro")
        skipOutro = legacyIntroOutro ?? d.bool(forKey: "skipOutro")
        skipSelfPromo = d.bool(forKey: "skipSelfPromo")
        skipCrossPromo = d.bool(forKey: "skipCrossPromo")
        keepHostReadAds = d.bool(forKey: "keepHostRead")
        keepComedyBitAds = d.bool(forKey: "keepComedyBits")
        processOnlyWhileCharging = d.bool(forKey: "chargingOnly")
        autoQueueNewEpisodes = d.bool(forKey: "autoQueue")
        analyzeSilence = d.bool(forKey: "analyzeSilence")
        defaultPlaybackSpeed = d.double(forKey: "speed")
        seekForwardSeconds = d.double(forKey: "seekFwd")
        seekBackwardSeconds = d.double(forKey: "seekBack")
        continuousPlayback = d.bool(forKey: "continuous")
        markPlayedAtEnd = d.bool(forKey: "markPlayed")
        preprocessAhead = d.integer(forKey: "preprocessAhead")
        interfaceSize = d.integer(forKey: UIScale.key)
        autoDownloadMode = d.string(forKey: "autoDownloadMode") ?? "off"
        autoDownloadLimit = d.string(forKey: "autoDownloadLimit") ?? "recent3"
        autoDownloadFindAds = d.bool(forKey: "autoDownloadFindAds")
        autoDownloadWiFiOnly = d.bool(forKey: "autoDownloadWiFi")
        playUnprocessedByDefault = d.bool(forKey: "playUnprocessed")
        playPromptCountdown = d.double(forKey: "playPromptCountdown")
        promptSwipeCancels = d.bool(forKey: "promptSwipeCancels")
        smartSpeedEnabled = d.bool(forKey: "smartSpeed")
        smartSpeedAggressiveness = d.double(forKey: "smartSpeedAmount")
        voiceBoostEnabled = d.bool(forKey: "voiceBoost")
        volumeNormalizationEnabled = d.bool(forKey: "normalize")
        rumbleFilterEnabled = d.bool(forKey: "rumble")
        deEsserEnabled = d.bool(forKey: "deEsser")
        deEsserStrength = d.double(forKey: "deEsserAmount")
        mudReductionEnabled = d.bool(forKey: "mudCut")
        mudReductionStrength = d.double(forKey: "mudCutAmount")
        bassReductionEnabled = d.bool(forKey: "bassCut")
        bassReductionStrength = d.double(forKey: "bassCutAmount")
        clarityEnabled = d.bool(forKey: "clarity")
        clarityStrength = d.double(forKey: "clarityAmount")
        harshnessReductionEnabled = d.bool(forKey: "harshCut")
        harshnessReductionStrength = d.double(forKey: "harshCutAmount")
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

// MARK: - Detection sensitivity

/// How eager ad detection is, expressed as a choice rather than a score.
///
/// Each case is a confidence threshold with a sentence attached. The threshold
/// is still adjustable by hand on the advanced screen — choosing a case just
/// sets it, and moving the number by hand puts the choice into `custom`.
enum DetectionSensitivity: String, CaseIterable, Identifiable {
    case conservative = "Conservative"
    case balanced = "Balanced"
    case aggressive = "Aggressive"
    case custom = "Custom"

    var id: String { rawValue }

    /// The confidence floor a passage has to clear to be cut.
    var threshold: Int {
        switch self {
        case .conservative: return 80
        case .balanced:     return 60
        case .aggressive:   return 42
        case .custom:       return 60
        }
    }

    var summary: String {
        switch self {
        case .conservative:
            return "Only cuts what it is sure about. Some ads will get through."
        case .balanced:
            return "Recommended. Catches most ads and rarely cuts anything else."
        case .aggressive:
            return "Catches more, and will occasionally cut a few seconds of the show."
        case .custom:
            return "Using your own confidence threshold."
        }
    }

    /// The named setting a given threshold corresponds to, or custom.
    static func matching(_ threshold: Int) -> DetectionSensitivity {
        allCases.first { $0 != .custom && $0.threshold == threshold } ?? .custom
    }
}

// MARK: - Equalizer presets

/// Ten ISO bands: 32, 64, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz.
///
/// The curves are built from what each band actually does to a voice rather
/// than from a label: 32 and 64 are rumble and room, 125–250 is chest and
/// boxiness, 500–1k is body, 2–4k is articulation and also where harshness
/// lives, 8k is sibilance and air, 16k is mostly hiss on spoken-word material.
struct EQPreset: Identifiable, Hashable {
    let name: String
    /// One line saying what it is for, because "Warm Speech" is not
    /// self-explanatory to someone who just wants the podcast to sound better.
    let summary: String
    let gains: [Double]
    var id: String { name }

    static let flat = EQPreset(
        name: "Flat", summary: "No change.",
        gains: Array(repeating: 0, count: 10))

    static let speech = EQPreset(
        name: "Speech", summary: "An everyday lift for talk. A good starting point.",
        gains: [-6, -5, -2,  0,  1,  2,  3,  2,  0, -2])

    static let voiceClarity = EQPreset(
        name: "Voice Clarity", summary: "For hosts who sound distant or unclear.",
        gains: [-7, -6, -3,  0,  2,  3,  5,  4,  2, -1])

    static let warmSpeech = EQPreset(
        name: "Warm Speech", summary: "Softer and rounder. Easier on thin recordings.",
        gains: [-2, -1,  1,  2,  2,  1,  0, -1, -2, -3])

    static let reduceHarshness = EQPreset(
        name: "Reduce Harshness", summary: "Takes the edge off bright, glaring voices.",
        gains: [-2, -1,  0,  0,  0, -1, -4, -5, -3, -2])

    static let reduceBoom = EQPreset(
        name: "Reduce Boom", summary: "For chesty, boomy voices and rumbly rooms.",
        gains: [-10, -8, -5, -3, -1,  0,  1,  1,  0,  0])

    static let reduceMud = EQPreset(
        name: "Reduce Mud", summary: "Clears a congested, boxy midrange.",
        gains: [-4, -3, -4, -5, -2,  0,  2,  2,  1,  0])

    static let balanced = EQPreset(
        name: "Balanced", summary: "Mild shaping that suits almost anything.",
        gains: [-3, -2,  0,  0,  1,  1,  2,  1,  1,  0])

    static let music = EQPreset(
        name: "Music", summary: "For music-heavy shows and live sets.",
        gains: [ 4,  3,  1,  0, -1,  0,  1,  2,  3,  3])

    static let bassReduction = EQPreset(
        name: "Bass Reduction", summary: "Less low end, without touching the voice.",
        gains: [-10, -8, -5, -2,  0,  0,  0,  0,  0,  0])

    static let trebleReduction = EQPreset(
        name: "Treble Reduction", summary: "Less hiss and sibilance.",
        gains: [ 0,  0,  0,  0,  0,  0, -1, -3, -6, -8])

    static let lateNight = EQPreset(
        name: "Late Night", summary: "Evens out loud and quiet so nothing startles you.",
        gains: [-6, -5, -2,  1,  3,  3,  2,  0, -2, -4])

    static let all: [EQPreset] = [
        flat, speech, voiceClarity, warmSpeech, balanced,
        reduceHarshness, reduceBoom, reduceMud,
        bassReduction, trebleReduction, lateNight, music
    ]

    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    static func named(_ name: String) -> EQPreset { all.first { $0.name == name } ?? flat }

    /// Kept so old stored preset names still resolve to something sensible
    /// rather than silently snapping back to flat.
    static func resolving(_ stored: String) -> EQPreset {
        if let exact = all.first(where: { $0.name == stored }) { return exact }
        switch stored {
        case "Voice":        return voiceClarity
        case "Podcast":      return speech
        case "Bass Reduce":  return bassReduction
        case "Treble Boost": return voiceClarity
        case "Night":        return lateNight
        default:             return flat
        }
    }
}
