import Foundation
import AVFoundation

/// What `PlayerEngine` needs from whatever is actually making the sound.
///
/// There are two implementations. `AudioEngine` is an `AVAudioEngine` graph —
/// it exists because Smart Speed, voice boost, the ten-band equaliser and
/// sample-accurate seeking all need access to the buffers, which `AVPlayer`
/// does not give you. `VideoEngine` is an `AVPlayer`, because video needs a
/// layer to draw into and `AVAudioEngine` has no concept of a picture.
///
/// Everything above this line — ad skipping, Smart Speed jumps, the queue,
/// Now Playing, the whole player UI — is written against the protocol and
/// does not know or care which one is running. Ad skipping in particular is
/// just seeking, so it works identically for both.
protocol PlaybackEngine: AnyObject {

    /// Called when playback reaches the end of the file.
    var onFinished: (() -> Void)? { get set }

    /// Fired when the real duration becomes known.
    ///
    /// `AVPlayer` does not know how long a file is until its item is ready,
    /// and `PlayerEngine.load` is synchronous. Rather than block, the feed's
    /// claimed duration is used first and replaced through this when the
    /// truth arrives. `AudioEngine` knows immediately and never calls it.
    var onDurationResolved: ((Double) -> Void)? { get set }

    /// Fired when the system tore the audio stack down and it has been rebuilt.
    /// The player uses it to put playback back where it was.
    var onEngineReset: (() -> Void)? { get set }

    var isRunning: Bool { get }
    /// Whether sound is actually coming out now, asked of the audio system
    /// rather than our own flag (which a call can leave stale).
    var isRendering: Bool { get }
    var currentTime: Double { get }
    /// Zero when not yet known — the caller should fall back to the feed's.
    var duration: Double { get }

    func load(fileURL: URL) throws
    func apply(settings: AppSettings, normalizationGain: Double)
    func setRate(_ rate: Double)

    /// Start at a specific position. Tears down and rebuilds the schedule, so
    /// this is the seek path.
    func play(from seconds: Double) throws

    /// Carry on from exactly where `pause` left off, without rescheduling.
    ///
    /// This exists separately from `play(from:)` because resuming used to go
    /// through the seek path, which throws away the node's own sample clock and
    /// depends on the position having been measured correctly at the moment of
    /// pausing — which it was not. A resume that does nothing but let the
    /// render thread run again cannot get the position wrong.
    func resume() throws

    func pause()
    func stop()
}

extension PlaybackEngine {
    var isRendering: Bool { isRunning }
}

/// Playback for video episodes.
///
/// Deliberately thin. `AVPlayer` handles the decode and the layer; this adds
/// the same surface the audio path has, so nothing above needs a branch.
///
/// What video does not get is the parts that need raw buffers: the equaliser,
/// voice boost and volume normalisation are all `AVAudioUnit`s on a graph
/// `AVPlayer` does not expose. Speed and ad skipping work exactly the same.
final class VideoEngine: NSObject, PlaybackEngine {

    /// Handed to the view layer so it can attach an `AVPlayerLayer`.
    let player = AVPlayer()

    var onFinished: (() -> Void)?
    var onDurationResolved: ((Double) -> Void)?
    /// `AVPlayer` rebuilds itself after a media services reset, so nothing here
    /// ever needs to raise this.
    var onEngineReset: (() -> Void)?

    private(set) var isRunning = false

    private var item: AVPlayerItem?
    private var endObserver: NSObjectProtocol?

    /// Picture on or off, on the same player.
    ///
    /// Switching between video and audio is not switching files: the audio
    /// carries on from the one player and only the picture comes and goes,
    /// so the two can never drift apart. With the picture off the video track
    /// is disabled outright, so the phone stops decoding frames nobody sees —
    /// which is most of the power a video episode costs.
    var showsVideo = true {
        didSet { if showsVideo != oldValue { applyVideoTrack() } }
    }

    private func applyVideoTrack() {
        guard let item else { return }
        for track in item.tracks where track.assetTrack?.mediaType == .video {
            track.isEnabled = showsVideo
        }
    }
    private var statusObservation: NSKeyValueObservation?
    private var wantedRate: Float = 1

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation?.invalidate()
    }

    // MARK: - Loading

    func load(fileURL: URL) throws {
        stop()

        let asset = AVURLAsset(url: fileURL)
        let newItem = AVPlayerItem(asset: asset)
        // Speech-tuned time stretching. The default algorithm turns a host at
        // 1.5x into a chipmunk; this is the one designed for voice.
        newItem.audioTimePitchAlgorithm = .timeDomain
        item = newItem
        player.replaceCurrentItem(with: newItem)

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: newItem,
            queue: .main
        ) { [weak self] _ in
            self?.isRunning = false
            self?.onFinished?()
        }

        // The duration arrives when the item is ready, not when it is created.
        statusObservation?.invalidate()
        statusObservation = newItem.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            guard observed.status == .readyToPlay else { return }
            Task { @MainActor in self?.applyVideoTrack() }
            let seconds = observed.duration.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            Task { @MainActor in self?.onDurationResolved?(seconds) }
        }
    }

    // MARK: - State

    var duration: Double {
        guard let seconds = item?.duration.seconds, seconds.isFinite, seconds > 0 else { return 0 }
        return seconds
    }

    var currentTime: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    // MARK: - Transport

    func play(from seconds: Double) throws {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        // Zero tolerance, because an ad cut that lands half a second late is
        // the ad you were trying not to hear.
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        player.rate = wantedRate
        isRunning = true
    }

    /// Resuming an `AVPlayer` is just setting the rate again — it keeps its own
    /// position, so there is nothing to reschedule.
    func resume() throws {
        guard item != nil else { throw PlaybackError.noFileLoaded }
        player.rate = wantedRate
        isRunning = true
    }

    func pause() {
        player.pause()
        isRunning = false
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        item = nil
        isRunning = false
    }

    func setRate(_ rate: Double) {
        wantedRate = Float(max(0.5, min(4, rate)))
        // Setting `rate` on a paused player starts it. Only follow through
        // when something is already running.
        if isRunning { player.rate = wantedRate }
    }

    /// Volume is all `AVPlayer` exposes of the audio chain.
    ///
    /// Normalisation is applied as a plain gain. The equaliser, voice boost
    /// and Smart Speed's silence trimming need the buffers, so they stay on
    /// the audio path and the player UI hides them for video.
    func apply(settings: AppSettings, normalizationGain: Double) {
        let gain = settings.volumeNormalizationEnabled ? Float(normalizationGain) : 1
        player.volume = max(0.1, min(2, gain))
    }
}
