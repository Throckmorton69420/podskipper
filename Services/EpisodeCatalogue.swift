import Foundation
import SwiftData

/// Every episode a show's feed lists, not the newest fifty.
///
/// A feed is the only source, and some publishers only put their most recent
/// few hundred episodes in it. The inserting happens in `LibraryIndex`, in its own
/// context: the first version of this did it on the main context and
/// froze the app while thousands of rows went in.
@MainActor
enum EpisodeCatalogue {

    /// A show just followed: everything in its feed. Saves the show first so
    /// the background context can find it.
    static func fill(_ podcast: Podcast, from feed: ParsedFeed, context: ModelContext,
                     save: (ModelContext) throws -> Void = { try $0.save() },
                     merge: ((ParsedFeed, PersistentIdentifier) async throws -> LibraryIndex.MergeResult)? = nil) async throws {
        let wasInserted = context.insertedModelsArray.contains { $0 === podcast }
        do {
            try Task.checkCancellation()
            try save(context)
        }
        catch {
            // Only remove this new insertion. Rolling back the shared context
            // would also discard an unrelated listening position or user edit.
            if wasInserted { context.delete(podcast) }
            throw error
        }
        try Task.checkCancellation()
        if let merge {
            _ = try await merge(feed, podcast.persistentModelID)
        } else {
            _ = try await LibraryIndexStatus.shared.merge(feed, into: podcast.persistentModelID)
        }
        await LibraryIndexStatus.shared.refreshSummary()
    }
}
