import Foundation
import Observation
import SwiftData

/// Turns processed episodes into a private RSS feed hosted on R2, so
/// Apple Podcasts (and CarPlay, Watch, HomePod, iPad) can subscribe to
/// ad-free versions of your shows.
///
/// The split that makes this work: your phone is the *worker*, R2 is the
/// *server*. Apple Podcasts refreshes feeds on its own schedule, often while
/// your phone is asleep — so the feed can't live on the phone. It has to live
/// somewhere always-on, and R2 costs nothing.
@MainActor
@Observable
final class FeedPublisher {

    static let shared = FeedPublisher()

    // MARK: - Progress

    var isPublishing = false
    var currentEpisodeTitle: String?
    var stage: Stage = .idle
    var stageFraction: Double = 0
    var itemsRemaining = 0
    private var startedAt: Date?

    enum Stage: Equatable {
        case idle, cutting, uploading, writingFeed

        static let ordered: [Stage] = [.cutting, .uploading, .writingFeed]

        var label: String {
            switch self {
            case .idle:        return ""
            case .cutting:     return "Removing ads from audio"
            case .uploading:   return "Uploading to Cloudflare"
            case .writingFeed: return "Updating your feed"
            }
        }
        var weight: Double {
            switch self {
            case .idle:        return 0
            case .cutting:     return 0.55
            case .uploading:   return 0.38
            case .writingFeed: return 0.07
            }
        }
        var number: Int { (Stage.ordered.firstIndex(of: self) ?? 0) + 1 }
        static var count: Int { ordered.count }
    }

    var overallFraction: Double {
        guard stage != .idle else { return 0 }
        let done = Stage.ordered.prefix(while: { $0 != stage }).reduce(0) { $0 + $1.weight }
        return min(1, done + stage.weight * stageFraction)
    }

    var etaSeconds: Double? {
        guard let startedAt, isPublishing else { return nil }
        let fraction = overallFraction
        guard fraction > 0.05 else { return nil }
        let elapsed = Date().timeIntervalSince(startedAt)
        return elapsed / fraction * (1 - fraction)
    }


    struct PublishResult {
        let feedURL: URL
        let episodesPublished: Int
        let bytesUploaded: Int
    }

    enum PublishError: LocalizedError {
        case noCredentials
        case nothingToPublish

        var errorDescription: String? {
            switch self {
            case .noCredentials:     return "Add your R2 credentials in Settings first."
            case .nothingToPublish:  return "No processed episodes are ready to publish."
            }
        }
    }

    private var context: ModelContext?
    private var pipeline: ProcessingPipeline = .shared

    private init() {}

    func configure(context: ModelContext, pipeline: ProcessingPipeline = .shared) {
        self.context = context
        self.pipeline = pipeline
    }

    // MARK: - Publish one show

    /// Cut, upload and re-publish episodes of a show.
    /// - Parameter only: when supplied, publish just these episodes. Otherwise
    ///   every processed episode of the show, newest first.
    @discardableResult
    func publish(_ podcast: Podcast,
                 only selection: [Episode]? = nil,
                 episodeLimit: Int = 20) async throws -> PublishResult {
        guard let context else { throw PublishError.noCredentials }
        guard let creds = R2Credentials.load() else { throw PublishError.noCredentials }
        let uploader = R2Uploader(credentials: creds)
        let slug = podcast.slug

        let pool = selection ?? podcast.episodes
            .filter { $0.processingState == .ready }
            .sorted { $0.publishedAt > $1.publishedAt }
        let candidates = Array(pool.filter { $0.processingState == .ready }.prefix(episodeLimit))

        guard !candidates.isEmpty else { throw PublishError.nothingToPublish }

        isPublishing = true
        startedAt = Date()
        defer {
            isPublishing = false
            stage = .idle
            stageFraction = 0
            currentEpisodeTitle = nil
            itemsRemaining = 0
            startedAt = nil
        }

        var bytes = 0
        var published: [PublishedEpisode] = []

        for (index, episode) in candidates.enumerated() {
            currentEpisodeTitle = episode.title
            itemsRemaining = candidates.count - index - 1

            // Already uploaded and unchanged? Reuse it.
            if let existing = episode.publishedURL,
               let existingURL = URL(string: existing),
               episode.publishedAdVersion == episode.adSegmentsFingerprint {
                published.append(PublishedEpisode(episode: episode,
                                                  url: existingURL,
                                                  byteCount: episode.publishedByteCount,
                                                  duration: episode.publishedDuration))
                continue
            }

            guard let localURL = episode.localFileURL,
                  FileManager.default.fileExists(atPath: localURL.path) else { continue }

            // 1. Cut the ads out for real.
            stage = .cutting
            stageFraction = 0.2
            let cutURL = FileStore.episodesDirectory
                .appendingPathComponent("cut-\(episode.guid.stableHash).m4a")
            let cut = try await AudioCutter.cut(source: localURL,
                                                removing: episode.skipRanges,
                                                to: cutURL)

            // 2. Upload.
            stage = .cutting
            stageFraction = 1
            stage = .uploading
            stageFraction = 0.1
            let key = "audio/\(slug)/\(episode.guid.stableHash).m4a"
            let remoteURL = try await uploader.upload(fileURL: cutURL,
                                                      key: key,
                                                      contentType: "audio/mp4")

            // 3. Record it, and delete the local cut copy — R2 has it now.
            episode.publishedURL = remoteURL.absoluteString
            episode.publishedByteCount = cut.byteCount
            episode.publishedDuration = cut.duration
            episode.publishedAdVersion = episode.adSegmentsFingerprint
            stage = .uploading
            stageFraction = 1
            try? context.save()
            try? FileManager.default.removeItem(at: cutURL)

            bytes += cut.byteCount
            published.append(PublishedEpisode(episode: episode,
                                              url: remoteURL,
                                              byteCount: cut.byteCount,
                                              duration: cut.duration))
        }

        // 4. Rewrite and upload the feed.
        stage = .writingFeed
        stageFraction = 0.4
        let xml = Self.buildRSS(podcast: podcast, episodes: published, baseURL: creds.publicBaseURL)
        let feedKey = "feeds/\(slug).xml"
        let feedURL = try await uploader.upload(data: Data(xml.utf8),
                                                key: feedKey,
                                                contentType: "application/rss+xml; charset=utf-8")

        podcast.publishedFeedURL = feedURL.absoluteString
        podcast.lastPublished = .now
        try? context.save()

        return PublishResult(feedURL: feedURL,
                             episodesPublished: published.count,
                             bytesUploaded: bytes)
    }

