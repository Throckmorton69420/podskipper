import Foundation

/// Browsing, not just searching.
///
/// Everything here comes from Apple's public podcast endpoints — the same
/// data the Podcasts app browses. No account, no key, no scraping.
enum DiscoverService {

    // MARK: - Categories

    /// Apple's podcast genre IDs. These are stable and public.
    struct Category: Identifiable, Hashable {
        let id: Int
        let name: String
        let symbol: String
    }

    static let categories: [Category] = [
        Category(id: 1303, name: "Comedy",            symbol: "face.smiling"),
        Category(id: 1489, name: "News",              symbol: "newspaper"),
        Category(id: 1321, name: "Business",          symbol: "chart.line.uptrend.xyaxis"),
        Category(id: 1318, name: "Technology",        symbol: "cpu"),
        Category(id: 1488, name: "True Crime",        symbol: "magnifyingglass"),
        Category(id: 1512, name: "Health & Fitness",  symbol: "heart"),
        Category(id: 1533, name: "Science",           symbol: "atom"),
        Category(id: 1487, name: "History",           symbol: "book.closed"),
        Category(id: 1545, name: "Sports",            symbol: "figure.run"),
        Category(id: 1310, name: "Music",             symbol: "music.note"),
        Category(id: 1324, name: "Society & Culture", symbol: "globe"),
        Category(id: 1301, name: "Arts",              symbol: "paintpalette"),
        Category(id: 1483, name: "Fiction",           symbol: "text.book.closed"),
        Category(id: 1502, name: "Leisure",           symbol: "gamecontroller"),
        Category(id: 1304, name: "Education",         symbol: "graduationcap"),
        Category(id: 1314, name: "Religion",          symbol: "hands.sparkles"),
        Category(id: 1511, name: "Government",        symbol: "building.columns"),
        Category(id: 1305, name: "Kids & Family",     symbol: "figure.2.and.child.holdinghands")
    ]

    // MARK: - Charts

    /// Apple's top-podcast chart. `genre` of nil returns the overall chart.
    static func topShows(genre: Int? = nil, limit: Int = 50,
                         country: String = "us") async throws -> [PodcastSearchResult] {
        var path = "https://itunes.apple.com/\(country)/rss/toppodcasts/limit=\(limit)"
        if let genre { path += "/genre=\(genre)" }
        path += "/json"

        guard let url = URL(string: path) else { throw DiscoverError.badRequest }
        let (data, _) = try await URLSession.shared.data(from: url)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feed = root["feed"] as? [String: Any],
              let entries = feed["entry"] as? [[String: Any]] else {
            throw DiscoverError.unexpectedResponse
        }

        // The chart gives collection IDs but not feed URLs, so the IDs get
        // looked up in one batched call rather than 50 separate ones.
        let ids: [Int] = entries.compactMap { entry in
            guard let attrs = (entry["id"] as? [String: Any])?["attributes"] as? [String: Any],
                  let raw = attrs["im:id"] as? String else { return nil }
            return Int(raw)
        }
        guard !ids.isEmpty else { return [] }
        return try await lookup(ids: ids)
    }

    /// Batched lookup. Preserves the order the IDs came in, which is the
    /// chart ranking.
    static func lookup(ids: [Int]) async throws -> [PodcastSearchResult] {
        var results: [PodcastSearchResult] = []

        // The lookup endpoint gets unhappy well before 200 ids, so chunk it.
        for chunk in stride(from: 0, to: ids.count, by: 25).map({
            Array(ids[$0..<min($0 + 25, ids.count)])
        }) {
            var components = URLComponents(string: "https://itunes.apple.com/lookup")
            components?.queryItems = [
                URLQueryItem(name: "id", value: chunk.map(String.init).joined(separator: ",")),
                URLQueryItem(name: "entity", value: "podcast")
            ]
            guard let url = components?.url else { continue }
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { continue }
            guard let decoded = try? JSONDecoder().decode(LookupEnvelope.self, from: data) else { continue }

            for row in decoded.results {
                guard let feed = row.feedUrl, !feed.isEmpty else { continue }
                results.append(PodcastSearchResult(
                    id: row.collectionId ?? feed.hashValue,
                    title: row.collectionName ?? "Untitled",
                    author: row.artistName ?? "",
                    feedURL: feed,
                    artworkURL: row.artworkUrl600 ?? row.artworkUrl100,
                    episodeCount: row.trackCount,
                    genre: row.primaryGenreName
                ))
            }
        }

        // Restore chart order.
        let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        return results.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
    }

