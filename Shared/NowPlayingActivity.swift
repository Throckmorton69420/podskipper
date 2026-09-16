import ActivityKit
import Foundation

/// What the Lock Screen's PodSkipper card shows. Shared by the app, which
/// starts and updates it, and the widget extension, which draws it.
struct NowPlayingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var show: String
        var isPlaying: Bool
        /// Seconds cut from this episode so far, shown as a reminder that the
        /// ads are going.
        var secondsSkipped: Double
        /// When playback would reach the end at the current rate, so the
        /// card can count down without the app updating it every second.
        var endsAt: Date?
    }

    var episodeGUID: String
}

enum NowPlayingLink {
    /// Opens the full player.
    static let player = URL(string: "podskipper://player")!
}
