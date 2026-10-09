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
    private(set) var lastSkip: (sponsor: String, seconds: Double, segmentStart: Double, segmentEnd: Double, at: Date)?
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
    /// An episode not downloaded yet, played from the web while it downloads.
    private let stream = StreamEngine()
    private var engine: any PlaybackEngine

    /// Playing from the web while the download finishes (task 07). The
    /// equaliser and repairs can't reach a stream; see `StreamEngine`.
    var isStreaming: Bool { engine === stream && currentEpisode != nil }
    /// This copy is a different length from the one the ads were found in,
    /// so the saved cuts would land in the wrong places: nothing is skipped
    /// until the download is in.
    private(set) var streamCutsDiffer = false
    /// The download running behind a stream. Kept apart from `loadTask`,
    /// which every new load cancels.
    @ObservationIgnored private var streamDownload: Task<Void, Never>?
    @ObservationIgnored private var streamDownloadGuid: String?

    /// The picture for a video episode — see `VideoSync`. The sound is
    /// always the audio engine's, so every audio setting applies to video.
    let videoSync = VideoSync()

    /// Whether the loaded episode has a picture to offer.
    var hasVideo: Bool {
        guard let episode = currentEpisode else { return false }
        return episode.isVideo || episode.pictureURL != nil
    }

    /// Handed to the player UI so it can draw the picture. Nil for audio, and
    /// nil when Audio is chosen.
    var videoOutput: AVPlayer? {
        hasVideo && prefersVideo && videoSync.sourceURL != nil ? videoSync.player : nil
    }

    /// The picture's player whenever one is loaded, Video chosen or not. The
    /// player screen keeps its layer in place under the cover while Audio is
    /// chosen, so switching back shows a frame at once instead of building
    /// a new layer and waiting for it.
    var loadedVideoPlayer: AVPlayer? {
        hasVideo && videoSync.sourceURL != nil ? videoSync.player : nil
    }

    /// Whether this episode should open in video: the show's own choice,
    /// else the app's "Always start in video".
    private func startsInVideo(_ episode: Episode) -> Bool {
        episode.podcast?.startInVideoOverride ?? settings.alwaysStartInVideo
    }

    /// The episode whose sound is open. The picture is lined up against the
    /// sound's length, so nothing is attached before this is set.
    private var loadedGuid: String?

    /// Video or audio only, for video episodes. Remembered between episodes,
    /// as Apple Podcasts does.
    var prefersVideo: Bool = UserDefaults.standard.object(forKey: "prefersVideo") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(prefersVideo, forKey: "prefersVideo")
            if !prefersVideo { cancelVideoAlignment() }
            attachVideoIfWanted()
            applyVideoVisibility()
        }
    }

    /// Picture in Picture running, so leaving the app keeps the picture.
    var pictureInPictureActive = false {
        didSet { applyVideoVisibility() }
    }

    /// The picture follows the sound only while someone can see it: the app
    /// on screen with Video chosen, or Picture in Picture. Otherwise it is
    /// paused and nothing is decoded; the sound is unaffected either way.
    func applyVideoVisibility() {
        let visible = hasVideo && prefersVideo && (!isInBackground || pictureInPictureActive)
        if visible || !isInBackground {
            videoSync.setActive(visible)
            return
        }
        // Leaving the app: Picture in Picture starts itself a moment after,
        // and it needs a moving picture to start from. Decide once it has
        // had the chance.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.isInBackground, !self.pictureInPictureActive else { return }
            self.videoSync.setActive(false)
        }
    }

    /// Load the picture for the current episode: the episode's own file for
    /// a video episode, or the feed's separate video version for an audio
    /// one.
    ///
    /// Also with Audio chosen, while the app is on screen (task 06: the lag
    /// when tapping the cover). The item is then loaded and parked near the
    /// sound's position, paused, with a small buffer, so switching to Video
    /// is a short seek rather than a cold start. In the background with
    /// Audio chosen nothing is loaded.
    private func attachVideoIfWanted() {
        if !prefersVideo { videoSync.setActive(false) }
        guard let episode = currentEpisode, loadedGuid == episode.guid,
              prefersVideo || !isInBackground else { return }
        if DemoData.isEnabled, episode.guid.hasPrefix("demo-"), episode.isVideo,
           ProcessInfo.processInfo.arguments.contains("-VideoFailureDemo") {
            videoSync.attach(URL.temporaryDirectory.appending(path: "missing-demo-video.mp4"), expectedDuration: duration)
        } else if DemoData.isEnabled, episode.guid.hasPrefix("demo-"), episode.isVideo,
                  let failure = DemoData.videoFixtureError {
            videoSync.unavailable(failure)
        } else if DemoData.isEnabled, episode.guid.hasPrefix("demo-"), episode.isVideo,
           let local = episode.localFileURL, FileManager.default.fileExists(atPath: local.path) {
            // Only the generated screenshot fixture uses a local picture.
            videoSync.attach(local, expectedDuration: duration)
        } else if episode.isVideo, let remote = URL(string: episode.audioURL) {
            // Video is streamed, never kept: the picture comes from the feed.
            videoSync.attach(remote, expectedDuration: duration)
        } else if let remote = episode.pictureURL, let url = URL(string: remote) {
            if needsInsertedSpansForVideo(episode) {
                lineUpVideo(episode, url: url)
            } else {
                videoSync.attach(url, expectedDuration: duration)
            }
        }
    }

    func retryVideo() {
        videoSync.detach()
        attachVideoIfWanted()
        applyVideoVisibility()
    }

    /// A host's video stream is the clean episode; the download has ads
    /// stitched in. When nothing has measured those yet, the picture can't
    /// be kept in step, so measure them first (the ad-free comparison: ~100
    /// small range requests, no model) and attach once they are known.
    ///
    /// Stavvy's World #200 (4 Oct): the stricter comparison keeps pre- and
    /// post-rolls out of `insertedSpans`, so those alone no longer add up to
    /// the difference and the picture was refused. Alignment now keeps its own
    /// spans (`videoAlignmentData`), ends included, and is measured whenever a
    /// host stream has none yet — not only when Apple's catalog gave a length.
    private func needsInsertedSpansForVideo(_ episode: Episode) -> Bool {
        episode.videoAlignmentData == nil && episode.analysableFileURL != nil
    }

    @ObservationIgnored private var liningUp: String?
    @ObservationIgnored private var alignmentTask: Task<Void, Never>?
    @ObservationIgnored private var alignmentID = UUID()

    private func cancelVideoAlignment() {
        alignmentID = UUID()
        alignmentTask?.cancel()
        alignmentTask = nil
        liningUp = nil
    }

    private func lineUpVideo(_ episode: Episode, url: URL) {
        guard liningUp != episode.guid, let file = episode.analysableFileURL else { return }
        cancelVideoAlignment()
        let token = alignmentID, revision = loadRevision
        liningUp = episode.guid
        let enclosure = episode.audioURL, feed = episode.podcast?.feedURL ?? ""
        let show = episode.podcast?.title ?? "", title = episode.title
        // No heavy-work lease: this is ~100 small range requests and one read
        // of the file. Waiting behind a Find Ads job (Build 303) left the
        // picture missing for as long as the job ran.
        alignmentTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.alignmentID == token {
                    self.liningUp = nil
                    self.alignmentTask = nil
                }
            }
            let outcome = await Task.detached(priority: .userInitiated) {
                await AdFreeCopy.compare(fileURL: file, enclosure: enclosure, feedURL: feed,
                                         showTitle: show, episodeTitle: title)
            }.value
            guard let self, !Task.isCancelled, self.alignmentID == token,
                  self.loadRevision == revision, self.currentEpisode === episode else { return }
            if !outcome.inserted.isEmpty {
                episode.insertedSpansData = try? JSONEncoder().encode(outcome.inserted)
                episode.insertedSpansPolicyVersion = outcome.policyVersion
            }
            if outcome.isDefinitiveForVideo {
                episode.videoAlignmentData = try? JSONEncoder().encode(outcome.alignmentSpans)
            }
            BackgroundLog.shared.note("Video lined up for \"\(title)\": \(outcome.alignmentSpans.count) stretch(es) the clean copy lacks"
                                      + (outcome.note.isEmpty ? "" : " · " + outcome.note))
            guard self.prefersVideo else { return }
            self.videoSync.attach(url, expectedDuration: self.duration)
        }
    }

    /// UI tests only (`-SimulateRoutePause`): once the picture has been
    /// playing a while, pause the video player behind the app's back, as iOS
    /// does when AirPods are taken out or put back. The sound must carry on.
    /// This is the regression test for the AirPods bug of pass 13–14.
    func simulateSystemVideoPauseIfAsked() {
        guard DemoData.isEnabled, ProcessInfo.processInfo.arguments.contains("-SimulateRoutePause") else { return }
        Task { @MainActor [weak self] in
            var playingFor = 0
            for _ in 0..<180 {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                playingFor = self.videoSync.player.rate > 0 ? playingFor + 1 : 0
                if playingFor >= 5 {
                    self.videoSync.player.pause()
                    return
                }
            }
        }
    }

    /// No picture in the feed: look elsewhere once (see
    /// `VideoSourceResolver`), and attach it if one turns up while this
    /// episode is still the one loaded.
    ///
    /// Started when the episode is chosen, before its download, so the
    /// lookup is done by the time anyone taps the cover. What it finds is
    /// kept on the episode (see `VideoSourceResolver`).
    private func resolveVideoIfNeeded(_ episode: Episode) {
        guard !episode.isVideo, episode.pictureURL == nil,
              resolving != episode.guid,
              !ProcessInfo.processInfo.arguments.contains("-UITestScreenshots") else { return }
        resolving = episode.guid
        let started = Date.now
        let lookedBefore = episode.videoResolvedAt
        Task { @MainActor [weak self] in
            let found = await VideoSourceResolver.resolve(episode)
            self?.resolving = nil
            if episode.videoResolvedAt != lookedBefore {
                let source = VideoSourceResolver.Source(rawValue: episode.videoSourceRaw)
                let what = found ? (source?.label ?? "found") : (source == .youtube ? "only on YouTube" : "none found")
                BackgroundLog.shared.note("Video source for \"\(episode.title)\": \(what), looked for \(Self.seconds(since: started)) s")
            }
            guard found, let self, self.currentEpisode === episode else { return }
            if self.startsInVideo(episode) { self.prefersVideo = true }
            self.attachVideoIfWanted()
            self.applyVideoVisibility()
        }
    }

    private var resolving: String?

    /// "0.8", for the background log's timings.
    static func seconds(since start: Date) -> String {
        String(format: "%.1f", Date.now.timeIntervalSince(start))
    }

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
    // Sorted by start, so the tick can binary-search them.
    private var adRanges: [ClosedRange<Double>] = []
    /// What is being skipped now, for a shared clip to leave out the same.
    var skippedRanges: [ClosedRange<Double>] { adRanges }
    private var silenceJumps: [ClosedRange<Double>] = []
    /// The episode's chapters in order, and the show's outro trim, read from
    /// the store once per episode rather than five times a second.
    private var sortedChapters: [Chapter] = []
    private var outroTrim: Double = 0

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
    private var lastModelPersistAt: Date = .distantPast
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

    /// The next `limit` episodes autoplay would reach. Set by the app.
    var upcomingProvider: (@MainActor (Episode?, Int) -> [Episode])?

    /// How autoplay starts the next episode, so an unprocessed one can be
    /// asked about. Falls back to loading it directly. Set by the app.
    var autoplayRouter: (@MainActor (Episode) -> Void)?

    private func wireVideo() {
        videoSync.soundTime = { [weak self] in
            guard let self else { return 0 }
            return self.isPlaying ? self.engine.currentTime : self.currentTime
        }
        videoSync.soundRate = { [weak self] in self?.playbackRate ?? 1 }
        videoSync.soundPlaying = { [weak self] in self?.isPlaying ?? false }
        // Only the audio engine's sound is delayed on its way out without
        // anyone allowing for it; `AVPlayer`-based playback already reports
        // the time being heard.
        videoSync.soundLatency = { [weak self] in
            guard let self, self.engine === self.audio else { return 0 }
            return self.audio.outputLatency
        }
        audio.onLatencyChanged = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let name = self.audio.outputRouteName.isEmpty ? "unknown" : self.audio.outputRouteName
                BackgroundLog.shared.note("Sound output: \(name), delay \(Int((self.audio.outputLatency * 1000).rounded())) ms")
                self.videoSync.outputChanged()
            }
        }
        audio.onConfigurationChanged = { [weak self] in
            Task { @MainActor in self?.handleEngineConfigurationChange() }
        }
        videoSync.insertedAdCandidates = { [weak self] in self?.currentEpisode?.videoGapCandidates ?? [] }
        videoSync.externalControlsActive = { [weak self] in self?.pictureInPictureActive ?? false }
        videoSync.mayPreload = { [weak self] in !(self?.isInBackground ?? true) }
        videoSync.log = { BackgroundLog.shared.note($0) }
        videoSync.onExternalPlayPause = { [weak self] playing in
            guard let self else { return }
            if playing, !self.isPlaying { self.play() }
            if !playing, self.isPlaying { self.pause() }
        }
    }

    private init() {
        engine = audio
        configureSession()
        setupRemoteCommands()
        wireVideo()
        // The Lock Screen card's buttons.
        NowPlayingControl.toggle = { [weak self] in self?.togglePlayPause() }
        NowPlayingControl.skipBack = { [weak self] in self?.skipBackward() }
        NowPlayingControl.skipForward = { [weak self] in self?.skipForward() }
        for candidate in [audio as any PlaybackEngine, video as any PlaybackEngine, stream as any PlaybackEngine] {
            candidate.onFinished = { [weak self] in
                Task { @MainActor in self?.handleEnd() }
            }
            // Video reports its length only once the item is ready. Until
            // then the feed's figure stands in, so the scrubber has a scale
            // from the first frame rather than a flat empty bar.
            candidate.onDurationResolved = { [weak self] seconds in
                Task { @MainActor in
                    guard let self, self.currentEpisode?.isVideo == true || self.isStreaming else { return }
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
    /// Whether the episode now loaded was in Up Next when it started. Autoplay
    /// continues through Up Next if so, and through the show's own order if
    /// not. Finishing an episode takes it out of Up Next, so this is kept
    /// rather than read at the end.
    private(set) var startedFromQueue = true

    @ObservationIgnored private(set) var loadRevision = UUID()

    func load(_ episode: Episode, autoplay: Bool = true, startingAt: TimeInterval? = nil) {
        loadRevision = UUID()
        cancelVideoAlignment()
        startedFromQueue = episode.isInQueue
        if let previous = currentEpisode, previous !== episode {
            persistProgress(force: true)
            flushSession()
        }
        currentChapter = nil
        smartSpeedSavedSeconds = 0
        jumpOrigin = nil
        replayRange = nil
        if currentEpisode !== episode { lastSkip = nil }
        streamCutsDiffer = false
        // For the Library's Recently Played. Set when listening starts, not
        // only when an episode is finished.
        if autoplay {
            episode.lastPlayedAt = .now
            if episode.isNew {
                episode.isNew = false
                CountsCache.invalidate(episode.podcast)   // the badge drops as soon as it starts
            }
        }
        phase = .loading
        loadTask?.cancel()

        // A different episode: the last one's picture goes now, not once
        // this one's download ends, and its source is looked up meanwhile.
        if currentEpisode?.guid != episode.guid {
            videoSync.detach()
            loadedGuid = nil
        }
        resolveVideoIfNeeded(episode)

        // Not downloaded yet: fetch it, then play it.
        //
        // This used to fail with "isn't downloaded yet — tap Find ads", which
        // is a dead end dressed as advice. Pressing play means play, and the
        // app downloads everything it processes anyway, so the only honest
        // difference between "stream this" and "play this" here is whether you
        // are made to go and do something else first.
        //
        // Task 07: it no longer waits for the whole file. An audio episode
        // starts from the web at once and moves to the download when it
        // lands (`streamThenSwitch`). Video episodes still download first:
        // their picture comes from the file.
        guard let url = episode.analysableFileURL else {
            currentEpisode = episode
            duration = episode.duration
            if let remote = URL(string: episode.audioURL),
               remote.scheme == "https" || remote.scheme == "http" {
                streamThenSwitch(episode, from: remote, autoplay: autoplay, startingAt: startingAt)
            } else {
                downloadThenPlay(episode, autoplay: autoplay, startingAt: startingAt)
            }
            return
        }

        // A video episode's sound is its own audio track, played by the audio
        // engine like any other episode — so Smart Speed, Voice Boost, the
        // equaliser and normalisation all apply — with the picture following
        // it (`VideoSync`). The track is copied out of the video once; the
        // same copy is what ad detection reads.
        var soundURL = url
        if episode.isVideo {
            if let extracted = episode.extractedAudioFilename,
               FileIndex.contains(extracted) {
                soundURL = FileStore.episodesDirectory.appendingPathComponent(extracted)
            } else {
                extractThenLoad(episode, from: url, autoplay: autoplay, startingAt: startingAt)
                return
            }
        }

        if engine !== audio {
            engine.stop()
            engine = audio
        }

        loadTask = Task { [weak self] in
            let opened: AVAudioFile
            do {
                opened = try await AudioEngine.openFile(at: soundURL)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed("Couldn't open this episode: \(error.localizedDescription)")
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.audio.adopt(opened)
            self.finishLoading(episode, autoplay: autoplay, startingAt: startingAt)
        }
    }

    /// Copy a video's audio track out, then load. Should that fail, the video
    /// plays through `AVPlayer` as it used to — picture and sound, without
    /// the audio engine's settings — rather than not at all.
    private func extractThenLoad(_ episode: Episode, from url: URL, autoplay: Bool, startingAt: TimeInterval?) {
        currentEpisode = episode
        duration = episode.duration
        phase = .loading
        loadTask = Task { [weak self] in
            let name = MediaExtractor.audioFilename(for: url.lastPathComponent)
            do {
                let saved = try await MediaExtractor.extractAudio(from: url, named: name)
                guard let self, !Task.isCancelled else { return }
                episode.extractedAudioFilename = saved
                self.load(episode, autoplay: autoplay, startingAt: startingAt)
            } catch {
                guard let self, !Task.isCancelled else { return }
                if self.engine !== self.video {
                    self.engine.stop()
                    self.engine = self.video
                }
                do {
                    try self.engine.load(fileURL: url)
                    self.finishLoading(episode, autoplay: autoplay, startingAt: startingAt)
                } catch {
                    self.phase = .failed("Couldn't open this episode: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Everything after the file is open. Same work as before; it just no
    /// longer happens with the interface waiting on it.
    private func finishLoading(_ episode: Episode, autoplay: Bool, startingAt: TimeInterval?) {
        currentEpisode = episode
        duration = engine.duration > 0 ? engine.duration : episode.duration
        if engine === audio { noteFileLength(duration, of: episode) }
        rebuildJumps()

        // Per-show speed override beats the global default.
        playbackRate = episode.podcast?.playbackSpeedOverride ?? settings.defaultPlaybackSpeed
        engine.apply(settings: settings,
                     sound: settings.sound(for: episode.podcast, normalizationGain: episode.normalizationGain))
        engine.setRate(playbackRate)

        let start = PlaybackStart.resolve(requested: startingAt, saved: episode.playbackPosition,
                                          duration: duration, intro: episode.podcast?.skipIntroSeconds ?? 0)

        if autoplay {
            play(from: start)
        } else {
            currentTime = start
            lastTickTime = start
            seekedWhilePaused = true
            phase = .paused
            updateNowPlaying()
        }
        rememberNowPlaying()
        episode.prewarmTranscript()
        loadedGuid = episode.guid
        if hasVideo, startsInVideo(episode), !prefersVideo { prefersVideo = true }
        attachVideoIfWanted()
        simulateSystemVideoPauseIfAsked()
        applyVideoVisibility()

        // Get the next episode or two ready while this one plays, so autoplay
        // does not stop dead and transcribe in the gap between episodes. The
        // work is queued, not done here — see `ProcessingPipeline`.
        if settings.preprocessAhead > 0, let provider = preprocessProvider {
            let upcoming = upcomingProvider?(episode, settings.preprocessAhead)
                ?? queuedAhead(from: episode, limit: settings.preprocessAhead)
            if !upcoming.isEmpty { provider(upcoming) }
        }
    }

    // MARK: - Streaming (task 07)

    /// Play from the web now; download behind it; move to the download when
    /// it lands.
    ///
    /// The length is read first (one small request), so the scrubber, the
    /// saved position and ad skipping all have a scale before a sound plays.
    /// If it can't be read, this is the old path: download, then play.
    private func streamThenSwitch(_ episode: Episode, from url: URL, autoplay: Bool, startingAt: TimeInterval?) {
        phase = .buffering
        updateNowPlaying()
        if engine !== stream {
            engine.stop()
            engine = stream
        }
        do {
            try stream.load(fileURL: url)
        } catch {
            downloadThenPlay(episode, autoplay: autoplay, startingAt: startingAt)
            return
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            let length = await self.stream.loadDuration()
            guard !Task.isCancelled, self.currentEpisode === episode else { return }
            guard length > 0 else {
                self.stream.stop()
                self.engine = self.audio
                self.downloadThenPlay(episode, autoplay: autoplay, startingAt: startingAt)
                return
            }
            // The ads were found in a copy on the phone that has since been
            // deleted. A host that stitches ads in per download can send a
            // copy of a different length now, and then every cut is in the
            // wrong place. Unknown length: the cuts are trusted.
            let found = episode.audioFileLength
            self.streamCutsDiffer = found > 0 && !episode.adSegments.isEmpty && abs(found - length) > 2
            self.finishLoading(episode, autoplay: autoplay, startingAt: startingAt)
            self.downloadBehindStream(episode)
        }
    }

    /// The length of the copy on the phone, which a later stream is checked
    /// against. Kept once ads have been found, since it is then the length
    /// of the copy they were found in; before that, whatever is here now is
    /// what they will be found in.
    private func noteFileLength(_ length: Double, of episode: Episode) {
        guard length > 0, episode.audioFileLength == 0 || episode.adSegments.isEmpty,
              abs(episode.audioFileLength - length) > 0.5 else { return }
        episode.audioFileLength = length
    }

    /// One at a time. Starting the same episode again keeps its download
    /// going; moving to another episode stops the last one's, so skipping
    /// through a show doesn't download every episode touched.
    private func downloadBehindStream(_ episode: Episode) {
        guard streamDownloadGuid != episode.guid || streamDownload == nil else { return }
        streamDownload?.cancel()
        streamDownloadGuid = episode.guid
        streamDownload = Task { [weak self] in
            let ok = await DownloadManager.fetchAudio(for: episode)
            guard let self else { return }
            if self.streamDownloadGuid == episode.guid {
                self.streamDownload = nil
                self.streamDownloadGuid = nil
            }
            guard ok, !Task.isCancelled, let file = episode.localFileURL else { return }
            await self.switchToDownloaded(episode, file: file)
        }
    }

    /// From the stream to the downloaded file, at the same moment.
    ///
    /// The file is opened first, off the main thread; only then does the
    /// sound move. The file starts at the stream's position before the
    /// stream stops, so the two overlap by a few milliseconds rather than
    /// leaving a gap.
    private func switchToDownloaded(_ episode: Episode, file: URL) async {
        guard currentEpisode === episode, engine === stream else { return }
        let opened: AVAudioFile
        do {
            opened = try await AudioEngine.openFile(at: file)
        } catch {
            return  // Keep streaming; the next play of it uses the file.
        }
        guard currentEpisode === episode, engine === stream else { return }
        switch phase {
        case .playing, .paused, .buffering: break
        default: return
        }
        let wasPlaying = isPlaying
        // Paused, a seek only moved our own number (see `seek`), so that is
        // the position; playing, the stream's own clock is.
        let at = wasPlaying ? stream.currentTime : currentTime
        audio.adopt(opened)
        let outgoing = stream
        engine = audio
        streamCutsDiffer = false
        engine.apply(settings: settings,
                     sound: settings.sound(for: episode.podcast, normalizationGain: episode.normalizationGain))
        engine.setRate(playbackRate)
        if audio.duration > 0 {
            duration = audio.duration
            noteFileLength(audio.duration, of: episode)
        }
        rebuildJumps()
        if wasPlaying {
            play(from: at)
        } else {
            currentTime = at
            lastTickTime = at
            seekedWhilePaused = true
        }
        outgoing.stop()
        updateNowPlaying()
    }

    /// Fetch the audio, then start it.
    ///
    /// Reported as `.buffering` rather than `.loading`, because that is what it
    /// is — the episode is wanted and nothing is coming out yet — and because
    /// the transport can then show a spinner instead of a play triangle that
    /// looks like it did nothing.
    private func downloadThenPlay(_ episode: Episode, autoplay: Bool, startingAt: TimeInterval?) {
        phase = .buffering
        updateNowPlaying()

        loadTask = Task { [weak self] in
            let ok = await DownloadManager.fetchAudio(for: episode)
            guard let self, !Task.isCancelled else { return }
            guard ok, episode.analysableFileURL != nil else {
                self.phase = .failed("Couldn't download this episode. Check your connection and try again.")
                return
            }
            // Round again, now that the file is there.
            self.load(episode, autoplay: autoplay, startingAt: startingAt)
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
            adRanges = []; silenceJumps = []; sortedChapters = []; currentChapter = nil; outroTrim = 0; return
        }
        sortedChapters = episode.chapters.sorted { $0.start < $1.start }
        currentChapter = sortedChapters.last { $0.start <= currentTime }
        outroTrim = episode.podcast?.skipOutroSeconds ?? 0
        // Per kind, and within each kind episode beats show beats default.
        // One switch for everything meant a listener who wanted their show's
        // tour dates had to keep the mattress ad too.
        //
        // The session switch is checked here and nowhere else. Turning ad
        // skipping off in the player empties the jump list rather than deleting
        // anything, so the detection survives and switching it back on is
        // instant — no reprocessing, no second transcription.
        let cutsFit = !(isStreaming && streamCutsDiffer)
        adRanges = (autoSkipEnabled && cutsFit ? episode.skipRanges(settings: settings) : [])
            .sorted { $0.lowerBound < $1.lowerBound }

        // Pass 33: the show's own Smart Speed when it has one. Show Settings
        // has saved a per-show Smart Speed for a long time, but the player
        // only ever read the app default, so it did nothing.
        let smart = settings.smartSpeed(for: episode.podcast)
        if smart.on {
            silenceJumps = AudioAnalyzer.smartSpeedJumps(
                from: episode.silenceRanges,
                aggressiveness: smart.amount
            ).sorted { $0.lowerBound < $1.lowerBound }
        } else {
            silenceJumps = []
        }
    }

    func refreshSkipRanges() {
        rebuildJumps()
        // Ads found since the video was turned away: it may line up now.
        if hasVideo, videoSync.problem != nil, videoSync.sourceURL == nil {
            attachVideoIfWanted()
            applyVideoVisibility()
        }
    }

    // MARK: - Previewing a cut

    /// The stretch currently being previewed, if any.
    ///
    /// Set only by `startPreview`. Read by the tick loop, which treats it as an
    /// instruction to skip nothing at all until the playhead leaves it.
    private(set) var previewRange: ClosedRange<Double>?
    private var previewSkipsCuts = false

    /// Where the listener was before the preview started, so they can be put
    /// back rather than abandoned inside an ad.
    private var resumeAfterPreview: (time: Double, wasPlaying: Bool)?

    /// Plays one stretch of the episode with every skip suspended.
    ///
    /// Restarting a preview that is already running just moves it, which is
    /// what tapping a different segment in the list should do.
    ///
    /// `skippingCuts` keeps the ad cuts skipped inside the stretch: a clip
    /// being shared (task 07) is previewed as it will sound, without them.
    func startPreview(_ range: ClosedRange<Double>, of episode: Episode, from time: Double? = nil,
                      skippingCuts: Bool = false) {
        guard range.upperBound > range.lowerBound else { return }
        previewSkipsCuts = skippingCuts
        if previewRange == nil {
            resumeAfterPreview = (currentTime, isPlaying)
        }
        if currentEpisode !== episode {
            // A different episode's report. Load it, but do not let it start
            // from wherever it was left.
            load(episode, autoplay: false)
            resumeAfterPreview = (range.lowerBound, false)
        }
        previewRange = range
        let at = min(max(range.lowerBound, time ?? range.lowerBound), range.upperBound)
        seek(to: at)
        play(from: at)
    }

    /// Ends a preview and puts the listener back where they were.
    func endPreview(resume: Bool = true) {
        guard previewRange != nil else { return }
        previewRange = nil
        let saved = resumeAfterPreview
        resumeAfterPreview = nil
        pause()
        guard resume, let saved else { return }
        seek(to: saved.time)
        if saved.wasPlaying { play(from: saved.time) }
    }

    /// For a slider being dragged: at most about 30 applies a second, and the
    /// last position always lands. More than that only queues parameter
    /// changes faster than anyone can hear them.
    func applyAudioSettingsSoon() {
        guard pendingAudioApply == nil else { return }
        let wait = max(0, 1.0 / 30 - Date.now.timeIntervalSince(lastAudioApply))
        pendingAudioApply = Task { @MainActor [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self else { return }
            self.pendingAudioApply = nil
            self.applyAudioSettings()
        }
    }

    @ObservationIgnored private var pendingAudioApply: Task<Void, Never>?
    @ObservationIgnored private var lastAudioApply = Date.distantPast

    func applyAudioSettings() {
        lastAudioApply = .now
        guard let episode = currentEpisode else { return }
        engine.apply(settings: settings,
                     sound: settings.sound(for: episode.podcast, normalizationGain: episode.normalizationGain))
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
        // Silent audio keeping a locked-phone job alive gives the session
        // back first (pass 22): the player needs it unmixed, or the Lock
        // Screen and AirPods stop controlling it.
        KeepAwake.shared.yieldToPlayer()
        try? AVAudioSession.sharedInstance().setActive(true)

        do {
            if let seconds {
                try engine.play(from: seconds)
                currentTime = seconds
                seekedWhilePaused = false
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
                if seekedWhilePaused {
                    try engine.play(from: currentTime)
                } else {
                    do {
                        try engine.resume()
                    } catch {
                        try engine.play(from: currentTime)
                    }
                }
            }
            phase = .playing
            seekedWhilePaused = false
            // After the phase is set, so the picture reckons with the sound
            // as playing — and so with its delay (task 09).
            if seconds != nil { videoSync.soundJumped() } else { videoSync.soundStateChanged() }
            if sessionStart == nil { sessionStart = .now }
            lastTickTime = currentTime
            startTicking()
            updateNowPlaying()
            trace(seconds == nil ? "play" : "play from \(Int(seconds ?? 0)) s")
        } catch {
            phase = .failed(error.localizedDescription)
            ticker?.cancel()
            updateNowPlaying()
            trace("play failed: \(error.localizedDescription)")
        }
    }

    func pause() {
        trace("pause requested")
        engine.pause()
        phase = .paused
        videoSync.soundStateChanged()
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

        // The crash-safe copy of the position goes to a small file every five
        // seconds; the library's own record only every minute, or at once on
        // pause, seek, episode change and leaving the app. Writing the
        // library every five seconds made every list watching episodes
        // refresh that often for as long as something played — which, among
        // other things, closed a touch-and-hold menu on Up Next a few seconds
        // after it opened, and cost battery for nothing.
        rememberNowPlaying()
        if !force, Date().timeIntervalSince(lastModelPersistAt) < 60 { return }
        lastModelPersistAt = Date()

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

    /// Where the listener was before the last jump made from somewhere other
    /// than the scrubber — a line of the transcript, a search match. The
    /// scrubber shows a ring there for a while, the same ring it leaves after
    /// a drag, and tapping it goes back.
    struct JumpOrigin: Equatable {
        let time: Double
        let at: Date
        let id = UUID()
    }
    private(set) var jumpOrigin: JumpOrigin?

    /// A seek that remembers where it came from.
    func jump(to seconds: Double) {
        let from = currentTime
        // Not worth a ring for a hop of a couple of seconds.
        if abs(seconds - from) > 3 {
            jumpOrigin = JumpOrigin(time: from, at: .now)
        }
        seek(to: seconds)
    }

    func seek(to seconds: Double, advanceAtEnd: Bool = true) {
        // A seek that reaches the end is the end.
        //
        // Skipping forward thirty seconds with less than thirty to go used to
        // clamp to a fifth of a second before the end, and the audio engine —
        // which restarts a finished episode when asked to play from its last
        // half-second, so that pressing play on something already finished
        // starts it again — took that literally and played the episode from
        // the beginning. Now, while playing, arriving at the end is handled
        // exactly like playing to the end: marked played, and on to the next
        // one. Skipping a segment that runs to the end (an outro) goes the
        // same way. Paused, the playhead stops just short of the end instead,
        // so nothing starts on its own.
        if advanceAtEnd, duration > 1, seconds >= duration - 1 {
            if isPlaying {
                currentTime = duration
                handleEnd()
                return
            }
            let parked = max(0, duration - 1)
            currentTime = parked
            seekedWhilePaused = true
            persistProgress(force: true)
            updateNowPlaying()
            videoSync.soundJumped()
            return
        }
        let target = min(max(0, seconds), max(0, duration - (advanceAtEnd ? 0.2 : 0.01)))
        currentTime = target
        if isPlaying {
            play(from: target)
        } else {
            // The audio has to move too, not just the number.
            //
            // Reported: drag from 5:52 to 10:37 while paused, press play, and
            // it plays from 5:52. A paused seek only set `currentTime`; Play
            // then *resumed* the buffer still scheduled at the old spot.
            // Resume stays the fast path — unless a seek happened since.
            seekedWhilePaused = true
            persistProgress(force: true)
            updateNowPlaying()
            videoSync.soundJumped()
        }
    }

    /// Set by a seek made while not playing, so the next play reschedules
    /// from the new position instead of resuming the old buffer.
    private var seekedWhilePaused = false

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

    // MARK: - Skip back (task 07)

    /// A cut being heard once on purpose: the tick doesn't skip it again
    /// until the playhead has passed its end, or left it.
    private(set) var replayRange: ClosedRange<Double>?
    /// When the replay started. For a second after, a position outside the
    /// cut is the jump back still landing, not the listener leaving.
    private var replayStartedAt = Date.distantPast

    /// "Skip back": hear what was just skipped. Only that one cut, once.
    func replayLastSkip() {
        guard let last = lastSkip, last.segmentEnd > last.segmentStart else { return }
        replayRange = last.segmentStart...last.segmentEnd
        replayStartedAt = .now
        lastSkip = nil
        seek(to: last.segmentStart)
        if !isPlaying { play(from: last.segmentStart) }
    }

    /// The replayed cut was just marked not an ad: nothing to guard now.
    func endReplay() { replayRange = nil }

    // MARK: - That was an ad (task 07)

    /// An ad that was heard and not cut: the thirty seconds before the
    /// playhead become a cut the listener made, confirmed through the same
    /// correction path as a thumbs-up (so the show learns from it), and
    /// playback moves past it. The caller opens the editor on it, so its
    /// edges can be dragged to where the ad really was.
    @discardableResult
    func markMissedAd() -> AdSegment? {
        guard let episode = currentEpisode, let context = episode.modelContext else { return nil }
        let end = duration > 0 ? min(currentTime, duration) : currentTime
        let start = max(0, end - 30)
        guard end - start >= 1 else { return nil }
        let segment = AdSegment(start: start, end: end, kind: .ad)
        segment.origin = "added"
        segment.episode = episode
        context.insert(segment)
        episode.apply(.confirmed, to: segment)
        try? context.save()
        rebuildJumps()
        // Past its end, so the next tick doesn't find the playhead on its
        // edge and announce a skip. Not in the last second: a seek there
        // is the end of the episode, and the editor would open on the next.
        if duration <= 0 || end + 0.05 < duration - 1 { seek(to: end + 0.05) }
        Haptics.success()
        return segment
    }

    func markPlayedAndAdvance() {
        currentEpisode?.isPlayed = true
        currentEpisode?.isNew = false
        currentEpisode?.isInQueue = false
        handleEnd(force: true)
    }

    // MARK: - The tick

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                let delay = self?.nextTickDelay() ?? .milliseconds(200)
                try? await Task.sleep(for: delay)
                guard let self, self.isPlaying else { continue }
                await MainActor.run { self.tick() }
            }
        }
    }

    /// Set from the app's scene phase. With nothing on screen, the tick only
    /// has jumps to make, and a video episode needs no picture.
    var isInBackground = false {
        didSet {
            guard isInBackground != oldValue else { return }
            if isInBackground, !pictureInPictureActive { cancelVideoAlignment() }
            // Back on screen with Audio chosen: load the picture ahead again.
            if !isInBackground { attachVideoIfWanted() }
            applyVideoVisibility()
        }
    }

    /// Five times a second while the app is on screen, for the scrubber.
    ///
    /// In the background nothing draws, so waking five times a second — for
    /// hours, through a whole commute — was pure battery. There the tick
    /// sleeps until just before the next thing it has to act on: the start of
    /// the next cut or shortened silence, a preview's end, the outro trim, the
    /// end of the episode. Capped at a second so a seek from the Lock Screen,
    /// AirPods or the car is noticed promptly. Jumps also land more exactly
    /// this way, since the wake is aimed at the boundary instead of falling
    /// anywhere in a 200 ms window.
    private func nextTickDelay() -> Duration {
        guard isInBackground else { return .milliseconds(200) }
        let now = engine.currentTime
        var next = duration
        if let preview = previewRange { next = Swift.min(next, preview.upperBound) }
        if previewRange == nil {
            if let outro = currentEpisode?.podcast?.skipOutroSeconds, outro > 0, duration - outro > now {
                next = Swift.min(next, duration - outro)
            }
            for range in adRanges where range.lowerBound > now { next = Swift.min(next, range.lowerBound) }
            for gap in silenceJumps where gap.lowerBound > now { next = Swift.min(next, gap.lowerBound) }
        }
        let rate = Swift.max(0.5, playbackRate)
        let seconds = (next - now) / rate - 0.03
        return .milliseconds(Int(Swift.max(0.05, Swift.min(1.0, seconds)) * 1000))
    }

    /// The range holding `t`, from a list sorted by start. Halves to the last
    /// range starting at or before `t`, then looks back a few in case ranges
    /// overlap.
    static func range(containing t: Double, in sorted: [ClosedRange<Double>]) -> ClosedRange<Double>? {
        var low = 0, high = sorted.count - 1, found = -1
        while low <= high {
            let mid = (low + high) / 2
            if sorted[mid].lowerBound <= t { found = mid; low = mid + 1 } else { high = mid - 1 }
        }
        guard found >= 0 else { return nil }
        for i in stride(from: found, through: max(0, found - 3), by: -1) where sorted[i].contains(t) {
            return sorted[i]
        }
        return nil
    }

    /// The last chapter starting at or before `t`.
    static func last(in sorted: [Chapter], atOrBefore t: Double) -> Chapter? {
        var low = 0, high = sorted.count - 1, found: Chapter?
        while low <= high {
            let mid = (low + high) / 2
            if sorted[mid].start <= t { found = sorted[mid]; low = mid + 1 } else { high = mid - 1 }
        }
        return found
    }

    /// Ticks in a row where we believe we're playing and the audio system says
    /// nothing is coming out.
    private var silentTicks = 0

    private func tick() {
        // A call can stop the audio without the interruption reaching us (or
        // before it does). Then the player showed a pause button over silence
        // and the headphones' play did nothing, because we thought we were
        // already playing (his report, pass 20). Believe the audio system:
        // after about a second of it saying nothing is playing, we're
        // interrupted — so the button shows play, the headphones start it,
        // and the end of the interruption resumes it.
        if engine.isRendering {
            silentTicks = 0
        } else {
            silentTicks += 1
            if silentTicks >= 5 {
                silentTicks = 0
                trace("silence watchdog: engine not rendering for a second")
                ticker?.cancel()
                persistProgress(force: true)
                phase = .interrupted(resumeWhenPossible: true)
                updateNowPlaying()
                return
            }
        }
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

        // Five times a second, so nothing here touches the store or walks a
        // list: chapters, ads and Smart Speed gaps are sorted once in
        // `rebuildJumps` and searched by halving.
        if !sortedChapters.isEmpty {
            let active = Self.last(in: sortedChapters, atOrBefore: now)
            if active !== currentChapter {
                currentChapter = active
                updateNowPlaying()
            }
        }

        // Previewing one stretch, with everything switched off.
        //
        // This is what "Listen" on the what-was-skipped page needs, and it is
        // the thing that did not exist. Before, that button seeked into the ad
        // and the very next tick skipped straight back out of it — so the only
        // way to hear what had been cut was to turn Skip Ads off by hand, hear
        // it, and remember to turn it back on. Which nobody does.
        //
        // While a preview is running nothing is skipped: no ad ranges, no Smart
        // Speed gaps, no outro trim. It stops itself at the far edge and puts
        // the listener back where they were.
        if let preview = previewRange {
            if now >= preview.upperBound || now < preview.lowerBound - 1 {
                endPreview()
            } else if previewSkipsCuts, let cut = Self.range(containing: now, in: adRanges) {
                if cut.upperBound + 0.05 >= preview.upperBound {
                    endPreview()
                } else {
                    seek(to: cut.upperBound + 0.05)
                }
            }
            return
        }

        // Outro trim
        if outroTrim > 0, now >= duration - outroTrim {
            handleEnd()
            return
        }

        // "Skip back" (task 07): the cut being replayed plays through once.
        if let replay = replayRange, Date.now.timeIntervalSince(replayStartedAt) > 1,
           now >= replay.upperBound || now < replay.lowerBound - 1 {
            replayRange = nil
        }

        // Advertisement, self-promotion, another show, an intro or an outro —
        // whichever kinds this listener has switched on.
        if let range = Self.range(containing: now, in: adRanges), !(replayRange?.contains(now) ?? false) {
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
            lastSkip = (sponsor, jumped, range.lowerBound, range.upperBound, .now)
            Haptics.skip()
            seek(to: target)
            return
        }

        // Smart Speed
        if let gap = Self.range(containing: now, in: silenceJumps) {
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

        if duration > 0, now >= duration - 0.3 { handleEnd() }
    }

    private func handleEnd(force: Bool = false) {
        guard let finished = currentEpisode else { return }
        persistProgress(force: true)
        flushSession()

        let markPlayed = settings.markPlayedAtEnd || force
        if markPlayed {
            finished.isPlayed = true
            finished.isNew = false
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

        // A show can decide for itself whether its episodes run on.
        let continues = finished.podcast?.continuousPlaybackOverride ?? settings.continuousPlayback
        guard continues || force, let next = queueProvider?(finished) else {
            engine.stop()
            phase = .stopped
            ticker?.cancel()
            updateNowPlaying()
            if markPlayed { tidyFinished(finished) }
            return
        }
        if let autoplayRouter {
            autoplayRouter(next)
        } else {
            load(next, autoplay: true)
        }
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

            let reasonRaw = info[AVAudioSessionInterruptionReasonKey] as? UInt
            let player = self
            Task { @MainActor in
                player?.handleInterruption(typeValue: typeValue, shouldResume: shouldResume, reasonRaw: reasonRaw)
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

            // Decide here, while the route description is in hand.
            var lostPrivateOutput = false
            if reason == .oldDeviceUnavailable,
               let previous = info[AVAudioSessionRouteChangePreviousRouteKey]
                as? AVAudioSessionRouteDescription {
                lostPrivateOutput = Self.isPrivateListening(previous)
            }

            let player = self
            Task { @MainActor in
                // Pass 33: every route change is recorded with its reason, so
                // a silent stretch can be lined up with what changed.
                player?.trace("route changed: " + PlaybackTrace.name(reason))
                if reason == .oldDeviceUnavailable {
                    player?.handleOutputDisappeared(wasPrivate: lostPrivateOutput)
                }
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
    ///
    /// Pass 33 (his report: opening an app that uses the microphone briefly
    /// pauses PodSkipper): PodSkipper's session is plain `.playback`, and it
    /// never uses the microphone. An app that takes the audio for recording
    /// makes iOS interrupt every non-mixing player; that is iOS's decision,
    /// and this only keeps the player's state matching it — paused while
    /// interrupted, resumed afterwards when iOS (or his setting) says so.
    private func handleInterruption(typeValue: UInt, shouldResume: Bool, reasonRaw: UInt? = nil) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        silentTicks = 0

        switch type {
        case .began:
            systemInterruptionActive = true
            trace("interruption began: " + PlaybackTrace.name(interruptionReason: reasonRaw))
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
            systemInterruptionActive = false
            trace("interruption ended (iOS says resume: \(shouldResume ? "yes" : "no"))")
            guard case .interrupted(let resumeWhenPossible) = phase else { return }
            // Resume only when the system says it is fine *and* this app was
            // the thing playing when it was cut off. Either one alone would
            // start an episode in someone's pocket.
            // His setting (pass 20): resume after a call even when iOS
            // doesn't offer to — it often doesn't after an answered call.
            let wanted = shouldResume || (settings.resumeAfterInterruption)
            guard wanted, resumeWhenPossible else {
                phase = .paused
                updateNowPlaying()
                return
            }
            play(from: currentTime)

        @unknown default:
            break
        }
    }

    /// An interruption iOS announced and hasn't yet ended (a call, another
    /// app's audio). While it lasts nothing restarts the engine on its own.
    private var systemInterruptionActive = false

    /// iOS stopped the file engine because the output format changed (a
    /// headset switching profile when some app opens its microphone, a
    /// sample-rate change). Restart it if we were playing — or if the
    /// silence watchdog, not a call, had marked us interrupted.
    private func handleEngineConfigurationChange() {
        trace("engine stopped by iOS: output format changed")
        guard engine === audio, currentEpisode != nil, !systemInterruptionActive else { return }
        let wanted: Bool = switch phase {
        case .playing: true
        case .interrupted(let resumeWhenPossible): resumeWhenPossible
        default: false
        }
        guard wanted else { return }
        silentTicks = 0
        play(from: currentTime)
        let restarted = phase == .playing
        trace(restarted ? "restarted after format change" : "could not restart after format change")
        BackgroundLog.shared.note("Sound output format changed; playback " + (restarted ? "restarted" : "could not restart"))
    }

    /// One diagnostics snapshot (see `PlaybackTrace`).
    func trace(_ event: String) {
        let kind: String
        let state: String
        if engine === audio {
            kind = "file"; state = audio.stateDescription
        } else if engine === stream {
            kind = "stream"; state = stream.stateDescription
        } else {
            kind = "video"; state = engine.isRendering ? "rendering" : "not rendering"
        }
        PlaybackTrace.shared.note(event, phase: String(describing: phase), engine: kind,
                                  engineState: state, position: engine.currentTime)
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
            Task { @MainActor in
                guard let player else { return }
                // A pause always pauses (pass 24). Pass 23 read a pause on a
                // paused episode, with the silence of `KeepAwake` running, as
                // "play" — but multipoint headphones send exactly that pause
                // to hand themselves to another device, so the iPhone took
                // them straight back. With only the silence playing, the
                // silence stops instead; a second press then plays. Pass 25:
                // either way, the silence stays off for the rest of his line
                // of jobs.
                let silenceOnly = !player.isPlaying && KeepAwake.shared.isActive
                KeepAwake.shared.remotePauseArrived()
                if !silenceOnly { player.pause() }
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            let player = self
            Task { @MainActor in
                guard let player else { return }
                // Pass 25: a toggle that pauses counts as a pause for the
                // silence (multipoint headphones hand themselves over with
                // one); a toggle with only the silence playing stops the
                // silence rather than starting the episode.
                if player.isPlaying {
                    KeepAwake.shared.remotePauseArrived()
                    player.pause()
                } else if KeepAwake.shared.isActive {
                    KeepAwake.shared.remotePauseArrived()
                } else {
                    player.play()
                }
            }
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
            NowPlayingActivityController.shared.end()
            return
        }
        NowPlayingActivityController.shared.sync(
            guid: episode.guid,
            title: episode.title,
            show: episode.podcast?.title ?? "",
            isPlaying: isPlaying,
            secondsSkipped: episode.adSecondsRemoved,
            elapsed: currentTime,
            duration: duration,
            rate: playbackRate,
            published: episode.publishedAt,
            artworkURL: episode.artworkURL ?? episode.podcast?.artworkURL)
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

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// The light tick when a control takes hold — picking up the scrubber,
    /// landing on a speed. Lighter than `skip`, which announces something the
    /// app did on its own.
    static func select() {
        generator.prepare()
        generator.impactOccurred(intensity: 0.35)
    }

    /// The firm click when a held seek commits — the tension breaking.
    static func commit() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.9)
    }

    /// The soft click of catching on a segment's edge.
    static func detent() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// The snap back when a tap only peeked.
    static func recoil() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.45)
    }

    /// Something saved — a bookmark, a favourite.
    static func toggle(on: Bool) {
        UIImpactFeedbackGenerator(style: on ? .medium : .light).impactOccurred(intensity: on ? 0.8 : 0.5)
    }
}