    /// Shows similar to one you already have, by searching its own category.
    static func related(to podcast: Podcast, limit: Int = 20) async throws -> [PodcastSearchResult] {
        let term = podcast.category.isEmpty ? podcast.author : podcast.category
        guard !term.isEmpty else { return [] }
        let found = try await PodcastSearch.search(term, limit: limit)
        return found.filter { $0.feedURL != podcast.feedURL }
    }

    // MARK: - Episodes

    /// One entry in Apple's top-episodes chart.
    struct ChartEpisode: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let showName: String
        let artworkURL: String?
        /// The show's directory id, parsed out of the episode's link, so the
        /// show's feed can be looked up when it is tapped.
        let showID: Int?
    }

    /// Apple's current top episodes, from the public marketing feed.
    static func topEpisodes(limit: Int = 25, country: String = "us") async throws -> [ChartEpisode] {
        guard let url = URL(string: "https://rss.marketingtools.apple.com/api/v2/\(country)/podcasts/top/\(limit)/podcast-episodes.json")
        else { throw DiscoverError.badRequest }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let feed = root["feed"] as? [String: Any],
              let results = feed["results"] as? [[String: Any]] else {
            throw DiscoverError.unexpectedResponse
        }
        return results.compactMap { row in
            guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
            let link = row["url"] as? String ?? ""
            var showID: Int?
            if let range = link.range(of: #"/id(\d+)"#, options: .regularExpression) {
                showID = Int(link[range].dropFirst(3))
            }
            return ChartEpisode(id: id, title: name,
                                showName: row["artistName"] as? String ?? "",
                                artworkURL: (row["artworkUrl100"] as? String).map(largeArtwork),
                                showID: showID)
        }
    }

    /// An episode found by searching Apple's directory.
    struct EpisodeResult: Identifiable, Hashable, Sendable {
        let id: Int
        let title: String
        let showTitle: String
        let feedURL: String
        let audioURL: String
        let artworkURL: String?
        let releaseDate: Date?
        let duration: Double
        let summary: String
        let showID: Int?
    }

    static func searchEpisodes(_ term: String, limit: Int = 25) async throws -> [EpisodeResult] {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: cleaned),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcastEpisode"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components?.url else { throw DiscoverError.badRequest }
        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(EpisodeEnvelope.self, from: data)
        let dates = ISO8601DateFormatter()
        return decoded.results.compactMap { row in
            guard let feed = row.feedUrl, !feed.isEmpty,
                  let title = row.trackName, let id = row.trackId else { return nil }
            return EpisodeResult(id: id, title: title,
                                 showTitle: row.collectionName ?? "",
                                 feedURL: feed,
                                 audioURL: row.episodeUrl ?? "",
                                 artworkURL: (row.artworkUrl600 ?? row.artworkUrl160).map(largeArtwork),
                                 releaseDate: row.releaseDate.flatMap { dates.date(from: $0) },
                                 duration: Double(row.trackTimeMillis ?? 0) / 1000,
                                 summary: row.shortDescription ?? row.description ?? "",
                                 showID: row.collectionId)
        }
    }

    /// Apple's artwork URLs carry their size in the path. A 100px thumbnail
    /// stretched to a 175pt tile is visibly soft on a Retina screen.
    static func largeArtwork(_ url: String) -> String {
        url.replacingOccurrences(of: #"/\d+x\d+bb\."#, with: "/600x600bb.", options: .regularExpression)
    }

    private struct EpisodeEnvelope: Decodable { let results: [EpisodeRow] }

    private struct EpisodeRow: Decodable {
        let trackId: Int?
        let trackName: String?
        let collectionId: Int?
        let collectionName: String?
        let feedUrl: String?
        let episodeUrl: String?
        let artworkUrl160: String?
        let artworkUrl600: String?
        let releaseDate: String?
        let trackTimeMillis: Int?
        let shortDescription: String?
        let description: String?
    }

    enum DiscoverError: LocalizedError {
        case badRequest, unexpectedResponse
        var errorDescription: String? {
            switch self {
            case .badRequest:        return "Couldn't build that request."
            case .unexpectedResponse: return "Apple's directory returned something unexpected."
            }
        }
    }

    private struct LookupEnvelope: Decodable {
        let results: [Row]
    }

    private struct Row: Decodable {
        let collectionId: Int?
        let collectionName: String?
        let artistName: String?
        let feedUrl: String?
        let artworkUrl100: String?
        let artworkUrl600: String?
        let trackCount: Int?
        let primaryGenreName: String?
    }
}
