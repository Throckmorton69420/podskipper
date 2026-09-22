import Foundation
import Observation
import SwiftData
import BackgroundTasks
import UIKit

/// Downloads an episode, transcribes it, finds the ads, saves the ranges.
///
/// The design decision that matters here: this runs *ahead of playback*, not
/// during it. Apps that classify live always leak the first second or two of
/// every ad, because the model can't know a break started until it hears it.
/// Pre-processing overnight means playback is instant and the cuts are clean.
@MainActor
@Observable
final class ProcessingPipeline {

    /// One shared instance. Views and intents all talk to this one.
    static let shared = ProcessingPipeline()

    static let backgroundTaskID = "com.yourname.podskipper.process"

    var currentEpisodeTitle: String?
    /// Which episode is being worked on, so a row can draw its own progress
    /// instead of a floating banner telling you only that *something* is
    /// happening.
    var currentEpisodeGUID: String?
    /// The episode itself, for a notification written about it. Not drawn
    /// anywhere, so not observed.
    @ObservationIgnored private(set) var currentEpisode: Episode?
    var stage: Stage = .idle
    var stageFraction: Double = 0
    var isRunning = false

    /// True when this episode is the one currently being processed.
    func isProcessing(_ episode: Episode) -> Bool {
        isRunning && currentEpisodeGUID == episode.guid
    }

    /// How many episodes are left in this batch, not counting the current one.
    var queueRemaining = 0

    private var jobStartedAt: Date?

    /// Speculative work for autoplay, held so it can be cancelled the moment
    /// someone asks for something real.
    private var backgroundJob: Task<Void, Never>?

    /// Weighted across the four steps, because transcription takes far longer
    /// than the others and a naive "step 2 of 4 = 50%" bar would lie.
    var overallFraction: Double {
        guard stage != .idle else { return 0 }
        let done = Stage.ordered.prefix(while: { $0 != stage }).reduce(0) { $0 + $1.weight }
        return min(1, done + stage.weight * stageFraction)
    }

    /// Extrapolated from how long we've taken to get this far. Deliberately
    /// absent for the first few percent, where the estimate would be nonsense.
    var etaSeconds: Double? {
        guard let jobStartedAt, isRunning else { return nil }
        let fraction = overallFraction
        guard fraction > 0.04 else { return nil }
        let elapsed = Date().timeIntervalSince(jobStartedAt)
        return elapsed / fraction * (1 - fraction)
    }

    var stageDescription: String? { stage == .idle ? nil : stage.label }

    enum Stage: Equatable {
        case idle, downloading, transcribing, detecting, analyzing, saving

        static let ordered: [Stage] = [.downloading, .transcribing, .detecting, .analyzing, .saving]

        var label: String {
            switch self {
            case .idle:         return ""
            case .downloading:  return "Downloading audio"
            case .transcribing: return "Transcribing on device"
            case .detecting:    return "Finding ads"
            case .analyzing:    return "Measuring silence and loudness"
            case .saving:       return "Saving results"
            }
        }

        /// Rough share of total wall time. Transcription dominates.
        var weight: Double {
            switch self {
            case .idle:         return 0
            case .downloading:  return 0.11
            case .transcribing: return 0.52
            case .detecting:    return 0.25
            case .analyzing:    return 0.08
            case .saving:       return 0.04
            }
        }

        var number: Int { (Stage.ordered.firstIndex(of: self) ?? 0) + 1 }
        static var count: Int { ordered.count }
    }

    private let transcriber = TranscriptionService()
    private let detector = AdDetector()
    private var modelContext: ModelContext?
    private var settings: AppSettings?

    /// Held for the length of a job so iOS doesn't suspend the app the moment
    /// it is backgrounded. Without this, minimising the app mid-transcription
    /// froze the progress bar until you came back — the work had simply been
    /// stopped, not slowed.
    private var backgroundAssertion: UIBackgroundTaskIdentifier = .invalid
    /// True while the app is in the background with a job running.
    ///
    /// Read by nothing that can act on it, and that is the honest state of
    /// affairs rather than an oversight: once iOS suspends the process there
    /// is no code running to bail out with. What it is good for is telling
    /// the truth afterwards — a job that stops while this is set stopped
    /// because the system stopped it, not because it failed.
    private(set) var wasBackgrounded = false

