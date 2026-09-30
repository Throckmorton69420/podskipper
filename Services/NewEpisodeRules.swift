import Foundation

/// Apple Podcasts' "New": an episode that arrived in a followed show and has
/// not been heard. Ad processing has no part in it.
///
/// Kept as plain functions so the rules can be tested without a store.
enum NewEpisodeRules {

    /// Should an episode being stored for the first time start out New?
    ///
    /// - The back catalogue is not New: only episodes published after the show
    ///   was followed count.
    /// - The one exception is the latest episode at the moment of following
    ///   (Apple's "current new episode"), passed as `isLatestAtFollow`.
    static func startsNew(publishedAt: Date, followedAt: Date,
                          isLatestAtFollow: Bool, showArchived: Bool = false) -> Bool {
        guard !showArchived else { return false }
        return isLatestAtFollow || publishedAt > followedAt
    }

    /// Is a stored episode New right now? Playing it, even for a moment, or
    /// marking it played clears the flag for good, so "Mark as Unplayed" never
    /// brings it back. The position and played checks cover changes made by
    /// paths that do not clear the flag themselves.
    static func isNew(flag: Bool, isPlayed: Bool, isArchived: Bool,
                      playbackPosition: Double, lastPlayedAt: Date?) -> Bool {
        flag && !isPlayed && !isArchived && playbackPosition <= 1 && lastPlayedAt == nil
    }
}

extension Episode {
    /// The New marker on rows.
    var showsAsNew: Bool {
        NewEpisodeRules.isNew(flag: isNew, isPlayed: isPlayed, isArchived: isArchived,
                              playbackPosition: playbackPosition, lastPlayedAt: lastPlayedAt)
    }
}
