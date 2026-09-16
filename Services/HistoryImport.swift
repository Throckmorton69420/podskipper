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
            let originalFeedURL: String?
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
        var markedUnplayed = 0
        var resumePoints = 0
        var starred = 0
        var notInLibrary = 0

        var summary: String {
            var parts: [String] = []
            if showsAdded > 0 { parts.append("followed \(showsAdded) new show\(showsAdded == 1 ? "" : "s")") }
            parts.append("marked \(markedPlayed) played")
            if markedUnplayed > 0 { parts.append("put back \(markedUnplayed) as unplayed") }
            if resumePoints > 0 { parts.append("restored \(resumePoints) resume point\(resumePoints == 1 ? "" : "s")") }
            if starred > 0 { parts.append("starred \(starred)") }
            var text = parts.joined(separator: ", ").capitalizedFirst + "."
            if notInLibrary > 0 {
                text += " \(notInLibrary) episode\(notInLibrary == 1 ? " is" : "s are") in Apple Podcasts but not in PodSkipper's list for that show — mostly older episodes, since PodSkipper keeps the newest 50 of each — so there was nothing to mark."
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
            EpisodeCatalogue.fill(podcast, from: feed, context: context)
            podcast.lastRefreshed = .now
            result.showsAdded += 1
        }
        try? context.save()
        podcasts = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []

        // 2. Index the library by show, then episode.
        //
        // By show first. The same guid appears in several shows — Cum Town
        // episodes are reposted in MYCTP and on The Adam Friedland Show — and
        // matching on guid alone applied one show's history to another's
        // episodes. An Apple Podcasts episode now only ever marks the
        // PodSkipper episode that belongs to the same feed.
        let episodes = (try? context.fetch(FetchDescriptor<Episode>())) ?? []
        var byFeedGUID: [String: Episode] = [:]
        var byFeedTitle: [String: Episode] = [:]
        for episode in episodes {
            guard let feed = episode.podcast?.feedURL else { continue }
            let show = normal(feed)
            byFeedGUID[show + "|" + episode.guid] = episode
            byFeedTitle[show + "|" + episode.title.lowercased()] = episode
        }

        // 3. Apply. What Apple Podcasts says wins, in both directions, so an
        // import also puts right what an earlier one got wrong.
        for (index, item) in file.episodes.enumerated() {
            if index % 500 == 0 { progress?(0.5 + 0.5 * Double(index) / Double(max(1, file.episodes.count))) }
            let feeds = [item.feedURL, item.originalFeedURL].compactMap { $0 }.map(normal)
            var match: Episode?
            for feed in feeds where match == nil {
                if let guid = item.guid { match = byFeedGUID[feed + "|" + guid] }
                if match == nil, let title = item.title { match = byFeedTitle[feed + "|" + title.lowercased()] }
            }
            guard let episode = match else {
                result.notInLibrary += 1
                continue
            }
            if let last = item.lastPlayed {
                let date = Date(timeIntervalSince1970: last)
                if episode.lastPlayedAt == nil || date > episode.lastPlayedAt! { episode.lastPlayedAt = date }
            }
            let playhead = item.playhead ?? 0
            if item.played == 1 {
                if !episode.isPlayed {
                    episode.isPlayed = true
                    episode.playbackPosition = 0
                    episode.isInQueue = false
                    result.markedPlayed += 1
                }
            } else {
                // Only if it was not actually listened to here: something
                // you finished in PodSkipper stays played.
                if episode.isPlayed, episode.secondsListened < 60 {
                    episode.isPlayed = false
                    result.markedUnplayed += 1
                }
                if playhead > 1, abs(playhead - episode.playbackPosition) > 1 {
                    episode.playbackPosition = playhead
                    result.resumePoints += 1
                }
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