    func configure(context: ModelContext, settings: AppSettings) {
        self.modelContext = context
        self.settings = settings
    }

    // MARK: - Staying alive in the background

    private func beginAssertion() {
        guard backgroundAssertion == .invalid else { return }
        backgroundAssertion = UIApplication.shared.beginBackgroundTask(
            withName: "PodSkipper.processing"
        ) { [weak self] in
            // iOS is about to reclaim the time. Give it back before it is
            // taken, otherwise the app is killed rather than suspended.
            Task { @MainActor in self?.endAssertion() }
        }
    }

    private func endAssertion() {
        guard backgroundAssertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundAssertion)
        backgroundAssertion = .invalid
    }

    /// Called from the scene-phase observer in `RootView`.
    ///
    /// A background assertion buys around thirty seconds — nowhere near enough
    /// for an hour of transcription. So when the app goes away mid-job we also
    /// ask the scheduler to run the processing task as soon as it is willing,
    /// with no power requirement, so the work resumes on its own rather than
    /// waiting for you to reopen the app.
    func applicationDidEnterBackground() {
        guard isRunning else { return }
        wasBackgrounded = true
        Self.scheduleNext(requiresPower: false, soon: true)
    }

    func applicationWillEnterForeground() {
        wasBackgrounded = false
    }

    // MARK: - Public entry points

    /// Process one episode end to end.
    func process(_ episode: Episode) async {
        guard let context = modelContext, let settings else { return }
        isRunning = true
        currentEpisodeTitle = episode.title
        currentEpisodeGUID = episode.guid
        currentEpisode = episode
        jobStartedAt = Date()
        beginAssertion()
        BackgroundWork.shared.workStarted()
        defer {
            isRunning = false
            currentEpisodeTitle = nil
            currentEpisodeGUID = nil
            currentEpisode = nil
            stage = .idle
            stageFraction = 0
            jobStartedAt = nil
            endAssertion()
            // A real job just finished; pick up anything that was waiting.
            // Not from inside the speculative loop itself, which carries on
            // with its own list.
            if backgroundJob == nil, !deferredSpeculative.isEmpty {
                let waiting = deferredSpeculative
                deferredSpeculative = []
                Task { @MainActor [weak self] in self?.enqueueBackground(waiting) }
            } else if backgroundJob == nil {
                // Finishing a job can change what "the next two" are ready
                // for; ask again rather than waiting for the next episode.
                Task { @MainActor in PrepareAhead.shared.refresh() }
            }
        }

        do {
            // 1. Download
            if episode.localFileURL == nil || !FileManager.default.fileExists(atPath: episode.localFileURL!.path) {
                episode.processingState = .downloading
                stage = .downloading
                stageFraction = 0
                let filename = try await download(episode)
                episode.localFilename = filename
                FileIndex.insert(filename)
                LibraryTotals.shared.invalidate()
                try? context.save()
            }
            guard let mediaURL = episode.localFileURL else { return }

            // A video's audio track has to come out before anything can read
            // it. AVAudioFile cannot open an mp4, so without this step every
            // video episode would fail at the first line of transcription.
            // The export copies the existing track rather than re-encoding,
            // so it is quick, and it only ever happens once per episode.
            if episode.isVideo, episode.extractedAudioFilename == nil,
               let filename = episode.localFilename {
                let audioName = MediaExtractor.audioFilename(for: filename)
                do {
                    episode.extractedAudioFilename =
                        try await MediaExtractor.extractAudio(from: mediaURL, named: audioName)
                    try? context.save()
                } catch {
                    episode.processingState = .failed
                    episode.processingError = error.localizedDescription
                    try? context.save()
                    return
                }
            }
            guard let fileURL = episode.analysableFileURL else { return }

            // Chapters live in the audio file, so this is the first moment
            // we can read them.
            await ChapterService.extract(for: episode, context: context)

            // 2. Transcribe — unless this episode already has a transcript.
            //
            // Transcription is the expensive step by a wide margin: an hour of
            // audio is minutes of work, and every run used to redo it from
            // nothing. That is what made a job interrupted by iOS suspending
            // the app feel like it had achieved nothing, and what made
            // changing the sensitivity and pressing Find Ads again cost
            // another full pass over the file.
            //
            // The transcript is saved on the episode as soon as it exists. If
            // it is there and it reaches the end of the audio, reuse it: the
            // words do not change, only what we decide about them does.
            stage = .downloading
            stageFraction = 1

            episode.processingState = .transcribing
            stage = .transcribing
            stageFraction = 0

            let segments: [TranscriptSegment]
            if let reusable = Self.reusableTranscript(for: episode) {
                segments = reusable
                stageFraction = 1
            } else {
                let throttle = ProgressThrottle { [weak self] p in self?.stageFraction = p }
                segments = try await transcriber.transcribe(fileURL: fileURL) { throttle.report($0) }
                // Joining and encoding a two-hour transcript is tens of
                // thousands of lines; done here it held the main thread for a
                // visible moment. Off it, then back to set the fields.
                let lines = segments.map { TimedLine(text: $0.text, start: $0.start, end: $0.end,
                                                      words: $0.words.isEmpty ? nil : $0.words) }
                let (text, data) = await Task.detached(priority: .utility) {
                    (lines.map(\.text).joined(separator: " "), try? JSONEncoder().encode(lines))
                }.value
                episode.transcriptText = text
                episode.storeTranscript(lines, encoded: data)
                try? context.save()
            }

            // 3. Detect ads
            stage = .transcribing
            stageFraction = 1
            // Speculative work steps aside here, between stages, when someone
            // presses Find Ads on something else. See `processNow`.
            try Task.checkCancellation()

            // 3. Measure silence and loudness, before detection rather than
            // after it. The detector snaps each cut to the nearest measured
            // pause, which is what stops a skip clipping the syllable either
            // side of it — so it needs these first.
            var silences: [ClosedRange<Double>] = []
            if settings.analyzeSilence {
                episode.processingState = .analyzing
                stage = .analyzing
                stageFraction = 0
                // Off the main thread. This reads every sample of the file and
                // used to run right here on the main actor, which is most of
                // why scrolling stuttered while ads were being found.
                let throttle = ProgressThrottle { [weak self] p in self?.stageFraction = p }
                let analysis = await Task.detached(priority: .utility) {
                    try? AudioAnalyzer.analyze(fileURL: fileURL, progress: { throttle.report($0) })
                }.value
                if let analysis {
                    silences = analysis.silences
                    episode.storeSilence(analysis.silences)
                    episode.normalizationGain = analysis.normalizationGain
                }
                stageFraction = 1
            }

            // 4. Classify.
            try Task.checkCancellation()
            episode.processingState = .detecting
            stage = .detecting
            stageFraction = 0
            let known = episode.podcast?.knownSponsors ?? []
            // Every thumbs-up and thumbs-down the listener has given on this
            // show, handed to the model as worked examples. This is the whole
            // of the feedback loop: without this line the thumbs change one
            // episode and nothing else.
            let corrections = episode.podcast?.corrections ?? []
            let detectThrottle = ProgressThrottle { [weak self] p in self?.stageFraction = p }
            // Sentence by sentence: see SegmentDetector and
            // claude/DETECTION-AUDIT.md for why the window detector was
            // replaced.
            let detection = try await detector.detectSentences(
                segments: segments,
                silences: silences,
                knownSponsors: known,
                corrections: corrections,
                globalCorrections: GlobalCorrections.all,
                showTitle: episode.podcast?.title ?? "",
                episodeTitle: episode.title,
                showNotes: episode.episodeDescription,
                audioDuration: episode.duration,
                minimumConfidence: settings.minimumConfidence,
                padding: settings.boundaryPadding
            ) { [detectThrottle] p in detectThrottle.report(p) }
            let ads = detection.segments

            // What this show advertises carries forward. Next episode the
            // detector recognises these instead of working them out again.
            if let show = episode.podcast, !detection.sponsors.isEmpty {
                var merged = Set(show.knownSponsors)
                merged.formUnion(detection.sponsors)
                show.knownSponsors = Array(merged).sorted().suffix(40).map { $0 }
            }

            // 5. Save, preserving any manual corrections the user already made
            stage = .saving
            stageFraction = 0.5
            let rejected = episode.adSegments.filter { $0.userVerdict == .notAnAd }
            for old in episode.adSegments where old.userVerdict != .notAnAd {
                context.delete(old)
            }
            let wantsDelivery = settings.keepHostReadAds || settings.keepComedyBitAds
            for (index, ad) in ads.enumerated() {
                let overlapsRejected = rejected.contains { $0.start < ad.end && $0.end > ad.start }
                guard !overlapsRejected else { continue }
                let segment = AdSegment(start: ad.start, end: ad.end,
                                        sponsor: ad.sponsor, confidence: ad.confidence,
                                        kind: ad.kind)
                // How it was delivered, for the keep-host-read and
                // keep-comedy-bit settings. About a second of the language
                // model per ad, so only asked when one of those settings is
                // on — with both off the answer changes nothing.
                if ad.kind == .ad, wantsDelivery {
                    stageFraction = 0.5 + 0.4 * Double(index) / Double(max(1, ads.count))
                    let text = segments.filter { $0.start < ad.end && $0.end > ad.start }
                        .map(\.text).joined(separator: " ")
                    if let style = await detector.classifyStyle(of: ad, text: text) {
                        segment.deliveryRaw = style.hostRead ? "host" : "produced"
                        segment.isComedyBit = style.comedyBit
                    }
                }
                segment.episode = episode
                context.insert(segment)
            }

            episode.processingState = .ready
            episode.lastProcessedAt = .now
            episode.processingError = nil
            CountsCache.invalidate(episode.podcast)
            LibraryTotals.shared.invalidate()
            try? context.save()
            // Listening to it right now: start skipping straight away, rather
            // than on the next load.
            if PlayerEngine.shared.currentEpisode?.guid == episode.guid {
                PlayerEngine.shared.refreshSkipRanges()
            }
            // The show publishes itself: straight into its feed, not already
            // in it, only once there is a feed to put it in.
            if let show = episode.podcast, show.autoPublish, show.publishedFeedURL != nil,
               episode.publishedURL == nil, R2Credentials.isConfigured {
                PublishQueue.shared.configure(context: context)
                PublishQueue.shared.enqueue([episode])
            }

        } catch is CancellationError {
            // Stepped aside for a job someone asked for. Not a failure: the
            // transcript, if it got that far, is already saved and reused.
            episode.processingState = .notStarted
            try? context.save()
        } catch {
            episode.processingState = .failed
            episode.processingError = error.localizedDescription
            CountsCache.invalidate(episode.podcast)
            try? context.save()
            // Away from the app: say so, and make the tap land on this episode.
            if UIApplication.shared.applicationState != .active {
                let message = error.localizedDescription
                Task {
                    await NotificationService.notifyJobProblem(
                        episode, title: "Couldn't find the ads",
                        body: "\(message) Tap to see where it's up to and try again.")
                }
            }
        }
    }

    /// Process an explicit set of episodes, in order. Used by the batch
    /// selection on the Publish screen.
    func process(_ episodes: [Episode]) async {
        for (index, episode) in episodes.enumerated() {
            queueRemaining = episodes.count - index - 1
            await process(episode)
        }
        queueRemaining = 0
    }

    /// Get episodes ready that nobody has asked for yet.
    ///
    /// The difference between this and `process` is who is waiting. A tap on
    /// Find Ads has someone watching a progress bar; this is speculative work
    /// for autoplay, and it must never push in front of the other kind or make
    /// the app feel busy. So it: does nothing while a job is already running,
    /// skips anything already processed or already queued, and takes the first
    /// one only — the rest are picked up the next time an episode loads.
    func enqueueBackground(_ episodes: [Episode]) {
        // Not failed ones: those would be retried every time anything asked,
        // forever. A failure is retried when someone presses Find Ads.
        let worth = episodes.filter {
            $0.processingState != .ready && $0.processingState != .failed
        }
        guard !worth.isEmpty else { return }
        // Busy with something someone asked for: remember the list and start
        // it when that finishes. It used to be dropped, and nothing asked
        // again until the next episode loaded — so one Find Ads tap while
        // listening cancelled preparing ahead for the rest of the episode.
        guard !isRunning, backgroundJob == nil else {
            // Kept either way. It was only kept when no speculative job was
            // running, so a new "next two" arriving mid-job was dropped.
            let known = Set(deferredSpeculative.map(\.guid))
            deferredSpeculative += worth.filter { !known.contains($0.guid) }
            return
        }
        deferredSpeculative = []

        backgroundJobStartedAt = .now
        let jobID = UUID()
        backgroundJobID = jobID
        let job = Task { [weak self] in
            guard let self else { return }
            defer {
                // Only clear the slot if it is still this job's. A cancelled
                // job finishing late used to clear the reference to the job
                // that replaced it.
                if self.backgroundJobID == jobID {
                    self.backgroundJob = nil
                    self.backgroundJobStartedAt = nil
                    self.speculativePausedReason = nil
                }
                if !self.deferredSpeculative.isEmpty, !self.isRunning {
                    let waiting = self.deferredSpeculative
                    self.deferredSpeculative = []
                    Task { @MainActor [weak self] in self?.enqueueBackground(waiting) }
                }
            }
            // A beat of grace so this never competes with the work of actually
            // starting the episode someone just pressed play on.
            try? await Task.sleep(for: .seconds(3))

            // All of them, not just the first.
            //
            // The setting says "Prepare 2 episodes ahead" and the caller
            // duly handed over two — and this then processed one and stopped,
            // so autoplay was still a wait every other episode. The cap is
            // belt and braces: the caller already limits the list.
            let list = Array(worth.prefix(4))
            for (index, episode) in list.enumerated() {
                guard !Task.isCancelled else { return }
                // Work nobody is waiting for waits for a cool, charged-enough
                // phone. Transcription is the heaviest thing the app does; in
                // Low Power Mode, or once iOS reports the phone as hot, doing
                // it speculatively is what makes a phone warm in a pocket.
                // Find Ads pressed by hand is not held back.
                while let reason = Self.speculativeHoldReason, !Task.isCancelled {
                    self.speculativePausedReason = reason
                    try? await Task.sleep(for: .seconds(30))
                }
                self.speculativePausedReason = nil
                self.backgroundJobStartedAt = .now
                // Never in front of a job someone is watching a progress bar
                // for. Checked every time round, not once at the start — and
                // what is left is kept for when that job finishes.
                guard !self.isRunning else {
                    self.deferredSpeculative = Array(list[index...])
                    return
                }
                guard episode.processingState != .ready else { continue }
                self.backgroundJobStartedAt = .now
                await self.process(episode)
                self.backgroundJobStartedAt = .now
            }
        }
        backgroundJob = job
    }

    /// Find the ads in this episode now — the player's Find Ads.
    ///
    /// Reported: pressing Find Ads in the player was greyed out for a while
    /// after playback started, then worked. Getting the next episodes ready
    /// had just started in the background, and the button was disabled while
    /// anything at all was running. Now speculative work is cancelled — it
    /// stops at the next stage boundary and keeps its transcript — and this
    /// runs as soon as it has; a job someone else asked for is waited out.
    func processNow(_ episode: Episode) async {
        guard !isProcessing(episode) else { return }
        waitingToProcess = episode.guid
        cancelBackgroundWork()
        while isRunning { try? await Task.sleep(for: .milliseconds(300)) }
        waitingToProcess = nil
        await process(episode)
    }

    /// An episode waiting for another job to finish before its own starts.
    var waitingToProcess: String?
    /// A download is waiting for the connection to come back.
    var waitingForConnection = false

    /// Why getting episodes ready ahead is waiting, in words, when it is.
    var speculativePausedReason: String?
    private var backgroundJobStartedAt: Date?
    private var backgroundJobID = UUID()

    var hasBackgroundJob: Bool { backgroundJob != nil }

    static var speculativeHoldReason: String? {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "Waiting — Low Power Mode is on" }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return "Waiting for the phone to cool down"
        default: return nil
        }
    }

    /// A speculative job that has sat for minutes without starting anything
    /// is stuck, not busy. Reported: two episodes in Up Next showed
    /// "Waiting" indefinitely and never began. Called on a timer by
    /// `PrepareAhead`; restarts the job with whatever it was holding.
    func restartBackgroundWorkIfStalled() {
        guard let started = backgroundJobStartedAt, !isRunning,
              speculativePausedReason == nil,
              Date().timeIntervalSince(started) > 120 else { return }
        backgroundJob?.cancel()
        backgroundJob = nil
        backgroundJobStartedAt = nil
        backgroundJobID = UUID()
    }

    /// Speculative work that arrived while a real job was running.
    private var deferredSpeculative: [Episode] = []

    /// Stop speculative work. Called when a real job starts.
    func cancelBackgroundWork() {
        backgroundJob?.cancel()
        backgroundJob = nil
        backgroundJobStartedAt = nil
        backgroundJobID = UUID()
    }

    // MARK: - Feed refresh
    //
    // One refresh at a time. Pulling down on the Library while the overnight
    // refresh is running, or pulling twice, joins the refresh already in
    // progress instead of starting a second one that merges the same feeds
    // over the top of it. A refresh only ever adds episodes and fills in
    // details (video, people, ratings) — it never touches a transcript, a
    // found ad, a download or anything being published — so it is safe to
    // run while ads are being found or episodes published.

    private var allFeedsRefresh: Task<Int, Never>?
    private var showRefreshes: [String: Task<Int, Never>] = [:]
    private static let lastRefreshKey = "lastFeedRefresh"

    /// When every feed was last checked, for "Updated 5m ago" and for
    /// deciding whether opening the app should check again.
    static var lastFeedRefresh: Date? {
        let stamp = UserDefaults.standard.double(forKey: lastRefreshKey)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    /// Check every subscribed show for new episodes. Returns how many were added.
    @discardableResult
    func refreshAllFeeds(queueNewEpisodes: Bool = false) async -> Int {
        if let running = allFeedsRefresh { return await running.value }
        let task = Task { @MainActor in await self.refreshFeeds(nil, queueNewEpisodes: queueNewEpisodes) }
        allFeedsRefresh = task
        let added = await task.value
        allFeedsRefresh = nil
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: Self.lastRefreshKey)
        return added
    }

    /// Check one show. Joins a refresh of everything if one is running,
    /// since that covers this show too.
    @discardableResult
    func refreshFeed(of podcast: Podcast, queueNewEpisodes: Bool = false) async -> Int {
        if let running = allFeedsRefresh { return await running.value }
        let key = podcast.feedURL
        if let running = showRefreshes[key] { return await running.value }
        let id = podcast.persistentModelID
        let task = Task { @MainActor in await self.refreshFeeds([id], queueNewEpisodes: queueNewEpisodes) }
        showRefreshes[key] = task
        let added = await task.value
        showRefreshes[key] = nil
        return added
    }

    /// For the background tasks, which have no view to read settings from.
    func refreshFeedsInBackground() async {
        await refreshAllFeeds(queueNewEpisodes: settings?.autoQueueNewEpisodes ?? false)
    }

    /// Opening the app checks for new episodes when it has been a while.
    func refreshIfStale(queueNewEpisodes: Bool, olderThan interval: TimeInterval = 30 * 60) {
        if let last = Self.lastFeedRefresh, Date.now.timeIntervalSince(last) < interval { return }
        Task { await refreshAllFeeds(queueNewEpisodes: queueNewEpisodes) }
    }

    private func refreshFeeds(_ only: [PersistentIdentifier]?, queueNewEpisodes: Bool) async -> Int {
        guard let context = modelContext else { return 0 }
        guard let podcasts = try? context.fetch(FetchDescriptor<Podcast>()) else { return 0 }

        // Merged in the background — see `LibraryIndex`. Feeds are fetched a
        // few at a time rather than one after another, and only episodes
        // published since the last refresh count as new for Up Next and
        // notifications.
        let wanted = only.map(Set.init)
        let shows = podcasts
            .filter { !$0.isArchived && (wanted?.contains($0.persistentModelID) ?? true) }
            .map { ($0.persistentModelID, $0.feedURL) }
        var freshIDs: [PersistentIdentifier] = []
        await withTaskGroup(of: (PersistentIdentifier, ParsedFeed?).self) { group in
            var iterator = shows.makeIterator()
            func addNext() {
                guard let (id, url) = iterator.next() else { return }
                group.addTask { (id, try? await FeedParser.fetch(url)) }
            }
            for _ in 0..<4 { addNext() }
            while let (id, feed) = await group.next() {
                if let feed {
                    let result = await LibraryIndexStatus.shared.merge(feed, into: id)
                    freshIDs += result.freshIDs
                }
                addNext()
            }
        }
        var fresh: [Episode] = []
        for id in freshIDs {
            guard let episode = context.model(for: id) as? Episode else { continue }
            if queueNewEpisodes, episode.podcast?.autoQueueNew == true { episode.isInQueue = true }
            fresh.append(episode)
        }
        if !fresh.isEmpty { try? context.save() }

        if !fresh.isEmpty {
            await NotificationService.notifyNewEpisodes(fresh, settings: settings ?? AppSettings())
        }

        // The automatic download rules — see `AutoDownload`.
        if let settings {
            await AutoDownload.apply(context: context, settings: settings, pipeline: self)
        }
        return fresh.count
    }

    /// Total bytes of downloaded audio sitting on disk.
    static func downloadedBytes() -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: FileStore.episodesDirectory,
                                                      includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return files.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    /// Delete downloaded audio. Transcripts and detected ads are kept, so a
    /// cleared episode only needs re-downloading, not re-analysing.
    func clearDownloads() {
        guard let context = modelContext else { return }
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: FileStore.episodesDirectory,
                                                   includingPropertiesForKeys: nil) {
            for file in files { try? fm.removeItem(at: file) }
        }
        FileIndex.removeAll()
        if let episodes = try? context.fetch(FetchDescriptor<Episode>()) {
            for episode in episodes {
                episode.localFilename = nil
                episode.extractedAudioFilename = nil
            }
        }
        LibraryTotals.shared.invalidate()
        try? context.save()
    }

    /// Work through everything queued that hasn't been processed yet.
    func processPending(limit: Int = 5) async {
        guard let context = modelContext else { return }
        // Note: SwiftData predicates are unreliable with enum comparisons,
        // so we fetch the queue and filter in memory instead.
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.isInQueue },
            sortBy: [SortDescriptor(\.queueOrder)]
        )
        guard let queued = try? context.fetch(descriptor) else { return }
        let pending = Array(queued.filter { $0.processingState != .ready }.prefix(limit))
        for (index, episode) in pending.enumerated() {
            queueRemaining = pending.count - index - 1
            await process(episode)
        }
        queueRemaining = 0
    }

    // MARK: - Reusing a transcript

    /// The transcript already stored on this episode, if it is complete enough
    /// to trust.
    ///
    /// "Complete enough" means it reaches the end of the audio. A transcript
    /// that stops at eleven minutes of a fifty-minute episode is the wreckage
    /// of a run that was killed part way, and reusing it would silently mean
    /// no ads are ever found in the other thirty-nine minutes. When the
    /// episode's duration is unknown — some feeds simply don't say — a
    /// transcript with real content in it is taken at face value, because the
    /// alternative is re-transcribing an hour of audio every single time.
    private static func reusableTranscript(for episode: Episode) -> [TranscriptSegment]? {
        let lines = episode.timedTranscript
        guard lines.count >= 10, let last = lines.last else { return nil }

        if episode.duration > 0 {
            // Generous: the tail of an episode is often music or silence and
            // produces no words at all, so demanding the last second would
            // reject perfectly good transcripts.
            let shortfall = episode.duration - last.end
            guard shortfall <= max(60, episode.duration * 0.08) else { return nil }
        }

        return lines.map { TranscriptSegment(text: $0.text, start: $0.start, end: $0.end, words: $0.words ?? []) }
    }

    // MARK: - Download

    /// Makes sure an episode's audio is on disk, downloading it if it is not.
    ///
    /// Publishing needs the file — it has to cut the ads out of something —
    /// and it used to `continue` silently past any episode whose audio had been
    /// deleted to save space. The result was a Publish that reported success
    /// and quietly published nothing, which is the most confusing possible
    /// outcome.
    ///
    /// It does not touch the transcript or the detection: an episode that is
    /// already `.ready` stays ready.
    @discardableResult
    func ensureDownloaded(_ episode: Episode) async -> Bool {
        if let url = episode.localFileURL,
           FileManager.default.fileExists(atPath: url.path) { return true }
        guard let filename = try? await download(episode) else { return false }
        episode.localFilename = filename
        FileIndex.insert(filename)
        try? modelContext?.save()
        return true
    }

    private static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 3
        return URLSession(configuration: config)
    }()

    private func download(_ episode: Episode) async throws -> String {
        guard let url = URL(string: episode.audioURL) else {
            throw URLError(.badURL)
        }
        // No connection: wait for one instead of failing the job. A download
        // that loses signal part-way also waits (`waitsForConnectivity`)
        // rather than erroring at once.
        if NetworkStatus.shared.isOffline {
            waitingForConnection = true
            await NetworkStatus.shared.waitUntilOnline()
            waitingForConnection = false
            try Task.checkCancellation()
        }
        let (tempURL, response) = try await Self.downloadSession.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        // Keep the original extension; AVAudioFile cares.
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let filename = "\(UUID().uuidString).\(ext)"
        let destination = FileStore.episodesDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return filename
    }

    // MARK: - Background scheduling

    /// Register at launch. iOS decides when to actually run this — typically
    /// overnight while charging on Wi-Fi, which is exactly when you want an
    /// hour of transcription happening.
    static func registerBackgroundTask(handler: @escaping @Sendable () async -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            let work = Task {
                await handler()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = {
                work.cancel()
                task.setTaskCompleted(success: false)
            }
            scheduleNext()
        }
    }

    /// Checking feeds for new episodes, on the system's schedule. A short
    /// task — iOS allows about thirty seconds — so it only fetches and
    /// merges; finding ads is the processing task's job.
    static let refreshTaskID = "com.yourname.podskipper.refresh"

    static func registerRefreshTask(handler: @escaping @Sendable () async -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            scheduleRefresh()
            let work = Task {
                await handler()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = {
                work.cancel()
                task.setTaskCompleted(success: false)
            }
        }
    }

    /// Asks for the next check in about two hours. iOS decides when it
    /// actually runs, learning from when the app is used.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 2 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// `soon` drops the fifteen-minute floor and the power requirement. Used
    /// when the app is backgrounded with a job already in flight — the work
    /// was already started deliberately, so waiting for the overnight window
    /// would just look like the app had stopped.
    static func scheduleNext(requiresPower: Bool = true, soon: Bool = false) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundTaskID)
        let request = BGProcessingTaskRequest(identifier: backgroundTaskID)
        request.requiresNetworkConnectivity = true   // downloads
        request.requiresExternalPower = soon ? false : requiresPower
        let earliest: Date? = soon ? nil : Date(timeIntervalSinceNow: 15 * 60)
        request.earliestBeginDate = earliest
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Passes progress to the screen a few times a second at most.
///
/// The transcriber and the analyser report after every buffer — hundreds of
/// times a second — and each report was its own hop onto the main thread and
/// its own redraw of every view showing the bar. Four a second looks the same
/// and leaves the main thread free to scroll.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastValue = -1.0
    private var lastTime = 0.0
    private let apply: @MainActor (Double) -> Void

    init(_ apply: @escaping @MainActor (Double) -> Void) { self.apply = apply }

    func report(_ value: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        let send: Bool = lock.withLock {
            let finished = value >= 1 && lastValue < 1
            guard finished || (now - lastTime >= 0.25 && abs(value - lastValue) >= 0.003) else { return false }
            lastTime = now
            lastValue = value
            return true
        }
        guard send else { return }
        let apply = self.apply
        Task { @MainActor in apply(value) }
    }
}
