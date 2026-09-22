import Foundation

// MARK: - The video version on YouTube
//
// Where the video in other apps comes from:
//
// • Apple Podcasts: the podcast's host sends Apple a private HLS stream
//   through Apple's own delivery system (since February 2026). It is never
//   in the public feed, and Apple offers no way for another app to read it.
// • Spotify: uploaded to Spotify, or sent through Spotify's closed
//   distribution API. Nothing is available to other apps.
// • YouTube (and YouTube Music): the show uploads full episodes to its own
//   channel, like any video. This is the one place the video is public.
//
// So for a show with an official YouTube channel, PodSkipper can find the
// episode's video there and show it in YouTube's own embedded player — the
// only way YouTube allows another app to play its videos. What that means,
// honestly: YouTube's ads play and can't be skipped, the video can't be fed
// through PodSkipper's audio engine (no Smart Speed, Voice Boost or ad
// skipping while watching), and it stops when the screen is off. When you
// close it, PodSkipper's own ad-free audio picks up at the same moment.
//
// Episodes are found in the channel's public video feed (the latest fifteen
// uploads), so this works for recent episodes; older ones won't match.

struct YouTubeVideo: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
    var published: Date
    /// From the channel page's thumbnail badge; the feed doesn't give it.
    var duration: Double?
}

enum YouTubeLink {

    // MARK: Channels

