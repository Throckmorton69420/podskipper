import Foundation

/// Search for shows by name instead of hunting down RSS addresses.
///
/// Uses Apple's iTunes Search API, which is public, free, needs no account
/// or key, and returns the show's real RSS address in `feedUrl` — which is
/// exactly what the rest of the app needs.
struct PodcastSearchResult: Identifiable, Sendable {
    let id: Int
    let title: String
    let author: String
    let feedURL: String
    let artworkURL: String?
    let episodeCount: Int?
    let genre: String?
}

enum PodcastSearch {

    enum SearchError: LocalizedError {
        case network(String)
        case noResults

        var errorDescription: String? {
            switch self {
            case .network(let m): return "Couldn't reach the podcast directory: \(m)"
            case .noResults:      return "No shows matched that."
            }
        }
    }

    static func search(_ term: String, limit: Int = 25) async throws -> [PodcastSearchResult] {
        let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: cleaned),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components?.url else { throw SearchError.network("bad search URL") }

        let data: Data
        do {
            var request = URLRequest(url: url)
            request.setValue("PodSkipper/1.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw SearchError.network(error.localizedDescription)
        }

        let decoded: Envelope
        do {
            decoded = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw SearchError.network("unexpected response")
        }

        let results: [PodcastSearchResult] = decoded.results.compactMap { row in
            // A show with no RSS address is useless to us.
            guard let feed = row.feedUrl, !feed.isEmpty else { return nil }
            return PodcastSearchResult(
                id: row.collectionId ?? feed.hashValue,
                title: row.collectionName ?? "Untitled",
                author: row.artistName ?? "",
                feedURL: feed,
                artworkURL: row.artworkUrl600 ?? row.artworkUrl100,
                episodeCount: row.trackCount,
                genre: row.primaryGenreName
            )
        }

        guard !results.isEmpty else { throw SearchError.noResults }
        return results
    }

    // MARK: - Wire format

    private struct Envelope: Decodable {
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
