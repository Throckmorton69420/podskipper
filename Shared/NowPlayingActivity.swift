import ActivityKit
import AppIntents
import Foundation

/// What the Lock Screen's PodSkipper card shows. Shared by the app, which
/// starts and updates it, and the widget extension, which draws it.
struct NowPlayingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var show: String
        var isPlaying: Bool
        /// Seconds cut from this episode so far.
        var secondsSkipped: Double
        /// When playback would reach the end at the current rate, so the
        /// card can count down without the app updating it every second.
        var endsAt: Date?
        /// The episode's release date, as the app's rows show it.
        var published: Date?
        /// Where the playhead is and how long the episode is, in seconds of
        /// audio, for the progress bar.
        var elapsed: Double = 0
        var duration: Double = 0
        var rate: Double = 1
        /// The cover, as a small JPEG. A Live Activity cannot load images
        /// from the network and its whole update must stay under 4 KB, so the
        /// app sends a tiny thumbnail rather than an address.
        var artwork: Data?
    }

    var episodeGUID: String
}

enum NowPlayingLink {
    /// Opens the full player.
    static let player = URL(string: "podskipper://player")!
}

/// What the card's buttons do. They run in the app, which sets these.
@MainActor
enum NowPlayingControl {
    static var toggle: (() -> Void)?
    static var skipBack: (() -> Void)?
    static var skipForward: (() -> Void)?
}

struct CardPlayPauseIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        NowPlayingControl.toggle?()
        return .result()
    }
}

struct CardSkipBackIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip Back"
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        NowPlayingControl.skipBack?()
        return .result()
    }
}

struct CardSkipForwardIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip Forward"
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        NowPlayingControl.skipForward?()
        return .result()
    }
}
