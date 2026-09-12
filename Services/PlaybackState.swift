import Foundation
import SwiftData

/// Remembers what was playing so the app can pick it back up.
///
/// Before this, closing the app — or crashing — left the mini player empty and
/// the only way back to an episode was to find its show and scroll to it. The
/// position itself was already stored on the episode; what was missing was any
/// record of *which* episode was the current one.
///
/// Written on every meaningful transport event rather than only on a clean
/// exit, because a crash never gets a clean exit.
enum PlaybackState {

    private enum Key {
        static let guid = "nowPlayingGUID"
        static let position = "nowPlayingPosition"
        static let rate = "nowPlayingRate"
        static let savedAt = "nowPlayingSavedAt"
    }

    struct Snapshot {
        var guid: String
        var position: Double
        var rate: Double
    }

    static func save(guid: String, position: Double, rate: Double) {
        let defaults = UserDefaults.standard
        defaults.set(guid, forKey: Key.guid)
        defaults.set(position, forKey: Key.position)
        defaults.set(rate, forKey: Key.rate)
        defaults.set(Date().timeIntervalSince1970, forKey: Key.savedAt)
    }

    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Key.guid)
        defaults.removeObject(forKey: Key.position)
        defaults.removeObject(forKey: Key.rate)
        defaults.removeObject(forKey: Key.savedAt)
    }

    static var snapshot: Snapshot? {
        let defaults = UserDefaults.standard
        guard let guid = defaults.string(forKey: Key.guid), !guid.isEmpty else { return nil }
        let rate = defaults.double(forKey: Key.rate)
        return Snapshot(guid: guid,
                        position: defaults.double(forKey: Key.position),
                        rate: rate > 0.1 ? rate : 1.0)
    }

    /// Find the saved episode again. Returns nil if it was deleted or its
    /// audio has since been cleaned up, in which case there is nothing to
    /// restore and the saved state is dropped.
    @MainActor
    static func restoreEpisode(in context: ModelContext) -> (Episode, Snapshot)? {
        guard let snapshot else { return nil }
        let guid = snapshot.guid
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        descriptor.fetchLimit = 1
        guard let episode = (try? context.fetch(descriptor))?.first else {
            clear()
            return nil
        }
        guard episode.isDownloaded else {
            // Keep the record — the file may come back on the next download —
            // but there is nothing loadable right now.
            return nil
        }
        return (episode, snapshot)
    }
}
