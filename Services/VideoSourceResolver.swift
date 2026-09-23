import Foundation
import CryptoKit

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
        if !force, let last = episode.videoResolvedAt, Date.now.timeIntervalSince(last) < 86_400 {
            return episode.publicVideoURL != nil
        }
        episode.videoResolvedAt = .now
        let duration = episode.duration

        if let found = await applePageStream(for: episode), await lengthMatches(found, audio: duration) {
            episode.publicVideoURL = found.absoluteString
            episode.videoSourceRaw = Source.publicHLS.rawValue
            return true
        }
        if let show = episode.podcast, !show.youtubeChannel.isEmpty {
            let videos = await YouTubeLink.recentVideos(channelID: show.youtubeChannel)
            if let match = YouTubeLink.match(episodeTitle: episode.title, episodeNumber: episode.episodeNumber,
                                             isBonus: episode.isBonus, showTitle: show.title,
                                             published: episode.publishedAt, in: videos) {
                episode.youtubeVideoID = match.id
                episode.videoSourceRaw = Source.youtube.rawValue
            }
        }
        return false
    }

    // MARK: Apple's episode page

    /// The host's HLS link from Apple's public page for this episode.
    ///
    /// The page carries its data as JSON inside the HTML, with slashes
    /// escaped. Two kinds of stream appear: one on Apple's own domain, which
    /// is Apple's and is never touched, and sometimes one on the show's host.
    static func applePageStream(for episode: Episode) async -> URL? {
        guard let page = await EpisodeLink.apple(for: episode, at: 0) else { return nil }
        var request = URLRequest(url: page)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) else { return nil }
        return hostStream(in: html)
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
        guard let master = await text(url), master.hasPrefix("#EXTM3U") else { return false }
        var playlist = master
        if master.contains("#EXT-X-STREAM-INF") {
            guard let line = master.split(separator: "\n").first(where: { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                  let variant = URL(string: String(line).trimmingCharacters(in: .whitespaces), relativeTo: url),
                  let body = await text(variant.absoluteURL) else { return false }
            playlist = body
        }
        if playlist.contains("com.apple.hls.interstitial") { return false }
        let total = playlist.split(separator: "\n").reduce(0.0) { sum, line in
            guard line.hasPrefix("#EXTINF:") else { return sum }
            let value = line.dropFirst(8).split(separator: ",").first.flatMap { Double($0) } ?? 0
            return sum + value
        }
        guard total > 0 else { return false }
        return lengthFits(stream: total, audio: audio)
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
