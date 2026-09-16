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

    /// Reads a file the user picked in the Files browser.
    ///
    /// Three things have to happen and a plain `Data(contentsOf:)` does none of
    /// them:
    ///
    /// - The URL is security-scoped. Reading it without asking fails with a
    ///   permissions error, and the only sign of that was one grey line of
    ///   footnote text a long way down the settings page.
    /// - The file may be in iCloud Drive and not present on the phone at all.
    ///   `startDownloadingUbiquitousItem` asks for it; the coordinated read
    ///   then waits for it to arrive instead of failing.
    /// - A coordinated read is also what avoids reading a file another process
    ///   is in the middle of writing.
    ///
    /// Errors are rethrown with the file's name in them, because "the file
    /// couldn't be opened" with no name attached is not a thing anyone can act
    /// on.
    static func readPicked(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        // Harmless and ignored for a file that is already local.
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        var coordinationError: NSError?
        var readError: Error?
        var data: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges],
                                       error: &coordinationError) { readable in
            do { data = try Data(contentsOf: readable) } catch { readError = error }
        }
        if let data { return data }
        // Last resort: some providers hand back a URL that coordinates badly
        // but reads fine directly.
        if let direct = try? Data(contentsOf: url) { return direct }

        let underlying = readError ?? coordinationError
        throw NSError(domain: "PodSkipper.OPML", code: 1, userInfo: [
            NSLocalizedDescriptionKey:
                "Couldn't read \(url.lastPathComponent)."
                + (underlying.map { " \($0.localizedDescription)" } ?? "")
                + " If it's in iCloud Drive, opening it once in the Files app downloads it."
        ])
    }

    /// Reads feed URLs out of an OPML file and subscribes to each one.
    /// Feeds that already exist are skipped rather than duplicated.
    @MainActor
    static func importFile(at url: URL, into context: ModelContext,
                           progress: ((Double) -> Void)? = nil) async throws -> ImportResult {
        let data = try readPicked(url)
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
                EpisodeCatalogue.fill(podcast, from: feed, context: context)
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
        let parsed = Array(NSOrderedSet(array: delegate.feeds)) as? [String] ?? delegate.feeds
        if !parsed.isEmpty { return parsed }
        // Fallback for a file `XMLParser` refused.
        //
        // One stray ampersand or a missing closing tag and the strict parser
        // stops at that line and hands back whatever it had, which is usually
        // nothing — and an export that is 99% fine then reads as "no feeds
        // found in that file". Scraping the attribute out of the raw text
        // costs nothing and rescues those.
        return scrapeFeedURLs(data)
    }

    private static func scrapeFeedURLs(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return [] }
        let pattern = #"xmlurl\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var found: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let captured = Range(match.range(at: 1), in: text) else { continue }
            let url = String(text[captured])
                .replacingOccurrences(of: "&amp;", with: "&")
            if !url.isEmpty, !found.contains(url) { found.append(url) }
        }
        return found
    }

    private final class Collector: NSObject, XMLParserDelegate {
        var feeds: [String] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            guard name.lowercased() == "outline" else { return }
            // Exporters disagree about the capitalisation, so match on a
            // lowercased key rather than guessing two of the spellings.
            let url = attributes.first { $0.key.lowercased() == "xmlurl" }?.value
            if let url, !url.isEmpty { feeds.append(url) }
        }
    }
}
