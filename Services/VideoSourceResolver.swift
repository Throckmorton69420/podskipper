import Foundation
import CryptoKit
import Observation

/// Where an episode's picture comes from, tried in the order Shashank chose:
///
/// 1. the feed's own video (an HLS stream, then a plain file) — `Episode.videoURL`;
/// 2. an open HLS stream on the host's own servers that Apple's public
///    episode page links to (Stavvy's World: Simplecast's CDN). Only when
///    its length matches the audio, and never Apple's own streams;
/// 3. the matching upload on the show's YouTube channel, which plays in
///    YouTube's player (the "Watch on YouTube" button).
///
/// The first two play in PodSkipper's own player, on the audio's clock, so ad
/// skipping moves the picture too. The resolver writes what it found to the
/// episode and remembers when it looked, so it asks once a day at most.
enum VideoSourceResolver {

    enum Source: String {
        case rssHLS, rssFile, publicHLS, youtube

        var label: String {
            switch self {
            case .rssHLS, .rssFile: "From the show's feed"
            case .publicHLS: "From the show's host, via Apple's episode page"
            case .youtube: "On YouTube"
            }
        }
    }

    /// Fills `publicVideoURL`, `youtubeVideoID` and `videoSourceRaw`.
    /// Returns true when a picture PodSkipper can play itself was found.
    @MainActor
    @discardableResult
    static func resolve(_ episode: Episode, force: Bool = false) async -> Bool {
        if let feed = episode.videoURL {
            episode.videoSourceRaw = (feed.lowercased().contains(".m3u8") ? Source.rssHLS : .rssFile).rawValue
            return true
        }
        if !force, let last = episode.videoResolvedAt,
           Date.now.timeIntervalSince(last) < recheckAfter(published: episode.publishedAt, found: episode.publicVideoURL != nil) {
            return episode.publicVideoURL != nil
        }
        episode.videoResolvedAt = .now
        let duration = episode.duration

        // Pass 39 (his 15 Oct: video regressed): Apple's page names each of
        // the episode's files and what it is — audio or video, free or for
        // subscribers — so the video is read from there first, and the old
        // search of the page's text for a stream address is the fallback.
        let page = await applePage(for: episode)
        var outcome = Outcome.none
        for candidate in page.map(videoCandidates) ?? [] {
            switch await check(candidate.url, audio: duration) {
            case .usable:
                episode.publicVideoURL = candidate.url.absoluteString
                episode.videoSourceRaw = Source.publicHLS.rawValue
                note(episode, .found(candidate.url.host ?? ""))
                return true
            case .refused(let why):
                outcome = .refused(why)
            }
        }
        if case .none = outcome, let page, page.subscriberVideoOnly {
            outcome = .refused("Its video on Apple Podcasts is for subscribers only.")
        }
        // A stream found before that no longer plays is let go.
        if episode.publicVideoURL != nil, episode.videoSourceRaw == Source.publicHLS.rawValue {
            episode.publicVideoURL = nil
            episode.videoSourceRaw = ""
        }
        if let show = episode.podcast, !show.youtubeChannel.isEmpty {
            let videos = await YouTubeLink.recentVideos(channelID: show.youtubeChannel)
            if let match = YouTubeLink.match(episodeTitle: episode.title, episodeNumber: episode.episodeNumber,
                                             isBonus: episode.isBonus, showTitle: show.title,
                                             published: episode.publishedAt, duration: episode.duration,
                                             in: videos) {
                episode.youtubeVideoID = match.id
                episode.videoSourceRaw = Source.youtube.rawValue
                note(episode, .youtubeOnly(outcome))
                return false
            }
        }
        note(episode, outcome)
        return false
    }

    /// How soon to look again. New episodes often get their video on
    /// Apple a few hours after the audio (Stavvy's #202 had none on its
    /// page three days in), so they are looked at again every few hours;
    /// a YouTube match never stops the look for one PodSkipper can play
    /// itself (it used to wait a week).
    static func recheckAfter(published: Date, found: Bool, now: Date = .now) -> TimeInterval {
        if found { return 7 * 86_400 }
        let age = now.timeIntervalSince(published)
        return age < 7 * 86_400 ? 3 * 3_600 : 86_400
    }

