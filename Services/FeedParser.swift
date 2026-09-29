import Foundation

/// Minimal RSS 2.0 + iTunes namespace parser.
/// Deliberately forgiving: podcast feeds in the wild are a mess.
struct ParsedFeed: Sendable {
    var title = ""
    var author = ""
    var summary = ""
    var artworkURL: String?
    var items: [ParsedItem] = []
    /// Hosts named on the show itself (`podcast:person` outside any item).
    var people: [String] = []
    /// The show's own `itunes:explicit`, which an episode without its own
    /// inherits.
    var explicit = false
}

struct ParsedItem: Sendable {
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
    /// A video version offered alongside the audio: Podcasting 2.0's
    /// `podcast:alternateEnclosure` (an HLS stream or an mp4), a second
    /// `<enclosure>` that is video, or Media RSS's `media:content`.
    var videoURL: String?
    /// People named on the episode (`podcast:person`), as "role:Name".
    var people: [String] = []
    /// Nil when the item does not say; the show's value applies then.
    var explicit: Bool?
    /// `itunes:episodeType`, lowercased: "full", "bonus", "trailer" or empty.
    var episodeType = ""
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
        self.videoURL = item.videoURL
        self.people = item.people.joined(separator: "|")
        self.isExplicit = item.explicit ?? false
        self.episodeType = item.episodeType
    }

    var isBonus: Bool { episodeType == "bonus" }
    var isTrailer: Bool { episodeType == "trailer" }

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
        var feed = delegate.feed
        // An episode that says nothing takes the show's rating.
        if feed.explicit {
            for index in feed.items.indices where feed.items[index].explicit == nil {
                feed.items[index].explicit = true
            }
        }
        return feed
    }

    // MARK: - XMLParser delegate

    private final class Delegate: NSObject, XMLParserDelegate {
        var feed = ParsedFeed()
        private var item: ParsedItem?
        private var text = ""
        private var inImage = false
        /// Inside a `podcast:alternateEnclosure`, with its declared type.
        private var alternate: VideoCandidate?
        /// The video versions an item offers, collected so the best one can
        /// be chosen when the item closes rather than whichever came first.
        private var videoCandidates: [VideoCandidate] = []
        private var personRole = ""
        private var personImage = ""

        struct VideoCandidate {
            var type: String
            var height: Int
            var bitrate: Int
            var url: String?

            var isHLS: Bool {
                type.contains("mpegurl") || (url?.lowercased().components(separatedBy: "?").first?.hasSuffix(".m3u8") ?? false)
            }

            /// HLS first — it adapts to the connection and starts at once —
            /// then the tallest picture, then the higher bitrate.
            static func best(_ all: [VideoCandidate]) -> String? {
                all.filter { $0.url != nil }
                    .max { a, b in
                        (a.isHLS ? 1 : 0, a.height, a.bitrate) < (b.isHLS ? 1 : 0, b.height, b.bitrate)
                    }?.url
            }

            /// Video, or an HLS stream not declared as audio. An audio
            /// alternate (Opus, a lower bitrate, an audio-only playlist) is
            /// not a picture.
            static func isVideo(type: String) -> Bool {
                type.hasPrefix("video") || (type.contains("mpegurl") && !type.hasPrefix("audio"))
            }

            /// Worth keeping as a picture: declared video, or an .m3u8 whose
            /// declared type doesn't say it is sound.
            var looksLikeVideo: Bool {
                Self.isVideo(type: type) || (isHLS && !type.hasPrefix("audio"))
            }

            /// Only addresses a phone can fetch: sources can also be IPFS or
            /// torrent links, which AVPlayer can't open.
            static func fetchable(_ uri: String) -> Bool {
                uri.hasPrefix("https://") || uri.hasPrefix("http://")
            }
        }

        // MARK: Namespaces
        //
        // A prefix is only a local alias; the URI is what names a namespace.
        // Nearly every feed spells them `podcast:` and `itunes:`, but nothing
        // obliges it, and a feed declaring `xmlns:pc="https://podcastindex.org/…"`
        // was invisible to a parser that matched the letters. Element names are
        // rewritten to the usual prefix for any declared URI we recognise, and
        // everything below keeps matching the familiar spelling.
        private var prefixes: [String: String] = [:]

        private static let knownNamespaces: [(uri: String, prefix: String)] = [
            ("podcastindex.org/namespace/1.0", "podcast"),
            ("github.com/podcastindex-org/podcast-namespace", "podcast"),
            ("www.itunes.com/dtds/podcast-1.0.dtd", "itunes"),
            ("search.yahoo.com/mrss", "media"),
        ]

        private func learnNamespaces(_ attrs: [String: String]) {
            for (key, value) in attrs where key.hasPrefix("xmlns:") {
                let alias = String(key.dropFirst(6))
                let bare = value.replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: "http://", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if let known = Self.knownNamespaces.first(where: { bare.hasPrefix($0.uri) }) {
                    prefixes[alias] = known.prefix
                }
            }
        }

        private func normalised(_ name: String) -> String {
            guard !prefixes.isEmpty, let colon = name.firstIndex(of: ":") else { return name }
            let alias = String(name[..<colon])
            guard let canonical = prefixes[alias], canonical != alias else { return name }
            return canonical + name[colon...]
        }

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

        func parser(_ p: XMLParser, didStartElement rawName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes attrs: [String: String]) {
            text = ""
            if attrs.keys.contains(where: { $0.hasPrefix("xmlns:") }) { learnNamespaces(attrs) }
            let name = normalised(rawName)
            switch name {
            case "item":
                item = ParsedItem()
                videoCandidates = []
            case "image":
                inImage = true
            case "enclosure":
                // Video used to be discarded here: anything whose type did
                // not begin with "audio" was dropped, so a video podcast
                // appeared in the app as a show with no episodes at all. The
                // type is kept now, and it is what decides which engine plays
                // the file.
                //
                // A few feeds carry two enclosures, the audio and the video.
                // The audio stays the episode (it is what gets downloaded and
                // read for ads) and the video becomes its picture, whichever
                // order they come in.
                if let url = attrs["url"] {
                    let type = attrs["type"] ?? ""
                    let playable = type.isEmpty
                        || type.hasPrefix("audio")
                        || type.hasPrefix("video")
                    if playable, let current = item {
                        let isVideo = type.lowercased().hasPrefix("video")
                        let hasAudio = !current.audioURL.isEmpty && !current.mediaType.lowercased().hasPrefix("video")
                        if isVideo && hasAudio {
                            videoCandidates.append(VideoCandidate(type: type.lowercased(), height: 0, bitrate: 0, url: url))
                        } else {
                            if !isVideo, current.mediaType.lowercased().hasPrefix("video") {
                                videoCandidates.append(VideoCandidate(type: current.mediaType.lowercased(), height: 0,
                                                                      bitrate: 0, url: current.audioURL))
                            }
                            item?.audioURL = url
                            item?.mediaType = type
                        }
                    }
                }
            case "podcast:alternateEnclosure":
                // Video comes as HLS (`application/x-mpegURL`, also spelled
                // `application/vnd.apple.mpegurl`) or as a plain video file.
                // Audio alternates — Opus, lower bitrates — are not ours,
                // unless one of their sources says it is video.
                alternate = VideoCandidate(type: (attrs["type"] ?? "").lowercased(),
                                           height: Int(attrs["height"] ?? "") ?? 0,
                                           bitrate: Int(Double(attrs["bitrate"] ?? "") ?? 0), url: nil)
            case "podcast:source":
                // Every source is kept, each with its own type when it gives
                // one (`contentType`), so an HLS source listed after an mp4
                // one still wins.
                if var source = alternate, let uri = attrs["uri"], VideoCandidate.fetchable(uri) {
                    if let own = attrs["contentType"], !own.isEmpty { source.type = own.lowercased() }
                    source.url = uri
                    if source.looksLikeVideo { videoCandidates.append(source) }
                }
            case "media:content":
                // Media RSS, used by some hosts (and YouTube-style feeds) for
                // the video file. Inside or outside a `media:group`.
                if item != nil, let url = attrs["url"], VideoCandidate.fetchable(url) {
                    let type = (attrs["type"] ?? "").lowercased()
                    let medium = (attrs["medium"] ?? "").lowercased()
                    let candidate = VideoCandidate(type: type.isEmpty && medium == "video" ? "video/mp4" : type,
                                                   height: Int(attrs["height"] ?? "") ?? 0,
                                                   bitrate: Int(Double(attrs["bitrate"] ?? "") ?? 0), url: url)
                    if candidate.looksLikeVideo { videoCandidates.append(candidate) }
                }
            case "podcast:person":
                personRole = (attrs["role"] ?? "host").lowercased()
                personImage = attrs["img"] ?? ""
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

        func parser(_ p: XMLParser, didEndElement rawName: String, namespaceURI: String?,
                    qualifiedName: String?) {
            let name = normalised(rawName)
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
                case "itunes:episodeType":          item?.episodeType = value.lowercased()
                case "itunes:explicit":             item?.explicit = Self.isExplicit(value)
                case "url" where inImage:           break
                case "item":
                    if var finished = item {
                        // The episode's own file is never also its picture.
                        finished.videoURL = VideoCandidate.best(videoCandidates.filter { $0.url != finished.audioURL })
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
                case "itunes:explicit":                     feed.explicit = Self.isExplicit(value)
                default: break
                }
            }
            if name == "podcast:alternateEnclosure" { alternate = nil }
            if name == "podcast:person", !value.isEmpty {
                // "role:Name", and "^photo" when the feed gives one (pass
                // 21: Hosts & Guests shows the photos, like Apple's page).
                let entry = "\(personRole):\(value)" + (personImage.hasPrefix("http") ? "^" + personImage : "")
                if item != nil { item?.people.append(entry) } else { feed.people.append(entry) }
            }
            if name == "image" { inImage = false }
            text = ""
        }

        /// "true", "yes" and "explicit" all appear in the wild; so do "false",
        /// "no" and "clean".
        private static func isExplicit(_ value: String) -> Bool {
            ["true", "yes", "explicit"].contains(value.lowercased())
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
