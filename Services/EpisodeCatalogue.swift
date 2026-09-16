import Foundation
import SwiftData

/// Every episode a show's feed lists, not the newest fifty.
///
/// Subscribing used to keep the newest 50 (100 from search), and a refresh
/// only ever looked at the newest 20 items — so a show's back catalogue was
/// never in the app, the history import could not mark most of what you had
/// played, and autoplay ran off the end of a show. Apple Podcasts shows the
/// whole catalogue, and so does this now, as far as the feed goes: a feed is
/// the only source, and some publishers only put their most recent few hundred
/// episodes in it.
@MainActor
enum EpisodeCatalogue {

    struct Result {
        var added: [Episode] = []
        /// Published since the show was last refreshed — the ones worth a
        /// notification or a place in Up Next. A back catalogue filled in for
        /// the first time is not "new".
        var fresh: [Episode] = []
    }

    /// Insert every item the show does not have yet.
    ///
    /// - Parameter knownGUIDs: guids already in the store, across all shows.
    ///   `Episode.guid` is unique store-wide, so inserting an item whose guid
    ///   belongs to another show would silently move that episode here.
    @discardableResult
    static func merge(_ feed: ParsedFeed, into podcast: Podcast, context: ModelContext,
                      knownGUIDs: inout Set<String>) -> Result {
        var result = Result()
        let cutoff = podcast.lastRefreshed
        for item in feed.items where !item.guid.isEmpty && !knownGUIDs.contains(item.guid) {
            let episode = Episode(item: item)
            episode.podcast = podcast
            context.insert(episode)
            knownGUIDs.insert(item.guid)
            result.added.append(episode)
            if let cutoff, item.publishedAt > cutoff {
                result.fresh.append(episode)
            }
        }
        return result
    }

    /// Store-wide guids, fetched once per batch.
    static func allGUIDs(in context: ModelContext) -> Set<String> {
        var descriptor = FetchDescriptor<Episode>()
        descriptor.propertiesToFetch = [\.guid]
        return Set(((try? context.fetch(descriptor)) ?? []).map(\.guid))
    }

    /// A show just followed: everything in its feed.
    static func fill(_ podcast: Podcast, from feed: ParsedFeed, context: ModelContext) {
        var known = allGUIDs(in: context)
        merge(feed, into: podcast, context: context, knownGUIDs: &known)
    }
}
