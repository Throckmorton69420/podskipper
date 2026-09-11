import Foundation
import SwiftData

/// OPML is how every podcast app on earth moves subscriptions in and out.
/// Supporting it is the difference between a project and something you can
/// actually leave for another app without losing your library.
enum OPMLService {

    // MARK: - Export

    static func export(podcasts: [Podcast]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head>
            <title>PodSkipper subscriptions</title>
            <dateCreated>\(formatter.string(from: .now))</dateCreated>
          </head>
          <body>
            <outline text="feeds">

        """
        for podcast in podcasts.sorted(by: { $0.title < $1.title }) {
            xml += "      <outline type=\"rss\" text=\"\(podcast.title.xmlEscaped)\""
            xml += " title=\"\(podcast.title.xmlEscaped)\""
            xml += " xmlUrl=\"\(podcast.feedURL.xmlEscaped)\"/>\n"
        }
        xml += """
            </outline>
          </body>
        </opml>

        """
        return xml
    }

    static func writeExportFile(podcasts: [Podcast]) throws -> URL {
        let text = export(podcasts: podcasts)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodSkipper-subscriptions.opml")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Import

    struct ImportResult {
        var added: Int
        var skipped: Int
        var failed: [String]
    }

    /// Reads feed URLs out of an OPML file and subscribes to each one.
    /// Feeds that already exist are skipped rather than duplicated.
    @MainActor
    static func importFile(at url: URL, into context: ModelContext,
                           progress: ((Double) -> Void)? = nil) async throws -> ImportResult {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let feeds = parseFeedURLs(data)
        guard !feeds.isEmpty else {
            return ImportResult(added: 0, skipped: 0, failed: ["No feeds found in that file."])
        }

        let existing = Set(((try? context.fetch(FetchDescriptor<Podcast>())) ?? []).map(\.feedURL))
        var result = ImportResult(added: 0, skipped: 0, failed: [])

        for (index, feedURL) in feeds.enumerated() {
            progress?(Double(index) / Double(feeds.count))
            if existing.contains(feedURL) {
                result.skipped += 1
                continue
            }
            do {
                let feed = try await FeedParser.fetch(feedURL)
                let podcast = Podcast(feedURL: feedURL, title: feed.title, author: feed.author,
                                      summary: feed.summary, artworkURL: feed.artworkURL)
                context.insert(podcast)
                for item in feed.items.prefix(50) {
                    let episode = Episode(item: item)
                    episode.podcast = podcast
                    context.insert(episode)
                }
                podcast.lastRefreshed = .now
                result.added += 1
            } catch {
                result.failed.append(feedURL)
            }
        }

        try? context.save()
        progress?(1)
        return result
    }

    /// Pulls every `xmlUrl` out of the document. OPML nests arbitrarily and
    /// exporters disagree about structure, so we ignore hierarchy entirely
    /// and take the attributes wherever they appear.
    static func parseFeedURLs(_ data: Data) -> [String] {
        let delegate = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return Array(NSOrderedSet(array: delegate.feeds)) as? [String] ?? delegate.feeds
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var feeds: [String] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            guard name.lowercased() == "outline" else { return }
            if let url = attributes["xmlUrl"] ?? attributes["xmlurl"], !url.isEmpty {
                feeds.append(url)
            }
        }
    }
}
