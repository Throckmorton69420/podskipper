import Foundation

/// An Apple Podcasts link for an episode, starting at a moment in it.
///
/// Apple's player has "Share from 12:34…", which shares a podcasts.apple.com
/// link that opens the episode at that point for anyone, in any app. PodSkipper
/// reads feeds rather than Apple's catalogue, so it first has to find the show
/// and the episode in Apple's public directory: the show by name, confirmed by
/// its feed address, and the episode by the feed's own guid. Both answers are
/// remembered, so only the first share of a show costs a lookup.
enum EpisodeLink {

    private static let showIDsKey = "appleShowIDs"

    /// podcasts.apple.com/…?i=…&t=<seconds>, or nil when the directory doesn't
    /// list this show or episode.
    static func apple(for episode: Episode, at seconds: Double) async -> URL? {
        guard let show = episode.podcast else { return nil }
        guard let showID = await appleShowID(title: show.title, feedURL: show.feedURL) else { return nil }
        guard var address = await episodeAddress(showID: showID, guid: episode.guid, title: episode.title)
        else { return nil }
        let t = Int(max(0, seconds))
        if t > 0 { address += (address.contains("?") ? "&" : "?") + "t=\(t)" }
        return URL(string: address)
    }

    static func appleShowID(title: String, feedURL: String) async -> Int? {
        var known = UserDefaults.standard.dictionary(forKey: showIDsKey) as? [String: Int] ?? [:]
        if let id = known[feedURL] { return id }
        guard let found = try? await PodcastSearch.search(title, limit: 15) else { return nil }
        let normalised = feedURL.lowercased().replacingOccurrences(of: "http://", with: "https://")
        let match = found.first {
            $0.feedURL.lowercased().replacingOccurrences(of: "http://", with: "https://") == normalised
        } ?? found.first { $0.title.caseInsensitiveCompare(title) == .orderedSame }
        guard let id = match?.id else { return nil }
        known[feedURL] = id
        UserDefaults.standard.set(known, forKey: showIDsKey)
        return id
    }

    private static func episodeAddress(showID: Int, guid: String, title: String) async -> String? {
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(showID)&entity=podcastEpisode&limit=200")
        else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [[String: Any]] else { return nil }
        let episodes = results.filter { ($0["kind"] as? String) == "podcast-episode" }
        let hit = episodes.first { ($0["episodeGuid"] as? String) == guid }
            ?? episodes.first { ($0["trackName"] as? String)?.caseInsensitiveCompare(title) == .orderedSame }
        return hit?["trackViewUrl"] as? String
    }
}
