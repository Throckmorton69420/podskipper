import Foundation

// MARK: - Apple Podcasts' own pages
//
// The New tab, the Search tab's categories, a category's page, Top Charts and
// Apple's hand-made collections are all built by Apple's servers, not by the
// app: the Podcasts app downloads a page description — a list of "shelves",
// each with a content type and its items — and draws it. None of that layout
// is inside the app bundle, which is why comparing bundles never showed it.
//
// Apple's public web player (podcasts.apple.com) is sent the *same* page
// descriptions, written into each page as JSON so the site can draw without
// a second request. The shelf types match the ones compiled into the app's
// ShelfKit framework (`showcase`, `largeLockup`, `largeChartLockup`,
// `episodeChartLockup`, `episodeHero`, `showHero`, `brick`, `searchLanding`…),
// so reading that JSON gives PodSkipper Apple's actual New page — its
// editors' picks, in its order, with its artwork — rather than a guess.
//
// This depends on the web page keeping its current shape. When it cannot be
// read, the tabs fall back to PodSkipper's own shelves.

/// A size-able image on Apple's image server: `…/{w}x{h}{c}.{f}`.
struct StoreArtwork: Codable, Hashable, Sendable {
    var template: String
    var width: Double
    var height: Double
    /// Hex, no "#". The colour Apple paints behind the image while it loads,
    /// and which the cards on New use as their background.
    var background: String?
    var textPrimary: String?
    var textSecondary: String?
    var crop: String?

    /// The URL for this image at `w`×`h` points' worth of pixels (the caller
    /// passes pixels). Apple's server crops and scales, so a 4320-pixel-wide
    /// banner arrives at the size it is drawn — which is also why the app
    /// never has to decode a picture bigger than the screen.
    func url(width w: Int, height h: Int, format: String = "jpg") -> String {
        let cropCode = (crop?.isEmpty == false) ? crop! : "bb"
        return template
            .replacingOccurrences(of: "{w}", with: String(w))
            .replacingOccurrences(of: "{h}", with: String(h))
            .replacingOccurrences(of: "{c}", with: cropCode)
            .replacingOccurrences(of: "{f}", with: format)
    }

    /// A square request, for covers.
    func squareURL(_ pixels: Int) -> String { url(width: pixels, height: pixels) }

    var aspect: Double { height > 0 ? width / height : 1 }
}

struct StoreItem: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case showcase, show, episode, showHero, brick, link, channel, categoryHeader, paragraph
    }
    var id: String
    var kind: Kind
    var title: String = ""
    /// Small capitals above a title ("NEW SEASON"), or an episode's "13h ago".
    var eyebrow: String?
    var subtitles: [String] = []
    var ordinal: String?
    var artwork: StoreArtwork?
    /// The tall editorial art behind a hero card.
    var uber: StoreArtwork?
    /// A show's cover, when `artwork` is something else (an episode's own art).
    var icon: StoreArtwork?
    var summary: String?
    var showTitle: String?
    var showAdamID: String?
    var adamID: String?
    var feedURL: String?
    var isExplicit = false
    var isVideo = false
    var duration: Double?
    var rating: Double?
    var ratingCount: Int?
    var genre: String?
    /// "Trailer" or "Latest Episode" on a show hero's button.
    var buttonTitle: String?
    var streamURL: String?
    var episodeType: String?
    /// Where tapping it goes, as a podcasts.apple.com address.
    var destination: String?
    var meta: [String] = []
}

struct StoreShelf: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case showcase, largeLockup, largeChartLockup, episodeChartLockup, episodeHero, showHero
        case brick, searchLanding, powerswoosh, channelOrdinal, categoryHeader, paragraph
        case unknown
    }
    var id: String
    var kind: Kind
    var title: String?
    var subtitle: String?
    var rowsPerColumn: Int
    var items: [StoreItem]
    /// A podcasts.apple.com page for "See All", when there is one.
    var seeAll: String?
}

struct StorePage: Codable, Hashable, Sendable {
    var title: String?
    var shelves: [StoreShelf]
    var fetchedAt: Date
}