    /// A channel ID (UC…) from whatever was pasted: an ID, a
    /// youtube.com/channel/UC… link, or an @handle link, which is looked up
    /// once on the channel's own page.
    static func channelID(from input: String) async -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let range = trimmed.range(of: #"UC[A-Za-z0-9_-]{22}"#, options: .regularExpression) {
            return String(trimmed[range])
        }
        var address = trimmed
        if address.hasPrefix("@") { address = "https://www.youtube.com/" + address }
        if !address.contains("://") { address = "https://" + address }
        guard let url = URL(string: address), url.host?.contains("youtube.com") == true else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let html = String(data: data, encoding: .utf8) else { return nil }
        // The page's own channel, not the first channel it mentions.
        for pattern in [#""externalId":"(UC[A-Za-z0-9_-]{22})""#,
                        #"<link rel="canonical" href="https://www\.youtube\.com/channel/(UC[A-Za-z0-9_-]{22})""#,
                        #"<meta itemprop="identifier" content="(UC[A-Za-z0-9_-]{22})""#] {
            if let match = html.firstMatch(of: try! Regex(pattern)),
               let id = match.output[1].substring {
                return String(id)
            }
        }
        return nil
    }

    // MARK: Uploads

    private static var memory: [String: (Date, [YouTubeVideo])] = [:]
    private static let lock = NSLock()

    /// The channel's latest uploads. Kept for an hour.
    ///
    /// The channel's public Videos page first: it lists about thirty uploads
    /// with their lengths. YouTube's feed is the fallback — it lists only
    /// fifteen, and since September 2026 it has been answering 404 for every
    /// channel.
    static func recentVideos(channelID: String) async -> [YouTubeVideo] {
        let cached = lock.withLock { memory[channelID] }
        if let cached, Date.now.timeIntervalSince(cached.0) < 3600 { return cached.1 }
        var videos: [YouTubeVideo] = []
        if let url = URL(string: "https://www.youtube.com/channel/\(channelID)/videos") {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                             forHTTPHeaderField: "User-Agent")
            request.setValue("en-US", forHTTPHeaderField: "Accept-Language")
            if let (data, _) = try? await URLSession.shared.data(for: request),
               let html = String(data: data, encoding: .utf8) {
                videos = parsePage(html)
            }
        }
        if videos.isEmpty,
           let url = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)"),
           let (data, response) = try? await URLSession.shared.data(from: url),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let xml = String(data: data, encoding: .utf8) {
            videos = parseFeed(xml)
        }
        guard !videos.isEmpty else { return cached?.1 ?? [] }
        lock.withLock { memory[channelID] = (.now, videos) }
        return videos
    }

    /// Uploads from a channel's Videos page. Each tile's data holds the
    /// thumbnail (whose address carries the video id), the title, the
    /// length badge and "3 days ago".
    static func parsePage(_ html: String, now: Date = .now) -> [YouTubeVideo] {
        var videos: [YouTubeVideo] = []
        var seen = Set<String>()
        for tile in html.components(separatedBy: "\"lockupViewModel\":{").dropFirst() {
            let block = String(tile.prefix(8000))
            guard let idMatch = block.firstMatch(of: try! Regex(#"i\.ytimg\.com/vi/([A-Za-z0-9_-]{11})/"#)),
                  let id = idMatch.output[1].substring.map(String.init), !seen.contains(id),
                  let titleMatch = block.firstMatch(of: try! Regex(#""title":\{"content":"((?:[^"\\]|\\.)*)""#)),
                  let rawTitle = titleMatch.output[1].substring else { continue }
            seen.insert(id)
            let title = (try? JSONSerialization.jsonObject(with: Data("\"\(rawTitle)\"".utf8), options: .fragmentsAllowed) as? String)
                ?? String(rawTitle)
            var duration: Double?
            if let badge = block.firstMatch(of: try! Regex(#""thumbnailBadgeViewModel":\{"text":"([0-9:]+)""#)),
               let text = badge.output[1].substring {
                duration = text.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
            }
            var published = Date.distantPast
            if let ago = block.firstMatch(of: try! Regex(#""content":"(\d+)\s*(second|minute|hour|day|week|month|year|[smhdwy])s?\s+ago""#)),
               let n = ago.output[1].substring.flatMap({ Double($0) }), let unit = ago.output[2].substring {
                let seconds: Double
                switch unit.prefix(2) {
                case "se", "s": seconds = 1
                case "mi", "m": seconds = unit == "mo" || unit.hasPrefix("mon") ? 2_592_000 : 60
                case "mo": seconds = 2_592_000
                case "ho", "h": seconds = 3600
                case "da", "d": seconds = 86_400
                case "we", "w": seconds = 604_800
                default: seconds = 31_536_000
                }
                published = now.addingTimeInterval(-n * seconds)
            }
            videos.append(YouTubeVideo(id: id, title: title, published: published, duration: duration))
        }
        return videos
    }

    static func parseFeed(_ xml: String) -> [YouTubeVideo] {
        let formatter = ISO8601DateFormatter()
        var videos: [YouTubeVideo] = []
        for entry in xml.components(separatedBy: "<entry>").dropFirst() {
            guard let id = between(entry, "<yt:videoId>", "</yt:videoId>"),
                  let title = between(entry, "<title>", "</title>") else { continue }
            let published = between(entry, "<published>", "</published>").flatMap(formatter.date) ?? .distantPast
            videos.append(YouTubeVideo(id: id, title: decodeEntities(title), published: published))
        }
        return videos
    }

    // MARK: Matching an episode

    /// The upload that is this episode, or nil.
    ///
    /// Shows post clips as well as the full episode, all with the episode's
    /// number and guests in the title, so the full one has to win: the
    /// number, the guests' names and the words "Full Episode" all count, and
    /// a bonus episode never matches a regular one or the other way round.
    static func match(episodeTitle: String, episodeNumber: Int, isBonus: Bool, showTitle: String,
                      published: Date, in videos: [YouTubeVideo]) -> YouTubeVideo? {
        let showWords = words(showTitle)
        let wanted = words(episodeTitle).subtracting(showWords).subtracting(["bonus", "full", "episode", "ep"])
        // The number in the title is what the video's title will repeat; the
        // feed's own episode number can count differently.
        let number = numberIn(episodeTitle) ?? (episodeNumber > 0 ? episodeNumber : nil)
        let episodeIsBonus = isBonus || episodeTitle.lowercased().hasPrefix("bonus")

        var best: (score: Double, video: YouTubeVideo)?
        for video in videos {
            let lower = video.title.lowercased()
            let have = words(video.title)
            let overlap = wanted.isEmpty ? 0 : Double(wanted.intersection(have).count) / Double(wanted.count)
            guard overlap >= 0.5 else { continue }
            let videoIsBonus = lower.contains("bonus")
            guard videoIsBonus == episodeIsBonus else { continue }
            var score = overlap * 10
            if let number, lower.range(of: "#\(number)\\b", options: .regularExpression) != nil { score += 5 }
            if lower.contains("full episode") { score += 4 }
            // Days apart, as a small tiebreak.
            score -= min(3, abs(video.published.timeIntervalSince(published)) / 86_400 / 7)
            if best == nil || score > best!.score { best = (score, video) }
        }
        return best?.video
    }

    /// The video's page, starting at a moment.
    static func watchURL(_ id: String, at seconds: Double) -> URL? {
        URL(string: "https://www.youtube.com/watch?v=\(id)&t=\(max(0, Int(seconds)))s")
    }

    // MARK: Time on the video ↔ time in the audio

    /// The podcast feed's audio has ads stitched in that the YouTube upload
    /// doesn't (the ones PodSkipper identified as produced spots rather than
    /// read by the host). Moving between the two means adding or removing
    /// those. Approximate: it is only as good as the ads that were found.
    static func videoTime(fromAudio audio: Double, insertedAds: [(start: Double, end: Double)]) -> Double {
        var removed = 0.0
        for ad in insertedAds.sorted(by: { $0.start < $1.start }) where ad.start < audio {
            removed += min(audio, ad.end) - ad.start
        }
        return max(0, audio - removed)
    }

    static func audioTime(fromVideo video: Double, insertedAds: [(start: Double, end: Double)]) -> Double {
        var audio = video
        for ad in insertedAds.sorted(by: { $0.start < $1.start }) where ad.start <= audio {
            audio += ad.end - ad.start
        }
        return audio
    }

    // MARK: Text

    private static let stopwords: Set<String> = ["the", "and", "with", "a", "an", "of", "to", "in", "on", "for", "w"]

    private static func words(_ text: String) -> Set<String> {
        let cleaned = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return Set(String(cleaned).split(separator: " ").map(String.init)
            .filter { $0.count >= 2 && !stopwords.contains($0) && Int($0) == nil })
    }

    private static func numberIn(_ title: String) -> Int? {
        guard let range = title.range(of: #"#\d+"#, options: .regularExpression) else { return nil }
        return Int(title[range].dropFirst())
    }

    private static func between(_ text: String, _ start: String, _ end: String) -> String? {
        guard let a = text.range(of: start), let b = text.range(of: end, range: a.upperBound..<text.endIndex)
        else { return nil }
        return String(text[a.upperBound..<b.lowerBound])
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
