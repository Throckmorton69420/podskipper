import Foundation

/// Minimal RSS 2.0 + iTunes namespace parser.
/// Deliberately forgiving: podcast feeds in the wild are a mess.
struct ParsedFeed {
    var title = ""
    var author = ""
    var summary = ""
    var artworkURL: String?
    var items: [ParsedItem] = []
}

struct ParsedItem {
    var guid = ""
    var title = ""
    var description = ""
    var audioURL = ""
    /// The enclosure's MIME type, e.g. "audio/mpeg" or "video/mp4". Empty
    /// when the feed omits it, which is common and means audio.
    var mediaType = ""
    var publishedAt = Date()
    var duration: Double = 0
    var artworkURL: String?
    var season = 0
    var episodeNumber = 0
}

extension Episode {
    /// One place that turns a parsed feed item into a stored episode.
    /// Four call sites used to build this by hand and could drift apart.
    convenience init(item: ParsedItem) {
        self.init(guid: item.guid, title: item.title,
                  episodeDescription: item.description,
                  audioURL: item.audioURL, publishedAt: item.publishedAt,
                  duration: item.duration, artworkURL: item.artworkURL)
        self.seasonNumber = item.season
        self.episodeNumber = item.episodeNumber
        self.mediaType = item.mediaType
    }

    /// "S2 E14", or just "E14", or nothing.
    var numberLabel: String {
        if seasonNumber > 0 && episodeNumber > 0 { return "S\(seasonNumber) E\(episodeNumber)" }
        if episodeNumber > 0 { return "E\(episodeNumber)" }
        return ""
    }
}

enum FeedError: LocalizedError {
    case badURL, network(String), notXML, noItems

    var errorDescription: String? {
        switch self {
        case .badURL:            return "That doesn't look like a URL."
        case .network(let m):    return "Couldn't reach the feed: \(m)"
        case .notXML:            return "That URL didn't return a podcast feed."
        case .noItems:           return "The feed parsed but contained no episodes."
        }
    }
}

enum FeedParser {

    static func fetch(_ urlString: String) async throws -> ParsedFeed {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw FeedError.badURL
        }
        let data: Data
        do {
            var request = URLRequest(url: url)
            // Some hosts 403 an empty UA.
            request.setValue("PodSkipper/1.0", forHTTPHeaderField: "User-Agent")
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw FeedError.network(error.localizedDescription)
        }
        let feed = try parse(data)
        guard !feed.items.isEmpty else { throw FeedError.noItems }
        return feed
    }

    static func parse(_ data: Data) throws -> ParsedFeed {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { throw FeedError.notXML }
        return delegate.feed
    }

    // MARK: - XMLParser delegate

    private final class Delegate: NSObject, XMLParserDelegate {
        var feed = ParsedFeed()
        private var item: ParsedItem?
        private var text = ""
        private var inImage = false

        private static let formatters: [DateFormatter] = {
            let patterns = ["EEE, dd MMM yyyy HH:mm:ss Z",
                            "EEE, dd MMM yyyy HH:mm:ss zzz",
                            "yyyy-MM-dd'T'HH:mm:ssZ"]
            return patterns.map {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = $0
                return f
            }
        }()

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes attrs: [String: String]) {
            text = ""
            switch name {
            case "item":
                item = ParsedItem()
            case "image":
                inImage = true
            case "enclosure":
                // Video used to be discarded here: anything whose type did
                // not begin with "audio" was dropped, so a video podcast
                // appeared in the app as a show with no episodes at all. The
                // type is kept now, and it is what decides which engine plays
                // the file.
                if let url = attrs["url"] {
                    let type = attrs["type"] ?? ""
                    let playable = type.isEmpty
                        || type.hasPrefix("audio")
                        || type.hasPrefix("video")
                    if playable {
                        item?.audioURL = url
                        item?.mediaType = type
                    }
                }
            case "itunes:image":
                if let href = attrs["href"] {
                    if item != nil { item?.artworkURL = href }
                    else if feed.artworkURL == nil { feed.artworkURL = href }
                }
            default:
                break
            }
        }

        func parser(_ p: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ p: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(data: CDATABlock, encoding: .utf8) ?? ""
        }

        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if item != nil {
                switch name {
                case "title":                       item?.title = value
                case "description", "itunes:summary":
                    if item?.description.isEmpty ?? false { item?.description = value }
                case "guid":                        item?.guid = value
                case "pubDate":                     item?.publishedAt = Self.date(from: value)
                case "itunes:duration":             item?.duration = Self.seconds(from: value)
                case "itunes:season":               item?.season = Int(value) ?? 0
                case "itunes:episode":              item?.episodeNumber = Int(value) ?? 0
                case "url" where inImage:           break
                case "item":
                    if var finished = item {
                        if finished.guid.isEmpty { finished.guid = finished.audioURL }
                        if !finished.audioURL.isEmpty { feed.items.append(finished) }
                    }
                    item = nil
                default: break
                }
            } else {
                switch name {
                case "title" where feed.title.isEmpty:      feed.title = value
                case "itunes:author" where feed.author.isEmpty: feed.author = value
                case "description" where feed.summary.isEmpty:  feed.summary = value
                case "url" where inImage && feed.artworkURL == nil: feed.artworkURL = value
                default: break
                }
            }
            if name == "image" { inImage = false }
            text = ""
        }

        private static func date(from s: String) -> Date {
            for f in formatters { if let d = f.date(from: s) { return d } }
            return Date()
        }

        /// iTunes duration is either seconds ("3600") or HH:MM:SS / MM:SS.
        private static func seconds(from s: String) -> Double {
            let parts = s.split(separator: ":").compactMap { Double($0) }
            switch parts.count {
            case 1: return parts[0]
            case 2: return parts[0] * 60 + parts[1]
            case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
            default: return 0
            }
        }
    }
}