// MARK: - Reading a page

enum StoreClient {

    enum Failure: LocalizedError {
        case badAddress, noData, unreadable
        var errorDescription: String? {
            switch self {
            case .badAddress: return "That page isn't on Apple Podcasts."
            case .noData:     return "Apple Podcasts didn't send a page."
            case .unreadable: return "Apple Podcasts' page has changed shape and couldn't be read."
            }
        }
    }

    /// Two-letter storefront from the phone's region; Apple's pages are
    /// per-country.
    static var storefront: String {
        (Locale.current.region?.identifier ?? "US").lowercased()
    }

    /// "new" → https://podcasts.apple.com/us/new
    static func url(forPath path: String) -> URL? {
        URL(string: "https://podcasts.apple.com/\(storefront)/\(path)")
    }

    /// Normalises a link found in a page into something fetchable, or nil when
    /// it points somewhere only Apple's own apps can read.
    static func fetchable(_ address: String?) -> URL? {
        guard let address, let url = URL(string: address) else { return nil }
        if url.host == "podcasts.apple.com" { return url }
        // "See All" on a chart points at Apple's private API. The same chart
        // is a public page.
        if url.host?.hasPrefix("amp-api") == true, url.path.contains("/charts") {
            return URL(string: "https://podcasts.apple.com/\(storefront)/charts")
        }
        return nil
    }

    private static let memory = NSCache<NSString, Box>()
    private final class Box { let page: StorePage; init(_ p: StorePage) { page = p } }

    /// How long a page is trusted. Apple updates New a few times a day at
    /// most; fetching a two-megabyte page every time the tab is opened would
    /// cost data and battery for nothing.
    static let freshFor: TimeInterval = 6 * 60 * 60

    private static var cacheDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StorePages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Part of every cache file's name. The cache holds pages already read
    /// into PodSkipper's own shape, so a new version of the reader must not
    /// be handed pages read by the old one — raise this when parsing changes.
    private static let cacheVersion = 2

    private static func cacheFile(for url: URL) -> URL {
        var hash: UInt64 = 5381 &+ UInt64(cacheVersion)
        for byte in url.absoluteString.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return cacheDirectory.appendingPathComponent(String(hash, radix: 36) + ".json")
    }

    /// Whatever is cached, however old — shown at once while a fresh copy
    /// is fetched.
    static func cached(_ url: URL) -> StorePage? {
        if let box = memory.object(forKey: url.absoluteString as NSString) { return box.page }
        // (Disk copies from an older reader have a different name — see
        // `cacheVersion` — and are simply never found.)
        guard let data = try? Data(contentsOf: cacheFile(for: url)),
              let page = try? JSONDecoder().decode(StorePage.self, from: data) else { return nil }
        memory.setObject(Box(page), forKey: url.absoluteString as NSString)
        return page
    }

    static func isFresh(_ page: StorePage) -> Bool {
        Date.now.timeIntervalSince(page.fetchedAt) < freshFor
    }

    /// Fetches and reads a page. The download, the JSON and the parsing all
    /// happen off the main thread; only the small result comes back.
    static func load(_ url: URL, force: Bool = false) async throws -> StorePage {
        if !force, let page = cached(url), isFresh(page) { return page }
        let page = try await Task.detached(priority: .userInitiated) {
            try await fetch(url)
        }.value
        memory.setObject(Box(page), forKey: url.absoluteString as NSString)
        if let data = try? JSONEncoder().encode(page) {
            try? data.write(to: cacheFile(for: url), options: .atomic)
        }
        return page
    }

