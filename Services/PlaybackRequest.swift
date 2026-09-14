import Foundation
import SwiftData

/// What happens when you press play on an episode nobody has found the ads in
/// yet.
///
/// Until now the answer was: nothing you asked for. Pressing play on an
/// unprocessed episode either refused, or silently started a transcription and
/// left you looking at a progress bar. Neither is what someone who just pressed
/// play wanted, and there was no way to say "just play it".
///
/// So a play on an unprocessed episode raises a request rather than making the
/// decision. The UI shows the two choices with a countdown, and **playing is
/// what the countdown lands on** — silence has to mean the thing that gets you
/// listening, not the thing that makes you wait. Finding ads first is one tap
/// away for the times you would rather wait.
@MainActor
@Observable
final class PlaybackRequest {

    static let shared = PlaybackRequest()

    /// The episode waiting on an answer, if any.
    private(set) var pending: Episode?
    /// Seconds left before the default is taken.
    private(set) var secondsLeft: Double = 0
    /// Why we are asking — the wording differs between a deliberate tap and
    /// autoplay moving on by itself.
    private(set) var reason: Reason = .tapped

    enum Reason {
        case tapped
        case autoplay

        var headline: String {
            switch self {
            case .tapped:   return "Ads haven't been found yet"
            case .autoplay: return "Up next hasn't been processed"
            }
        }

        var detail: String {
            switch self {
            case .tapped:
                return "You can play it now with the ads in, or wait while they're found."
            case .autoplay:
                return "Playing it with the ads in, unless you'd rather wait."
            }
        }
    }

    private var countdown: Task<Void, Never>?
    private var onPlayNow: ((Episode) -> Void)?
    private var onProcessFirst: ((Episode) -> Void)?

    private init() {}

    /// True when this episode can just be played — already processed, or the
    /// listener has said they do not want it processed.
    static func needsAsking(_ episode: Episode, settings: AppSettings) -> Bool {
        guard episode.isDownloaded else { return false }
        guard episode.processingState != .ready else { return false }
        // Nothing to find ads in if ad skipping is off for this episode
        // entirely — asking would be a question with one real answer.
        guard episode.skipsAds(default: settings.autoSkipEnabled) else { return false }
        return true
    }

    func ask(for episode: Episode,
             reason: Reason,
             countdownSeconds: Double,
             playNow: @escaping (Episode) -> Void,
             processFirst: @escaping (Episode) -> Void) {
        countdown?.cancel()
        pending = episode
        self.reason = reason
        onPlayNow = playNow
        onProcessFirst = processFirst
        secondsLeft = max(1, countdownSeconds)

        countdown = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.secondsLeft -= 0.1
                if self.secondsLeft <= 0 {
                    self.choosePlayNow()
                    return
                }
            }
        }
    }

    func choosePlayNow() {
        countdown?.cancel(); countdown = nil
        guard let episode = pending else { return }
        clear()
        onPlayNow?(episode)
    }

    func chooseProcessFirst() {
        countdown?.cancel(); countdown = nil
        guard let episode = pending else { return }
        clear()
        onProcessFirst?(episode)
    }

    /// Dismissed without choosing. Treated as "play it" — the same as letting
    /// the countdown run out, because a swipe away is not a request to wait.
    func dismiss() {
        choosePlayNow()
    }

    private func clear() {
        pending = nil
        secondsLeft = 0
        onPlayNow = nil
        onProcessFirst = nil
    }
}

// MARK: - Next episode

/// Which episode logically follows the one playing.
///
/// "The next one" is not the next array element. A show sorted newest-first
/// puts the episode *before* the current one at the following index, so playing
/// through a back catalogue used to walk backwards in time — finish episode 40,
/// get episode 41, then 42, going further from where you were reading. Apple's
/// own app has this problem and it was worth not copying.
///
/// The rule is: follow the show's own sequence, not the list's order. Within a
/// show that means the next episode by publication date in the direction the
/// listener is travelling, and only among episodes they can actually play.
enum NextEpisode {

    static func following(_ episode: Episode, in context: ModelContext) -> Episode? {
        guard let show = episode.podcast else { return nil }

        let current = episode.publishedAt
        // Playable means downloaded and not already finished. Offering an
        // episode with no audio is a dead end whatever the ordering says.
        let candidates = show.episodes.filter {
            $0.guid != episode.guid && $0.isDownloaded && !$0.isPlayed
        }
        guard !candidates.isEmpty else { return nil }

        // Someone working through a back catalogue oldest-first wants the next
        // one forward in time. Someone keeping up with a show newest-first has
        // already heard what came after, so the next one is older.
        let goingForward = !(show.newestFirst)

        if goingForward {
            let later = candidates
                .filter { $0.publishedAt > current }
                .min { $0.publishedAt < $1.publishedAt }
            if let later { return later }
        } else {
            let earlier = candidates
                .filter { $0.publishedAt < current }
                .max { $0.publishedAt < $1.publishedAt }
            if let earlier { return earlier }
        }

        // Ran off the end of the show in the direction of travel. Fall back to
        // the nearest unplayed episode either side rather than stopping dead.
        return candidates.min {
            abs($0.publishedAt.timeIntervalSince(current))
                < abs($1.publishedAt.timeIntervalSince(current))
        }
    }

    /// The handful of episodes worth getting ready while the current one plays,
    /// so autoplay does not stop to think.
    static func upcoming(after episode: Episode, limit: Int, in context: ModelContext) -> [Episode] {
        guard limit > 0 else { return [] }
        var found: [Episode] = []
        var cursor = episode
        for _ in 0..<limit {
            guard let next = following(cursor, in: context) else { break }
            guard !found.contains(where: { $0.guid == next.guid }) else { break }
            found.append(next)
            cursor = next
        }
        return found
    }
}
