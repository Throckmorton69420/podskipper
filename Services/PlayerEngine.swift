import Foundation
import Observation
import AVFoundation
import MediaPlayer
import SwiftData

/// Playback, ad skipping and Smart Speed, on top of `AudioEngine`.
///
/// Skips are driven by a polling loop rather than boundary observers, because
/// there are now two kinds of jump — advertisements and shortened silences —
/// and merging them into one sorted list is simpler than juggling two sets of
/// observers that keep getting invalidated by seeks.
@MainActor
@Observable
final class PlayerEngine {

    static let shared = PlayerEngine()

    private(set) var currentEpisode: Episode?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var lastSkip: (sponsor: String, seconds: Double, segmentStart: Double)?
    private(set) var smartSpeedSavedSeconds: Double = 0
    private(set) var loadError: String?

    var playbackRate: Double = 1.0 {
        didSet {
            audio.setRate(playbackRate)
            updateNowPlaying()
        }
    }
    var autoSkipEnabled = true

    private let audio = AudioEngine()
    private var settings = AppSettings()
    private var ticker: Task<Void, Never>?
    private var adRanges: [ClosedRange<Double>] = []
    private var silenceJumps: [ClosedRange<Double>] = []

    /// Fed in so the player can advance to the next queued episode.
    var queueProvider: (@MainActor () -> Episode?)?

    private init() {
        configureSession()
        setupRemoteCommands()
        audio.onFinished = { [weak self] in
            Task { @MainActor in self?.handleEnd() }
        }
    }

    func configure(settings: AppSettings) {
        self.settings = settings
        playbackRate = settings.defaultPlaybackSpeed
        autoSkipEnabled = settings.autoSkipEnabled
    }

    // MARK: - Loading

    func load(_ episode: Episode, autoplay: Bool = true) {
        if let previous = currentEpisode, previous !== episode {
            previous.playbackPosition = currentTime
        }
        loadError = nil
        smartSpeedSavedSeconds = 0

        guard let url = episode.localFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            loadError = "This episode isn't downloaded yet. Tap Find ads, or download it first."
            return
        }

        do {
            try audio.load(fileURL: url)
        } catch {
            loadError = "Couldn't open the audio: \(error.localizedDescription)"
            return
        }

        currentEpisode = episode
        duration = audio.duration > 0 ? audio.duration : episode.duration
        rebuildJumps()

        // Per-show speed override beats the global default.
        playbackRate = episode.podcast?.playbackSpeedOverride ?? settings.defaultPlaybackSpeed
        audio.apply(settings: settings, normalizationGain: episode.normalizationGain)
        audio.setRate(playbackRate)

        var start = episode.playbackPosition
        if start < 1, let intro = episode.podcast?.skipIntroSeconds, intro > 0 {
            start = intro
        }
        if start >= duration - 2 { start = 0 }

        if autoplay {
            play(from: start)
        } else {
            currentTime = start
            updateNowPlaying()
        }
    }

    /// Recompute the merged jump list. Call after changing a correction or a
    /// Smart Speed setting mid-episode.
    func rebuildJumps() {
        guard let episode = currentEpisode else {
            adRanges = []; silenceJumps = []; return
        }
        adRanges = autoSkipEnabled ? episode.skipRanges : []

        if settings.smartSpeedEnabled {
            silenceJumps = AudioAnalyzer.smartSpeedJumps(
                from: episode.silenceRanges,
                aggressiveness: settings.smartSpeedAggressiveness
            )
        } else {
            silenceJumps = []
        }
    }

    func refreshSkipRanges() { rebuildJumps() }

    func applyAudioSettings() {
        guard let episode = currentEpisode else { return }
        audio.apply(settings: settings, normalizationGain: episode.normalizationGain)
        audio.setRate(playbackRate)
        rebuildJumps()
    }

    // MARK: - Transport

    func play(from seconds: Double? = nil) {
        do {
            if let seconds {
                try audio.play(from: seconds)
                currentTime = seconds
            } else if audio.isRunning {
                return
            } else {
                try audio.play(from: currentTime)
            }
            isPlaying = true
            startTicking()
            updateNowPlaying()
        } catch {
            loadError = error.localizedDescription
        }
    }

    func pause() {
        audio.pause()
        isPlaying = false
        ticker?.cancel()
        currentEpisode?.playbackPosition = currentTime
        updateNowPlaying()
    }

    func togglePlayPause() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        let target = min(max(0, seconds), max(0, duration - 0.2))
        currentTime = target
        if isPlaying {
            play(from: target)
        } else {
            updateNowPlaying()
        }
    }

    func skipForward() { seek(to: currentTime + settings.seekForwardSeconds) }
    func skipBackward() { seek(to: currentTime - settings.seekBackwardSeconds) }

    func rewindLastSkip() {
        guard let last = lastSkip else { return }
        seek(to: max(0, last.segmentStart - 1))
        lastSkip = nil
    }

    func markPlayedAndAdvance() {
        currentEpisode?.isPlayed = true
        currentEpisode?.isInQueue = false
        handleEnd(force: true)
    }

    // MARK: - The tick

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.isPlaying else { continue }
                await MainActor.run { self.tick() }
            }
        }
    }

    private func tick() {
        let now = audio.currentTime
        currentTime = now
        currentEpisode?.playbackPosition = now

        // Outro trim
        if let outro = currentEpisode?.podcast?.skipOutroSeconds, outro > 0,
           now >= duration - outro {
            handleEnd()
            return
        }

        // Advertisement
        if let range = adRanges.first(where: { $0.contains(now) }) {
            let sponsor = currentEpisode?.adSegments
                .first { $0.start <= now && $0.end >= now }?.sponsor ?? ""
            lastSkip = (sponsor, range.upperBound - now, range.lowerBound)
            seek(to: range.upperBound)
            return
        }

        // Smart Speed
        if let gap = silenceJumps.first(where: { $0.contains(now) }) {
            smartSpeedSavedSeconds += gap.upperBound - now
            seek(to: gap.upperBound)
            return
        }

        if now >= duration - 0.3 { handleEnd() }
    }

    private func handleEnd(force: Bool = false) {
        guard let finished = currentEpisode else { return }
        if settings.markPlayedAtEnd || force {
            finished.isPlayed = true
            finished.isInQueue = false
            finished.playbackPosition = 0
            finished.lastPlayedAt = .now
        }
        ticker?.cancel()

        guard settings.continuousPlayback || force, let next = queueProvider?() else {
            audio.stop()
            isPlaying = false
            updateNowPlaying()
            return
        }
        load(next, autoplay: true)
    }

    // MARK: - System integration

    private func configureSession() {
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
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }; return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.markPlayedAndAdvance() }; return .success
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
        guard let episode = currentEpisode else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: episode.podcast?.title ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0.0
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Sleep timer

    private(set) var sleepTimerEndsAt: Date?
    private(set) var sleepAtEpisodeEnd = false
    private var sleepTask: Task<Void, Never>?

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel(); sleepTask = nil
        sleepAtEpisodeEnd = false
        guard let minutes else { sleepTimerEndsAt = nil; return }
        sleepTimerEndsAt = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.pause()
                self?.sleepTimerEndsAt = nil
            }
        }
    }

    func sleepAtEndOfEpisode() {
        sleepTask?.cancel(); sleepTask = nil
        sleepTimerEndsAt = nil
        sleepAtEpisodeEnd = true
    }
}
