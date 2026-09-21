import Foundation
import SwiftData

/// Brings in what you have listened to in Apple Podcasts.
///
/// OPML carries subscriptions and nothing else, so importing it left every
/// episode looking unplayed. Apple Podcasts has no export of its own, and an
/// iPhone app cannot read another app's data. What does work: a Mac signed in
/// to the same Apple Account holds a synced copy of the whole library,
/// including plays made on the iPhone. `Tools/ApplePodcastsExport/
/// export-history.sh` reads a copy of it and saves a JSON file to iCloud
/// Drive; this reads that file.
///
/// Matching is by the episode's feed guid, then by title within the same show
/// for feeds that rewrite their guids. Episodes older than what PodSkipper
/// has fetched for a show are not in the library to mark, and are counted
/// rather than silently dropped.
enum HistoryImport {

    struct File: Decodable, Sendable {
        let format: String
        let shows: [Show]
        let episodes: [Item]

        struct Show: Decodable, Sendable {
            let feedURL: String
            let title: String?
            let subscribed: Int?
        }

        struct Item: Decodable, Sendable {
            let feedURL: String?
            let originalFeedURL: String?
            let guid: String?
            let title: String?
            let played: Int
            let playhead: Double?
            let lastPlayed: Double?
            let saved: Int?
        }
    }

    struct Result: Sendable {
        var showsAdded = 0
        var markedPlayed = 0
        var alreadyPlayed = 0
        var markedUnplayed = 0
        var resumePoints = 0
        var starred = 0
        /// In a show you follow, but not in that show's feed any more —
        /// publishers often drop old episodes from their feeds.
        var notInFeed = 0
        /// From shows you don't follow in PodSkipper.
        var otherShows = 0
        /// Shows whose catalogue could not be fetched, so their episodes could
        /// not be matched.
        var showsUnindexed = 0

        var summary: String {
            var parts: [String] = []
            if showsAdded > 0 { parts.append("followed \(showsAdded) new show\(showsAdded == 1 ? "" : "s")") }
            parts.append("marked \(markedPlayed) played")
            if alreadyPlayed > 0 { parts.append("\(alreadyPlayed) already were") }
            if markedUnplayed > 0 { parts.append("put back \(markedUnplayed) as unplayed") }
            if resumePoints > 0 { parts.append("restored \(resumePoints) resume point\(resumePoints == 1 ? "" : "s")") }
            if starred > 0 { parts.append("starred \(starred)") }
            var text = parts.joined(separator: ", ").capitalizedFirst + "."
            if otherShows > 0 {
                text += " \(otherShows) episode\(otherShows == 1 ? " is" : "s are") from shows you don't follow here, so they were left out."
            }
            if notInFeed > 0 {
                text += " \(notInFeed) \(notInFeed == 1 ? "is" : "are") from shows you follow but no longer in those shows' feeds — publishers often drop old episodes — so there was nothing to mark."
            }
            if showsUnindexed > 0 {
                text += " \(showsUnindexed) show\(showsUnindexed == 1 ? "" : "s") couldn't be fetched; import again once they have been."
            }
            return text
        }
    }

    static func normal(_ url: String) -> String {
        url.lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func isHistoryFile(_ data: Data) -> Bool {
        guard data.count > 20, let head = String(data: data.prefix(200), encoding: .utf8) else { return false }
        return head.contains("podskipper-apple-podcasts-history")
    }

    /// Follow what is missing, wait for every show's whole catalogue to be
    /// in, then apply — the last step in the background.
    ///
    /// The first import ran before the catalogues had been fetched (and the
    /// fetching had been crashing), so most played episodes had nothing to
    /// match and were reported as "not in PodSkipper's list". Now it waits.
    @MainActor
    static func importData(_ data: Data, into context: ModelContext,
                           progress: ((String) -> Void)? = nil) async throws -> Result {
        let file = try await Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(File.self, from: data)
        }.value
        var added = 0

        // 1. Follow what is followed there and missing here.
        let podcasts = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []
        let known = Set(podcasts.map { normal($0.feedURL) })
        let missing = file.shows.filter { ($0.subscribed ?? 0) == 1 && !known.contains(normal($0.feedURL)) }
        for (index, show) in missing.enumerated() {
            progress?("Following \(index + 1) of \(missing.count) shows")
            guard let feed = try? await FeedParser.fetch(show.feedURL) else { continue }
            let podcast = Podcast(feedURL: show.feedURL, title: feed.title, author: feed.author,
                                  summary: feed.summary, artworkURL: feed.artworkURL)
            context.insert(podcast)
            await EpisodeCatalogue.fill(podcast, from: feed, context: context)
            added += 1
        }
        try? context.save()

        // 2. Every show's catalogue in.
        let status = LibraryIndexStatus.shared
        progress?("Getting every episode of your shows")
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if status.isIndexing {
                    progress?("Getting every episode: \(status.showsDone) of \(status.showsTotal) shows")
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        await status.waitForIndexing()
        watcher.cancel()

        // 3. Apply, off the main thread.
        progress?("Marking what you've played")
        var result = await status.applyHistory(file)
        result.showsAdded = added
        await status.refreshSummary()
        result.showsUnindexed = max(0, status.totalShows - status.indexedShows)
        return result
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
