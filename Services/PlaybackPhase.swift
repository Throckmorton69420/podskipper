import Foundation

/// What the player is actually doing, as one value.
///
/// This replaces a `Bool` called `isPlaying` plus a separate `loadError`
/// string, and it exists because that pair could not describe the states the
/// system actually puts an audio app into.
///
/// The app has three reported bugs that are all the same bug:
///
///   * AirPods pause works but resume does nothing.
///   * The Lock Screen shows the pause button while the scrubber sits still.
///   * Another app starts playing, this one goes quiet, and the UI still
///     offers to pause.
///
/// All three are one missing idea. When iOS interrupts an audio session — a
/// call arrives, another app takes the session, a route disappears — it stops
/// your audio without telling your code, unless your code asked to be told.
/// Nothing here asked. So `isPlaying` stayed `true` over silence, the Lock
/// Screen was handed a playback rate derived from that lie, and `play()`, which
/// returned early when it believed the engine was already running, refused to
/// start anything.
///
/// A Boolean has room for "playing" and "not playing". It has no room for
/// "stopped by the system and waiting to be told whether it may resume", which
/// is the state all three bugs live in.
enum PlaybackPhase: Equatable {

    /// Nothing loaded.
    case idle

    /// An episode is being opened. Brief for local files, but not free — and
    /// a tap during it must not be mistaken for a tap on a running player.
    case loading

    /// Making sound.
    case playing

    /// Stopped because a person stopped it.
    case paused

    /// Loaded and wanted, but nothing is coming out yet.
    case buffering

    /// The system took the audio away.
    ///
    /// `resumeWhenPossible` records whether this app was playing at the moment
    /// it was interrupted. It is the difference between a call arriving during
    /// an episode — resume when the call ends — and a call arriving while the
    /// app sat paused in someone's pocket, where resuming would start playing
    /// out of nowhere. iOS supplies its own opinion separately, as the
    /// `.shouldResume` option on the interruption-ended notification; playback
    /// only resumes when both agree.
    case interrupted(resumeWhenPossible: Bool)

    /// Playback finished, or was deliberately torn down. Distinct from
    /// `paused`: there is no position worth returning to.
    case stopped

    /// Could not play, with the reason in the listener's words.
    case failed(String)

    // MARK: - Derived

    /// The single question every play/pause button in the app asks.
    ///
    /// Kept as a name the UI already uses so that adopting this enum changed no
    /// view code: `PlayerEngine.isPlaying` is now computed from here, and all
    /// twenty-two read sites across the views and the intents carried on
    /// working untouched. A rename across that many call sites is exactly the
    /// change that has broken this project's build twice.
    var isPlaying: Bool { self == .playing }

    /// True while the app intends to be making sound, including the moment
    /// before the first sample arrives — so a transport button does not flicker
    /// back to a play triangle between the tap and the audio.
    var isActive: Bool { self == .playing || self == .buffering }

    /// What to hand `MPNowPlayingInfoPropertyPlaybackRate`.
    ///
    /// Zero for every state that is not actually producing sound. The Lock
    /// Screen derives both its button and its scrubber animation from this, so
    /// a non-zero rate over silence is precisely the disagreement people
    /// reported seeing.
    func nowPlayingRate(at speed: Double) -> Double {
        self == .playing ? speed : 0
    }

    /// The message to show, if this phase is a failure.
    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    /// Whether a position is worth remembering for next launch.
    var isResumable: Bool {
        switch self {
        case .playing, .paused, .buffering, .interrupted: return true
        case .idle, .loading, .stopped, .failed:          return false
        }
    }
}
