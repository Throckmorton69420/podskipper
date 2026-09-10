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
    var dateAdded: Date
    var lastRefreshed: Date?
    var publishedFeedURL: String?
    var lastPublished: Date?

    /// Per-show override. nil means "use the global setting".
    var autoSkipEnabled: Bool?

    @Relationship(deleteRule: .cascade, inverse: \Episode.podcast)
    var episodes: [Episode] = []

    init(feedURL: String, title: String, author: String = "", summary: String = "", artworkURL: String? = nil) {
        self.feedURL = feedURL
        self.title = title
        self.author = author
        self.summary = summary
        self.artworkURL = artworkURL
        self.dateAdded = .now
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
    var duration: Double          // seconds, from the feed; may be 0 or wrong
    var artworkURL: String?

    // Local state
    var localFilename: String?    // relative to Application Support/Episodes
    var playbackPosition: Double = 0
    var isPlayed: Bool = false
    var isInQueue: Bool = false
    var queueOrder: Int = 0

    // Ad-detection state
    var processingState: ProcessingState = ProcessingState.notStarted
    var transcriptText: String?
    var lastProcessedAt: Date?
    var processingError: String?

    // Publishing state (see FeedPublisher)
    var publishedURL: String?
    var publishedByteCount: Int = 0
    var publishedDuration: Double = 0
    /// Fingerprint of the ad segments at the time of upload, so we only
    /// re-cut and re-upload when the detected ads actually changed.
    var publishedAdVersion: String?

    var podcast: Podcast?

    @Relationship(deleteRule: .cascade, inverse: \AdSegment.episode)
    var adSegments: [AdSegment] = []

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

    /// Ad ranges the player should skip, sorted and merged, excluding anything
    /// the user has manually rejected.
    var skipRanges: [ClosedRange<Double>] {
        adSegments
            .filter { $0.userVerdict != .notAnAd }
            .map { $0.start...$0.end }
            .sorted { $0.lowerBound < $1.lowerBound }
    }

    var localFileURL: URL? {
        guard let localFilename else { return nil }
        return FileStore.episodesDirectory.appendingPathComponent(localFilename)
    }
}

enum ProcessingState: String, Codable {
    case notStarted
    case downloading
    case transcribing
    case detecting
    case ready
    case failed
}

// MARK: - Ad segment

@Model
final class AdSegment {
    var start: Double             // seconds into the episode
    var end: Double
    var sponsor: String
    var confidence: Int           // 0-100, from the model
    var userVerdict: UserVerdict = UserVerdict.unreviewed
    var episode: Episode?

    init(start: Double, end: Double, sponsor: String = "", confidence: Int = 0) {
        self.start = start
        self.end = end
        self.sponsor = sponsor
        self.confidence = confidence
    }

    var duration: Double { max(0, end - start) }
}

enum UserVerdict: String, Codable {
    case unreviewed
    case confirmed
    case notAnAd      // user said this was real content; player stops skipping it
}

// MARK: - Where files live

enum FileStore {
    static var episodesDirectory: URL {
        let base = URL.applicationSupportDirectory.appendingPathComponent("Episodes", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

// MARK: - Settings

@Observable
final class AppSettings {
    var autoSkipEnabled: Bool {
        didSet { UserDefaults.standard.set(autoSkipEnabled, forKey: "autoSkip") }
    }
    /// Ignore detections the model is unsure about. Raising this trades
    /// missed ads for fewer clipped cold opens.
    var minimumConfidence: Int {
        didSet { UserDefaults.standard.set(minimumConfidence, forKey: "minConfidence") }
    }
    /// Seconds of slack left at each end of a cut, so a skip doesn't
    /// swallow the first syllable of real content.
    var boundaryPadding: Double {
        didSet { UserDefaults.standard.set(boundaryPadding, forKey: "padding") }
    }
    var processOnlyWhileCharging: Bool {
        didSet { UserDefaults.standard.set(processOnlyWhileCharging, forKey: "chargingOnly") }
    }

    init() {
        let d = UserDefaults.standard
        d.register(defaults: ["autoSkip": true, "minConfidence": 60,
                              "padding": 0.4, "chargingOnly": true])
        autoSkipEnabled = d.bool(forKey: "autoSkip")
        minimumConfidence = d.integer(forKey: "minConfidence")
        boundaryPadding = d.double(forKey: "padding")
        processOnlyWhileCharging = d.bool(forKey: "chargingOnly")
    }
}
