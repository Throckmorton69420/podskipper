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
    var stage: Stage = .idle { didSet { if stage != oldValue { stageStartedAt = .now; noteProgress() } } }
    var stageFraction: Double = 0 { didSet { if stageFraction != oldValue { noteProgress() } } }
    var isRunning = false

    /// True when this episode is the one currently being processed.
    func isProcessing(_ episode: Episode) -> Bool {
        isRunning && currentEpisodeGUID == episode.guid
    }

    // MARK: - Who started it, and whether it is moving (pass 19)

    /// Who asked for the job running now. His rule (23 Sep): a job he starts
    /// finishes, in the background if the screen locks; nothing heavy starts
    /// in the background on its own. It is also Apple's rule for continued
    /// processing, which is only for work a person started with a tap.
    enum Origin: String { case user, automatic }
    private(set) var currentOrigin: Origin?

    /// Set when a job has made no progress for `stallLimit` with the app
    /// open. The row, the banner and the status sheet then say so and offer
    /// Restart, which keeps the transcript and every answer so far.
    var stalledSince: Date?
    static let stallLimit: TimeInterval = 120

    /// Jobs he started that have not finished — paused by iOS, or cut off by
    /// the app being closed. Kept across launches; each one resumes from its
    /// transcript and saved answers as soon as the app is open.
    private(set) var unfinishedJobs: [String] = UserDefaults.standard.stringArray(forKey: "unfinishedUserJobs") ?? []

    @ObservationIgnored private var currentJob: Task<Void, Never>?
    /// Which job owns the shared state. A job abandoned by Restart can still
    /// be winding down; it must not clear the state of the one that replaced it.
    @ObservationIgnored private var jobToken = UUID()
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var lastProgressAt = Date()
    /// The answers being given for the episode being worked on, so they can
    /// be written to disk the moment the app leaves the screen.
    @ObservationIgnored private var activeCheckpoint: DetectionCheckpoint?

    private func noteProgress() {
        lastProgressAt = .now
        if stalledSince != nil { stalledSince = nil }
    }

    private func setUnfinished(_ guid: String, _ on: Bool) {
        var list = unfinishedJobs.filter { $0 != guid }
        if on { list.append(guid) }
        guard list != unfinishedJobs else { return }
        unfinishedJobs = list
        UserDefaults.standard.set(list, forKey: "unfinishedUserJobs")
    }

    /// A job of his that stopped part way and isn't running now.
    func isPaused(_ episode: Episode) -> Bool {
        unfinishedJobs.contains(episode.guid) && !isProcessing(episode) && episode.processingState != .ready
    }

    /// Minutes without progress, for "No progress for 3 min".
    var stalledMinutes: Int? {
        guard let stalledSince else { return nil }
        return max(2, Int(Date().timeIntervalSince(stalledSince) / 60))
    }

    /// How many episodes are left in this batch, not counting the current one.
    var queueRemaining = 0

    private var jobStartedAt: Date?

    /// Speculative work for autoplay, held so it can be cancelled the moment
    /// someone asks for something real.
    private var backgroundJob: Task<Void, Never>?

    /// Expected seconds for each step of the job running now. Reported
    /// (23 Sep, more than once): the bar raced through transcription and then
    /// sat for most of the job on "Finding ads" — the weights were fixed and
    /// had transcription as the longest step. His phone's timing log says the
    /// opposite: per hour of audio, transcribing ≈ 75 s and finding ads
    /// ≈ 350 s. A step with nothing to do (the transcript or the download is
    /// already there) now weighs nothing.
    private(set) var stagePlan: [Stage: Double] = [:]
    private var stageStartedAt: Date?

    static func plan(for episode: Episode) -> [Stage: Double] {
        let hours = max(0.1, episode.duration / 3600)
        return [
            .downloading: episode.isDownloaded ? 0 : 25 * hours,
            .transcribing: episode.hasTranscript ? 0 : 75 * hours,
            .detecting: 350 * hours,
            .analyzing: 6 * hours,
            .saving: 2,
        ]
    }

    private func planned(_ stage: Stage) -> Double {
        stagePlan.isEmpty ? stage.weight * 600 : (stagePlan[stage] ?? 0)
    }

    /// Weighted by the time each step is expected to take for this episode.
    var overallFraction: Double {
        guard stage != .idle else { return 0 }
        let total = Stage.ordered.reduce(0) { $0 + planned($1) }
        guard total > 0 else { return 0 }
        let done = Stage.ordered.prefix(while: { $0 != stage }).reduce(0) { $0 + planned($1) }
        return min(1, (done + planned(stage) * stageFraction) / total)
    }

    /// Time left: the rest of this step at the pace it is going (or as
    /// planned, early on), plus the steps still to come as planned.
    var etaSeconds: Double? {
        guard isRunning, stage != .idle else { return nil }
        var current = planned(stage) * (1 - stageFraction)
        if let started = stageStartedAt, stageFraction > 0.08 {
            let elapsed = Date().timeIntervalSince(started)
            current = elapsed / stageFraction * (1 - stageFraction)
        }
        let later = Stage.ordered.drop(while: { $0 != stage }).dropFirst().reduce(0) { $0 + planned($1) }
        let eta = current + later
        return eta > 1 ? eta : nil
    }

    var stageDescription: String? { stage == .idle ? nil : stage.label }

    enum Stage: Hashable {
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
        AdDetector.inBackground = true
        // Written now, not every eighth answer: iOS may end the app while
        // it is away, and every answer on disk is one not asked again.
        activeCheckpoint?.save()
        stopMaintenance()
        let percent = Int(overallFraction * 100)
        // Work the app gave itself (getting Up Next ready) does not carry on
        // in the background unless something is playing — the app is awake
        // for the audio then anyway, and the next episode needs it. Otherwise
        // it stops cleanly here, keeping its transcript and answers, and
        // starts again when he is back.
        if isRunning, currentOrigin == .automatic, !PlayerEngine.shared.isPlaying {
            BackgroundLog.shared.note("Left the app: automatic job stopped at \(stage.label) \(percent)% (resumes when you're back)")
            cancelCurrentJob()
            cancelBackgroundWork()
        }
        guard isRunning || !unfinishedJobs.isEmpty else { return }
        if isRunning {
            wasBackgrounded = true
            BackgroundLog.shared.note("Left the app with \(currentOrigin == .user ? "your" : "an automatic") job running: \(stage.label) \(percent)%")
        }
        // A job he started: if iOS pauses it, the processing window picks it
        // up again as soon as the system is willing, plugged in or not.
        if currentOrigin == .user || !unfinishedJobs.isEmpty {
            Self.scheduleNext(soon: true)
        }
    }

    func applicationWillEnterForeground() {
        AdDetector.inBackground = false
        // Time away doesn't count towards "no progress".
        lastProgressAt = .now
        if wasBackgrounded {
            let limited = JobHeartbeat.shared.takeRateLimited()
            BackgroundLog.shared.note("Back in the app: " + (isRunning ? "\(stage.label) \(Int(overallFraction * 100))%" : "no job running")
                                      + (limited > 0 ? " · iOS made the model wait \(limited)×" : ""))
        }
        wasBackgrounded = false
        // His job, still going: ask again to be allowed to carry on after
        // the next time he leaves (the last permission may have ended).
        if isRunning, currentOrigin == .user { BackgroundWork.shared.workStarted() }
        resumeUnfinished()
    }

    // MARK: - Public entry points

    /// Process one episode end to end.
    ///
    /// One job at a time. Find Ads Again used to call straight in here and
    /// run beside a job already going — the one iOS had paused, or the one
    /// the processing window had started — so two jobs shared one progress
    /// bar, one model and one answer cache, and the second sat at 0 % on
    /// step 3 (his report, 23 Sep). Now a second call waits its turn.
    func process(_ episode: Episode, origin: Origin = .automatic) async {
        guard modelContext != nil, settings != nil else { return }
        let guid = episode.guid
        let queued = waitingQueue.contains(guid)
        // His jobs go in the order he asked for them; the app's own wait
        // until his line is empty.
        while isRunning || (queued ? waitingQueue.first != guid : !waitingQueue.isEmpty) {
            if Task.isCancelled { return }
            if queued && !waitingQueue.contains(guid) { return }   // taken out of the line
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard !Task.isCancelled else {
            if queued { waitingQueue.removeAll { $0 == guid } }
            return
        }
        // Claimed before anything is awaited, so a second caller woken in
        // the same moment sees the slot taken.
        let token = UUID()
        jobToken = token
        stopMaintenance()
        isRunning = true
        currentOrigin = origin
        currentEpisodeTitle = episode.title
        currentEpisodeGUID = episode.guid
        currentEpisode = episode
        waitingQueue.removeAll { $0 == guid }
        stagePlan = Self.plan(for: episode)
        jobStartedAt = Date()
        lastProgressAt = .now
        stalledSince = nil
        beginAssertion()
        if origin == .user {
            setUnfinished(episode.guid, true)
            BackgroundWork.shared.workStarted()
        }
        BackgroundLog.shared.note("Started (\(origin == .user ? "you" : "automatic")): \(episode.title)")
        startWatchdog(token)
        let job = Task { @MainActor [weak self] () -> Void in
            guard let self else { return }
            await self.run(episode, origin: origin, token: token)
        }
        currentJob = job
        await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            job.cancel()
        }
    }

    /// Screenshot runs only: a job that has stopped moving, or one iOS
    /// paused, drawn without running anything (the demo library has no audio).
    func simulateForScreenshots(stalled episode: Episode) {
        guard DemoData.isEnabled else { return }
        isRunning = true
        currentOrigin = .user
        currentEpisodeTitle = episode.title
        currentEpisodeGUID = episode.guid
        currentEpisode = episode
        stage = .detecting
        stageFraction = 0.02
        jobStartedAt = Date().addingTimeInterval(-600)
        stalledSince = Date().addingTimeInterval(-180)
    }

    func simulateForScreenshots(paused episode: Episode) {
        guard DemoData.isEnabled else { return }
        unfinishedJobs = [episode.guid]
    }

    /// Writes the answers given so far to disk (iOS is about to pause the app).
    func saveCheckpointNow() {
        activeCheckpoint?.save()
    }

    /// Stops the job running now at its next step. Its transcript and its
    /// answers so far are kept.
    func cancelCurrentJob() {
        activeCheckpoint?.save()
        currentJob?.cancel()
    }

    /// Restart, for a job that stopped moving: the old one is cancelled and,
    /// if it doesn't wind down within a few seconds (a call that never
    /// returns), abandoned — it can no longer touch the progress bar. The new
    /// one keeps the transcript and every answer already saved.
    func restart(_ episode: Episode) async {
        BackgroundLog.shared.note("Restarted by you at \(stage.label) \(Int(overallFraction * 100))%")
        if isProcessing(episode) {
            cancelCurrentJob()
            let deadline = Date().addingTimeInterval(6)
            while isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
            if isRunning { endJob(jobToken, abandoned: true) }
            // A restart goes back to the front of the line, not the end.
            if !waitingQueue.contains(episode.guid) {
                waitingQueue.insert(episode.guid, at: 0)
                batchTotal += 1
                await process(episode, origin: .user)
                return
            }
        }
        await processNow(episode)
    }

    /// Picks up his jobs that stopped part way, one after another, when the
    /// app is open (or in the system's processing window).
    func resumeUnfinished(inBackground: Bool = false) {
        guard !isRunning, waitingQueue.isEmpty, !DemoData.isEnabled, let context = modelContext,
              inBackground || UIApplication.shared.applicationState != .background else { return }
        for guid in unfinishedJobs where !waitingQueue.contains(guid) {
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
            descriptor.fetchLimit = 1
            guard let episode = try? context.fetch(descriptor).first, episode.processingState != .ready else {
                setUnfinished(guid, false)
                continue
            }
            BackgroundLog.shared.note("Resuming your job: \(episode.title)")
            // Marked before the task starts, so a second call in the same
            // moment doesn't start it twice. All of them join the line at once, in the order he started them.
            enqueue(guid)
            Task { await self.process(episode, origin: .user) }
        }
    }

    /// Every fifteen seconds while a job runs: has anything moved? Only with
    /// the app on screen — in the background iOS sets the pace.
    private func startWatchdog(_ token: UUID) {
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, self.jobToken == token, self.isRunning else { return }
                guard UIApplication.shared.applicationState == .active, !self.waitingForConnection else {
                    self.lastProgressAt = .now
                    continue
                }
                let last = max(self.lastProgressAt, JobHeartbeat.shared.last)
                if Date().timeIntervalSince(last) > Self.stallLimit, self.stalledSince == nil {
                    self.stalledSince = last
                    BackgroundLog.shared.note("No progress for 2 min at \(self.stage.label) \(Int(self.overallFraction * 100))% — offered Restart")
                }
            }
        }
    }

    /// Clears the shared state when a job ends — only if it is still this
    /// job's.
    private func endJob(_ token: UUID, abandoned: Bool = false) {
        guard jobToken == token else { return }
        if abandoned { jobToken = UUID() }
        if currentOrigin == .user { batchDone = min(batchTotal, batchDone + 1) }
        isRunning = false
        currentOrigin = nil
        currentEpisodeTitle = nil
        currentEpisodeGUID = nil
        currentEpisode = nil
        stage = .idle
        stageFraction = 0
        stalledSince = nil
        jobStartedAt = nil
        currentJob = nil
        watchdog?.cancel()
        watchdog = nil
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
        // The next of his paused jobs, if any.
        Task { @MainActor [weak self] in self?.resumeUnfinished() }
    }

    /// The job itself, run in its own task so it can be cancelled.
    private func run(_ episode: Episode, origin: Origin, token: UUID) async {
        guard let context = modelContext, let settings else { endJob(token); return }
        defer { endJob(token) }

        do {
            // Find Ads Again on an episode whose audio has since been
            // removed: the transcript and everything measured from the audio
            // are stored, so only the ad finding runs again (his rule: a
            // finished transcript is never redone). Episodes fingerprinted
            // before pass 18 have no stored measurements and download.
            let hasAudio = episode.localFileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            if !hasAudio, episode.producedSpansData != nil, let reusable = await Self.reusableTranscript(for: episode) {
                stage = .transcribing
                stageFraction = 1
                let seconds = try await detectAndSave(episode, segments: reusable, silences: episode.silenceRanges,
                                                      inserted: episode.insertedSpans, produced: episode.producedSpans,
                                                      context: context, settings: settings)
                finished(episode, origin: origin, audioSeconds: reusable.last?.end ?? episode.duration,
                         transcribe: nil, analyze: nil, detect: seconds, thermalAtStart: Diagnostics.thermalName,
                         adFree: nil, context: context)
                return
            }

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

            // The ad-free comparison (pass 17) only needs the download, and
            // its first answer can take a while (Simplecast prepares the
            // stored file on first request), so it runs alongside
            // transcription and is waited for just before the ads are found.
            // Audio MP3s only: the original download, not an extracted track.
            let adFreeJob: Task<AdFreeCopy.Outcome, Never>? = settings.useAdFreeCopy && !episode.isVideo
                ? Task { [enclosure = episode.audioURL, feed = episode.podcast?.feedURL ?? "",
                          show = episode.podcast?.title ?? "", title = episode.title] in
                    await AdFreeCopy.compare(fileURL: mediaURL, enclosure: enclosure, feedURL: feed,
                                             showTitle: show, episodeTitle: title)
                  }
                : nil
            defer { adFreeJob?.cancel() }

            // 4b. Audio that plays again (pass 18, research stage 2): this
            // episode's fingerprints against the show's last two episodes and
            // itself — themes, promos, produced ads, reads used twice — found
            // exactly with no model. About five seconds of one core an hour,
            // off the main thread, alongside transcription.
            let showKey = episode.podcast?.feedURL ?? episode.podcast?.title ?? ""
            let printJob: Task<[AdPrints.Produced], Never> = Task.detached(priority: .utility) {
                [guid = episode.guid, fileURL] in
                guard let landmarks = try? AdPrints.landmarks(fileURL: fileURL) else { return [] }
                let previous = AdPrints.previous(show: showKey, excluding: guid)
                var found = AdPrints.produced(in: landmarks, previous: previous)
                // And against the recordings known from every show (pass 19):
                // a spot learned on one show is found by its sound on another.
                found += AdPrints.Library.matches(in: landmarks, excludingSource: guid).map {
                    AdPrints.Produced(start: $0.start, end: $0.end, acrossEpisodes: true,
                                      known: $0.negative ? nil : $0.kind, negative: $0.negative)
                }
                AdPrints.remember(landmarks, show: showKey, guid: guid)
                return found.sorted { $0.start < $1.start }
            }
            defer { printJob.cancel() }

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

            // For Settings → Diagnostics: seconds per stage on this phone.
            let thermalAtStart = Diagnostics.thermalName
            var transcribeSeconds: Double?
            var analyzeSeconds: Double?

            let segments: [TranscriptSegment]
            var reusedTranscript = false
            if let reusable = await Self.reusableTranscript(for: episode) {
                segments = reusable
                reusedTranscript = true
                stageFraction = 1
            } else {
                let throttle = ProgressThrottle { [weak self] p in self?.stageFraction = p }
                let timer = Diagnostics.Interval.begin("Transcribe")
                segments = try await transcriber.transcribe(fileURL: fileURL) { throttle.report($0) }
                transcribeSeconds = timer.end()
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
            // Measured already on an earlier run of this same file: the
            // pauses don't change, so Find Ads Again doesn't read every
            // sample again.
            let stored = reusedTranscript ? episode.silenceRanges : []
            if !stored.isEmpty {
                silences = stored
            } else if settings.analyzeSilence {
                episode.processingState = .analyzing
                stage = .analyzing
                stageFraction = 0
                // Off the main thread. This reads every sample of the file and
                // used to run right here on the main actor, which is most of
                // why scrolling stuttered while ads were being found.
                let throttle = ProgressThrottle { [weak self] p in self?.stageFraction = p }
                let timer = Diagnostics.Interval.begin("Analyze")
                let analysis = await Task.detached(priority: .utility) {
                    try? AudioAnalyzer.analyze(fileURL: fileURL, progress: { throttle.report($0) })
                }.value
                analyzeSeconds = timer.end()
                if let analysis {
                    silences = analysis.silences
                    episode.storeSilence(analysis.silences)
                    episode.normalizationGain = analysis.normalizationGain
                }
                stageFraction = 1
            }

            // 4. The ad-free copy (pass 17, decision 2): where the host
            // stitched ads into this download, to the frame, with no model.
            // Audio MP3s only; the original download, not an extracted track.
            var inserted: [InsertedSpan] = []
            var adFree: AdFreeCopy.Outcome?
            if let adFreeJob {
                episode.processingState = .detecting
                stage = .detecting
                stageFraction = 0
                // Waited for at most two minutes from here. It asks a server
                // about a hundred small questions; on a bad connection that
                // could hold the job at 0 % indefinitely, and the ads are
                // still found without it (by the fingerprints and the model).
                let waitStarted = Date()
                let outcome = await withTaskGroup(of: AdFreeCopy.Outcome?.self) { group in
                    group.addTask { await adFreeJob.value }
                    // Ends the comparison after two minutes, or at once if
                    // this job is cancelled (awaiting a task's value doesn't
                    // stop by itself).
                    group.addTask {
                        try? await Task.sleep(for: .seconds(120))
                        adFreeJob.cancel()
                        return nil
                    }
                    var result: AdFreeCopy.Outcome?
                    for await value in group {
                        if let value { result = value; group.cancelAll() }
                    }
                    return result ?? AdFreeCopy.Outcome()
                }
                if Date().timeIntervalSince(waitStarted) > 119, outcome.inserted.isEmpty {
                    BackgroundLog.shared.note("Ad-free comparison took over 2 min; carried on without it")
                }
                adFree = outcome
                inserted = outcome.inserted
                episode.insertedSpansData = try? JSONEncoder().encode(inserted)
            }
            let produced = await printJob.value
            episode.producedSpansData = try? JSONEncoder().encode(produced)

            // 5. Classify and save.
            try Task.checkCancellation()
            let detectSeconds = try await detectAndSave(episode, segments: segments, silences: silences,
                                                        inserted: inserted, produced: produced,
                                                        context: context, settings: settings)
            finished(episode, origin: origin, audioSeconds: segments.last?.end ?? episode.duration,
                     transcribe: transcribeSeconds, analyze: analyzeSeconds, detect: detectSeconds,
                     thermalAtStart: thermalAtStart, adFree: adFree, context: context)

        } catch let error where error is CancellationError || Task.isCancelled {
            // Stepped aside for a job someone asked for, or paused. Not a
            // failure: the transcript, if it got that far, is already saved,
            // and so are the answers; both are reused.
            episode.processingState = .notStarted
            try? context.save()
            BackgroundLog.shared.note("Stopped part way (kept for next time): \(episode.title)")
        } catch {
            episode.processingState = .failed
            episode.processingError = error.localizedDescription
            CountsCache.invalidate(episode.podcast)
            try? context.save()
            setUnfinished(episode.guid, false)
            BackgroundLog.shared.note("Failed: \(error.localizedDescription)")
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

    /// What follows a job that went through: its timing for Diagnostics,
    /// skipping in the episode playing now, publishing if the show does.
    private func finished(_ episode: Episode, origin: Origin, audioSeconds: Double,
                          transcribe: Double?, analyze: Double?, detect: Double,
                          thermalAtStart: String, adFree: AdFreeCopy.Outcome?, context: ModelContext) {
        setUnfinished(episode.guid, false)
        Self.learnPrints(from: episode)
        let foreground = UIApplication.shared.applicationState == .active
        BackgroundLog.shared.note("Finished \(foreground ? "on screen" : "in the background"): \(episode.title)")
        let battery = UIDevice.current.batteryState
        TimingLog.shared.record(ProcessingTiming(
            date: .now,
            show: episode.podcast?.title ?? "",
            episode: episode.title,
            audioSeconds: audioSeconds,
            transcribeSeconds: transcribe,
            analyzeSeconds: analyze,
            detectSeconds: detect,
            thermalAtStart: thermalAtStart,
            thermalAtEnd: Diagnostics.thermalName,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            onPower: battery == .charging || battery == .full,
            foreground: foreground,
            device: Diagnostics.deviceModel,
            build: BuildInfo.commit,
            adFree: adFree,
            detectorVersion: AdDetector.version,
            relabel: false,
            stitchedSeconds: episode.cleanDuration > 0 ? max(0, audioSeconds - episode.cleanDuration) : nil,
            cutSeconds: episode.adSegments.filter { $0.userVerdict != .notAnAd }.reduce(0) { $0 + $1.duration }))

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
        // Finished while he was away: say so, as Apple's own apps do for a
        // long job, and let the tap land on it.
        if origin == .user, !foreground {
            Task {
                await NotificationService.notifyJobProblem(
                    episode, title: "Ads found",
                    body: "\(episode.title) is ready to play without them.")
            }
        }
    }

    /// Teaches the cross-show library (`AdPrints.Library`) the recordings in
    /// this episode that are certainly ads or promos: stitched in at download
    /// (found by the ad-free comparison), or produced repeats the model called
    /// an ad or a promotion. Off the main thread; the episode's fingerprints
    /// are the ones kept for the show's next episode.
    nonisolated static func learnPrints(from episode: Episode) {
        let show = episode.podcast?.feedURL ?? episode.podcast?.title ?? ""
        let guid = episode.guid
        let certain = episode.adSegments.compactMap { s -> (Double, Double, String)? in
            guard s.userVerdict != .notAnAd, [.ad, .crossPromo].contains(s.kind),
                  s.insertedAtDownload || s.evidenceText.contains(SegmentEvidence.repeatedAudio.rawValue) else { return nil }
            return (s.start, s.end, s.kind.rawValue)
        }
        guard !certain.isEmpty else { return }
        Task.detached(priority: .background) {
            guard let landmarks = AdPrints.stored(show: show, guid: guid) else { return }
            for (start, end, kind) in certain {
                AdPrints.Library.add(landmarks.slice(start...end), show: show, source: guid, kind: kind)
            }
        }
    }

    /// His verdict on a cut, into the library: a confirmed ad is learned as
    /// one; "not an ad" is kept as a negative, so that recording is never cut
    /// by fingerprint again. Only while the episode's fingerprints are still
    /// kept (the show's last three episodes).
    nonisolated static func learnVerdict(_ verdict: UserVerdict, on segment: AdSegment, in episode: Episode) {
        guard verdict != .unreviewed, segment.end - segment.start >= 8 else { return }
        let show = episode.podcast?.feedURL ?? episode.podcast?.title ?? ""
        let guid = episode.guid, range = segment.start...segment.end
        let kind = segment.kind.rawValue, negative = verdict == .notAnAd
        Task.detached(priority: .background) {
            guard let landmarks = AdPrints.stored(show: show, guid: guid) else { return }
            AdPrints.Library.add(landmarks.slice(range), show: show, source: guid, kind: kind, negative: negative)
        }
    }

    /// Finding the ads in a transcript already in hand, and saving them.
    /// Shared by a full job and by a re-label (D22), which skips the
    /// download and the transcription. Returns the seconds it took.
    ///
    /// Anything the listener has had a say in — rejected, confirmed, edited,
    /// added or locked — is kept exactly as they left it, and a new finding
    /// over the same stretch is not made. Only cuts nobody has touched are
    /// replaced.
    private func detectAndSave(_ episode: Episode, segments: [TranscriptSegment],
                               silences: [ClosedRange<Double>], inserted: [InsertedSpan],
                               produced: [AdPrints.Produced] = [],
                               context: ModelContext, settings: AppSettings,
                               quiet: Bool = false) async throws -> Double {
        // A quiet re-label shows nothing: no progress bar, no "Finding ads"
        // on the row. The episode stays ready throughout.
        if !quiet {
            episode.processingState = .detecting
            stage = .detecting
            stageFraction = 0
        }
        let known = episode.podcast?.knownSponsors ?? []
        // Every thumbs-up and thumbs-down the listener has given on this
        // show, handed to the model as worked examples.
        let corrections = episode.podcast?.corrections ?? []
        let detectThrottle = ProgressThrottle { [weak self] p in if !quiet { self?.stageFraction = p } }
        // SponsorBlock's labels for this episode's YouTube upload, when
        // there is one: places to read closely, never cuts in themselves.
        var hints: [ClosedRange<Double>] = []
        if !quiet, let show = episode.podcast, !show.youtubeChannel.isEmpty {
            let videos = await YouTubeLink.recentVideos(channelID: show.youtubeChannel)
            if let video = YouTubeLink.match(episodeTitle: episode.title, episodeNumber: episode.episodeNumber,
                                             isBonus: episode.isBonus, showTitle: show.title,
                                             published: episode.publishedAt, in: videos) {
                episode.youtubeVideoID = video.id
                if episode.videoSourceRaw.isEmpty { episode.videoSourceRaw = VideoSourceResolver.Source.youtube.rawValue }
                let labels = await SponsorBlockHints.labels(videoID: video.id)
                hints = SponsorBlockHints.hints(labels, audioDuration: episode.duration, videoDuration: video.duration)
            }
        }
        // Answers already given for this episode, if an earlier run was
        // stopped part way (the screen locked, the phone got warm): reused
        // rather than asked again. See `DetectionCheckpoint`.
        //
        // Always this episode's own answers. It used to be skipped when
        // another job still held the shared cache — the job iOS had paused —
        // so the new one saved nothing, and the old one cleared the cache
        // from under it when it ended. Now each job installs its own, and
        // only the job that installed it takes it away.
        let checkpoint = DetectionCheckpoint(guid: episode.guid)
        let owner = UUID()
        AdDetector.replyCache = checkpoint.cache
        cacheOwner = owner
        if !quiet { activeCheckpoint = checkpoint }
        var done = false
        defer {
            if !done { checkpoint.save() }
            if cacheOwner == owner {
                AdDetector.replyCache = nil
                cacheOwner = nil
            }
            if activeCheckpoint === checkpoint { activeCheckpoint = nil }
        }
        let detectTimer = Diagnostics.Interval.begin("Detect")
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
            padding: settings.boundaryPadding,
            hints: hints,
            inserted: inserted.map { $0.start...$0.end },
            produced: produced
        ) { [detectThrottle] p in detectThrottle.report(p) }
        // A cancelled job's model calls come back empty; what it found is
        // not a result and must not replace the cuts already saved.
        try Task.checkCancellation()
        let ads = detection.segments

        // What this show advertises carries forward.
        if let show = episode.podcast, !detection.sponsors.isEmpty {
            var merged = Set(show.knownSponsors)
            merged.formUnion(detection.sponsors)
            show.knownSponsors = Array(merged).sorted().suffix(40).map { $0 }
        }

        if !quiet { stage = .saving; stageFraction = 0.5 }
        let kept = episode.adSegments.filter { $0.isReviewed }
        for old in episode.adSegments where !old.isReviewed {
            context.delete(old)
        }
        for (index, ad) in ads.enumerated() {
            let overlapsRejected = kept.contains { $0.start < ad.end && $0.end > ad.start }
            guard !overlapsRejected else { continue }
            let segment = AdSegment(start: ad.start, end: ad.end,
                                    sponsor: ad.sponsor, confidence: ad.confidence,
                                    kind: ad.kind)
            segment.startConfidence = ad.startConfidence
            segment.endConfidence = ad.endConfidence
            segment.evidenceText = ad.evidence.joined(separator: " · ")
            segment.insertedAtDownload = ad.insertedAtDownload
            segment.detailRaw = ad.detail
            // How it was delivered, for the keep-host-read and keep-funny-read
            // switches. Asked of every ad now, whatever the switches say
            // (D14): with "keep funny reads" on by default the answer
            // matters, and asking later would mean running the model again.
            if ad.kind == .ad {
                if !quiet { stageFraction = 0.5 + 0.4 * Double(index) / Double(max(1, ads.count)) }
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
        episode.detectorVersion = AdDetector.version
        CountsCache.invalidate(episode.podcast)
        LibraryTotals.shared.invalidate()
        try? context.save()
        done = true
        checkpoint.discard()
        return detectTimer.end()
    }

    // MARK: - Keeping processed episodes current (D14, D22)

    /// The maintenance loop, held so a job someone asks for can stop it.
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    /// Which call to `detectAndSave` installed `AdDetector.replyCache`.
    @ObservationIgnored private var cacheOwner: UUID?

    /// Whether heavy background re-labelling may run now: plugged in (when
    /// the "only while charging" setting is on), not in Low Power Mode, and
    /// not already warm.
    private func mayMaintain() -> Bool {
        guard let settings, !DemoData.isEnabled else { return false }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        if [.serious, .critical].contains(ProcessInfo.processInfo.thermalState) { return false }
        if settings.processOnlyWhileCharging {
            let battery = UIDevice.current.batteryState
            guard battery == .charging || battery == .full else { return false }
        }
        return true
    }

    /// Re-labels, from their stored transcripts, the episodes whose cuts an
    /// older ad finder made (D22): newest first, one at a time, and only
    /// while nothing else is running. Never downloads or transcribes; cuts
    /// the listener touched are kept by `detectAndSave`.
    func maintain(limit: Int = 25) {
        guard maintenanceTask == nil, !isRunning, backgroundJob == nil, mayMaintain(),
              let context = modelContext, let settings else { return }
        maintenanceTask = Task { [weak self] in
            defer { self?.maintenanceTask = nil }
            let current = AdDetector.version
            for _ in 0..<limit {
                guard let self, !Task.isCancelled, !self.isRunning, self.mayMaintain() else { return }
                var descriptor = FetchDescriptor<Episode>(
                    predicate: #Predicate { $0.lastProcessedAt != nil && $0.detectorVersion < current },
                    sortBy: [SortDescriptor(\.lastProcessedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                guard let episode = try? context.fetch(descriptor).first else { return }
                // Decoded off the main thread, and a pause between episodes,
                // so re-labelling after an update doesn't make scrolling stutter.
                let lines = await episode.loadTranscript()
                guard lines.count >= 10 else {
                    // Nothing to re-label from; don't keep finding it.
                    episode.detectorVersion = current
                    try? context.save()
                    continue
                }
                let segments = lines.map { TranscriptSegment(text: $0.text, start: $0.start, end: $0.end,
                                                             words: $0.words ?? []) }
                // Processed before pass 18: fingerprint it now if its audio
                // is still here (seconds of one core, off the main thread),
                // so the re-label finds the show's repeated recordings too.
                if episode.producedSpansData == nil, let file = episode.analysableFileURL {
                    let showKey = episode.podcast?.feedURL ?? episode.podcast?.title ?? ""
                    let guid = episode.guid
                    let found = await Task.detached(priority: .utility) { () -> [AdPrints.Produced] in
                        guard let landmarks = try? AdPrints.landmarks(fileURL: file) else { return [] }
                        let previous = AdPrints.previous(show: showKey, excluding: guid)
                        AdPrints.remember(landmarks, show: showKey, guid: guid)
                        return AdPrints.produced(in: landmarks, previous: previous)
                    }.value
                    episode.producedSpansData = try? JSONEncoder().encode(found)
                }
                do {
                    let seconds = try await self.detectAndSave(episode, segments: segments,
                                                               silences: episode.silenceRanges,
                                                               inserted: episode.insertedSpans,
                                                               produced: episode.producedSpans,
                                                               context: context, settings: settings, quiet: true)
                    let battery = UIDevice.current.batteryState
                    TimingLog.shared.record(ProcessingTiming(
                        date: .now, show: episode.podcast?.title ?? "", episode: episode.title,
                        audioSeconds: segments.last?.end ?? episode.duration,
                        transcribeSeconds: nil, analyzeSeconds: nil, detectSeconds: seconds,
                        thermalAtStart: Diagnostics.thermalName, thermalAtEnd: Diagnostics.thermalName,
                        lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                        onPower: battery == .charging || battery == .full,
                        foreground: UIApplication.shared.applicationState == .active,
                        device: Diagnostics.deviceModel, build: BuildInfo.commit,
                        adFree: nil, detectorVersion: current, relabel: true))
                    if PlayerEngine.shared.currentEpisode?.guid == episode.guid {
                        PlayerEngine.shared.refreshSkipRanges()
                    }
                } catch {
                    // The model is unavailable or the task was stopped: try
                    // again another time rather than marking it done.
                    return
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The same, waited for: the overnight processing task must not report
    /// itself finished while the work is still going.
    func maintainNow() async {
        maintain()
        await maintenanceTask?.value
    }

    /// Stops re-labelling at once: someone asked for a real job.
    private func stopMaintenance() {
        maintenanceTask?.cancel()
        maintenanceTask = nil
    }

    /// When a keep-funny-reads or keep-host-reads switch is turned on, the
    /// ads in what he is about to hear need to know how they were read. Asks
    /// only for cuts that don't know yet: the one playing and the Up Next
    /// queue. About a second of the model per ad; no charging needed.
    func classifyMissingStyles() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.isInQueue })
        var episodes = (try? context.fetch(descriptor)) ?? []
        if let playing = PlayerEngine.shared.currentEpisode { episodes.insert(playing, at: 0) }
        Task { [weak self] in
            guard let self else { return }
            for episode in episodes.prefix(10) {
                let lines = episode.timedTranscript
                var changed = false
                for segment in episode.adSegments where segment.kind == .ad && segment.deliveryRaw.isEmpty && !segment.isReviewed {
                    let text = lines.filter { $0.start < segment.end && $0.end > segment.start }.map(\.text).joined(separator: " ")
                    guard !text.isEmpty else { continue }
                    let probe = DetectedSegment(start: segment.start, end: segment.end, kind: .ad, sponsor: segment.sponsor, confidence: segment.confidence)
                    if let style = await self.detector.classifyStyle(of: probe, text: text) {
                        segment.deliveryRaw = style.hostRead ? "host" : "produced"
                        segment.isComedyBit = style.comedyBit
                        changed = true
                    }
                }
                if changed {
                    try? context.save()
                    if PlayerEngine.shared.currentEpisode?.guid == episode.guid { PlayerEngine.shared.refreshSkipRanges() }
                }
            }
        }
    }

    /// Process an explicit set of episodes, in order. Used by the batch
    /// selection on the Publish screen.
    func process(_ episodes: [Episode]) async {
        for (index, episode) in episodes.enumerated() {
            queueRemaining = episodes.count - index - 1
            await process(episode, origin: .user)
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
    ///
    /// Every button that finds ads comes here — Find Ads, Find Ads Again,
    /// Try Again, Resume — never straight to `process`. Pressed on a job
    /// that has stopped moving, it restarts it.
    func processNow(_ episode: Episode) async {
        if isProcessing(episode) {
            if stalledSince != nil { await restart(episode) }
            return
        }
        // Pressed again on an episode already waiting: it keeps its place.
        guard !waitingQueue.contains(episode.guid) else { return }
        enqueue(episode.guid)
        cancelBackgroundWork()
        // Work the app gave itself steps aside at once (keeping what it has).
        if isRunning, currentOrigin == .automatic { cancelCurrentJob() }
        await process(episode, origin: .user)
    }

    /// His jobs waiting their turn, first in line first. Reported (23 Sep):
    /// Find Ads on a second episode took the first one's place instead of
    /// joining the line, and the same episode could be queued twice.
    var waitingQueue: [String] = []
    /// Jobs of his finished, and in total, since the line was last empty —
    /// the banner's "2/5".
    private(set) var batchDone = 0
    private(set) var batchTotal = 0

    /// The first episode in line (kept for older callers).
    var waitingToProcess: String? { waitingQueue.first }

    func isWaiting(_ guid: String?) -> Bool {
        guard let guid else { return false }
        return waitingQueue.contains(guid)
    }

    private func enqueue(_ guid: String) {
        if !isRunning && waitingQueue.isEmpty { batchDone = 0; batchTotal = 0 }
        waitingQueue.append(guid)
        batchTotal += 1
    }

    /// Stops his running job for good: it is not picked up again later.
    /// The transcript and answers so far are kept for next time.
    func stopJob(_ episode: Episode) {
        guard isProcessing(episode) else { return }
        setUnfinished(episode.guid, false)
        BackgroundLog.shared.note("Stopped by you at \(stage.label) \(Int(overallFraction * 100))%")
        cancelCurrentJob()
    }

    /// "2 of 5" while one of his jobs runs and more than one was asked for.
    var batchLabel: String? {
        guard isRunning, currentOrigin == .user, batchTotal > 1 else { return nil }
        return "\(min(batchDone + 1, batchTotal)) of \(batchTotal)"
    }

    /// The place in line, counting from 1, of an episode waiting its turn.
    func linePosition(_ guid: String) -> Int? {
        waitingQueue.firstIndex(of: guid).map { $0 + 1 }
    }

    /// Takes an episode out of the line before it starts.
    func cancelWaiting(_ guid: String) {
        guard let index = waitingQueue.firstIndex(of: guid) else { return }
        waitingQueue.remove(at: index)
        batchTotal = max(batchDone, batchTotal - 1)
        setUnfinished(guid, false)
        BackgroundLog.shared.note("Taken out of the line by you")
    }
    /// A download is waiting for the connection to come back.
    var waitingForConnection = false

    /// Why getting episodes ready ahead is waiting, in words, when it is.
    var speculativePausedReason: String?
    private var backgroundJobStartedAt: Date?
    private var backgroundJobID = UUID()

    var hasBackgroundJob: Bool { backgroundJob != nil }

    static var speculativeHoldReason: String? {
        // His rule: nothing heavy starts in the background on its own.
        if UIApplication.shared.applicationState == .background { return "Waiting until you open PodSkipper" }
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

    @ObservationIgnored private var catchUpTask: Task<Void, Never>?

    /// What follows opening the app — checking the feeds, filling in back
    /// catalogues, re-labelling older episodes — one after another, a few
    /// seconds apart, instead of all in the first second, which is exactly
    /// when he starts scrolling. His report after installing e89234b: the
    /// Library stuttered, then settled by itself (pass 19).
    func catchUpAfterOpening(queueNewEpisodes: Bool) {
        catchUpTask?.cancel()
        catchUpTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled else { return }
            if !DemoData.isEnabled, (Self.lastFeedRefresh.map { Date.now.timeIntervalSince($0) >= 30 * 60 } ?? true) {
                _ = await self.refreshAllFeeds(queueNewEpisodes: queueNewEpisodes)
            }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            LibraryIndexStatus.shared.indexCatalogues()
            await LibraryIndexStatus.shared.moveTranscriptsToFiles()
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { return }
            self.maintain()
        }
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
            .map { ($0.persistentModelID, $0.feedURL, $0.title) }
        var freshIDs: [PersistentIdentifier] = []
        var catalogDue: [(PersistentIdentifier, String, String)] = []
        await withTaskGroup(of: (PersistentIdentifier, String, String, ParsedFeed?).self) { group in
            var iterator = shows.makeIterator()
            func addNext() {
                guard let (id, url, title) = iterator.next() else { return }
                group.addTask { (id, url, title, try? await FeedParser.fetch(url)) }
            }
            for _ in 0..<4 { addNext() }
            while let (id, url, title, feed) = await group.next() {
                if let feed {
                    let result = await LibraryIndexStatus.shared.merge(feed, into: id)
                    freshIDs += result.freshIDs
                }
                if only != nil {
                    // One show pulled down: its catalog now.
                    await LibraryIndexStatus.shared.mergeAppleCatalog(into: id, title: feed?.title ?? title,
                                                                      feedURL: url, force: true)
                } else if LibraryIndexStatus.isCatalogDue(feedURL: url) {
                    catalogDue.append((id, feed?.title ?? title, url))
                }
                addNext()
            }
        }
        // Apple's catalog: video streams, clean lengths and episodes older
        // than the feed, daily per show. A few shows per refresh, one at a
        // time with a pause between, after the feeds: on the first run after
        // an update every show was due at once, and thousands of older
        // episodes landing in the library together made scrolling stutter.
        for (id, title, url) in catalogDue.prefix(4) {
            if Task.isCancelled { break }
            await LibraryIndexStatus.shared.mergeAppleCatalog(into: id, title: title, feedURL: url, force: false)
            try? await Task.sleep(for: .seconds(2))
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
    func processPending(limit: Int = 5, origin: Origin = .automatic) async {
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
            guard !Task.isCancelled else { break }
            queueRemaining = pending.count - index - 1
            await process(episode, origin: origin)
        }
        queueRemaining = 0
    }

    /// The system's processing window (the `processing` background task),
    /// which iOS opens when it chooses — soon after he leaves the app with a
    /// job of his running, or overnight.
    ///
    /// First his own job: carried on if it is still going, resumed if iOS
    /// stopped it. Then feeds are checked (light). Anything heavy the app
    /// would start on its own — getting Up Next ready, re-labelling older
    /// episodes — only on a charger (his rule, 23 Sep).
    func backgroundWindow() async {
        let battery = UIDevice.current.batteryState
        let charging = battery == .charging || battery == .full
        BackgroundLog.shared.note("iOS opened a processing window (\(charging ? "charging" : "on battery"))"
                                  + (isRunning ? " — job running" : "") + (unfinishedJobs.isEmpty ? "" : " — \(unfinishedJobs.count) of yours unfinished"))
        func waitForJob() async {
            while isRunning || !waitingQueue.isEmpty {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        await waitForJob()
        resumeUnfinished(inBackground: true)
        await waitForJob()
        guard !Task.isCancelled else { return }
        await refreshFeedsInBackground()
        guard charging, !Task.isCancelled else { return }
        await processPending()
        await maintainNow()
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
    private static func reusableTranscript(for episode: Episode) async -> [TranscriptSegment]? {
        let lines = await episode.loadTranscript()
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
    ///
    /// Otherwise it always waits for a charger: the overnight window only
    /// does heavy work the app started on its own, and that never runs on
    /// battery in the background (his rule, 23 Sep).
    static func scheduleNext(soon: Bool = false) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundTaskID)
        let request = BGProcessingTaskRequest(identifier: backgroundTaskID)
        request.requiresNetworkConnectivity = true   // downloads
        request.requiresExternalPower = !soon
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
