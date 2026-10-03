import Foundation

/// A missing directory entry is distinct from a failed directory request.
/// Show and episode previews share that distinction and exact show identity.
enum PreviewFeedAddress {
    static func resolve(feedURL: String?, showID: Int?,
        lookup: ([Int]) async throws -> [PodcastSearchResult] = { try await DiscoverService.lookup(ids: $0) }) async throws -> String? {
        try Task.checkCancellation()
        if let feedURL, !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return feedURL }
        guard let showID else { return nil }
        let shows = try await lookup([showID])
        try Task.checkCancellation()
        return shows.first(where: { $0.id == showID })?.feedURL
    }
}
