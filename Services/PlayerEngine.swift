import Foundation
import Observation
import AVFoundation
import MediaPlayer
import SwiftData
import UIKit

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

    /// Playhead bookkeeping.
    ///
    /// `tick()` used to write `playbackPosition` and `secondsListened` straight
    /// onto the SwiftData model five times a second. Every one of those writes
    /// marks the context dirty, which invalidates every `@Query` in the app and
    /// re-renders the Library, Up Next and Settings screens — five times a
    /// second, for the entire length of an episode. That is the single largest
    /// cause of the navigation lag.
    ///
    /// The values now accumulate in memory and are flushed to the model on a
    /// slow cadence and at every point where losing them would matter: pause,
    /// seek, episode change, end, and backgrounding.
    private var pendingListenSeconds: Double = 0
    private var lastPersistAt: Date = .distantPast
    private static let persistInterval: TimeInterval = 5

    /// Current chapter, if the episode has any.
    private(set) var currentChapter: Chapter?
    /// Rolling tally for the session that gets written when playback stops.
    private var sessionStart: Date?
    private var sessionSeconds: Double = 0
    private var sessionAdSeconds: Double = 0
    private var sessionSilenceSeconds: Double = 0
    private var lastTickTime: Double = 0
    /// Set by the app so completed sessions can be written to the store.
    var sessionRecorder: (@MainActor (ListeningSession) -> Void)?
    private var artworkCache: [String: MPMediaItemArtwork] = [:]

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
            persistProgress(force: true)
            flushSession()
        }
        currentChapter = nil
        loadError = nil
        smartSpeedSavedSeconds = 0

        guard let url = episode.localFileURL, episode.isDownloaded else {
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
            lastTickTime = start
            updateNowPlaying()
        }
        rememberNowPlaying()
    }

    /// Restore whatever was playing when the app last went away.
    ///
    /// Loaded paused, at the saved position, so reopening the app after a
    /// crash or a force-quit puts the episode back in the mini player instead
    /// of leaving it blank and making you hunt for it in its show.
    func restoreLastSession(context: ModelContext) {
        guard currentEpisode == nil,
              let (episode, snapshot) = PlaybackState.restoreEpisode(in: context)
        else { return }

        load(episode, autoplay: false)
        // `load` clamps to the episode's own stored position; the snapshot is
        // the more recent of the two after an unclean exit.
        if snapshot.position > 1, snapshot.position < duration - 2 {
            currentTime = snapshot.position
            lastTickTime = snapshot.position
            episode.playbackPosition = snapshot.position
        }
        playbackRate = snapshot.rate
        updateNowPlaying()
    }

    /// Recompute the merged jump list. Call after changing a correction or a
    /// Smart Speed setting mid-episode.
    func rebuildJumps() {
        guard let episode = currentEpisode else {
            adRanges = []; silenceJumps = []; return
        }
        // A per-show override beats the global switch.
        let skipping = episode.podcast?.autoSkipEnabled ?? autoSkipEnabled
        adRanges = skipping ? episode.skipRanges : []

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
            if sessionStart == nil { sessionStart = .now }
            lastTickTime = currentTime
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
        persistProgress(force: true)
        flushSession()
        updateNowPlaying()
    }

    /// Write the in-memory playhead onto the model.
    ///
    /// Called on a slow timer while playing and immediately at every point
    /// where the value would otherwise be lost. `force` skips the interval
    /// check.
    func persistProgress(force: Bool = false) {
        guard let episode = currentEpisode else { return }
        if !force, Date().timeIntervalSince(lastPersistAt) < Self.persistInterval { return }
        lastPersistAt = Date()

        episode.playbackPosition = currentTime
        if pendingListenSeconds > 0 {
            episode.secondsListened += pendingListenSeconds
            pendingListenSeconds = 0
        }
        rememberNowPlaying()
    }

    private func rememberNowPlaying() {
        guard let episode = currentEpisode else { return }
        PlaybackState.save(guid: episode.guid, position: currentTime, rate: playbackRate)
    }

    /// Called when the app goes to the background or is about to be terminated.
    func handleAppWillResignActive() {
        persistProgress(force: true)
    }

    /// Writes the accumulated tally as one session and resets the counters.
    /// Called on pause, on episode change, and when playback ends.
    private func flushSession() {
        guard let start = sessionStart, sessionSeconds > 5 else {
            sessionStart = nil
            sessionSeconds = 0; sessionAdSeconds = 0; sessionSilenceSeconds = 0
            return
        }
        let session = ListeningSession(
            startedAt: start,
            seconds: sessionSeconds,
            adSecondsSkipped: sessionAdSeconds,
            silenceSecondsSkipped: sessionSilenceSeconds,
            showTitle: currentEpisode?.podcast?.title ?? "",
            episodeTitle: currentEpisode?.title ?? ""
        )
        sessionRecorder?(session)
        sessionStart = nil
        sessionSeconds = 0; sessionAdSeconds = 0; sessionSilenceSeconds = 0
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

    /// Jump to the start of the next or previous chapter.
    func seekChapter(_ direction: Int) {
        guard let chapters = currentEpisode?.chapters, !chapters.isEmpty else {
            direction > 0 ? skipForward() : skipBackward()
            return
        }
        let sorted = chapters.sorted { $0.start < $1.start }
        if direction > 0 {
            if let next = sorted.first(where: { $0.start > currentTime + 1 }) {
                seek(to: next.start)
            } else {
                seek(to: duration)
            }
        } else {
            // Two taps back within a chapter goes to the previous one.
            let current = sorted.last { $0.start <= currentTime }
            if let current, currentTime - current.start > 3 {
                seek(to: current.start)
            } else if let index = sorted.firstIndex(where: { $0 === current }), index > 0 {
                seek(to: sorted[index - 1].start)
            } else {
                seek(to: 0)
            }
        }
    }

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

        // Count real listening time. A jump backwards is a seek, not listening.
        let delta = now - lastTickTime
        if delta > 0 && delta < 2 {
            sessionSeconds += delta
            pendingListenSeconds += delta
        }
        lastTickTime = now

        currentTime = now
        // Deliberately not written to the model here — see `persistProgress`.
        persistProgress()

        if let chapters = currentEpisode?.chapters, !chapters.isEmpty {
            let active = ChapterService.chapter(at: now, in: chapters)
            if active !== currentChapter {
                currentChapter = active
                updateNowPlaying()
            }
        }

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
            let jumped = range.upperBound - now
            sessionAdSeconds += jumped
            lastSkip = (sponsor, jumped, range.lowerBound)
            Haptics.skip()
            seek(to: range.upperBound)
            return
        }

        // Smart Speed
        if let gap = silenceJumps.first(where: { $0.contains(now) }) {
            let saved = gap.upperBound - now
            smartSpeedSavedSeconds += saved
            sessionSilenceSeconds += saved
            seek(to: gap.upperBound)
            return
        }

        if now >= duration - 0.3 { handleEnd() }
    }

    private func handleEnd(force: Bool = false) {
        guard let finished = currentEpisode else { return }
        persistProgress(force: true)
        flushSession()

        let markPlayed = settings.markPlayedAtEnd || force
        if markPlayed {
            finished.isPlayed = true
            finished.isInQueue = false
            finished.playbackPosition = 0
            finished.lastPlayedAt = .now
            CountsCache.invalidate(finished.podcast)
            LibraryTotals.shared.invalidate()
        }
        ticker?.cancel()

        // A sleep timer set to "end of episode" stops here regardless of
        // whether continuous playback is on.
        if sleepAtEpisodeEnd {
            sleepAtEpisodeEnd = false
            audio.stop()
            isPlaying = false
            updateNowPlaying()
            if markPlayed { tidyFinished(finished) }
            return
        }

        guard settings.continuousPlayback || force, let next = queueProvider?() else {
            audio.stop()
            isPlaying = false
            updateNowPlaying()
            if markPlayed { tidyFinished(finished) }
            return
        }
        load(next, autoplay: true)
        if markPlayed { tidyFinished(finished) }
    }

    /// Honour "Remove Played Downloads", after the engine has either stopped
    /// or moved on to the next episode — never while this file is still the
    /// scheduled segment.
    private func tidyFinished(_ episode: Episode) {
        let wasDownloaded = episode.isDownloaded
        DownloadManager.removePlayedIfWanted(episode, settings: settings)

        // If its audio just went away and it is still what the mini player
        // would restore to, there is nothing left to resume — forget it rather
        // than reopening to an episode that can't play.
        if wasDownloaded, !episode.isDownloaded,
           currentEpisode === episode || currentEpisode == nil,
           PlaybackState.snapshot?.guid == episode.guid {
            PlaybackState.clear()
        }
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
            MPMediaItemPropertyTitle: currentChapter?.title ?? episode.title,
            MPMediaItemPropertyArtist: episode.podcast?.title ?? "",
            MPMediaItemPropertyAlbumTitle: episode.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }

        let art = episode.artworkURL ?? episode.podcast?.artworkURL
        if let art, let cached = artworkCache[art] {
            info[MPMediaItemPropertyArtwork] = cached
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // Fetch the artwork once per show, then reuse it. Without this the
        // lock screen and CarPlay-style displays show a blank square.
        if let art, artworkCache[art] == nil, let url = URL(string: art) {
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = UIImage(data: data) else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                await MainActor.run {
                    self?.artworkCache[art] = artwork
                    self?.updateNowPlaying()
                }
            }
        }
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


// MARK: - Haptics

/// A short tap when the player jumps an ad, so a skip registers as something
/// the app did on purpose rather than an audio glitch.
enum Haptics {
    private static let generator = UIImpactFeedbackGenerator(style: .soft)

    static func skip() {
        generator.prepare()
        generator.impactOccurred(intensity: 0.6)
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
