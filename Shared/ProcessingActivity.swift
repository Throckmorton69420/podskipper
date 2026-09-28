import ActivityKit
import Foundation

/// The Lock Screen card for finding ads (pass 21): which episode, which
/// step, how far, how long left, "2 of 5", and how it ended. His 27 Sep ask:
/// see without unlocking whether ads are still being found and what the app
/// is doing. Shared by the app, which updates it, and the widget extension,
/// which draws it.
struct ProcessingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable { case working, waiting, paused, done }
        var phase: Phase
        var title: String
        var show: String
        /// "Transcribing on device", "Finding ads", "Paused by iOS"…
        var step: String
        /// This episode, 0...1.
        var fraction: Double
        /// "2 of 5", when there is a line.
        var position: Int
        var total: Int
        /// When it should be done at the current pace, for a countdown the
        /// card runs itself.
        var endsAt: Date?
        /// When finished: how many cuts, and how long they add up to.
        var cuts: Int = 0
        var cutSeconds: Double = 0
        var artwork: Data?
    }

    /// One card per session of work, not per episode.
    var startedAt: Date
}

enum ProcessingLink {
    /// Opens the Activity screen.
    static let activity = URL(string: "podskipper://activity")!
}