    private static func fetch(_ url: URL) async throws -> StorePage {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        // The site sends the same page to any browser; this is Safari's.
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.noData
        }
        guard let json = extractJSON(from: data) else { throw Failure.noData }
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let first = (object["data"] as? [[String: Any]])?.first,
              let pageObject = first["data"] as? [String: Any] else { throw Failure.unreadable }
        return parse(pageObject)
    }

    /// The JSON the site writes into the page for itself.
    static func extractJSON(from html: Data) -> Data? {
        let opener = Data(#"id="serialized-server-data">"#.utf8)
        let closer = Data("</script>".utf8)
        guard let start = html.range(of: opener)?.upperBound,
              let end = html.range(of: closer, in: start..<html.endIndex)?.lowerBound
        else { return nil }
        return html.subdata(in: start..<end)
    }

    // MARK: Parsing

    static func parse(_ page: [String: Any]) -> StorePage {
        let shelves = (page["shelves"] as? [[String: Any]] ?? []).compactMap(parseShelf)
        return StorePage(title: page["title"] as? String, shelves: shelves, fetchedAt: .now)
    }

    private static func parseShelf(_ s: [String: Any]) -> StoreShelf? {
        let type = s["contentType"] as? String ?? ""
        let kind = StoreShelf.Kind(rawValue: type) ?? .unknown
        guard kind != .unknown else { return nil }
        let items = (s["items"] as? [[String: Any]] ?? []).compactMap(parseItem)
        guard !items.isEmpty else { return nil }
        let seeAll = (s["seeAllAction"] as? [String: Any])?["pageUrl"] as? String
        return StoreShelf(id: s["id"] as? String ?? UUID().uuidString,
                          kind: kind,
                          title: nonEmpty(s["title"]),
                          subtitle: nonEmpty(s["subtitle"]),
                          rowsPerColumn: max(1, s["rowsPerColumn"] as? Int ?? 1),
                          items: items,
                          seeAll: seeAll)
    }

    private static func parseItem(_ o: [String: Any]) -> StoreItem? {
        let kindName = o["$kind"] as? String ?? ""
        let id = (o["id"] as? String) ?? (o["adamId"] as? String) ?? UUID().uuidString
        let click = (o["clickAction"] as? [String: Any]) ?? (o["segue"] as? [String: Any])
        let destination = click?["pageUrl"] as? String

        switch kindName {
        case "Showcase":
            var item = StoreItem(id: id, kind: .showcase)
            item.title = o["title"] as? String ?? ""
            item.eyebrow = nonEmpty(o["caption"])
            item.summary = nonEmpty(o["overlayingCaption"])
            item.artwork = artwork(o["artwork"])
            item.destination = destination
            for entry in o["showMetadata"] as? [[String: Any]] ?? [] {
                if let category = entry["category"] as? String { item.meta.append(category) }
                if let frequency = entry["updateFrequency"] as? String { item.meta.append(frequency) }
            }
            return item

        case "LegacyLockup":
            var item = StoreItem(id: id, kind: .show)
            item.title = o["title"] as? String ?? ""
            item.showTitle = nonEmpty(o["titleAccessibilityLabel"])
            item.subtitles = o["subtitles"] as? [String] ?? []
            item.ordinal = nonEmpty(o["ordinal"])
            item.artwork = artwork(o["icon"])
            item.adamID = o["adamId"] as? String
            item.isExplicit = o["isExplicit"] as? Bool ?? false
            item.isVideo = (o["mediaKinds"] as? [String] ?? []).contains("video")
            let offer = (o["contextAction"] as? [String: Any])?["podcastOffer"] as? [String: Any]
            item.feedURL = offer?["feedUrl"] as? String
            item.destination = destination
            return item

        case "LegacyEpisodeLockup":
            var item = StoreItem(id: id, kind: .episode)
            item.title = o["title"] as? String ?? ""
            item.showTitle = o["showTitle"] as? String
            item.showAdamID = o["showAdamId"] as? String
            item.adamID = o["adamId"] as? String
            item.eyebrow = nonEmpty(o["caption"])
            item.summary = nonEmpty(o["summary"])
            // A video episode reports 0 here and its length on the audio
            // enclosure.
            let enclosureLength = (o["mediaEnclosures"] as? [[String: Any]] ?? [])
                .compactMap { $0["duration"] as? Double }.max()
            let stated = o["duration"] as? Double ?? 0
            item.duration = stated > 0 ? stated : enclosureLength
            item.isExplicit = o["isExplicit"] as? Bool ?? false
            item.isVideo = (o["mediaType"] as? String) == "video"
            item.episodeType = o["episodeType"] as? String
            item.icon = artwork(o["icon"])
            item.artwork = artwork(o["episodeArtwork"]) ?? item.icon
            item.uber = artwork(o["showUberArtwork"])
            item.streamURL = (o["mediaEnclosures"] as? [[String: Any]])?.first?["streamUrl"] as? String
            item.destination = destination
            return item

        case "ShowHero":
            var item = StoreItem(id: id, kind: .showHero)
            item.title = o["title"] as? String ?? ""
            item.adamID = (o["adamId"] as? String) ?? id
            item.summary = nonEmpty(o["description"])
            item.artwork = artwork(o["artwork"])
            item.uber = artwork(o["uberArtwork"])
            item.rating = o["rating"] as? Double
            item.ratingCount = o["ratingCount"] as? Int
            item.genre = nonEmpty(o["genreName"])
            item.isExplicit = (o["contentRating"] as? String) == "explicit"
            let trailer = o["playTrailerAction"] as? [String: Any]
            let latest = o["playEpisodeAction"] as? [String: Any]
            item.buttonTitle = trailer != nil ? "Trailer" : (latest != nil ? "Latest Episode" : nil)
            let offer = (trailer ?? latest)?["episodeOffer"] as? [String: Any]
            let show = (offer?["showOffer"] as? [String: Any]) ?? (offer?["podcastOffer"] as? [String: Any])
            item.feedURL = show?["feedUrl"] as? String
            item.streamURL = (offer?["currentMediaEnclosure"] as? [String: Any])?["streamUrl"] as? String
            item.destination = destination
            return item

        case "Brick":
            var item = StoreItem(id: id, kind: .brick)
            item.title = o["accessibilityLabel"] as? String ?? ""
            item.artwork = artwork(o["artwork"])
            item.destination = destination
            return item

        case "Link":
            var item = StoreItem(id: id, kind: .link)
            item.title = o["title"] as? String ?? ""
            item.summary = nonEmpty(o["subtitle"])
            item.artwork = artwork(o["artwork"])
            item.showTitle = (o["artwork"] as? [String: Any])?["accessibilityTitle"] as? String
            item.destination = destination
            return item

        case "LegacyChannelLockup":
            var item = StoreItem(id: id, kind: .channel)
            item.title = o["title"] as? String ?? ""
            item.subtitles = o["subtitles"] as? [String] ?? []
            item.ordinal = nonEmpty(o["ordinal"])
            item.artwork = artwork(o["icon"])
            item.destination = destination
            return item

        case "CategoryHeader":
            var item = StoreItem(id: id, kind: .categoryHeader)
            let category = o["category"] as? [String: Any]
            item.title = category?["title"] as? String ?? ""
            item.artwork = artwork(o["artwork"])
            item.icon = artwork(category?["artwork"])
            return item

        case "Paragraph":
            var item = StoreItem(id: id, kind: .paragraph)
            item.summary = o["text"] as? String
            return item

        default:
            return nil
        }
    }

    private static func artwork(_ value: Any?) -> StoreArtwork? {
        guard let o = value as? [String: Any], let template = o["template"] as? String else { return nil }
        let colours = o["textColors"] as? [String: Any]
        return StoreArtwork(template: template,
                            width: o["width"] as? Double ?? 1,
                            height: o["height"] as? Double ?? 1,
                            background: o["backgroundColor"] as? String,
                            textPrimary: colours?["primary"] as? String,
                            textSecondary: colours?["secondary"] as? String,
                            crop: o["crop"] as? String)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The show id in a podcasts.apple.com show or episode address
    /// (`…/id1200361736?i=…`), for looking up its feed.
    static func showID(in address: String?) -> Int? {
        guard let address, let range = address.range(of: #"/id(\d+)"#, options: .regularExpression)
        else { return nil }
        return Int(address[range].dropFirst(3))
    }

    /// Whether an address is a show or episode page (handled by PodSkipper's
    /// own show preview) rather than a page of shelves.
    static func isShowPage(_ address: String?) -> Bool {
        guard let address else { return false }
        return address.contains("/podcast/")
    }
}
