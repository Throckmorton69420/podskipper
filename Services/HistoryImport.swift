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

    struct File: Decodable {
        let format: String
        let shows: [Show]
        let episodes: [Item]

        struct Show: Decodable {
            let feedURL: String
            let title: String?
            let subscribed: Int?
        }

        struct Item: Decodable {
            let feedURL: String?
            let guid: String?
            let title: String?
            let played: Int
            let playhead: Double?
            let lastPlayed: Double?
            let saved: Int?
        }
    }

    struct Result {
        var showsAdded = 0
        var markedPlayed = 0
        var resumePoints = 0
        var starred = 0
        var notInLibrary = 0

        var summary: String {
            var parts: [String] = []
            if showsAdded > 0 { parts.append("followed \(showsAdded) new show\(showsAdded == 1 ? "" : "s")") }
            parts.append("marked \(markedPlayed) played")
            if resumePoints > 0 { parts.append("restored \(resumePoints) resume point\(resumePoints == 1 ? "" : "s")") }
            if starred > 0 { parts.append("starred \(starred)") }
            var text = parts.joined(separator: ", ").capitalizedFirst + "."
            if notInLibrary > 0 {
                text += " \(notInLibrary) older episode\(notInLibrary == 1 ? " isn't" : "s aren't") in your library, so there was nothing to mark."
            }
            return text
        }
    }

    static func isHistoryFile(_ data: Data) -> Bool {
        guard data.count > 20, let head = String(data: data.prefix(200), encoding: .utf8) else { return false }
        return head.contains("podskipper-apple-podcasts-history")
    }

    @MainActor
    static func importData(_ data: Data, into context: ModelContext,
                           progress: ((Double) -> Void)? = nil) async throws -> Result {
        let file = try JSONDecoder().decode(File.self, from: data)
        var result = Result()

        func normal(_ url: String) -> String {
            url.lowercased()
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        // 1. Follow what is followed there and missing here.
        var podcasts = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []
        let known = Set(podcasts.map { normal($0.feedURL) })
        let missing = file.shows.filter { ($0.subscribed ?? 0) == 1 && !known.contains(normal($0.feedURL)) }
        for (index, show) in missing.enumerated() {
            progress?(0.5 * Double(index) / Double(max(1, missing.count)))
            guard let feed = try? await FeedParser.fetch(show.feedURL) else { continue }
            let podcast = Podcast(feedURL: show.feedURL, title: feed.title, author: feed.author,
                                  summary: feed.summary, artworkURL: feed.artworkURL)
            context.insert(podcast)
            for item in feed.items.prefix(50) {
                let episode = Episode(item: item)
                episode.podcast = podcast
                context.insert(episode)
            }
            podcast.lastRefreshed = .now
            result.showsAdded += 1
        }
        try? context.save()
        podcasts = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []

        // 2. Index the library.
        let episodes = (try? context.fetch(FetchDescriptor<Episode>())) ?? []
        var byGUID: [String: Episode] = [:]
        var byTitle: [String: Episode] = [:]
        for episode in episodes {
            byGUID[episode.guid] = episode
            if let feed = episode.podcast?.feedURL {
                byTitle[normal(feed) + "|" + episode.title.lowercased()] = episode
            }
        }

        // 3. Apply.
        for (index, item) in file.episodes.enumerated() {
            if index % 500 == 0 { progress?(0.5 + 0.5 * Double(index) / Double(max(1, file.episodes.count))) }
            var match = item.guid.flatMap { byGUID[$0] }
            if match == nil, let feed = item.feedURL, let title = item.title {
                match = byTitle[normal(feed) + "|" + title.lowercased()]
            }
            guard let episode = match else {
                result.notInLibrary += 1
                continue
            }
            if let last = item.lastPlayed {
                let date = Date(timeIntervalSince1970: last)
                if episode.lastPlayedAt == nil || date > episode.lastPlayedAt! { episode.lastPlayedAt = date }
            }
            if item.played == 1, !episode.isPlayed {
                episode.isPlayed = true
                episode.playbackPosition = 0
                episode.isInQueue = false
                result.markedPlayed += 1
            } else if let playhead = item.playhead, playhead > 1, !episode.isPlayed,
                      playhead > episode.playbackPosition {
                episode.playbackPosition = playhead
                result.resumePoints += 1
            }
            if (item.saved ?? 0) == 1, !episode.isStarred {
                episode.isStarred = true
                result.starred += 1
            }
        }
        try? context.save()
        progress?(1)
        return result
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
