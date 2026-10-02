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
        let version: Int?
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
            /// Version 3 retains the evidence behind Apple's play state. In
            /// particular, source 6 can be a default back-catalogue record.
            let playStateSource: Int?
            let playCount: Int?
            let lastUserMarkedPlayed: Double?
        }

        func validate() throws {
            guard format == HistoryImport.format else { throw ImportError.unsupportedFormat }
            guard let version, (1...3).contains(version) else { throw ImportError.unsupportedVersion(version) }
        }
    }

    static let format = "podskipper-apple-podcasts-history"

    enum ImportError: LocalizedError {
        case unsupportedFormat, unsupportedVersion(Int?)
        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: return "That file is not a PodSkipper Apple Podcasts history export."
            case .unsupportedVersion(let version):
                return "This history export's version \(version.map(String.init) ?? "is missing") isn't supported. Make a new export with PodSkipper's export-history.sh."
            }
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
        /// Repeated titles or conflicting feed aliases cannot select an episode.
        var ambiguous = 0
        var duplicateRows = 0

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
            if ambiguous > 0 {
                text += " \(ambiguous) episode\(ambiguous == 1 ? " has" : "s have") more than one possible match and \(ambiguous == 1 ? "was" : "were") left unchanged."
            }
            if duplicateRows > 0 { text += " Combined \(duplicateRows) duplicate history row\(duplicateRows == 1 ? "" : "s")." }
            return text
        }
    }

    static func normal(_ url: String) -> String {
        guard var parts = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty else { return "" }
        // Preserve existing HTTP/HTTPS feed identity, but never lowercase a
        // case-sensitive path/query or remove a slash from a non-root path.
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { parts.port = nil }
        parts.scheme = "https"
        parts.host = host
        parts.fragment = nil
        if parts.percentEncodedPath == "/" { parts.percentEncodedPath = "" }
        return parts.string ?? ""
    }

    static func isHistoryFile(_ data: Data) -> Bool {
        (try? decode(data)) != nil
    }

    static func decode(_ data: Data) throws -> File {
        let file = try JSONDecoder().decode(File.self, from: data)
        try file.validate()
        return file
    }

    static func normalTitle(_ title: String) -> String {
        title.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    struct Resume: Sendable {
        var position: Double
        var date: Date?
    }
    struct State: Sendable {
        var played = false
        var lastPlayed: Date?
        var resume: Resume?
        var saved = false
    }

    /// History adds evidence; an unplayed/default record cannot revoke a
    /// local explicit Mark Played. Combining before mutation makes duplicate
    /// or conflicting sync rows independent of their order in the archive.
    static func state(_ items: [File.Item], version: Int, duration: Double, now: Date) -> State {
        var state = State()
        func date(_ value: Double?) -> Date? {
            guard let value, value.isFinite, value > 0, value <= now.timeIntervalSince1970 + 86_400 else { return nil }
            return Date(timeIntervalSince1970: value)
        }
        for item in items {
            let rawPosition = item.playhead ?? 0
            let position = rawPosition.isFinite && rawPosition > 1
                && rawPosition < Double(Int.max) / 2
                && (!(duration.isFinite && duration > 0) || rawPosition <= duration + 1) ? rawPosition : 0
            let last = date(item.lastPlayed)
            let counted = (item.playCount ?? 0) > 0
            let marked = date(item.lastUserMarkedPlayed) != nil
            let nonDefaultDate = item.playStateSource.map { $0 != 6 } == true && last != nil
            // Legacy v2 already corrected the played predicate. It cannot
            // prove a completed listening date because source was omitted.
            // Legacy v1's played-only flags are not reliable evidence.
            let completed = item.played == 1 && (counted || marked || nonDefaultDate
                || (version == 2 && item.playStateSource == nil))
            state.played = state.played || completed
            state.saved = state.saved || item.saved == 1
            let partialResume = item.played != 1 && position > 0
            let genuinelyListened = counted || partialResume || (nonDefaultDate && item.played == 1)
            if genuinelyListened, let last, state.lastPlayed == nil || last > state.lastPlayed! {
                state.lastPlayed = last
            }
            if partialResume {
                let candidate = Resume(position: position, date: genuinelyListened ? last : nil)
                if state.resume == nil || (candidate.date ?? .distantPast) > (state.resume!.date ?? .distantPast)
                    || (candidate.date == state.resume!.date && candidate.position > state.resume!.position) {
                    state.resume = candidate
                }
            }
        }
        return state
    }

    /// Follow what is missing, wait for every show's whole catalogue to be
    /// in, then apply — the last step in the background.
    ///
    /// The first import ran before the catalogues had been fetched (and the
    /// fetching had been crashing), so most played episodes had nothing to
    /// match and were reported as "not in PodSkipper's list". Now it waits.
    @MainActor
    static func importData(_ data: Data, into context: ModelContext,
                           progress: ((String) -> Void)? = nil,
                           fetchFeed: (String) async throws -> ParsedFeed = { try await FeedParser.fetch($0) }) async throws -> Result {
        let file = try await Task.detached(priority: .userInitiated) {
            try decode(data)
        }.value
        try Task.checkCancellation()
        var added = 0

        // 1. Follow what is followed there and missing here.
        let podcasts = try context.fetch(FetchDescriptor<Podcast>())
        var known = Set(podcasts.map { normal($0.feedURL) }.filter { !$0.isEmpty })
        let missing = file.shows.filter { ($0.subscribed ?? 0) == 1 && !normal($0.feedURL).isEmpty }
            .sorted { $0.feedURL < $1.feedURL }
        for (index, show) in missing.enumerated() {
            try Task.checkCancellation()
            let key = normal(show.feedURL)
            guard !known.contains(key) else { continue }
            progress?("Following \(index + 1) of \(missing.count) shows")
            let feed = try await fetchFeed(show.feedURL)
            try Task.checkCancellation()
            let podcast = Podcast(feedURL: show.feedURL, title: feed.title, author: feed.author,
                                  summary: feed.summary, artworkURL: feed.artworkURL)
            context.insert(podcast)
            try await EpisodeCatalogue.fill(podcast, from: feed, context: context)
            known.insert(key)
            added += 1
        }
        try Task.checkCancellation()
        try context.save()

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
        try Task.checkCancellation()

        // 3. Apply, off the main thread.
        progress?("Marking what you've played")
        var result = try await status.applyHistory(file)
        result.showsAdded = added
        await status.refreshSummary()
        result.showsUnindexed = max(0, status.totalShows - status.indexedShows)
        return result
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
