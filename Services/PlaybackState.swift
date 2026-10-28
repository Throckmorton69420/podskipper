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
        /// When it was written; nil from builds before Pass 47.
        var savedAt: Date?
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
        let savedAt = defaults.double(forKey: Key.savedAt)
        return Snapshot(guid: guid,
                        position: defaults.double(forKey: Key.position),
                        rate: rate > 0.1 ? rate : 1.0,
                        savedAt: savedAt > 0 ? Date(timeIntervalSince1970: savedAt) : nil)
    }

    /// Pass 47: the snapshot's position for `episode`, when it is the newer
    /// of the two. The player writes the snapshot every few seconds and the
    /// library's record only each minute or at a pause, and the library's
    /// change can be lost if iOS ends the app before it saves; so for the
    /// episode it names, the snapshot is the latest intentional position —
    /// unless the record was set after it (marked played, or another
    /// device's newer pause).
    static func fresherPosition(for episode: Episode, snapshot: Snapshot? = snapshot) -> Double? {
        guard let snapshot, snapshot.guid == episode.guid, snapshot.position.isFinite, snapshot.position >= 0
        else { return nil }
        if let changed = episode.playbackPositionChangedAt,
           changed > (snapshot.savedAt ?? .distantPast).addingTimeInterval(1) { return nil }
        // A pre-Pass-47 snapshot against an undated record: the snapshot
        // (written more often, and on every pause) is the newer.
        return abs(snapshot.position - episode.playbackPosition) > 0.5 ? snapshot.position : nil
    }

    /// Brings `episode`'s record up to the snapshot when the snapshot is newer.
    @MainActor
    static func adoptFresherPosition(into episode: Episode) {
        guard let snap = snapshot, let position = fresherPosition(for: episode, snapshot: snap) else { return }
        episode.setPosition(position, at: snap.savedAt ?? .now)
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
        // Pass 47: the record catches up with the snapshot here, whether or
        // not there is a file to put in the player, so playing the episode
        // from its show later starts where it was paused too.
        adoptFresherPosition(into: episode)
        guard episode.isDownloaded else {
            // Keep the record — the file may come back on the next download —
            // but there is nothing loadable right now.
            return nil
        }
        return (episode, snapshot)
    }
}
