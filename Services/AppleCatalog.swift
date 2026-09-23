import Foundation

/// Apple's podcast catalog: the public API podcasts.apple.com itself reads,
/// with the token that web page gives every visitor.
///
/// It supplies three things an RSS feed can't:
/// 1. **Video for every episode that has it.** Apple lists the host's own
///    video stream beside the audio (`offers[].alternateAssets`). On Stavvy's
///    World 165 of the newest 300 episodes have one, #198 among them; the feed
///    has none. Apple's own stream (`hlsUrl`) is FairPlay-encrypted audio and
///    is never used.
/// 2. **Episodes older than the feed.** Feeds often list only the newest
///    few hundred; Apple keeps everything it has seen.
/// 3. **Each episode's clean length**, without the ads stitched in at
///    download time: Stavvy's #199 is 5,682 s here and 6,096 s downloaded.
///    The detector uses the difference as a check (research §5, stage 0).
///
/// One request returns 300 episodes, so even an 800-episode show is three.
enum AppleCatalog {

    struct Item: Sendable, Equatable {
        var appleID: String
        var guid: String
        var title: String
        var published: Date?
        /// Seconds, without inserted ads. Zero when Apple doesn't say.
        var duration: Double
        var audioURL: String?
        /// The host's own video stream, when there is one.
        var videoStream: String?
        var episodeNumber: Int
        var summary: String
        var artworkURL: String?
        var isExplicit: Bool
        var kind: String
    }

    // MARK: Episodes

    /// Every episode Apple lists for a show, newest first. Empty on failure.
    static func episodes(showID: Int, maxPages: Int = 12) async -> [Item] {
        var out: [Item] = []
        var path: String? = "/v1/catalog/us/podcasts/\(showID)/episodes?limit=300"
        var pages = 0
        while let next = path, pages < maxPages {
            pages += 1
            guard let json = await get(next) else { break }
            let data = json["data"] as? [[String: Any]] ?? []
            out += data.compactMap(item)
            path = (json["next"] as? String).map { $0.contains("limit=") ? $0 : $0 + "&limit=300" }
            if data.isEmpty { break }
        }
        return out
    }

    static func item(_ entry: [String: Any]) -> Item? {
        guard let id = entry["id"] as? String, let a = entry["attributes"] as? [String: Any] else { return nil }
        let offers = a["offers"] as? [[String: Any]] ?? []
        let video = offers.lazy
            .flatMap { ($0["alternateAssets"] as? [[String: Any]]) ?? [] }
            .first { (($0["mediaKinds"] as? [String]) ?? []).contains("video") }?["url"] as? String
        let description = a["description"] as? [String: Any]
        let artwork = (a["artwork"] as? [String: Any])?["url"] as? String
        return Item(appleID: id,
                    guid: a["guid"] as? String ?? "",
                    title: a["name"] as? String ?? "",
                    published: (a["releaseDateTime"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
                    duration: Double(a["durationInMilliseconds"] as? Int ?? 0) / 1000,
                    audioURL: a["assetUrl"] as? String,
                    videoStream: video.flatMap(usable),
                    episodeNumber: a["episodeNumber"] as? Int ?? 0,
                    summary: description?["standard"] as? String ?? "",
                    artworkURL: artwork?.replacingOccurrences(of: "{w}x{h}", with: "600x600")
                        .replacingOccurrences(of: "{f}", with: "jpg"),
                    isExplicit: (a["contentRating"] as? String) == "explicit",
                    kind: a["kind"] as? String ?? "full")
    }

    /// A title reduced to letters and digits, for matching when guids differ.
    static func plain(_ title: String) -> String {
        String(title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Only the host's streams; Apple's own are encrypted and not ours to play.
    static func usable(_ url: String) -> String? {
        guard let host = URL(string: url)?.host?.lowercased() else { return nil }
        if host.hasSuffix("apple.com") || host.hasSuffix("itunes.com") || host.hasSuffix("mzstatic.com") { return nil }
        return url
    }

    // MARK: The web token

    private static let tokenKey = "appleCatalogToken"
    private static let api = "https://amp-api.podcasts.apple.com"
    private static let browserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    /// One API call; a rejected token is fetched again once.
    static func get(_ path: String) async -> [String: Any]? {
        for attempt in 0..<2 {
            guard let token = await token(refresh: attempt > 0), let url = URL(string: api + path) else { return nil }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("https://podcasts.apple.com", forHTTPHeaderField: "Origin")
            request.timeoutInterval = 20
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { continue }
            guard status == 200 else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        return nil
    }

    /// The token podcasts.apple.com ships inside its main script. Kept until
    /// a week before it expires (they last months), so the 2 MB script is
    /// fetched a few times a year at most.
    static func token(refresh: Bool) async -> String? {
        if !refresh, let saved = UserDefaults.standard.string(forKey: tokenKey),
           let expires = expiry(saved), expires.timeIntervalSinceNow > 7 * 86_400 {
            return saved
        }
        guard let page = await text("https://podcasts.apple.com/us/browse"),
              let script = page.firstMatch(of: try! Regex(#"/assets/index[^"']*\.js"#)).map({ String(page[$0.range]) }),
              let js = await text("https://podcasts.apple.com" + script) else { return nil }
        let jwt = js.matches(of: try! Regex(#"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#))
            .map { String(js[$0.range]) }
            .first { expiry($0) != nil }
        if let jwt { UserDefaults.standard.set(jwt, forKey: tokenKey) }
        return jwt
    }

    /// The `exp` claim of a JSON Web Token.
    static func expiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var body = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? Double, claims["iss"] != nil else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private static func text(_ address: String) async -> String? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(browserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
