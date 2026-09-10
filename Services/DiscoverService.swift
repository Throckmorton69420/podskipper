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