    /// Process anything outstanding, then publish every show that has a feed.
    func processAndPublishAll() async {
        await pipeline.processPending(limit: 10)
        guard let context else { return }
        let descriptor = FetchDescriptor<Podcast>()
        guard let podcasts = try? context.fetch(descriptor) else { return }
        for podcast in podcasts {
            _ = try? await publish(podcast)
        }
    }

    // MARK: - RSS

    struct PublishedEpisode {
        let episode: Episode
        let url: URL
        let byteCount: Int
        let duration: Double
    }

    static func buildRSS(podcast: Podcast,
                         episodes: [PublishedEpisode],
                         baseURL: String) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"
             xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
             xmlns:content="http://purl.org/rss/1.0/modules/content/">
        <channel>
          <title>\(podcast.title.xmlEscaped) (ad-free)</title>
          <link>\(baseURL.xmlEscaped)</link>
          <description>\(podcast.summary.xmlEscaped)</description>
          <language>en-us</language>
          <itunes:author>\(podcast.author.xmlEscaped)</itunes:author>
          <itunes:explicit>false</itunes:explicit>
          <itunes:block>Yes</itunes:block>

        """
        // itunes:block keeps this private feed out of Apple's directory if it
        // ever gets crawled. It's your copy, not a republication.

        if let art = podcast.artworkURL {
            xml += "  <itunes:image href=\"\(art.xmlEscaped)\"/>\n"
        }

        for item in episodes {
            let e = item.episode
            let removed = e.adSegments.reduce(0) { $0 + $1.duration }
            xml += """
              <item>
                <title>\(e.title.xmlEscaped)</title>
                <guid isPermaLink="false">podskipper-\(e.guid.stableHash)</guid>
                <pubDate>\(Self.rfc822.string(from: e.publishedAt))</pubDate>
                <description>\(e.episodeDescription.xmlEscaped)</description>
                <itunes:duration>\(Int(item.duration))</itunes:duration>
                <itunes:summary>\(e.episodeDescription.xmlEscaped)</itunes:summary>
                <enclosure url="\(item.url.absoluteString.xmlEscaped)" length="\(item.byteCount)" type="audio/mp4"/>
                <itunes:subtitle>\(Int(removed / 60)) min of ads removed</itunes:subtitle>
              </item>

            """
        }

        xml += "</channel>\n</rss>\n"
        return xml
    }

    private static let rfc822: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()
}

// MARK: - Supporting bits

extension Podcast {
    /// Stable, URL-safe identifier used for R2 keys and the feed filename.
    var slug: String {
        let base = title.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return base.isEmpty ? feedURL.stableHash : "\(base.prefix(40))-\(feedURL.stableHash.prefix(6))"
    }
}

extension Episode {
    /// Changes whenever the detected ads change, so republishing only happens
    /// when the audio would actually be different.
    var adSegmentsFingerprint: String {
        adSegments
            .sorted { $0.start < $1.start }
            .map { "\(Int($0.start * 10))-\(Int($0.end * 10))" }
            .joined(separator: ",")
            .stableHash
    }
}

extension String {
    /// Deterministic across launches, unlike hashValue.
    var stableHash: String {
        var hash: UInt64 = 5381
        for byte in self.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return String(hash, radix: 36)
    }

    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
