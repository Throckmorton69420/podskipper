import Foundation
import SwiftData

/// Every episode a show's feed lists, not the newest fifty.
///
/// A feed is the only source, and some publishers only put their most recent
/// few hundred episodes in it. The inserting happens in `LibraryIndex`, off
/// the main thread: the first version of this did it on the main context and
/// froze the app while thousands of rows went in.
@MainActor
enum EpisodeCatalogue {

    /// A show just followed: everything in its feed. Saves the show first so
    /// the background context can find it.
    /// Pass 58 (L21): if that save fails the show isn't in the store for
    /// the background context to fill — said in the background log rather
    /// than merging into nothing; the next refresh fills it.
    static func fill(_ podcast: Podcast, from feed: ParsedFeed, context: ModelContext) async {
        do { try context.save() } catch {
            BackgroundLog.shared.note("\(podcast.title) couldn't be saved before its episodes were added: \(error.localizedDescription).")
            return
        }
        _ = await LibraryIndexStatus.shared.merge(feed, into: podcast.persistentModelID)
        await LibraryIndexStatus.shared.refreshSummary()
    }
}
