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
        var explicit = false
        /// "bonus" or "trailer"; empty for a normal episode.
        var type = ""
        /// A fixed date instead of `daysAgo`, as (years back, month, day) —
        /// for the year headings, which need episodes either side of a
        /// new year.
        var dated: (yearsBack: Int, month: Int, day: Int)? = nil
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
                            minutes: 77, daysAgo: 15, played: true, explicit: true),
                EpisodeSpec(title: "New Year, Same Fax Machine",
                            notes: "Resolutions for hardware that will not keep them.",
                            minutes: 58, daysAgo: 0, dated: (0, 1, 2)),
                EpisodeSpec(title: "The Boxing Day Router Reset",
                            notes: "Recorded between two families' Wi-Fi passwords.",
                            minutes: 21, daysAgo: 0, explicit: true, type: "bonus", dated: (1, 12, 26)),
                EpisodeSpec(title: "Our Annual Floppy Disk Retrospective",
                            notes: "One point four four megabytes of memories.",
                            minutes: 66, daysAgo: 0, dated: (1, 11, 14)),
                EpisodeSpec(title: "Hard Drive Full: The Trailer",
                            notes: "What this show is, in ninety seconds.",
                            minutes: 2, daysAgo: 0, type: "trailer", dated: (2, 6, 1))
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

    private static func date(for spec: EpisodeSpec) -> Date {
        guard let dated = spec.dated else { return Date().addingTimeInterval(-spec.daysAgo * 86_400) }
        let calendar = Calendar.current
        var parts = DateComponents()
        parts.year = calendar.component(.year, from: .now) - dated.yearsBack
        parts.month = dated.month
        parts.day = dated.day
        parts.hour = 9
        return calendar.date(from: parts) ?? .now
    }

    // MARK: - Seeding

    /// Under test only (`-HLSDemo`): follows the Podcast Standards
    /// Project's real demo feed — an episode whose audio is an mp3 and whose
    /// video is an HLS stream in `podcast:alternateEnclosure` — so the native
    /// video path can be exercised end to end against a real feed.
    @MainActor
    static func seedHLSDemo(into context: ModelContext) async {
        guard isEnabled, ProcessInfo.processInfo.arguments.contains("-HLSDemo") else { return }
        let address = "https://podcast-standards-project.github.io/hls-video/feed.xml"
        guard let feed = try? await FeedParser.fetch(address) else { return }
        let podcast = Podcast(feedURL: address, title: feed.title, author: feed.author,
                              summary: feed.summary, artworkURL: feed.artworkURL)
        context.insert(podcast)
        for item in feed.items {
            let episode = Episode(item: item)
            episode.podcast = podcast
            context.insert(episode)
        }
        podcast.lastRefreshed = .now
        try? context.save()
        CountsCache.invalidate()
    }

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
                    publishedAt: Self.date(for: spec),
                    duration: spec.minutes * 60,
                    artworkURL: nil
                )
                episode.podcast = podcast
                // One video episode. Its picture is generated on first run —
                // a clock of the playhead drawn on every frame — so a
                // screenshot can show the picture following the sound: the
                // number in the frame should match the time under the bar.
                let isDemoVideo = show.title == "The Long Way Round" && episodeIndex == 0
                if isDemoVideo { episode.mediaType = "video/mp4" }
                episode.isPlayed = spec.played
                episode.isStarred = spec.starred
                episode.isExplicit = spec.explicit
                episode.episodeType = spec.type
                // Against the audio that exists, for the same reason the
                // segments are. Placed against the feed's claimed 98 minutes,
                // a third of the way through landed past the end of a
                // two-minute file, so the player opened on a finished episode
                // with the playhead pinned to the right-hand edge.
                let playableSeconds = spec.downloaded ? Self.silenceSeconds : spec.minutes * 60
                episode.playbackPosition = spec.progress * playableSeconds
                // Real listening time, so the on-device taste profile has
                // something to weight by. Without it every show counts the
                // same and "For You" is just the charts again.
                if spec.played {
                    episode.secondsListened = spec.minutes * 60
                } else if spec.progress > 0 {
                    episode.secondsListened = spec.progress * spec.minutes * 60
                }
                episode.episodeNumber = show.episodes.count - episodeIndex
                // Under test only: a demo show pointed at a real show's
                // YouTube channel, with its first episode named as that
                // show's latest full episode, so Watch on YouTube can be
                // exercised end to end. Depends on that upload still being in
                // the channel's latest fifteen.
                if ProcessInfo.processInfo.arguments.contains("-YouTubeDemo"),
                   show.title == "Quiet Hours" {
                    podcast.youtubeChannel = "UCBVAaHkKSwfzee79b7SPyPw"
                    if episodeIndex == 0 { episode.title = "#199 - Are You Garbage?" }
                }
                // One show in seasons, so the season picker has something to pick.
                if show.title == "The Long Way Round" {
                    episode.seasonNumber = episodeIndex < 2 ? 2 : 1
                }

                if spec.downloaded, let filename = silence(named: "demo-\(showIndex)-\(episodeIndex).wav") {
                    if isDemoVideo {
                        // The sound is the demo audio, as the extracted track
                        // of a real video would be; the picture comes after.
                        episode.extractedAudioFilename = filename
                        let videoName = "demo-video-\(showIndex)-\(episodeIndex).mp4"
                        episode.localFilename = videoName
                        DemoVideo.makeIfNeeded(named: videoName, seconds: Self.silenceSeconds)
                    } else {
                        episode.localFilename = filename
                    }
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
                    // Lengths in proportion to the file, not to the 98
                    // minutes the feed claims. Sized for the notional episode
                    // they overlapped end to end across two minutes of audio,
                    // so pressing play skipped straight to the end and the
                    // seek bar could never be seen doing anything.
                    let breaks: [(Double, Double, String, Int, SegmentKind)] = [
                        (0.01, 4,  "", 82, .intro),
                        (0.08, 9,  "Brightwater", 91, .ad),
                        (0.31, 8,  "Odeon Coffee", 85, .ad),
                        (0.50, 13, "the live tour", 77, .selfPromo),
                        (0.70, 7,  "Fenn & Co", 88, .ad),
                        (0.85, 6,  "Quiet Hours", 71, .crossPromo),
                        (0.95, 4,  "", 80, .outro)
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

                    // A transcript, because half the app is about words.
                    //
                    // Without one the what-was-skipped page can only ever say
                    // "no transcript was kept", the trimmer has no speech to
                    // draw, and the live transcript in the player is empty —
                    // so none of it could be looked at before shipping, which
                    // is exactly the class of thing that keeps reaching a real
                    // phone unverified.
                    episode.storeTranscript(
                        Self.transcript(total: total, breaks: breaks.map {
                            (start: $0.0 * total,
                             end: $0.0 * total + $0.1,
                             sponsor: $0.2,
                             kind: $0.4)
                        })
                    )
                }

                // One published episode per show that has a second processed
                // one, so the Publish page's feed link — its whole headline —
                // has something to draw. Without it the page can only ever be
                // photographed in its "nothing published yet" state.
                if spec.ready && episodeIndex == 1 {
                    episode.publishedURL = "https://pods.example.invalid/audio/demo-\(showIndex)-1.m4a"
                    episode.publishedByteCount = 41_000_000
                    episode.publishedDuration = spec.minutes * 60
                    episode.publishedAdVersion = "demo"
                    podcast.publishedFeedURL = "https://pods.example.invalid/feeds/\(podcast.slug).xml"
                    podcast.lastPublished = Date().addingTimeInterval(-5 * 3600)
                }

                if episodeIndex == 0 {
                    episode.isInQueue = true
                    episode.queueOrder = showIndex
                }
                context.insert(episode)
            }
            podcast.lastRefreshed = Date()
            podcast.catalogueIndexedAt = Date()
        }

        // Under test only: one episode whose ad finding failed, opened as if
        // its notification had just been tapped.
        if ProcessInfo.processInfo.arguments.contains("-StatusDemo") {
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == "demo-0-2" })
            descriptor.fetchLimit = 1
            if let episode = try? context.fetch(descriptor).first {
                episode.processingState = .failed
                episode.processingError = "The download was interrupted."
                AppRouter.shared.statusEpisodeGUID = episode.guid
            }
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

    // MARK: - Generated transcript

    /// Plausible words across a demo episode, with real ad copy inside the
    /// stretches that are marked as promotions.
    ///
    /// The point is not realism for its own sake. Every screen that shows
    /// words — the live transcript, the what-was-skipped page, the speech
    /// texture behind the trim handles — is blank without this, so none of them
    /// could be photographed and checked before being handed to a phone.
    private static func transcript(
        total: Double,
        breaks: [(start: Double, end: Double, sponsor: String, kind: SegmentKind)]
    ) -> [TimedLine] {
        let showLines = [
            "So we were talking about this before we started recording, and I still don't buy it.",
            "Right, but that's the whole point — nobody asked them to do it in the first place.",
            "I read the filing. It's forty pages and thirty-eight of them are apologising.",
            "Which is a lot of apologising for something they insist wasn't their fault.",
            "Okay, hold on. Let's back up, because people listening won't know the timeline.",
            "Three weeks ago. That's when the first email went out, and nobody noticed.",
            "Nobody noticed because it went to spam. That is genuinely what happened.",
            "I want to be fair to them here. They did eventually respond.",
            "Eventually is doing an enormous amount of work in that sentence.",
            "Anyway — this is the part that actually made me laugh.",
            "They put out a statement saying the numbers were, quote, directionally accurate.",
            "Directionally accurate. As in, wrong, but wrong in a consistent direction.",
            "I'm going to start using that. My taxes are directionally accurate.",
            "Please don't say that to anyone official on a recorded line.",
            "Too late. Anyway, the second thing, and this one is worse."
        ]

        func adCopy(_ sponsor: String, kind: SegmentKind) -> [String] {
            switch kind {
            case .intro:
                return ["Welcome back to the show. I'm here as always, and we have a lot to get through today."]
            case .outro:
                return ["That's it for this week. Thanks for listening, and we'll see you next time."]
            case .selfPromo:
                return [
                    "Quick bit of housekeeping before we carry on.",
                    "We're taking \(sponsor.isEmpty ? "the show" : sponsor) out on the road this spring.",
                    "Tickets are on sale now, and the early shows are already going.",
                    "Link is in the show notes, and there's a presale code in the newsletter."
                ]
            case .crossPromo:
                return [
                    "If you like this, there's another show you should be listening to.",
                    "\(sponsor.isEmpty ? "It" : sponsor) is out every Tuesday, wherever you get your podcasts."
                ]
            case .ad:
                let name = sponsor.isEmpty ? "our sponsor" : sponsor
                return [
                    "This episode is brought to you by \(name).",
                    "I've been using \(name) for about six months now and it genuinely changed how I do this.",
                    "Go to \(name.lowercased().replacingOccurrences(of: " ", with: ""))dot com slash show and use code SHOW.",
                    "That's twenty percent off your first order, and you can cancel anytime."
                ]
            }
        }

        var lines: [TimedLine] = []
        var cursor: Double = 0
        var showIndex = 0
        let ordered = breaks.sorted { $0.start < $1.start }

        func fill(until limit: Double) {
            while cursor < limit - 1 {
                let length = min(3.4, limit - cursor)
                lines.append(TimedLine(text: showLines[showIndex % showLines.count],
                                       start: cursor, end: cursor + length))
                cursor += length
                showIndex += 1
            }
            cursor = max(cursor, limit)
        }

        for segment in ordered {
            fill(until: segment.start)
            let copy = adCopy(segment.sponsor, kind: segment.kind)
            let each = max(1.0, (segment.end - segment.start) / Double(copy.count))
            for (index, text) in copy.enumerated() {
                let from = segment.start + Double(index) * each
                lines.append(TimedLine(text: text, start: from,
                                       end: min(segment.end, from + each)))
            }
            cursor = segment.end
        }
        fill(until: total)
        return lines
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