    // MARK: What was found, in words

    indirect enum Outcome: Equatable {
        case none
        case refused(String)
        case found(String)
        case youtubeOnly(Outcome?)
    }

    @MainActor private static func note(_ episode: Episode, _ outcome: Outcome) {
        VideoLimitations.shared.outcomes[episode.guid] = outcome
    }

    // MARK: Apple's episode page

    /// The host's HLS link from Apple's public page for this episode.
    ///
    /// The page carries its data as JSON inside the HTML, with slashes
    /// escaped. Two kinds of stream appear: one on Apple's own domain, which
    /// is Apple's and is never touched, and sometimes one on the show's host.
    static func applePageStream(for episode: Episode) async -> URL? {
        guard let page = await applePage(for: episode) else { return nil }
        return videoCandidates(page).first?.url
    }

    /// Apple's public page for this episode, read once.
    struct ApplePage {
        var html: String
        /// Each file Apple lists for the episode (`mediaEnclosures`).
        var enclosures: [Enclosure]
        /// Video listed only as a subscriber's file.
        var subscriberVideoOnly: Bool {
            enclosures.contains { $0.isVideo && !$0.isFree } && !enclosures.contains { $0.isVideo && $0.isFree }
        }
    }

    struct Enclosure: Equatable {
        var url: URL
        var kinds: [String]
        /// "STDQ" for everyone; "PSUB" for subscribers.
        var price: String
        var needsToken: Bool
        var isVideo: Bool { kinds.contains("video") }
        var isFree: Bool { price != "PSUB" && !needsToken }
    }

    static func applePage(for episode: Episode) async -> ApplePage? {
        guard let page = await EpisodeLink.apple(for: episode, at: 0) else { return nil }
        var request = URLRequest(url: page)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return parsePage(html)
    }

    static func parsePage(_ html: String) -> ApplePage {
        let text = html.replacingOccurrences(of: "\\u002F", with: "/").replacingOccurrences(of: "\\/", with: "/")
        var enclosures: [Enclosure] = []
        // `"mediaEnclosures":[{…},{…}]` — the first list is the episode's own.
        if let start = text.range(of: "\"mediaEnclosures\":[") {
            var depth = 1
            var index = start.upperBound
            while index < text.endIndex, depth > 0 {
                let c = text[index]
                if c == "[" { depth += 1 } else if c == "]" { depth -= 1 }
                index = text.index(after: index)
            }
            let list = "[" + text[start.upperBound..<text.index(before: index)] + "]"
            if let items = try? JSONSerialization.jsonObject(with: Data(list.utf8)) as? [[String: Any]] {
                for item in items {
                    guard let address = item["streamUrl"] as? String,
                          let url = URL(string: address.replacingOccurrences(of: "&amp;", with: "&")) else { continue }
                    let token = item["tokenRequirements"]
                    enclosures.append(Enclosure(url: url, kinds: item["mediaKinds"] as? [String] ?? [],
                                                price: item["priceType"] as? String ?? "",
                                                needsToken: token != nil && !(token is NSNull)))
                }
            }
        }
        return ApplePage(html: html, enclosures: enclosures)
    }

    /// Video PodSkipper may play, best first: free video files Apple lists
    /// (on the show's host, or Apple's own when it serves them to everyone),
    /// then a host stream found in the page's text.
    static func videoCandidates(_ page: ApplePage) -> [(url: URL, appleHosted: Bool)] {
        var out: [(url: URL, appleHosted: Bool)] = []
        for enclosure in page.enclosures where enclosure.isVideo && enclosure.isFree {
            out.append((enclosure.url, isAppleHost(enclosure.url)))
        }
        if out.isEmpty, page.enclosures.allSatisfy({ !$0.isVideo }), let host = hostStream(in: page.html),
           !page.enclosures.contains(where: { $0.url == host && !$0.isFree }) {
            out.append((host, false))
        }
        // The host's own stream before Apple's copy of it.
        return out.sorted { !$0.appleHosted && $1.appleHosted }
    }

