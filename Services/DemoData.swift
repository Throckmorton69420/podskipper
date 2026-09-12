import Foundation
import SwiftData
import UIKit
import AVFoundation

/// Seeds a fake library when the app is launched by the screenshot test.
///
/// The screenshot workflow existed to turn "I think this looks right" into
/// "here is what it looks like" — but it launched a fresh install with nothing
/// in it, so every run photographed empty states. The show page, the episode
/// rows, the ad timeline and the player, which are the screens worth looking
/// at, could not appear at all.
///
/// Everything here is generated on device: the covers are drawn with Core
/// Graphics and the audio is silence written by AVAudioFile, so the run needs
/// no network and produces the same pictures every time. It only ever runs
/// under the launch argument, into an in-memory store.
enum DemoData {

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITestScreenshots")
    }

    private struct Show {
        let title: String
        let author: String
        /// Deliberately HTML. Feeds send markup, and rendering it raw is what
        /// used to put a literal `<p>` in front of every description — so the
        /// screenshots should prove that is fixed.
        let summary: String
        let hue: Double
        let letter: String
        let episodes: [EpisodeSpec]
    }

    private struct EpisodeSpec {
        let title: String
        let notes: String
        let minutes: Double
        let daysAgo: Double
        var played = false
        var progress: Double = 0
        var starred = false
        var ready = false
        var downloaded = false
    }

    private static let shows: [Show] = [
        Show(title: "The Long Way Round",
             author: "Ardent Audio",
             summary: "<p>Two friends take the <em>slowest possible route</em> between two points and talk about what they find. Updated weekly.</p><p>Recorded on location, mostly badly.</p>",
             hue: 0.94, letter: "L",
             episodes: [
                EpisodeSpec(title: "Crossing the Pennines on a Tandem Nobody Asked For",
                            notes: "We attempt forty miles of hill on a bike built for people who like each other more than we do.",
                            minutes: 98, daysAgo: 0.1, progress: 0.34, ready: true, downloaded: true),
                EpisodeSpec(title: "The Ferry That Only Runs When It Feels Like It",
                            notes: "A timetable, a tide, and a man called Gordon who disagrees with both.",
                            minutes: 74, daysAgo: 7, starred: true, ready: true, downloaded: true),
                EpisodeSpec(title: "Sleeping in a Bothy With Two Strangers and a Stove",
                            notes: "Shelter, in the loosest sense the word will bear.",
                            minutes: 63, daysAgo: 14, played: true, downloaded: true),
                EpisodeSpec(title: "Every Motorway Services Ranked, Badly",
                            notes: "A definitive list that we will be revising immediately after publication.",
                            minutes: 51, daysAgo: 21)
             ]),

        Show(title: "Hard Drive Full",
             author: "Northside Media",
             summary: "<p>A comedy show about technology that has aged badly. Two hosts, one working microphone.</p>",
             hue: 0.58, letter: "H",
             episodes: [
                EpisodeSpec(title: "The Zip Drive Was Actually Fine, Everyone",
                            notes: "A spirited defence of a format nobody misses.",
                            minutes: 82, daysAgo: 1, progress: 0.72, ready: true, downloaded: true),
                EpisodeSpec(title: "We Read the Manual for a Printer From 1997",
                            notes: "Four hundred pages. One paper tray. No mercy.",
                            minutes: 69, daysAgo: 8, ready: true, downloaded: true),
                EpisodeSpec(title: "Listener Mailbag: Your Worst Office IT Stories",
                            notes: "You sent them in. We regret asking.",
                            minutes: 77, daysAgo: 15, played: true)
             ]),

        Show(title: "Quiet Hours",
             author: "Fieldnote",
             summary: "<p>Long-form interviews recorded after midnight, when people say what they actually think.</p>",
             hue: 0.33, letter: "Q",
             episodes: [
                EpisodeSpec(title: "A Lighthouse Keeper on the Last Year of the Job",
                            notes: "Forty years of weather, and the morning it was automated.",
                            minutes: 112, daysAgo: 2, starred: true, ready: true, downloaded: true),
                EpisodeSpec(title: "The Night Shift at a Twenty-Four Hour Bakery",
                            notes: "Bread, insomnia, and the radio station nobody else listens to.",
                            minutes: 94, daysAgo: 11)
             ])
    ]

    // MARK: - Seeding

    @MainActor
    static func seed(into context: ModelContext) {
        guard isEnabled else { return }
        let existing = (try? context.fetchCount(FetchDescriptor<Podcast>())) ?? 0
        guard existing == 0 else { return }

        for (showIndex, show) in shows.enumerated() {
            let podcast = Podcast(feedURL: "https://example.invalid/demo/\(showIndex).xml",
                                  title: show.title,
                                  author: show.author,
                                  summary: show.summary,
                                  artworkURL: cover(letter: show.letter, hue: show.hue,
                                                    name: "show-\(showIndex)"),
                                  category: "Documentary")
            context.insert(podcast)

            for (episodeIndex, spec) in show.episodes.enumerated() {
                let episode = Episode(
                    guid: "demo-\(showIndex)-\(episodeIndex)",
                    title: spec.title,
                    episodeDescription: "<p>\(spec.notes)</p>",
                    audioURL: "https://example.invalid/demo/\(showIndex)/\(episodeIndex).mp3",
                    publishedAt: Date().addingTimeInterval(-spec.daysAgo * 86_400),
                    duration: spec.minutes * 60,
                    artworkURL: nil
                )
                episode.podcast = podcast
                episode.isPlayed = spec.played
                episode.isStarred = spec.starred
                // Against the audio that exists, for the same reason the
                // segments are. Placed against the feed's claimed 98 minutes,
                // a third of the way through landed past the end of a
                // two-minute file, so the player opened on a finished episode
                // with the playhead pinned to the right-hand edge.
                let playableSeconds = spec.downloaded ? Self.silenceSeconds : spec.minutes * 60
                episode.playbackPosition = spec.progress * playableSeconds
                episode.episodeNumber = show.episodes.count - episodeIndex

                if spec.downloaded, let filename = silence(named: "demo-\(showIndex)-\(episodeIndex).wav") {
                    episode.localFilename = filename
                }

                if spec.ready {
                    episode.processingState = .ready
                    episode.lastProcessedAt = Date()
                    // Breaks at plausible places, one of each kind, so the
                    // timeline draws its four colours and the breakdown under
                    // the episode has something real to count.
                    //
                    // Placed against the length of the audio that actually
                    // exists, not the length the feed claims. The generated
                    // file is two minutes; positioning segments across a
                    // notional 98 minutes put every one of them past the end
                    // of the track, so the player's timeline showed a single
                    // stray block and nothing else.
                    let total = spec.downloaded ? Self.silenceSeconds : spec.minutes * 60
                    let breaks: [(Double, Double, String, Int, SegmentKind)] = [
                        (0.005, 22, "", 82, .intro),
                        (0.03,  62, "Brightwater", 91, .ad),
                        (0.41,  74, "Odeon Coffee", 85, .ad),
                        (0.62, 138, "the live tour", 77, .selfPromo),
                        (0.83,  58, "Fenn & Co", 88, .ad),
                        (0.95,  41, "Quiet Hours", 71, .crossPromo),
                        (0.985, 26, "", 80, .outro)
                    ]
                    for (fraction, length, sponsor, confidence, kind) in breaks {
                        let start = total * fraction
                        let segment = AdSegment(start: start, end: start + length,
                                                sponsor: sponsor,
                                                confidence: confidence,
                                                kind: kind)
                        segment.episode = episode
                        context.insert(segment)
                    }
                    if let show = podcast.knownSponsors.isEmpty ? podcast : nil {
                        show.knownSponsors = ["Brightwater", "Fenn & Co", "Odeon Coffee"]
                    }
                }

                if episodeIndex == 0 {
                    episode.isInQueue = true
                    episode.queueOrder = showIndex
                }
                context.insert(episode)
            }
            podcast.lastRefreshed = Date()
        }

        try? context.save()
        CountsCache.invalidate()
        LibraryTotals.shared.invalidate()
    }

    // MARK: - Generated cover art

    /// Drawn rather than downloaded, so the run is offline and deterministic —
    /// and so the colour the header extracts from a cover is predictable
    /// enough to check by eye.
    private static func cover(letter: String, hue: Double, name: String) -> String? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DemoArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")

        if FileManager.default.fileExists(atPath: url.path) { return url.absoluteString }

        let side: CGFloat = 600
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { context in
            let core = context.cgContext
            let second = (hue + 0.11).truncatingRemainder(dividingBy: 1)
            let colours = [
                UIColor(hue: hue, saturation: 0.82, brightness: 0.95, alpha: 1).cgColor,
                UIColor(hue: second, saturation: 0.92, brightness: 0.48, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colours, locations: [0, 1]) {
                core.drawLinearGradient(gradient, start: .zero,
                                        end: CGPoint(x: side, y: side), options: [])
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 300, weight: .heavy),
                .foregroundColor: UIColor.white.withAlphaComponent(0.9)
            ]
            let text = NSAttributedString(string: letter, attributes: attributes)
            let size = text.size()
            text.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
        }

        guard let data = image.pngData(), (try? data.write(to: url)) != nil else { return nil }
        return url.absoluteString
    }

    // MARK: - Generated audio

    /// How long the generated audio actually is.
    private static let silenceSeconds: Double = 120

    /// Two minutes of silence at 8 kHz — about two megabytes.
    ///
    /// Enough for the player to load, show transport controls and run its
    /// clock, without shipping a media file or hitting the network.
    private static func silence(named filename: String) -> String? {
        let url = FileStore.episodesDirectory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: url.path) {
            FileIndex.insert(filename)
            return filename
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 8_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        guard let file = try? AVAudioFile(forWriting: url, settings: settings) else { return nil }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000) else { return nil }
        buffer.frameLength = 8_000   // one second, already zeroed

        for _ in 0..<Int(silenceSeconds) {
            try? file.write(from: buffer)
        }

        FileIndex.insert(filename)
        return filename
    }
}
