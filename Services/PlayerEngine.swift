import Foundation
import AVFoundation
import MediaPlayer
import Combine

/// Playback with ad ranges cut out.
///
/// Skips are done with boundary observers rather than a timer poll, so the
/// seek fires at the sample the ad starts instead of up to a half-second late.
@MainActor
@Observable
final class PlayerEngine {

    static let shared = PlayerEngine()

    private(set) var currentEpisode: Episode?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var lastSkip: (sponsor: String, seconds: Double)?

    var playbackRate: Float = 1.0 {
        didSet {
            if isPlaying { player.rate = playbackRate }
            UserDefaults.standard.set(playbackRate, forKey: "rate")
        }
    }
    var autoSkipEnabled = true

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var boundaryObserver: Any?
    private var skipRanges: [ClosedRange<Double>] = []

    private init() {
        playbackRate = UserDefaults.standard.float(forKey: "rate")
        if playbackRate == 0 { playbackRate = 1.0 }
        configureAudioSession()
        setupRemoteCommands()
        observeTime()
    }

    // MARK: - Loading

    func load(_ episode: Episode, autoplay: Bool = true) {
        // Save position of whatever was playing.
        if let previous = currentEpisode {
            previous.playbackPosition = currentTime
        }

        let url: URL
        if let local = episode.localFileURL, FileManager.default.fileExists(atPath: local.path) {
            url = local
        } else if let remote = URL(string: episode.audioURL) {
            // Streaming works, but ad ranges only exist for processed episodes,
            // so a streamed episode plays with its ads intact.
            url = remote
        } else {
            return
        }

        currentEpisode = episode
        skipRanges = episode.skipRanges
        player.replaceCurrentItem(with: AVPlayerItem(url: url))

        if episode.playbackPosition > 1 {
            seek(to: episode.playbackPosition)
        }
        installBoundaryObserver()
        updateNowPlaying()

        if autoplay { play() }
    }

    /// Call after re-processing so the player picks up new cuts mid-episode.
    func refreshSkipRanges() {
        guard let episode = currentEpisode else { return }
        skipRanges = episode.skipRanges
        installBoundaryObserver()
    }

    // MARK: - Transport

    func play() {
        player.rate = playbackRate
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        currentEpisode?.playbackPosition = currentTime
        updateNowPlaying()
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
        updateNowPlaying()
    }

    func skipForward(_ seconds: Double = 30) { seek(to: currentTime + seconds) }
    func skipBackward(_ seconds: Double = 15) { seek(to: currentTime - seconds) }

    /// Undo an automatic skip — the app just jumped, and it was wrong.
    func rewindLastSkip() {
        guard let last = lastSkip else { return }
        seek(to: max(0, currentTime - last.seconds - 1))
        lastSkip = nil
    }

    // MARK: - Ad skipping

    private func installBoundaryObserver() {
        if let boundaryObserver {
            player.removeTimeObserver(boundaryObserver)
            self.boundaryObserver = nil
        }
        guard autoSkipEnabled, !skipRanges.isEmpty else { return }

        let starts = skipRanges.map {
            NSValue(time: CMTime(seconds: $0.lowerBound, preferredTimescale: 600))
        }
        boundaryObserver = player.addBoundaryTimeObserver(
            forTimes: starts, queue: .main
        ) { [weak self] in
            self?.handleAdBoundary()
        }
    }

    private func handleAdBoundary() {
        let now = player.currentTime().seconds
        guard let range = skipRanges.first(where: { $0.contains(now) }) else { return }
        let jumped = range.upperBound - now
        let sponsor = currentEpisode?.adSegments
            .first { $0.start <= now && $0.end >= now }?.sponsor ?? ""
        lastSkip = (sponsor, jumped)
        seek(to: range.upperBound)
    }

    /// Boundary observers can be missed if the user seeks straight into the
    /// middle of an ad, so the periodic observer acts as a safety net.
    private func observeTime() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            if let item = self.player.currentItem, item.duration.isNumeric {
                self.duration = item.duration.seconds
            }
            self.currentEpisode?.playbackPosition = time.seconds

            if self.autoSkipEnabled,
               let range = self.skipRanges.first(where: { $0.contains(time.seconds) }),
               range.upperBound - time.seconds > 1 {
                self.handleAdBoundary()
            }
        }
    }

    // MARK: - System integration

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }; return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }; return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipForward() }; return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipBackward() }; return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: e.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let episode = currentEpisode else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: episode.podcast?.title ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackRate) : 0.0
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