    static func isAppleHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.hasSuffix("apple.com") || host.hasSuffix("itunes.com") || host.hasSuffix("mzstatic.com")
    }

    enum Check: Equatable { case usable, refused(String) }

    /// Whether a stream can play here, in step with the audio, and if not, why.
    static func check(_ url: URL, audio: Double) async -> Check {
        guard let master = await text(url), master.hasPrefix("#EXTM3U") else {
            return .refused("Its video on Apple Podcasts couldn't be opened.")
        }
        guard let playlist = await mediaPlaylist(master, url: url) else {
            return .refused("Its video on Apple Podcasts couldn't be opened.")
        }
        if encrypted(playlist) || encrypted(master) {
            return .refused("Its video on Apple Podcasts is protected, so only Apple's app can play it.")
        }
        if playlist.contains("com.apple.hls.interstitial") {
            return .refused("Its video carries ads of its own, so it can't be kept in step with the audio.")
        }
        let total = streamLength(playlist)
        guard total > 0 else { return .refused("Its video on Apple Podcasts couldn't be opened.") }
        return lengthFits(stream: total, audio: audio) ? .usable
            : .refused("Its video is a different edit from the audio (\(Int(total / 60)) min against \(Int(audio / 60)) min).")
    }

    /// The media playlist to measure: a variant with a picture, not the
    /// audio-only one a master may list first.
    static func mediaPlaylist(_ master: String, url: URL) async -> String? {
        guard master.contains("#EXT-X-STREAM-INF") else { return master }
        guard let variant = videoVariant(in: master, base: url) else { return nil }
        return await text(variant)
    }

    static func videoVariant(in master: String, base: URL) -> URL? {
        let lines = master.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var fallback: URL?
        for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
            guard let uri = lines[(i + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let url = URL(string: uri, relativeTo: base)?.absoluteURL else { continue }
            let hasPicture = line.contains("RESOLUTION=") || line.contains("avc1") || line.contains("hvc1") || line.contains("hev1")
            if hasPicture { return url }
            if fallback == nil { fallback = url }
        }
        return fallback
    }

    /// FairPlay or other key systems PodSkipper has no key for.
    static func encrypted(_ playlist: String) -> Bool {
        playlist.split(separator: "\n").contains { line in
            (line.hasPrefix("#EXT-X-KEY") || line.hasPrefix("#EXT-X-SESSION-KEY")) && !line.contains("METHOD=NONE")
        }
    }

    static func streamLength(_ playlist: String) -> Double {
        playlist.split(separator: "\n").reduce(0.0) { sum, line in
            guard line.hasPrefix("#EXTINF:") else { return sum }
            return sum + (line.dropFirst(8).split(separator: ",").first.flatMap { Double($0) } ?? 0)
        }
    }

    /// Split out so the parsing can be tested without a network.
    static func hostStream(in html: String) -> URL? {
        let text = html.replacingOccurrences(of: "\\u002F", with: "/").replacingOccurrences(of: "\\/", with: "/")
        let pattern = #"https://[A-Za-z0-9.\-]+/[^"'\s<>\\]+\.m3u8[^"'\s<>\\]*"#
        for match in text.matches(of: try! Regex(pattern)) {
            let raw = String(text[match.range]).replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: raw), let host = url.host?.lowercased() else { continue }
            if host.hasSuffix("apple.com") || host.hasSuffix("itunes.com") || host.hasSuffix("mzstatic.com") { continue }
            return url
        }
        return nil
    }

    /// The stream's length, from its first variant's segment durations,
    /// against the audio's. A picture that is a different length has ads
    /// or edits of its own and would drift, so it isn't used. A stream with
    /// interstitials declared is refused for the same reason.
    static func lengthMatches(_ url: URL, audio: Double) async -> Bool {
        await check(url, audio: audio) == .usable
    }

    /// Whether a stream this long can be the same episode as the audio.
    ///
    /// Host video streams (Simplecast's "SGAI" ones) are the clean episode;
    /// the downloaded audio carries ads stitched in at download time, so it
    /// is often a few minutes *longer*. Stavvy's World #198: stream 6,130 s,
    /// Apple's clean length 6,130 s, the download ~6 % longer. So a stream
    /// may be shorter than the audio by up to a fifth, never longer; VideoSync
    /// then lines the two up by taking the inserted ads out, or refuses.
    static func lengthFits(stream: Double, audio: Double) -> Bool {
        // No audio length yet (not downloaded): take the stream on trust.
        guard audio > 0 else { return true }
        return stream <= audio + max(3, audio * 0.005) && stream >= audio * 0.8
    }

    private static func text(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// SponsorBlock's community labels for a YouTube upload, as hints.
///
/// Its data is licensed CC BY-NC-SA, so nothing of it is stored or shipped:
/// the app asks for one video's labels at the moment it finds ads, and uses
/// them only as places for the detector to read closely. It never cuts
/// anything because SponsorBlock said so.
///
/// The lookup is by the first four characters of the video id's SHA-256, so
/// the service never learns which video was asked about.
enum SponsorBlockHints {

    struct Label: Sendable {
        var category: String
        var start: Double
        var end: Double
    }

    static func labels(videoID: String) async -> [Label] {
        let digest = SHA256.hash(data: Data(videoID.utf8)).map { String(format: "%02x", $0) }.joined()
        let categories = #"["sponsor","selfpromo","intro","outro","interaction"]"#
        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(digest.prefix(4))")
        components?.queryItems = [URLQueryItem(name: "categories", value: categories)]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return parse(list, videoID: videoID)
    }

    static func parse(_ list: [[String: Any]], videoID: String) -> [Label] {
        guard let entry = list.first(where: { ($0["videoID"] as? String) == videoID }),
              let segments = entry["segments"] as? [[String: Any]] else { return [] }
        return segments.compactMap { s in
            guard let category = s["category"] as? String,
                  let range = s["segment"] as? [Double], range.count == 2, range[1] > range[0] else { return nil }
            return Label(category: category, start: range[0], end: range[1])
        }
    }

    /// Video times as places to look in the audio.
    ///
    /// The upload and the audio are different edits: on Stavvy's World #199
    /// the upload is two minutes *longer* than the audio, yet its sponsor
    /// reads sit three to four minutes *earlier*, because the audio carries
    /// stitched-in ads before them. So a label becomes a generous window
    /// either side — at least two minutes, more when the lengths differ more.
    /// The detector only reads there more closely.
    static func hints(_ labels: [Label], audioDuration: Double, videoDuration: Double?) -> [ClosedRange<Double>] {
        let difference = abs(audioDuration - (videoDuration ?? audioDuration))
        let reach = max(120, difference + 60)
        return labels.map { label in
            let lower = max(0, label.start - reach)
            var upper = label.end + reach
            if audioDuration > 0 { upper = min(audioDuration, upper) }
            return lower...max(lower + 1, upper)
        }
    }
}

/// The last look for video for each episode this launch, watched by the
/// player: a video that exists but can't be played here says why, rather
/// than the player quietly showing the cover (Pass 39). An episode with no
/// video anywhere says nothing.
@MainActor
@Observable
final class VideoLimitations {
    static let shared = VideoLimitations()
    var outcomes: [String: VideoSourceResolver.Outcome] = [:]

    /// Why this episode's video can't play in PodSkipper, when one exists.
    func reason(for guid: String) -> String? {
        switch outcomes[guid] {
        case .refused(let why): return why
        case .youtubeOnly(.refused(let why)): return why + " Watch on YouTube plays YouTube's upload instead."
        default: return nil
        }
    }
}
