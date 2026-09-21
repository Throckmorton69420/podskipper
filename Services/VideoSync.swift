import AVFoundation
import Observation

/// The picture for a video episode, following the sound.
///
/// The sound of a video episode is played exactly like any other episode — by
/// the audio engine, from the episode's own audio track — so Smart Speed,
/// Voice Boost, the equaliser, normalisation and ad skipping all work on it.
/// The picture is a muted `AVPlayer` that follows that sound: it is started,
/// stopped and moved whenever the sound is, and a few times a second it is
/// checked against the sound's position and nudged back into step — a small
/// speed change for a small drift, a jump for a large one (an ad skip, a Smart
/// Speed jump, a seek).
///
/// This is how the Video / Audio switch stays in sync: switching never
/// touches the sound at all. Only the picture comes and goes, and with it off
/// nothing is decoded.
@MainActor
@Observable
final class VideoSync {

    let player: AVPlayer = {
        let player = AVPlayer()
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = true
        return player
    }()

    /// The source currently loaded, if any.
    private(set) var sourceURL: URL?
    /// Ready to show a picture.
    private(set) var isReady = false
    /// Why a video could not be shown, in words, when that happens.
    private(set) var problem: String?

    // Where the sound is, supplied by `PlayerEngine`.
    @ObservationIgnored var soundTime: () -> Double = { 0 }
    @ObservationIgnored var soundRate: () -> Double = { 1 }
    @ObservationIgnored var soundPlaying: () -> Bool = { false }
    /// The picture was paused or played from outside — Picture in Picture's
    /// own buttons. The sound follows.
    @ObservationIgnored var onExternalPlayPause: ((Bool) -> Void)?

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var lastRateWeSet: Float = 0
    @ObservationIgnored private var active = false
    @ObservationIgnored private var expectedDuration: Double = 0

    // MARK: Source

    /// Load a picture. `expectedDuration` is the sound's length; a remote
    /// stream whose length differs by more than a few seconds has different
    /// ad breaks from the audio and cannot be kept in step.
    func attach(_ url: URL, expectedDuration: Double) {
        guard url != sourceURL else { return }
        detach()
        sourceURL = url
        self.expectedDuration = expectedDuration
        problem = nil
        let item = AVPlayerItem(url: url)
        // Only the picture is used; the audio track is never heard.
        item.preferredForwardBufferDuration = url.isFileURL ? 0 : 20
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            let status = observed.status
            let seconds = observed.duration.seconds
            let message = observed.error?.localizedDescription
            Task { @MainActor in self?.itemChanged(status: status, duration: seconds, error: message) }
        }
        player.replaceCurrentItem(with: item)
    }

    func detach() {
        loop?.cancel(); loop = nil
        statusObservation?.invalidate(); statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        sourceURL = nil
        isReady = false
        lastRateWeSet = 0
    }

    private func itemChanged(status: AVPlayerItem.Status, duration: Double, error: String?) {
        switch status {
        case .readyToPlay:
            if let url = sourceURL, !url.isFileURL, duration.isFinite, duration > 0,
               expectedDuration > 0, abs(duration - expectedDuration) > 4 {
                // A stream with its own, differently timed ad breaks. Showing
                // it would put the picture minutes away from the sound.
                problem = "This episode's video has different ad breaks from its audio, so PodSkipper can't keep the two in step. Playing audio only."
                detach()
                return
            }
            isReady = true
            if active { snap() }
        case .failed:
            problem = "The video couldn't be loaded" + (error.map { ": \($0)" } ?? ".")
            isReady = false
        default:
            break
        }
    }

    // MARK: Following

    /// Run while the picture can be seen; stop decoding when it cannot.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            snap()
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.correct()
                }
            }
        } else {
            loop?.cancel(); loop = nil
            player.pause()
            lastRateWeSet = 0
        }
    }

    /// Put the picture exactly where the sound is now — after a seek or a
    /// jump, rather than waiting for the next check.
    func snap() {
        guard active, isReady, !seeking else { return }
        let target = soundTime()
        seeking = true
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeking = false
                self.applyRate(drift: 0)
            }
        }
    }

    private func correct() {
        guard active, isReady, !seeking, player.currentItem != nil else { return }

        // Picture in Picture's play and pause buttons act on this player.
        // Anything that changed its rate other than us is the listener.
        if lastRateWeSet > 0, player.rate == 0, player.timeControlStatus == .paused, soundPlaying() {
            lastRateWeSet = 0
            onExternalPlayPause?(false)
            return
        }
        if lastRateWeSet == 0, player.rate > 0, !soundPlaying() {
            lastRateWeSet = player.rate
            onExternalPlayPause?(true)
            return
        }

        let target = soundTime()
        let now = player.currentTime().seconds
        guard now.isFinite else { return }
        let drift = now - target
        if abs(drift) > 0.35 {
            snap()
        } else {
            applyRate(drift: drift)
        }
    }

    /// The sound's speed, plus up to 4% either way to close a small gap.
    private func applyRate(drift: Double) {
        guard soundPlaying() else {
            if player.rate != 0 { player.pause() }
            lastRateWeSet = 0
            return
        }
        let base = Float(max(0.5, soundRate()))
        let correction = Float(max(-0.04, min(0.04, -drift * 0.5)))
        let rate = abs(drift) < 0.03 ? base : base * (1 + correction)
        if abs(player.rate - rate) > 0.001 { player.rate = rate }
        lastRateWeSet = rate
    }
}
