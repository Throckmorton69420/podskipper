import Foundation
import AVFoundation

/// Playback straight from the feed's address, for an episode that isn't
/// downloaded yet (task 07).
///
/// Pressing play on an episode that wasn't downloaded used to mean waiting
/// for the whole file first — a minute or more for a long episode on a slow
/// connection. This plays it at once with `AVPlayer`, while the normal
/// download carries on; `PlayerEngine` moves to the downloaded file at the
/// same moment once it lands.
///
/// What streaming can't do: the equaliser, Enhance Dialogue and the other
/// repairs are `AVAudioUnit`s in the audio engine's graph, which needs a file
/// it can read buffers from. `AVPlayer` gives no access to its buffers, so
/// while streaming only the speed and the volume level apply. Ad skipping is
/// seeking, so it works the same as always.
final class StreamEngine: NSObject, PlaybackEngine {

    private let player: AVPlayer = {
        let player = AVPlayer()
        // Sound only: nothing here is ever shown.
        player.allowsExternalPlayback = false
        return player
    }()

    var onFinished: (() -> Void)?
    var onDurationResolved: ((Double) -> Void)?
    /// `AVPlayer` rebuilds itself after a media services reset.
    var onEngineReset: (() -> Void)?

    private(set) var isRunning = false

    private var asset: AVURLAsset?
    private var item: AVPlayerItem?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var wantedRate: Float = 1
    /// The length read from the file before playing, so the scrubber and ad
    /// skipping have a scale from the first second.
    private var knownDuration: Double = 0
    /// A position asked for before the item could seek. `AVPlayer` drops a
    /// seek made before its item is ready, so it is kept and made then.
    private var pendingSeek: Double?

    deinit {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation?.invalidate()
    }

    // MARK: Loading

    /// `fileURL` is the enclosure's web address here, whatever the name says.
    func load(fileURL: URL) throws {
        stop()
        let newAsset = AVURLAsset(url: fileURL)
        let newItem = AVPlayerItem(asset: newAsset)
        // Speech-tuned time stretching, as on the other engines.
        newItem.audioTimePitchAlgorithm = .timeDomain
        asset = newAsset
        item = newItem
        player.replaceCurrentItem(with: newItem)

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: newItem,
            queue: .main
        ) { [weak self] _ in
            self?.isRunning = false
            self?.onFinished?()
        }

        statusObservation = newItem.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            guard observed.status == .readyToPlay else { return }
            let seconds = observed.duration.seconds
            Task { @MainActor in
                guard let self else { return }
                if let target = self.pendingSeek {
                    self.pendingSeek = nil
                    self.seek(to: target)
                }
                if seconds.isFinite, seconds > 0, abs(seconds - self.knownDuration) > 0.5 {
                    self.knownDuration = seconds
                    self.onDurationResolved?(seconds)
                }
            }
        }
    }

    /// Reads the file's length from the start of the stream. Zero when it
    /// can't be read — no connection, or not an audio file — which the
    /// caller takes as "download it instead".
    func loadDuration() async -> Double {
        guard let asset else { return 0 }
        guard let time = try? await asset.load(.duration) else { return 0 }
        let seconds = time.seconds
        guard seconds.isFinite, seconds > 0 else { return 0 }
        knownDuration = seconds
        return seconds
    }

    // MARK: State

    var duration: Double {
        if let seconds = item?.duration.seconds, seconds.isFinite, seconds > 0 { return seconds }
        return knownDuration
    }

    var currentTime: Double {
        if let pendingSeek { return pendingSeek }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    /// Waiting for the network counts as playing: it is not an interruption,
    /// and the player must not give up on it as one.
    var isRendering: Bool {
        isRunning && player.timeControlStatus != .paused
    }

    // MARK: Transport

    func play(from seconds: Double) throws {
        guard item != nil else { throw PlaybackError.noFileLoaded }
        seek(to: max(0, seconds))
        player.rate = wantedRate
        isRunning = true
    }

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
        asset = nil
        pendingSeek = nil
        knownDuration = 0
        isRunning = false
    }

    func setRate(_ rate: Double) {
        wantedRate = Float(max(0.5, min(4, rate)))
        if isRunning { player.rate = wantedRate }
    }

    /// Only the level reaches a stream (see the type's note): normalisation
    /// as a plain gain, as video does.
    func apply(settings: AppSettings, sound: SoundSettings) {
        let gain = Float(pow(10, sound.normalizationDB / 20))
        player.volume = max(0.1, min(2, gain))
    }

    private func seek(to seconds: Double) {
        guard let item, item.status == .readyToPlay else {
            pendingSeek = seconds
            return
        }
        // Exact, like the other engines: an ad cut that lands late is the ad
        // you were trying not to hear.
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }
}
