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

    /// What the player is doing, as one value. See `PlaybackPhase` for why a
    /// Boolean could not describe it.
    private(set) var phase: PlaybackPhase = .idle

    /// The question every transport button asks, unchanged for callers.
    ///
    /// Computed from `phase` rather than stored, which is what let the state
    /// machine land without touching a single view: the twenty-two read sites
    /// across the player, the library and the intents all still say
    /// `player.isPlaying`.
    var isPlaying: Bool { phase.isPlaying }

    /// Also computed now, so a failure cannot outlive the state that caused it.
    /// It used to be a separate stored string, which meant an error from one
    /// episode could still be on screen while the next one played.
    var loadError: String? { phase.errorMessage }

    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var lastSkip: (sponsor: String, seconds: Double, segmentStart: Double)?
    private(set) var smartSpeedSavedSeconds: Double = 0

    var playbackRate: Double = 1.0 {
        didSet {
            engine.setRate(playbackRate)
            updateNowPlaying()
        }
    }
    /// Whether this session is skipping ads at all.
    ///
    /// The switch existed but was never consulted: `rebuildJumps` asked the
    /// episode for its skip ranges and used them unconditionally, so turning ad
    /// skipping off in the player changed a toggle and nothing else. Now it
    /// rebuilds, which is what makes "hear the episode as broadcast" possible
    /// without throwing away the detection and running it again.
    var autoSkipEnabled = true {
        didSet {
            guard autoSkipEnabled != oldValue else { return }
            rebuildJumps()
        }
    }

    /// The two engines, and whichever one is currently in charge.
    ///
    /// Both are kept alive rather than created per episode: an AVAudioEngine
    /// graph costs real time to build, and switching between a video and an
    /// audio episode should not rebuild it.
    private let audio = AudioEngine()
    private let video = VideoEngine()
    private var engine: any PlaybackEngine

    /// Handed to the player UI so it can draw the picture. Nil for audio.
    var videoOutput: AVPlayer? { currentEpisode?.isVideo == true ? video.player : nil }

    private var settings = AppSettings()
    private var ticker: Task<Void, Never>?

    /// The in-flight open or download, cancelled whenever a new episode is
    /// asked for — so a slow fetch cannot arrive after you have moved on and
    /// start playing something you are no longer looking at.
    private var loadTask: Task<Void, Never>?

    /// Held so the observers outlive `configureSession`. The player is a
    /// singleton, so these are never torn down in practice — they are kept
    /// rather than discarded so that nothing relies on that staying true.
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
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
    /// Playhead position at the last Now Playing refresh, so the Lock Screen
    /// gets corrected on a slow cadence rather than never or every tick.
    private var lastNowPlayingPush: Double = -.greatestFiniteMagnitude

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
    /// Takes the episode that just finished, so the answer can follow the
    /// show's own sequence rather than whatever happens to be next in a list.
    var queueProvider: (@MainActor (Episode?) -> Episode?)?

    /// Called with the episodes worth getting ready while this one plays, so
    /// autoplay does not stop and transcribe between episodes. Set by the app.
    var preprocessProvider: (@MainActor ([Episode]) -> Void)?

    private init() {
        engine = audio
        configureSession()
        setupRemoteCommands()
        for candidate in [audio as any PlaybackEngine, video as any PlaybackEngine] {
            candidate.onFinished = { [weak self] in
                Task { @MainActor in self?.handleEnd() }
            }
            // Video reports its length only once the item is ready. Until
            // then the feed's figure stands in, so the scrubber has a scale
            // from the first frame rather than a flat empty bar.
            candidate.onDurationResolved = { [weak self] seconds in
                Task { @MainActor in
                    guard let self, self.currentEpisode?.isVideo == true else { return }
                    self.duration = seconds
                }
            }
            // The system can tear the whole audio stack down — a bad route
            // change, a hardware hiccup, mediaserverd restarting. The engine
            // rebuilds its graph and says so here; without this the app goes
            // silent for good and the only cure is relaunching it.
            candidate.onEngineReset = { [weak self] in
                Task { @MainActor in
                    guard let self, self.currentEpisode != nil else { return }
                    let resumeAfter = self.phase == .playing
                    self.phase = .paused
                    if resumeAfter { self.play(from: self.currentTime) }
                }
            }
        }
    }

    func configure(settings: AppSettings) {
        self.settings = settings
        playbackRate = settings.defaultPlaybackSpeed
        autoSkipEnabled = settings.autoSkipEnabled
    }

    // MARK: - Loading

    /// Open an episode and, unless told otherwise, start it.
    ///
    /// Still synchronous to its callers — every play button in the app calls
    /// this — but the expensive part is no longer done on the main actor.
    /// `AVAudioFile(forReading:)` reads and parses the container, and for a
    /// two-hour episode that takes seconds. It was running inline here, which
    /// is the gap between pressing play and hearing anything, with the whole
    /// interface frozen through it.
    ///
    /// The phase goes to `.loading` immediately, so a play button can say so,
    /// and the rest happens when the file is open.
    func load(_ episode: Episode, autoplay: Bool = true) {
        if let previous = currentEpisode, previous !== episode {
            persistProgress(force: true)
            flushSession()
        }
        currentChapter = nil
        smartSpeedSavedSeconds = 0
        phase = .loading
        loadTask?.cancel()

        // Not downloaded yet: fetch it, then play it.
        //
        // This used to fail with "isn't downloaded yet — tap Find ads", which
        // is a dead end dressed as advice. Pressing play means play, and the
        // app downloads everything it processes anyway, so the only honest
        // difference between "stream this" and "play this" here is whether you
        // are made to go and do something else first.
        guard episode.isDownloaded, let url = episode.localFileURL else {
            currentEpisode = episode
            duration = episode.duration
            downloadThenPlay(episode, autoplay: autoplay)
            return
        }

        // Pick the engine before loading, and stop whichever one was running,
        // or a video episode would start over the tail of an audio one.
        let wanted: any PlaybackEngine = episode.isVideo ? video : audio
        if engine !== wanted {
            engine.stop()
            engine = wanted
        }

        // Video opens fast — AVPlayer does its work asynchronously by design —
        // so only the audio path needs moving off the main actor.
        guard !episode.isVideo else {
            do {
                try engine.load(fileURL: url)
            } catch {
                phase = .failed("Couldn't open this episode: \(error.localizedDescription)")
                return
            }
            finishLoading(episode, autoplay: autoplay)
            return
        }

        loadTask = Task { [weak self] in
            let opened: AVAudioFile
            do {
                opened = try await AudioEngine.openFile(at: url)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed("Couldn't open this episode: \(error.localizedDescription)")
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.audio.adopt(opened)
            self.finishLoading(episode, autoplay: autoplay)
        }
    }

    /// Everything after the file is open. Same work as before; it just no
    /// longer happens with the interface waiting on it.
    private func finishLoading(_ episode: Episode, autoplay: Bool) {
        currentEpisode = episode
        duration = engine.duration > 0 ? engine.duration : episode.duration
        rebuildJumps()

        // Per-show speed override beats the global default.
        playbackRate = episode.podcast?.playbackSpeedOverride ?? settings.defaultPlaybackSpeed
        engine.apply(settings: settings, normalizationGain: episode.normalizationGain)
        engine.setRate(playbackRate)

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
            phase = .paused
            updateNowPlaying()
        }
        rememberNowPlaying()

        // Get the next episode or two ready while this one plays, so autoplay
        // does not stop dead and transcribe in the gap between episodes. The
        // work is queued, not done here — see `ProcessingPipeline`.
        if settings.preprocessAhead > 0, let provider = preprocessProvider {
            let upcoming = queuedAhead(from: episode, limit: settings.preprocessAhead)
            if !upcoming.isEmpty { provider(upcoming) }
        }
    }

    /// Fetch the audio, then start it.
    ///
    /// Reported as `.buffering` rather than `.loading`, because that is what it
    /// is — the episode is wanted and nothing is coming out yet — and because
    /// the transport can then show a spinner instead of a play triangle that
    /// looks like it did nothing.
    private func downloadThenPlay(_ episode: Episode, autoplay: Bool) {
        phase = .buffering
        updateNowPlaying()

        loadTask = Task { [weak self] in
            let ok = await DownloadManager.fetchAudio(for: episode)
            guard let self, !Task.isCancelled else { return }
            guard ok, episode.isDownloaded, episode.localFileURL != nil else {
                self.phase = .failed("Couldn't download this episode. Check your connection and try again.")
                return
            }
            // Round again, now that the file is there.
            self.load(episode, autoplay: autoplay)
        }
    }

    /// The episodes autoplay would reach next, resolved through the same rule
    /// autoplay itself uses so the two cannot disagree about what is next.
    private func queuedAhead(from episode: Episode, limit: Int) -> [Episode] {
        var found: [Episode] = []
        var cursor: Episode? = episode
        for _ in 0..<limit {
            guard let current = cursor, let next = queueProvider?(current) else { break }
            guard next.guid != episode.guid,
                  !found.contains(where: { $0.guid == next.guid }) else { break }
            found.append(next)
            cursor = next
        }
        return found
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

        // A restore is something the app does on its own at launch, so a
        // failure here must not put an error on screen for an episode nobody
        // asked for. Fall back to an empty player, which is what the app did
        // before any of this existed.
        if case .failed = phase {
            phase = .idle
            return
        }

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
        // Per kind, and within each kind episode beats show beats default.
        // One switch for everything meant a listener who wanted their show's
        // tour dates had to keep the mattress ad too.
        //
        // The session switch is checked here and nowhere else. Turning ad
        // skipping off in the player empties the jump list rather than deleting
        // anything, so the detection survives and switching it back on is
        // instant — no reprocessing, no second transcription.
        adRanges = autoSkipEnabled ? episode.skipRanges(settings: settings) : []

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
        engine.apply(settings: settings, normalizationGain: episode.normalizationGain)
        engine.setRate(playbackRate)
        rebuildJumps()
    }

    // MARK: - Transport

    func play(from seconds: Double? = nil) {
        guard currentEpisode != nil else { return }

        // The guard here used to be `engine.isRunning`, and that one word was
        // half the resume bug. `isRunning` is the engine's own belief about
        // itself, and after the system stopped it out from under us — a call,
        // another app, AirPods leaving an ear — that belief was stale and still
        // `true`. A tap on play hit this line and returned: nothing started,
        // nothing failed, nothing logged. Asking our own phase instead means
        // the only thing that suppresses a play is already playing.
        if seconds == nil, phase == .playing { return }

        // Reactivating is cheap when the session is already active, and is the
        // required step when it is not — after an interruption the session has
        // been deactivated and an engine will start on a dead session without
        // making a sound.
        try? AVAudioSession.sharedInstance().setActive(true)

        do {
            if let seconds {
                try engine.play(from: seconds)
                currentTime = seconds
            } else {
                // Resume rather than re-seek. The old code went through the
                // seek path for every resume, which rebuilds the schedule and
                // therefore depends on the position having been measured
                // correctly at the moment of pausing. It had not been: the
                // audio engine reported the start of the current segment while
                // paused, so a resume after an ad skip could jump minutes
                // backwards. Resuming touches the position at all.
                //
                // If the graph has been disturbed too badly to resume — the
                // session was handed to another app and back, the node lost its
                // schedule — fall back to a seek at the position we know. That
                // costs a reschedule but never leaves a player that says it is
                // playing over silence.
                do {
                    try engine.resume()
                } catch {
                    try engine.play(from: currentTime)
                }
            }
            phase = .playing
            if sessionStart == nil { sessionStart = .now }
            lastTickTime = currentTime
            startTicking()
            updateNowPlaying()
        } catch {
            phase = .failed(error.localizedDescription)
            ticker?.cancel()
            updateNowPlaying()
        }
    }

    func pause() {
        engine.pause()
        phase = .paused
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
        let now = engine.currentTime

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

        // Re-publish the elapsed time on a slow cadence.
        //
        // iOS animates the Lock Screen scrubber between updates from the rate,
        // so it does not need this every frame — but it does need correcting
        // periodically, and without any correction at all the bar drifts away
        // from the audio over a long episode and never comes back.
        if now - lastNowPlayingPush >= 5 || now < lastNowPlayingPush {
            lastNowPlayingPush = now
            updateNowPlaying()
        }

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

        // Advertisement, self-promotion, another show, an intro or an outro —
        // whichever kinds this listener has switched on.
        if let range = adRanges.first(where: { $0.contains(now) }) {
            // Land *past* the end, not on it.
            //
            // These are closed ranges, so `range.contains(range.upperBound)`
            // is true: seeking to the end of an ad put the playhead on a
            // point that is still inside the ad. The next tick, a twentieth
            // of a second later, found it there again, buzzed, and seeked to
            // the same place — five haptics a second, forever, until you
            // paused or pressed forward. Reported as "it doesn't stop
            // vibrating", and that is exactly what it was.
            let target = Swift.min(duration, range.upperBound + 0.05)
            let jumped = target - now

            // Already at the far edge — arrived by scrubbing, or by the jump
            // above landing a hair short. Step out quietly: there is nothing
            // to announce and nothing was saved.
            guard jumped > 0.3 else {
                seek(to: target)
                return
            }

            let hit = currentEpisode?.adSegments.first { $0.start <= now && $0.end >= now }
            // Falls back to the kind's own name, so a skip with no brand
            // attached still says what it was rather than nothing.
            let sponsor = (hit?.sponsor.isEmpty == false ? hit?.sponsor : hit?.kind.label) ?? ""
            sessionAdSeconds += jumped
            lastSkip = (sponsor, jumped, range.lowerBound)
            Haptics.skip()
            seek(to: target)
            return
        }

        // Smart Speed
        if let gap = silenceJumps.first(where: { $0.contains(now) }) {
            // Past the end for the same reason as above: a closed range
            // contains its own upper bound, so landing on it means arriving
            // back inside the gap you were leaving. No haptic here, so this
            // one never announced itself — it just quietly seeked to the same
            // spot several times a second and the episode stopped advancing.
            let target = Swift.min(duration, gap.upperBound + 0.05)
            let saved = target - now
            guard saved > 0.3 else {
                seek(to: target)
                return
            }
            smartSpeedSavedSeconds += saved
            sessionSilenceSeconds += saved
            seek(to: target)
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
            engine.stop()
            phase = .stopped
            ticker?.cancel()
            updateNowPlaying()
            if markPlayed { tidyFinished(finished) }
            return
        }

        guard settings.continuousPlayback || force, let next = queueProvider?(finished) else {
            engine.stop()
            phase = .stopped
            ticker?.cancel()
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
        observeSessionNotifications()
    }

    /// Listen for the system taking the audio away, and for outputs appearing
    /// and disappearing.
    ///
    /// Neither of these existed. `AVAudioSession` was configured once and never
    /// heard from again, which is why the app could be sitting in silence while
    /// every part of it still believed it was playing.
    ///
    /// The notification payloads are read here, off the main actor, and only
    /// plain values cross onto it — a `Notification` and an
    /// `AVAudioSessionRouteDescription` are not `Sendable`, so the decisions
    /// that need them are made before the hop.
    private func observeSessionNotifications() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt
            else { return }

            // The option is only present on `.ended`, and its absence means
            // "do not resume" rather than "unknown".
            var shouldResume = false
            if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    .contains(.shouldResume)
            }

            let player = self
            Task { @MainActor in
                player?.handleInterruption(typeValue: typeValue, shouldResume: shouldResume)
            }
        }

        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
            else { return }

            guard reason == .oldDeviceUnavailable else { return }

            // Decide here, while the route description is in hand.
            var lostPrivateOutput = false
            if let previous = info[AVAudioSessionRouteChangePreviousRouteKey]
                as? AVAudioSessionRouteDescription {
                lostPrivateOutput = Self.isPrivateListening(previous)
            }

            let player = self
            Task { @MainActor in
                player?.handleOutputDisappeared(wasPrivate: lostPrivateOutput)
            }
        }
    }

    /// Was the audio going somewhere only the listener could hear?
    ///
    /// Apple's own sample checks for wired headphones alone, which would miss
    /// the case that actually matters here: AirPods report as Bluetooth, not as
    /// headphones. Anything that is not the phone's own speaker or earpiece
    /// counts — headphones, any flavour of Bluetooth, USB, AirPlay, a car.
    /// `nonisolated` because it is called from the notification block, which
    /// runs off the main actor — the whole point of deciding here is to avoid
    /// carrying a non-`Sendable` route description across the hop.
    nonisolated private static func isPrivateListening(_ route: AVAudioSessionRouteDescription) -> Bool {
        let speakers: Set<AVAudioSession.Port> = [.builtInSpeaker, .builtInReceiver]
        return route.outputs.contains { !speakers.contains($0.portType) }
    }

    /// A call arrived, another app took the session, or Siri spoke.
    private func handleInterruption(typeValue: UInt, shouldResume: Bool) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // The audio is already gone; this only brings our bookkeeping in
            // line with it. `engine.pause()` matters as much as the phase does,
            // because the engine's own `isRunning` was the stale flag that made
            // the later play a no-op.
            let wasPlaying = phase == .playing
            engine.pause()
            ticker?.cancel()
            if wasPlaying { persistProgress(force: true) }
            phase = .interrupted(resumeWhenPossible: wasPlaying)
            updateNowPlaying()

        case .ended:
            guard case .interrupted(let resumeWhenPossible) = phase else { return }
            // Resume only when the system says it is fine *and* this app was
            // the thing playing when it was cut off. Either one alone would
            // start an episode in someone's pocket.
            guard shouldResume, resumeWhenPossible else {
                phase = .paused
                updateNowPlaying()
                return
            }
            play(from: currentTime)

        @unknown default:
            break
        }
    }

    /// Headphones out, AirPods disconnected, car left, AirPlay dropped.
    ///
    /// Plugging something in should never stop an episode; unplugging it should
    /// always stop one. Someone who pulls their headphones out has not asked to
    /// broadcast their podcast to the room.
    private func handleOutputDisappeared(wasPrivate: Bool) {
        guard wasPrivate, phase == .playing else { return }
        pause()
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        // These still answer `.success` before the work has happened — the
        // handler is synchronous and the player is main-actor isolated, so
        // there is nothing to report yet at the moment of returning. That was
        // survivable noise before and is harmless now; what made it dangerous
        // was `play()` silently doing nothing behind the `.success`, which is
        // fixed at the source rather than papered over here.
        center.playCommand.addTarget { [weak self] _ in
            let player = self
            Task { @MainActor in player?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            let player = self
            Task { @MainActor in player?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            let player = self
            Task { @MainActor in player?.togglePlayPause() }
            return .success
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
            // Derived from the phase, so the Lock Screen and Control Center can
            // no longer disagree with the audio. This line used to read the
            // stale `isPlaying` flag.
            MPNowPlayingInfoPropertyPlaybackRate: phase.nowPlayingRate(at: playbackRate),
            // The other half of why the Lock Screen scrubber sat still under a
            // pause button. iOS animates the scrubber itself between updates by
            // comparing the current rate to the *default* rate, and with no
            // default declared it assumes 1.0 — so an episode at 1.5x looked
            // like fast-forwarding rather than playing, and the system stopped
            // advancing the bar. Declaring both makes 1.5x simply mean playing.
            MPNowPlayingInfoPropertyDefaultPlaybackRate: playbackRate,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyMediaType: (episode.isVideo
                ? MPNowPlayingInfoMediaType.video
                : MPNowPlayingInfoMediaType.audio).rawValue
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

    /// The light tick when a control takes hold — picking up the scrubber,
    /// landing on a speed. Lighter than `skip`, which announces something the
    /// app did on its own.
    static func select() {
        generator.prepare()
        generator.impactOccurred(intensity: 0.35)
    }
}
