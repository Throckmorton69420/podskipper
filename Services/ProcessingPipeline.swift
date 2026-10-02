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
    @ObservationIgnored private let jobs: ProcessingJobStore
    @ObservationIgnored private let resources: HeavyWorkCoordinator
    /// An injected worker lets queue/relaunch/cancellation tests use disposable
    /// episodes without downloading media or invoking a model.
    typealias Worker = @MainActor (Episode, UUID) async throws -> Void
    @ObservationIgnored private let worker: Worker?

    init(jobs: ProcessingJobStore? = nil, resources: HeavyWorkCoordinator? = nil,
         worker: Worker? = nil) {
        self.jobs = jobs ?? .shared; self.resources = resources ?? .shared; self.worker = worker
    }
    var jobStorageError: String? { jobs.storageError }
    func jobRecord(_ guid: String) -> ProcessingJob? { jobs.record(guid) }
    var failedJobs: [ProcessingJob] {
        jobs.records.values.filter { $0.status == .failed }.sorted { $0.updatedAt > $1.updatedAt }
    }
    func hasOutstandingJob(_ guid: String) -> Bool {
        guard let status = jobs.record(guid)?.status else { return false }
        return [.queued, .running, .interrupted, .paused].contains(status)
    }

    private func selectedEngine() -> ProcessingEngineSelection {
        let engine = settings?.adFinder ?? AdFinderChoice.apple.rawValue
        let modelID = engine == AdFinderChoice.coreAI.rawValue ? CoreAIModelLibrary.shared.selectedID
            : engine == AdFinderChoice.model.rawValue ? ModelStore.shared.selected.id : nil
        let name = engine == AdFinderChoice.coreAI.rawValue ? CoreAIModelLibrary.shared.selectedEntry?.name
            : engine == AdFinderChoice.model.rawValue ? ModelStore.shared.selected.name : nil
        let benchmarkID = engine == AdFinderChoice.coreAI.rawValue ? modelID.map(CoreAIQwen3.benchmarkID(for:)) : modelID
        return ProcessingEngineSelection(engine: engine, modelID: modelID, modelName: name,
                                         enabled: benchmarkID.map { ModelBench.shared.isEnabled($0) } ?? true)
    }

    static var backgroundTaskID: String { BackgroundIDs.process }

    var currentEpisodeTitle: String?
    /// Which episode is being worked on, so a row can draw its own progress
    /// instead of a floating banner telling you only that *something* is
    /// happening.
    var currentEpisodeGUID: String?
    /// The episode itself, for a notification written about it. Not drawn
    /// anywhere, so not observed.
    @ObservationIgnored private(set) var currentEpisode: Episode?
    /// When each step of the job running now started and ended, for the
    /// Activity screen's step list (pass 21b).
    struct StepRecord: Equatable { var started: Date?; var ended: Date? }
    private(set) var steps: [Stage: StepRecord] = [:]
    /// What the ad-free comparison said for the job running now.
    private(set) var adFreeNote: String?
    /// What the on-device model is doing in the job running now (task 05),
    /// for the Activity screen; nil while only the reader is at work.
    enum FinderPhase: Equatable {
        case reading(fast: Bool)
        case retrying(attempt: Int)
        case readerForNow(String)
    }
    private(set) var finderPhase: FinderPhase?
    /// Who found the ads in the job running now, once it's known.
    private(set) var finderNote: String?
    /// The last `detectAndSave`'s finder, for the timing log.
    @ObservationIgnored private var lastFinderRun: ModelFinder.Run?
    /// Episodes read while locked (or not by the model at all) being read in
    /// full now the app is open (task 05): how many are left, and which.
    private(set) var modelCatchUpRemaining = 0
    private(set) var modelCatchUpTitle: String?
    @ObservationIgnored private var modelCatchUpTask: Task<Void, Never>?
    /// Which catch-up owns the state above: a stopped one winding down
    /// mustn't clear the next one's.
    @ObservationIgnored private var modelCatchUpToken = UUID()
    /// Episodes the catch-up already tried since launch. Pass 26 (his phone,
    /// 30 Sep): kept per task, it re-ran the same failing episodes after every
    /// job (Kam Patterson 4×). Now each is tried once per launch.
    @ObservationIgnored private var modelCatchUpTried = Set<String>()

    var stage: Stage = .idle {
        didSet {
            guard stage != oldValue else { return }
            if oldValue != .idle { steps[oldValue, default: StepRecord()].ended = .now }
            if stage != .idle, steps[stage]?.started == nil { steps[stage, default: StepRecord()].started = .now }
            stageStartedAt = .now
            noteProgress()
            if stage == .detecting { startPrepIfUseful() }
        }
    }
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
    private(set) var unfinishedJobs: [String] {
        get { jobs.outstanding }
        set {
            for guid in jobs.outstanding where !newValue.contains(guid) { jobs.setOutstanding(guid, false) }
            for guid in newValue { jobs.setOutstanding(guid, true) }
        }
    }

    /// His line while it is paused (task 14): the job that was running, then
    /// the ones waiting behind it, in order. Kept across launches. Nothing in
    /// here counts as outstanding work, so continued processing ends and
    /// nothing starts until he resumes.
    private(set) var pausedLine: PausedLine {
        get { PausedLine(guids: jobs.paused) }
        set { jobs.replacePaused(newValue.guids) }
    }
    /// Pause was pressed and the step hasn't ended yet: the button says
    /// Pausing… rather than looking ignored.
    private(set) var pausing = false

    @ObservationIgnored private var currentJob: Task<Void, Never>?
    /// Which job owns the shared state. A job abandoned by Restart can still
    /// be winding down; it must not clear the state of the one that replaced it.
    @ObservationIgnored private var jobToken = UUID()
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var lastProgressAt = Date()
    @ObservationIgnored private var watchdogTickAt = Date()
    /// The answers being given for the episode being worked on, so they can
    /// be written to disk the moment the app leaves the screen.
    @ObservationIgnored private var activeCheckpoint: DetectionCheckpoint?

    private func noteProgress() {
        if isRunning, let guid = currentEpisodeGUID {
            jobs.progress(guid, id: jobToken, stage: stage.rawValue, fraction: stageFraction)
        }
        lastProgressAt = .now
        if stalledSince != nil { stalledSince = nil }
    }

    /// Keeps its place if it is already listed: the list is also his line's
    /// order, kept across launches (pass 21).
    private func setUnfinished(_ guid: String, _ on: Bool) { jobs.setOutstanding(guid, on) }

    private func saveLineOrder() { jobs.setWaitingOrder(waitingQueue) }

    /// A job of his that stopped part way and isn't running now.
    func isPaused(_ episode: Episode) -> Bool {
        guard let status = jobs.record(episode.guid)?.status else { return false }
        return [.paused, .interrupted].contains(status) && !isProcessing(episode)
    }

    /// Minutes without progress, for "No progress for 3 min".
    var stalledMinutes: Int? {
        guard let stalledSince else { return nil }
        return max(2, Int(Date().timeIntervalSince(stalledSince) / 60))
    }

    /// How many episodes are left in this batch, not counting the current one.
    var queueRemaining = 0

    private(set) var jobStartedAt: Date?

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

    enum Stage: String, Hashable {
        case idle, downloading, transcribing, detecting, analyzing, saving

        /// The order the job really runs them in. Measuring ran before
        /// finding ads but was listed after it, so the bar jumped to ~98 %
        /// while measuring and fell back to ~20 % when finding ads began —
        /// on the Lock Screen too, where iOS reads a falling bar as a stuck
        /// job (pass 20, his 24 Sep diagnostics).
        static let ordered: [Stage] = [.downloading, .transcribing, .analyzing, .detecting, .saving]

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
        if worker == nil { BackgroundWork.reportUncleanExit() }
    }

    // MARK: - Staying alive in the background

    private func beginAssertion() {
        guard backgroundAssertion == .invalid else { return }
        backgroundAssertion = UIApplication.shared.beginBackgroundTask(
            withName: "PodSkipper.processing"
        ) { [weak self] in
            // iOS is about to reclaim the time. Give it back before it is
            // taken, otherwise the app is killed rather than suspended —
            // here and now, not on a later turn of the main queue (pass 22):
            // iOS allows about a second after this handler, and a busy main
            // thread could miss it. The handler runs on the main thread.
            MainActor.assumeIsolated { self?.endAssertion() }
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
        jobs.flush()
        stopMaintenance()
        // Catching up is only while the app stays open.
        stopModelCatchUp()
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
            startPrepIfUseful()
        }
        // Before the 30-second grace runs out, not after (pass 22).
        KeepAwake.shared.update(wanted: BackgroundWork.hisWorkOutstanding)
        // A job he started: if iOS pauses it, the processing window picks it
        // up again as soon as the system is willing, plugged in or not.
        if currentOrigin == .user || !unfinishedJobs.isEmpty {
            Self.scheduleNext(soon: true)
        }
    }

    func applicationWillEnterForeground() {
        AdDetector.inBackground = false
        UserDefaults.standard.removeObject(forKey: BackgroundWork.awayKey)
        // Time away doesn't count towards "no progress" while the model was
        // what iOS held back; anything else stuck while away still counts.
        // Nor does time the app was suspended (the watchdog didn't tick).
        if stage == .detecting || Date().timeIntervalSince(watchdogTickAt) > 30 { lastProgressAt = .now }
        if wasBackgrounded {
            let limited = JobHeartbeat.shared.takeRateLimited()
            // Pass 23: how many answers the model actually gave while away,
            // so the next file says what iOS allows a locked phone.
            let away = JobHeartbeat.shared.takeAwayCounts()
            BackgroundLog.shared.note("Back in the app: " + (isRunning ? "\(stage.label) \(Int(overallFraction * 100))%" : "no job running")
                                      + (limited > 0 ? " · iOS made the model wait \(limited)×" : "")
                                      + (away.answered + away.refused > 0
                                         ? " · while away the model answered \(away.answered), refused \(away.refused)" : ""))
        }
        wasBackgrounded = false
        jobs.clearRetryDelays()
        // His job, still going: ask again to be allowed to carry on after
        // the next time he leaves (the last permission may have ended).
        if isRunning, currentOrigin == .user { BackgroundWork.shared.workStarted() }
        resumeUnfinished()
        catchUpModelReads()
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
        // Queue order is checked again after taking the shared resource: a
        // benchmark or cancelled worker may still own it while this job waits.
        let coordinator = resources
        let lease: HeavyWorkCoordinator.Lease
        while true {
            while isRunning || (queued ? waitingQueue.first != guid : !waitingQueue.isEmpty) {
                if Task.isCancelled || (queued && !waitingQueue.contains(guid)) { return }
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled, !queued || waitingQueue.contains(guid) else { return }
            if let retryAfter = jobs.record(guid)?.retryAfter, retryAfter > .now {
                try? await Task.sleep(for: .milliseconds(300))
                continue
            }
            stopMaintenance()
            stopModelCatchUp()
            styleTask?.cancel()
            let acquired: HeavyWorkCoordinator.Lease
            do {
                acquired = try await coordinator.acquire(owner: "episode:" + guid,
                    priority: origin == .user ? .user : .preparation)
            } catch { return }
            if Task.isCancelled || (queued && !waitingQueue.contains(guid)) {
                coordinator.release(acquired)
                return
            }
            if isRunning || (queued ? waitingQueue.first != guid : !waitingQueue.isEmpty) {
                coordinator.release(acquired)
                continue
            }
            lease = acquired
            break
        }
        // The lease lasts until the real worker exits, including after the UI's
        // four-second Stop timeout. It cannot overlap the replacement worker.
        defer { coordinator.release(lease) }
        // Claimed before anything is awaited, so a second caller woken in
        // the same moment sees the slot taken.
        guard let record = jobs.begin(guid, title: episode.title, origin: origin.rawValue,
                                      selection: selectedEngine()) else {
            BackgroundLog.shared.note(jobs.storageError ?? "This job is paused or stopped; resume or retry it explicitly.")
            return
        }
        let token = record.id
        jobToken = token
        stopMaintenance()
        stopModelCatchUp()
        isRunning = true
        currentOrigin = origin
        currentEpisodeTitle = episode.title
        currentEpisodeGUID = episode.guid
        currentEpisode = episode
        waitingQueue.removeAll { $0 == guid }
        currentCredit = origin == .user ? (prepCredit.removeValue(forKey: guid) ?? 0) : 0
        stagePlan = Self.plan(for: episode)
        steps = [:]
        adFreeNote = nil
        finderPhase = nil
        finderNote = nil
        JobHeartbeat.shared.startJob()
        jobStartedAt = Date()
        lastProgressAt = .now
        stalledSince = nil
        if worker == nil { beginAssertion() }
        if origin == .user {
            markStopped(guid, false)
            setUnfinished(episode.guid, true)
            if worker == nil {
                BackgroundWork.shared.workStarted()
                ProcessingActivityController.shared.jobStarted()
            }
        }
        BackgroundLog.shared.note("Started (\(origin == .user ? "you" : "automatic")): \(episode.title)")
        if worker == nil { startWatchdog(token) }
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
        stagePlan = Self.plan(for: episode)
        stage = .transcribing
        stage = .analyzing
        stage = .detecting
        stageFraction = 0.02
        adFreeNote = "Ad-free copy: this host keeps no ad-free copy we know of"
        JobHeartbeat.shared.startJob()
        JobHeartbeat.shared.setPhase("Checking 4 finds in context")
        jobStartedAt = Date().addingTimeInterval(-600)
        stalledSince = Date().addingTimeInterval(-180)
    }

    func simulateForScreenshots(line: [String], paused: String) {
        guard DemoData.isEnabled else { return }
        waitingQueue = line
        batchTotal = line.count + 1
        batchDone = 0
        unfinishedJobs = [paused]
    }

    func simulateForScreenshots(paused episode: Episode) {
        guard DemoData.isEnabled else { return }
        unfinishedJobs = [episode.guid]
    }

    /// Writes the answers given so far to disk (iOS is about to pause the app).
    func saveCheckpointNow() {
        activeCheckpoint?.save()
        jobs.flush()
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
        guard !isRunning, !pausedLine.isPaused, jobs.storageError == nil, (worker != nil || !DemoData.isEnabled), let context = modelContext,
              worker != nil || inBackground || UIApplication.shared.applicationState != .background else { return }
        // Restore the interrupted head ahead of jobs that were merely queued.
        // Appending it to the old waiting list would silently change the order.
        let pending = unfinishedJobs
        if waitingQueue != pending { waitingQueue = pending }
        if batchTotal == 0 { batchTotal = pending.count }
        for guid in pending where userTasks[guid] == nil {
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
            descriptor.fetchLimit = 1
            guard let episode = try? context.fetch(descriptor).first else {
                setUnfinished(guid, false)
                continue
            }
            BackgroundLog.shared.note("Resuming your job: \(episode.title)")
            // Marked before the task starts, so a second call in the same
            // moment doesn't start it twice. All of them join the line at once, in the order he started them.
            if !waitingQueue.contains(guid) { enqueue(guid) }
            _ = scheduleUserJob(episode)
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
                self.watchdogTickAt = .now
                // Away from the app only the model's waits are iOS's doing;
                // a transcript or a download that stops moving is stuck
                // wherever he is (pass 20: one sat at 21 % for 8 min while
                // he went in and out of the app, and nothing noticed).
                let away = UIApplication.shared.applicationState != .active
                // A window of the on-device model can take minutes; it
                // reports per window, not per second.
                let modelReading = self.stage == .detecting && LocalJudgeMonitor.shared.isRunning
                if self.waitingForConnection || (away && self.stage == .detecting) || modelReading {
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
        if let guid = currentEpisodeGUID {
            jobs.finish(guid, id: token, status: .interrupted,
                        reason: abandoned ? "Waiting for the interrupted worker to finish stopping" : "Work was interrupted; completed stages are kept")
        }
        if abandoned { jobToken = UUID() }
        if currentOrigin == .user { batchDone = min(batchTotal, batchDone + 1) }
        currentCredit = 0
        stopping = false
        pausing = false
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
        if worker != nil {
            Task { @MainActor [weak self] in self?.resumeUnfinished() }
            return
        }
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
        // The next of his paused jobs, if any; then any episode read while
        // locked, now that nothing else is running (task 05).
        Task { @MainActor [weak self] in
            self?.resumeUnfinished()
            self?.catchUpModelReads()
        }
    }

    /// The job itself, run in its own task so it can be cancelled.
    private func run(_ episode: Episode, origin: Origin, token: UUID) async {
        guard let context = modelContext, let settings else { endJob(token); return }
        defer { endJob(token) }
        if let worker {
            do {
                try await worker(episode, token)
                try Task.checkCancellation()
                jobs.finish(episode.guid, id: token, status: .completed)
            } catch is CancellationError {
                jobs.finish(episode.guid, id: token, status: .interrupted, reason: "Work was interrupted")
            } catch {
                jobs.finish(episode.guid, id: token, status: .failed, reason: error.localizedDescription)
            }
            return
        }
        // These tasks overlap stages within this job, but the heavy-work lease
        // must outlive them even when a stage throws or Stop abandons the UI.
        var cleanup: [Task<Void, Never>] = []
        await runSteps(episode, origin: origin, token: token, context: context, settings: settings) {
            cleanup.append($0)
        }
        for task in cleanup { await task.value }
    }

    private func runSteps(_ episode: Episode, origin: Origin, token: UUID,
                          context: ModelContext, settings: AppSettings,
                          registerCleanup: (Task<Void, Never>) -> Void) async {
        do {
            // Being got ready ahead of its turn (pass 20): let that finish
            // rather than make the same transcript twice.
            await joinPrep(episode.guid)
            try Task.checkCancellation()

            // Find Ads Again on an episode whose audio has since been
            // removed: the transcript and everything measured from the audio
            // are stored, so only the ad finding runs again (his rule: a
            // finished transcript is never redone). Episodes fingerprinted
            // before pass 18 have no stored measurements and download.
            let hasAudio = episode.analysableFileURL != nil
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
            if episode.analysableFileURL == nil {
                episode.processingState = .downloading
                stage = .downloading
                stageFraction = 0
                let filename = try await download(episode)
                try Task.checkCancellation()
                if episode.isVideo {
                    // Video is streamed, never kept: the audio is pulled out
                    // and the video file is deleted in the same step.
                    let audio = try await VideoAudio.keepOnlyAudio(of: filename)
                    episode.localFilename = audio
                    episode.extractedAudioFilename = audio
                } else {
                    episode.localFilename = filename
                    FileIndex.insert(filename)
                }
                LibraryTotals.shared.invalidate()
                try? context.save()
            }
            guard let mediaURL = episode.analysableFileURL else { return }

            // A video's audio track has to come out before anything can read
            // it. AVAudioFile cannot open an mp4, so without this step every
            // video episode would fail at the first line of transcription.
            // The export copies the existing track rather than re-encoding,
            // so it is quick, and it only ever happens once per episode.
            if episode.isVideo, episode.extractedAudioFilename.map(FileIndex.contains) != true,
               let filename = episode.localFilename {
                let audioName = MediaExtractor.audioFilename(for: filename)
                do {
                    episode.extractedAudioFilename =
                        try await MediaExtractor.extractAudio(from: mediaURL, named: audioName)
                    try? context.save()
                } catch {
                    throw error
                }
            }
            guard let fileURL = episode.analysableFileURL else { return }

            // The ad-free comparison (pass 17) only needs the download, and
            // its first answer can take a while (Simplecast prepares the
            // stored file on first request), so it runs alongside
            // transcription and is waited for just before the ads are found.
            // Audio MP3s only: the original download, not an extracted track.
            // Everything below that needs no model may already have been done
            // while the previous job waited on the model (pass 20).
            let ready = prepared.removeValue(forKey: episode.guid)
            let adFreeJob: Task<AdFreeCopy.Outcome, Never>? = settings.useAdFreeCopy && !episode.isVideo && ready?.adFree == nil
                ? Task { [enclosure = episode.audioURL, feed = episode.podcast?.feedURL ?? "",
                          show = episode.podcast?.title ?? "", title = episode.title] in
                    await AdFreeCopy.compare(fileURL: mediaURL, enclosure: enclosure, feedURL: feed,
                                             showTitle: show, episodeTitle: title)
                  }
                : nil
            defer { adFreeJob?.cancel() }
            if let adFreeJob { registerCleanup(Task { _ = await adFreeJob.value }) }

            // 4b. Audio that plays again (pass 18, research stage 2): this
            // episode's fingerprints against the show's last two episodes and
            // itself — themes, promos, produced ads, reads used twice — found
            // exactly with no model. About five seconds of one core an hour,
            // off the main thread, alongside transcription.
            let showKey = episode.podcast?.feedURL ?? episode.podcast?.title ?? ""
            let printJob: Task<[AdPrints.Produced], Never>? = ready?.produced != nil ? nil : Task.detached(priority: .utility) {
                [guid = episode.guid, fileURL] in
                Self.repeatedAudio(fileURL: fileURL, showKey: showKey, guid: guid)
            }
            defer { printJob?.cancel() }
            if let printJob { registerCleanup(Task { _ = await printJob.value }) }

            // Chapters live in the audio file, so this is the first moment
            // we can read them.
            await ChapterService.extract(for: episode, context: context)
            try Task.checkCancellation()

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
                let throttle = ProgressThrottle { [weak self] p in
                    guard let self, self.jobToken == token, self.isRunning else { return }
                    self.stageFraction = p
                }
                let timer = Diagnostics.Interval.begin("Transcribe")
                // Resumable (cloud task 03): an interrupted run keeps what it
                // transcribed and the next run carries on from there.
                let checkpointKey = episode.guid
                segments = try await transcriber.transcribe(fileURL: fileURL, checkpointKey: checkpointKey) { throttle.report($0) }
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

            try Task.checkCancellation()
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
                let throttle = ProgressThrottle { [weak self] p in
                    guard let self, self.jobToken == token, self.isRunning else { return }
                    self.stageFraction = p
                }
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
                try Task.checkCancellation()
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
                // No measured work is available while the host prepares its
                // copy. Keep the bar still and show the real waiting reason.
                adFreeNote = "Checking the host's comparison copy"
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
                try Task.checkCancellation()
                adFree = outcome
                inserted = AdFreeCopy.trustedInserted(outcome.inserted, policyVersion: outcome.policyVersion,
                                                       duration: episode.audioFileLength > 0 ? episode.audioFileLength : episode.duration)
                stageFraction = Self.adFreeShare
                adFreeNote = inserted.isEmpty
                    ? (outcome.note.isEmpty ? "No confirmed comparison differences" : outcome.note)
                    : "Confirmed \(inserted.count) interior difference\(inserted.count == 1 ? "" : "s")"
                        + (outcome.note.isEmpty ? "" : "; " + outcome.note)

                episode.insertedSpansData = try? JSONEncoder().encode(inserted)
                episode.insertedSpansPolicyVersion = outcome.policyVersion
            } else if let ready {
                adFree = ready.adFree
                inserted = AdFreeCopy.trustedInserted(ready.inserted, policyVersion: ready.adFree?.policyVersion,
                                                       duration: episode.audioFileLength > 0 ? episode.audioFileLength : episode.duration)
                episode.insertedSpansPolicyVersion = ready.adFree?.policyVersion
                episode.insertedSpansData = try? JSONEncoder().encode(inserted)
            }
            let produced = (await printJob?.value) ?? ready?.produced ?? []
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
            guard jobToken == token else { return }
            jobs.finish(episode.guid, id: token, status: .interrupted, reason: "Work was interrupted; completed stages are kept")
            // Stepped aside for a job someone asked for, or paused. Not a
            // failure: the transcript, if it got that far, is already saved,
            // and so are the answers; both are reused.
            episode.processingState = .notStarted
            try? context.save()
            BackgroundLog.shared.note("Stopped part way (kept for next time): \(episode.title)")
        } catch {
            guard jobToken == token else { return }
            // Away from the app, an error is iOS's doing more often than the
            // episode's (pass 21b: "avfaudio error 561277293" 25 s after he
            // locked the phone mid-transcription, and the job he'd started
            // was simply marked Failed). His job pauses instead: tried again
            // in 20 s, twice, then when he's back in the app.
            let away = wasBackgrounded || UIApplication.shared.applicationState != .active
            if origin == .user, away {
                jobs.finish(episode.guid, id: token, status: .interrupted, reason: error.localizedDescription)
                let guid = episode.guid
                episode.processingState = .notStarted
                try? context.save()
                let tries = awayRetries[guid, default: 0]
                if tries < 2 {
                    awayRetries[guid] = tries + 1
                    BackgroundLog.shared.note("Hit an error while you were away (\(error.localizedDescription)); trying again in 20 s: \(episode.title)")
                    if !waitingQueue.contains(guid) {
                        waitingQueue.insert(guid, at: 0)
                        batchTotal += 1
                    }
                    jobs.deferRetry(guid, until: .now.addingTimeInterval(20))
                } else {
                    jobs.deferRetry(guid, until: .distantFuture)
                    BackgroundLog.shared.note("Paused after repeated errors while you were away (\(error.localizedDescription)); carries on when you open PodSkipper: \(episode.title)")
                }
                return
            }
            jobs.finish(episode.guid, id: token, status: .failed, reason: error.localizedDescription)
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
        guard jobs.finish(episode.guid, id: jobToken, status: .completed) else { return }
        setUnfinished(episode.guid, false)
        awayRetries[episode.guid] = nil
        if origin == .user { ProcessingActivityController.shared.noteFinished(episode) }
        Self.learnPrints(from: episode)
        // How each ad was delivered, if iOS lets Apple's model answer now
        // (pass 25: after the job, never inside it).
        classifyMissingStyles([episode])
        let foreground = UIApplication.shared.applicationState == .active
        let lowest = BackgroundWork.shared.takeLowestFreeMB()
        let unanswered = JobHeartbeat.shared.unansweredSummary
        let skipped = JobHeartbeat.shared.skippedForLimit
        BackgroundLog.shared.note("Finished \(foreground ? "on screen" : "in the background"): \(episode.title)"
                                  + (lowest.map { " · least memory left while away \($0) MB" } ?? "")
                                  + " · heat \(Diagnostics.thermalName)"
                                  + " · " + (lastFinderRun ?? ModelFinder.Run(finder: "reader")).logLine(totalSeconds: detect)
                                  + (unanswered.count > 0 ? " · \(unanswered.count) questions the model never answered (\(unanswered.reasons))" : ""))
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
            cutSeconds: episode.adSegments.filter { $0.userVerdict != .notAnAd }.reduce(0) { $0 + $1.duration },
            skippedQuestions: skipped,
            finder: lastFinderRun))

        // Listening to it right now: start skipping straight away, rather
        // than on the next load.
        if PlayerEngine.shared.currentEpisode?.guid == episode.guid {
            PlayerEngine.shared.refreshSkipRanges()
        }
        // The show publishes itself: straight into its feed, not already
        // in it, only once there is a feed to put it in.
        if let show = episode.podcast, show.autoPublish, show.publishedFeedURL != nil,
           episode.publishedURL == nil, R2Credentials.isConfigured {
            PublishQueue.shared.configure(context: context, resume: false)
            PublishQueue.shared.enqueue([episode], automatically: true)
        }
        // Finished while he was away: say so, as Apple's own apps do for a
        // long job, and let the tap land on it.
        // (Not when the model couldn't run: that has its own notification.)
        if origin == .user, !foreground, !episode.modelPending {
            let body = "\(episode.title) is ready to play without them."
            Task {
                await NotificationService.notifyJobProblem(episode, title: "Ads found", body: body)
            }
        }
    }

    /// This episode's fingerprints against the show's last two episodes,
    /// itself, and the recordings known from every show (pass 19): a spot
    /// learned on one show is found by its sound on another. No model.
    nonisolated static func repeatedAudio(fileURL: URL, showKey: String, guid: String) -> [AdPrints.Produced] {
        guard let landmarks = try? AdPrints.landmarks(fileURL: fileURL) else { return [] }
        let previous = AdPrints.previous(show: showKey, excluding: guid)
        var found = AdPrints.produced(in: landmarks, previous: previous)
        found += AdPrints.Library.matches(in: landmarks, excludingSource: guid).map {
            AdPrints.Produced(start: $0.start, end: $0.end, acrossEpisodes: true,
                              known: $0.negative ? nil : $0.kind, negative: $0.negative,
                              evidenceProvenance: $0.provenance, evidencePolicyVersion: $0.evidencePolicyVersion)
        }
        AdPrints.remember(landmarks, show: showKey, guid: guid)
        return found.sorted { $0.start < $1.start }
    }

    /// Teaches the cross-show library (`AdPrints.Library`) the recordings in
    /// this episode that are certainly ads or promos: stitched in at download
    /// (found by the ad-free comparison), or produced repeats the model called
    /// an ad or a promotion. Off the main thread; the episode's fingerprints
    /// are the ones kept for the show's next episode.
    nonisolated static func learnPrints(from episode: Episode) {
        let show = episode.podcast?.feedURL ?? episode.podcast?.title ?? ""
        let guid = episode.guid
        let certain = episode.adSegments.compactMap { s -> (Double, Double, String, AdPrints.Library.Provenance)? in
            guard s.userVerdict != .notAnAd, s.canApplyAutomatically, [.ad, .crossPromo].contains(s.kind),
                  s.insertedAtDownload || s.evidenceText.contains(SegmentEvidence.repeatedAudio.rawValue) else { return nil }
            return (s.start, s.end, s.kind.rawValue, s.isReviewed ? .userCorrection : .currentAutomatic)
        }
        guard !certain.isEmpty else { return }
        Task.detached(priority: .background) {
            guard let landmarks = AdPrints.stored(show: show, guid: guid) else { return }
            for (start, end, kind, provenance) in certain {
                AdPrints.Library.add(landmarks.slice(start...end), show: show, source: guid, kind: kind,
                                    provenance: provenance, evidencePolicyVersion: AdPrints.Library.currentEvidencePolicyVersion)
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
            AdPrints.Library.add(landmarks.slice(range), show: show, source: guid, kind: kind, negative: negative,
                                provenance: .userCorrection, evidencePolicyVersion: AdPrints.Library.currentEvidencePolicyVersion)
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
                               quiet: Bool = false, finder: FinderRequest = .chosen) async throws -> Double {
        // A quiet re-label shows nothing: no progress bar, no "Finding ads"
        // on the row. The episode stays ready throughout.
        // Carries on from the ad-free comparison's share rather than falling
        // back to 0 (pass 20: the bar never moves backwards).
        let base = !quiet && stage == .detecting ? min(Self.adFreeShare, stageFraction) : 0
        if !quiet {
            episode.processingState = .detecting
            stage = .detecting
            stageFraction = base
        }
        let evidenceDuration = episode.audioFileLength > 0 ? episode.audioFileLength : episode.duration
        let produced = AdPrints.detectionEvidence(produced, duration: evidenceDuration)
        let selection = (!quiet ? jobs.record(episode.guid)?.selection : nil) ?? selectedEngine()
        let known = episode.podcast?.knownSponsors ?? []
        // Every thumbs-up and thumbs-down the listener has given on this
        // show, handed to the model as worked examples.
        let corrections = episode.podcast?.corrections ?? []
        // Task 05: the reader always runs first; the on-device model after
        // it when it's the chosen finder. The bar is shared between them:
        // the reader's seconds, then the model's windows.
        let wantsModel = selection.enabled != false && (finder == .modelFull
            || (finder == .chosen && selection.engine == AdFinderChoice.model.rawValue))
        let wantsCoreAI = selection.enabled != false && finder == .chosen && selection.engine == AdFinderChoice.coreAI.rawValue
        let coreAIReady = CoreAIModelLibrary.shared.entry(for: selection.modelID ?? CoreAIModelLibrary.shared.selectedID).map {
            CoreAIModelLibrary.shared.isDownloaded($0)
        } ?? false
        let selectedMLX = selection.modelID.flatMap { id in LocalModelSpec.all.first { $0.id == id } }
        let mlxDisk = wantsModel && selectedMLX != nil
            ? await ModelStore.readDisk(for: selectedMLX!, manifest: nil) : nil
        try Task.checkCancellation()
        let mlxReady = mlxDisk?.manifest != nil && mlxDisk?.remainingBytes == 0
        let readerShare = (wantsModel && mlxReady) || (wantsCoreAI && coreAIReady) ? 0.1 : 1.0
        let progressToken = jobToken
        lastFinderRun = nil
        let detectThrottle = ProgressThrottle { [weak self] p in
            if !quiet, let self, self.jobToken == progressToken, self.isRunning { self.stageFraction = max(self.stageFraction, base + (1 - base) * readerShare * p) }
        }
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
        // Pass 27: "Apple Intelligence" as the finder brings back the
        // detector that asks Apple's on-device model about each stretch (the
        // pre-pass-25 path). iOS limits that model in the background on
        // battery; when it isn't available at all, the reader runs instead.
        //
        // Pass 27b (his phone, 30 Sep): with Apple Intelligence it finished
        // on screen and locked on the charger, but unplugged and locked iOS
        // held its model back and the job sat at "Finding ads 23 %" until
        // iOS paused it. No entitlement lifts that for a sideload. So off
        // screen on battery the reader (the full process, proven locked on
        // battery) finds the ads now, and Apple Intelligence reads the
        // episode again when he next opens the app.
        let wantsApple = (finder == .chosen && selection.engine == AdFinderChoice.apple.rawValue)
            || finder == .appleFull
        let appleWhyNot = wantsApple ? AdDetector.availability() : nil
        let battery = UIDevice.current.batteryState
        let onPower = battery == .charging || battery == .full
        let appleLater = wantsApple && appleWhyNot == nil && finder != .appleFull
            && UIApplication.shared.applicationState != .active && !onPower
        let useApple = wantsApple && appleWhyNot == nil && !appleLater
        let previousTuning = SegmentDetector.tuning
        SegmentDetector.tuning.ownReader = !useApple
        defer { SegmentDetector.tuning = previousTuning }
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
        // Nor must a re-label the model didn't fully answer (pass 22). His
        // 28 Sep results: 2 Bears "What Percent Gay Are You?" re-labelled
        // at 11:36, in the background, lost both of its sponsor breaks
        // (Manscaped + DraftKings at 12:06, Hims + BetterHelp at 26:57 —
        // "This episode is sponsored by…", read in full), both of which the
        // lab finds on the same episode. A question the model doesn't answer
        // leaves its stretch read by nobody, which reads as "no ad". The
        // earlier cuts stay, and the episode is marked done so it isn't
        // asked about again in a loop; the log says what happened.
        // (Pass 25: the own reader asks Apple's model nothing, so a job can
        // no longer finish half-answered as a "quick check".)
        let unanswered = JobHeartbeat.shared.unansweredSummary
        if quiet, unanswered.count > 0, !episode.adSegments.isEmpty {
            BackgroundLog.shared.note("Re-labelling kept the earlier cuts: the model didn't answer \(unanswered.count) questions (\(unanswered.reasons)) — \(episode.title)")
            episode.detectorVersion = AdDetector.version
            try? context.save()
            return detectTimer.end()
        }
        let readerAds = detection.segments
        // Both answers are kept, whoever's cuts are saved.
        episode.readerSegmentsData = ModelFinder.encode(readerAds)
        var ads = readerAds
        var sponsors = detection.sponsors
        var run = ModelFinder.Run(finder: useApple ? "apple" : "reader")
        if let appleWhyNot {
            run.failure = "Apple Intelligence isn't available: \(appleWhyNot)"
            if !quiet { finderNote = "Using the reader — " + appleWhyNot }
        }

        if wantsModel || wantsCoreAI {
            let read: (cuts: [DetectedSegment]?, run: ModelFinder.Run)
            if wantsCoreAI {
                read = try await readWithCoreAI(
                    episode, segments: segments, readerAds: readerAds, inserted: inserted,
                    produced: produced, silences: silences, settings: settings, quiet: quiet,
                    selection: selection
                ) { [weak self] p in
                    guard !quiet, let self, self.jobToken == progressToken, self.isRunning else { return }
                    self.stageFraction = max(self.stageFraction, base + (1 - base) * (readerShare + (1 - readerShare) * p))
                }
            } else {
                read = try await readWithModel(
                    episode, segments: segments, readerAds: readerAds,
                    inserted: inserted, produced: produced, hints: hints,
                    silences: silences, settings: settings,
                    forceFull: finder == .modelFull, quiet: quiet, selection: selection
                ) { [weak self] p in
                    guard !quiet, let self, self.jobToken == progressToken, self.isRunning else { return }
                    self.stageFraction = max(self.stageFraction, base + (1 - base) * (readerShare + (1 - readerShare) * p))
                }
            }
            try Task.checkCancellation()
            run = read.run
            if let cuts = read.cuts {
                ads = cuts
                sponsors = Array(Set(sponsors + cuts.filter { $0.kind == .ad && !$0.sponsor.isEmpty }.map(\.sponsor))).sorted()
                episode.modelVersion = ModelFinder.version
                episode.needsFullModelRead = run.mode == ModelFinder.Mode.fast.rawValue
                episode.modelPending = false
                if !quiet { finderNote = run.mode == ModelFinder.Mode.fast.rawValue
                    ? "On-device model: fast check while locked; a full read follows when you open PodSkipper"
                    : "On-device model: read in full" }
            } else if run.deferred == true, finder != .modelFull {
                // Off screen (pass 27): the reader's cuts now, the model's read
                // when he next opens the app. Not a failure, so no notification.
                episode.modelPending = true
                episode.needsFullModelRead = false
            } else if finder == .modelFull {
                // Catching up and it still couldn't run: the cuts it has
                // stay as they are, and it's tried again another time.
                lastFinderRun = run
                try? context.save()
                return detectTimer.end()
            } else if run.attempts > 0 {
                // Tried three times and failed: the reader's cuts for now,
                // re-checked when he opens the app.
                episode.modelPending = true
                episode.needsFullModelRead = false
                BackgroundLog.shared.note("Using the reader's cuts for now: the on-device model failed \(run.attempts)× (\(run.failure ?? "unknown")) — \(episode.title)")
                if UIApplication.shared.applicationState != .active {
                    Task { await NotificationService.notifyReaderForNow(episode) }
                }
            }
        } else if finder == .readerOnly, episode.modelVersion > 0, !episode.modelPending {
            // A new reader re-labelling in the background: the model's cuts
            // stay; only the reader's own answer is brought up to date.
            episode.detectorVersion = AdDetector.version
            try context.save()
            done = true
            checkpoint.discard()
            return detectTimer.end()
        }
        if !run.byModel {
            episode.modelVersion = 0
            if !wantsModel { episode.modelPending = false; episode.needsFullModelRead = false }
            if !quiet, wantsModel { finderNote = "Using the reader for now — " + Self.whyNotModel(run) }
        }
        episode.finderNote = Self.finderSummary(run)
        if selection.enabled == false {
            episode.finderNote = "Found by PodSkipper Reader because \(selection.modelName ?? "the selected model") is turned off."
            if !quiet { finderNote = episode.finderNote }
        }
        if appleLater {
            // Read again with Apple Intelligence on screen or on the charger.
            episode.modelPending = true
            episode.finderNote = "Found by the reader for now: Apple Intelligence reads it again when you next open PodSkipper"
            run.deferred = true
            BackgroundLog.shared.note("Locked on battery: the reader found the ads; Apple Intelligence reads it again when you next open the app — \(episode.title)")
            if !quiet { finderNote = "Reader now (locked on battery); Apple Intelligence later" }
        }
        lastFinderRun = run

        // What this show advertises carries forward.
        if let show = episode.podcast, !sponsors.isEmpty {
            var merged = Set(show.knownSponsors)
            merged.formUnion(sponsors)
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
            // switches: read by PodSkipper's own reader along with
            // everything else (pass 25), so it is there however the job ran.
            if ad.kind == .ad {
                if !quiet { stageFraction = 0.5 + 0.4 * Double(index) / Double(max(1, ads.count)) }
                if let style = ad.style {
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
        try context.save()
        done = true
        checkpoint.discard()
        return detectTimer.end()
    }

    // MARK: - The on-device model finds the ads (task 05)

    /// Who finds the ads in one `detectAndSave`.
    enum FinderRequest {
        /// The listener's choice (Settings → Find ads with).
        case chosen
        /// Only the reader: a background re-label for a new reader.
        case readerOnly
        /// A full read by the model, whatever the setting: catching up on
        /// an episode read while locked.
        case modelFull
        /// Apple Intelligence reads an episode the reader did while the
        /// phone was locked on battery (pass 27b).
        case appleFull
    }

    /// The model's read of one episode: every line with the app open, the
    /// suspicious stretches (`ModelFinder.fastRanges`) with it in the
    /// background. Up to three tries, a short wait between them, whatever
    /// the error (not enough memory, an answer it couldn't read, needing
    /// the foreground). Nil cuts when it couldn't run.
    private func readWithModel(_ episode: Episode, segments: [TranscriptSegment], readerAds: [DetectedSegment],
                               inserted: [InsertedSpan], produced: [AdPrints.Produced],
                               hints: [ClosedRange<Double>], silences: [ClosedRange<Double>],
                               settings: AppSettings, forceFull: Bool, quiet: Bool, selection: ProcessingEngineSelection,
                               progress: @escaping @MainActor (Double) -> Void)
        async throws -> (cuts: [DetectedSegment]?, run: ModelFinder.Run) {
        var run = ModelFinder.Run(finder: "reader")
        guard let selectedModel = LocalModelSpec.all.first(where: { $0.id == selection.modelID }) else {
            run.failure = "the selected model is no longer in the library"
            if !quiet { finderPhase = .readerForNow(Self.whyNotModel(run)) }
            return (nil, run)
        }
        let disk = await ModelStore.readDisk(for: selectedModel, manifest: nil)
        try Task.checkCancellation()
        guard disk.manifest != nil, disk.remainingBytes == 0 else {
            run.failure = "isn't downloaded yet"
            if !quiet { finderPhase = .readerForNow(Self.whyNotModel(run)) }
            return (nil, run)
        }
        let lines = segments.map { TimedLine(text: $0.text, start: $0.start, end: $0.end) }
        let duration = episode.duration > 0 ? episode.duration : (lines.last?.end ?? 0)
        let evidence = ModelFinder.evidence(inserted: inserted, produced: produced)
        let corrections = ModelFinder.correctionsBlock(episode.podcast?.corrections ?? [])
        let show = episode.podcast?.title ?? "", title = episode.title, notes = episode.plainDescription
        let throttle = ProgressThrottle(progress)
        let started = Date()
        // Pass 27: without Background GPU Access the model runs only with the
        // app on screen (no GPU in the background, and the CPU fallback
        // stalled and was killed on his phone). Off screen, the reader's cuts
        // stand and the episode is read by the model when he next opens
        // PodSkipper. Signed with it, the continued-processing task carries
        // the read on in the background (see LocalJudge).
        func mustWaitForScreen() -> Bool {
            UIApplication.shared.applicationState != .active && !SignedEntitlements.backgroundGPU
        }
        func deferred() -> (cuts: [DetectedSegment]?, run: ModelFinder.Run) {
            run.deferred = true
            run.failure = "needs PodSkipper open on screen; it reads this episode when you next open the app"
            run.seconds = Date().timeIntervalSince(started)
            if !quiet { finderPhase = .readerForNow(Self.whyNotModel(run)) }
            return (nil, run)
        }

        for attempt in 1...ModelFinder.attempts {
            try Task.checkCancellation()
            if mustWaitForScreen() { return deferred() }
            if attempt > 1 {
                if !quiet { finderPhase = .retrying(attempt: attempt) }
                try await Task.sleep(for: ModelFinder.retryWait)
                if mustWaitForScreen() { return deferred() }
            }
            // Always a full read now: the "fast" read of suspicious stretches
            // was for the locked phone, where the model no longer runs.
            _ = forceFull
            run.mode = ModelFinder.Mode.full.rawValue
            run.attempts = attempt
            if !quiet { finderPhase = .reading(fast: false) }
            do {
                let report = try await LocalJudge.shared.judgeReport(
                    lines: lines, show: show, title: title, notes: notes, evidence: evidence,
                    only: nil, corrections: corrections, model: selectedModel, progress: { throttle.report($0) })
                if !report.failedLines.isEmpty {
                    throw LocalJudge.JudgeError.someWindowsFailed(found: report.parts, failedLines: report.failedLines)
                }
                run.finder = "model"
                run.modelName = selectedModel.name
                run.failure = nil
                run.windows = report.stats.windows
                run.tokensPerSecond = report.stats.readTokensPerSecond
                run.seconds = Date().timeIntervalSince(started)
                let cuts = ModelFinder.cuts(from: report.parts, lines: lines, readerCuts: readerAds,
                                            inserted: inserted, silences: silences,
                                            padding: settings.boundaryPadding, duration: duration)
                return (cuts, run)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if case LocalJudge.JudgeError.needsForeground = error {
                    BackgroundLog.shared.note("On-device model stopped: PodSkipper left the screen. The reader's cuts stand for now — \(episode.title)")
                    return deferred()
                }
                run.failure = error.localizedDescription
                BackgroundLog.shared.note("On-device model, try \(attempt) of \(ModelFinder.attempts): \(error.localizedDescription) — \(episode.title)")
            }
        }
        run.seconds = Date().timeIntervalSince(started)
        if !quiet { finderPhase = .readerForNow(Self.whyNotModel(run)) }
        return (nil, run)
    }

    /// Core AI version of the contextual model read. CoreAIKit handles
    /// the selected model's download/cache and the Apple Core AI runtime.
    private func readWithCoreAI(
        _ episode: Episode, segments: [TranscriptSegment], readerAds: [DetectedSegment],
        inserted: [InsertedSpan], produced: [AdPrints.Produced],
        silences: [ClosedRange<Double>], settings: AppSettings, quiet: Bool,
        selection: ProcessingEngineSelection,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> (cuts: [DetectedSegment]?, run: ModelFinder.Run) {
        var run = ModelFinder.Run(finder: "reader")
        let started = Date()
        let selectedModel = CoreAIModelLibrary.shared.entry(for: selection.modelID ?? CoreAIModelLibrary.shared.selectedID)
        guard selectedModel.map({ CoreAIModelLibrary.shared.isDownloaded($0) }) == true else {
            run.failure = "the selected Core AI model isn't downloaded yet"
            if !quiet { finderPhase = .readerForNow(Self.whyNotModel(run)) }
            return (nil, run)
        }

        if UIApplication.shared.applicationState != .active && !SignedEntitlements.backgroundGPU {
            run.deferred = true
            run.failure = "needs PodSkipper open on screen; it reads this episode when you next open the app"
            if !quiet { finderPhase = .readerForNow(Self.whyNotModel(run)) }
            return (nil, run)
        }

        let lines = segments.map { TimedLine(text: $0.text, start: $0.start, end: $0.end) }
        let duration = episode.duration > 0 ? episode.duration : (lines.last?.end ?? 0)
        let evidence = ModelFinder.evidence(inserted: inserted, produced: produced)
        let corrections = ModelFinder.correctionsBlock(episode.podcast?.corrections ?? [])
        let show = episode.podcast?.title ?? ""
        let throttle = ProgressThrottle(progress)

        for attempt in 1...ModelFinder.attempts {
            try Task.checkCancellation()
            run.mode = ModelFinder.Mode.full.rawValue
            run.attempts = attempt
            if !quiet { finderPhase = .reading(fast: false) }
            do {
                let report = try await CoreAIAdJudge.shared.judgeReport(
                    lines: lines, show: show, title: episode.title,
                    notes: episode.plainDescription, evidence: evidence,
                    corrections: corrections, modelID: selectedModel?.id, progress: { throttle.report($0) }
                )
                if !report.failedLines.isEmpty {
                    throw CoreAIAdJudge.JudgeError.failed("Some Core AI transcript windows could not be read.")
                }
                run.finder = "coreAI"
                run.modelName = selectedModel?.name
                run.failure = nil
                run.windows = report.stats.windows
                run.tokensPerSecond = report.stats.readTokensPerSecond
                run.seconds = Date().timeIntervalSince(started)
                let cuts = ModelFinder.cuts(
                    from: report.parts, lines: lines, readerCuts: readerAds,
                    inserted: inserted, silences: silences, padding: settings.boundaryPadding,
                    duration: duration
                )
                return (cuts, run)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if case CoreAIAdJudge.JudgeError.needsForeground = error {
                    run.deferred = true
                    run.failure = "needs PodSkipper open on screen; it reads this episode when you next open the app"
                    return (nil, run)
                }
                run.failure = error.localizedDescription
                BackgroundLog.shared.note("Core AI ad judge, try \(attempt) of \(ModelFinder.attempts): \(error.localizedDescription) — \(episode.title)")
                if attempt < ModelFinder.attempts {
                    try await Task.sleep(for: ModelFinder.retryWait)
                }
            }
        }

        run.seconds = Date().timeIntervalSince(started)
        if !quiet { finderPhase = .readerForNow(Self.whyNotModel(run)) }
        return (nil, run)
    }

    /// Why the reader's cuts were saved though the model is the chosen finder.
    static func whyNotModel(_ run: ModelFinder.Run) -> String {
        guard let failure = run.failure else { return "the on-device model couldn't run" }
        return run.attempts == 0 ? "the on-device model \(failure)" : "the on-device model couldn't run: \(failure)"
    }

    /// One plain line on the episode about who found its ads.
    static func finderSummary(_ run: ModelFinder.Run) -> String {
        if run.byModel {
            return run.mode == ModelFinder.Mode.fast.rawValue
                ? "Found by the on-device model's fast check while locked"
                : "Found by the on-device model"
        }
        if run.finder == "apple" { return "Found with Apple Intelligence" }
        if run.deferred == true { return "Found by the reader for now: the on-device model reads it when you next open PodSkipper" }
        guard run.failure != nil || run.attempts > 0 else { return "Found by PodSkipper's reader" }
        return "Found by the reader for now: " + whyNotModel(run)
    }

    /// The Activity screen's line for the model (task 05): "Reading with the
    /// on-device model — part 3 of 7 (82 words/s)". Windows done are the
    /// progress; nothing is estimated.
    var finderStatus: String? {
        guard let finderPhase else { return nil }
        let monitor = LocalJudgeMonitor.shared
        let total = monitor.windowsTotal
        let part = total > 0 ? " — part \(min(monitor.windowsDone + 1, total)) of \(total)" : ""
        let speed = monitor.wordsPerSecond > 0 ? " (\(Int(monitor.wordsPerSecond.rounded())) words/s)" : ""
        switch finderPhase {
        case .reading(let fast):
            if monitor.isRunning, total == 0 { return "Loading the on-device model" }
            return (fast ? "Fast check of suspicious parts (phone locked)" : "Reading with the on-device model") + part + speed
        case .retrying(let attempt):
            return "Retrying (\(attempt) of \(ModelFinder.attempts))"
        case .readerForNow(let why):
            return "Using the reader for now — \(why)"
        }
    }

    /// "Keep reader's cuts" from the notification: stored by the delegate
    /// (the app may not be set up yet when it arrives) and applied here.
    nonisolated static let keepReaderKey = "keepReaderCutsFor"

    /// Straight away, when the app is already set up.
    func applyKeptReaderCutsNow() {
        if let modelContext { applyKeptReaderCuts(modelContext) }
    }

    private func applyKeptReaderCuts(_ context: ModelContext) {
        let guids = UserDefaults.standard.stringArray(forKey: Self.keepReaderKey) ?? []
        guard !guids.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: Self.keepReaderKey)
        for guid in guids {
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
            descriptor.fetchLimit = 1
            guard let episode = try? context.fetch(descriptor).first else { continue }
            episode.modelPending = false
            episode.needsFullModelRead = false
            episode.finderNote = "Found by the reader (you kept its cuts)"
            BackgroundLog.shared.note("Kept the reader's cuts, as you asked: \(episode.title)")
        }
        try? context.save()
    }

    /// Episodes read while locked, or that the model couldn't read, read in
    /// full now the app is open: one at a time, newest first, and only
    /// while it stays open. Their unreviewed cuts are replaced. Then, while
    /// charging, up to five a day of the episodes the reader alone labelled.
    func catchUpModelReads() {
        guard modelCatchUpTask == nil, !isRunning, !pausedLine.isPaused, !DemoData.isEnabled, let context = modelContext, let settings,
              UIApplication.shared.applicationState == .active else { return }
        applyKeptReaderCuts(context)
        // The downloaded model, or (pass 27b) Apple Intelligence re-reading
        // what the reader did while the phone was locked on battery.
        let byApple = settings.adFinder == AdFinderChoice.apple.rawValue && AdDetector.availability() == nil
        // Pass 27f: open-source models are on trial (his self-tests); they
        // no longer re-read episodes on their own at launch — that held the
        // model for minutes and greyed out the model list. Only Apple
        // Intelligence catches up.
        guard byApple else { return }
        let request: FinderRequest = .appleFull
        let token = UUID()
        modelCatchUpToken = token
        modelCatchUpTask = Task { [weak self] in
            defer {
                if let self, self.modelCatchUpToken == token {
                    self.modelCatchUpTask = nil
                    self.modelCatchUpRemaining = 0
                    self.modelCatchUpTitle = nil
                }
            }
            // Not on top of the app's own start (pass 27).
            try? await Task.sleep(for: ModelFinder.catchUpDelay)
            while !Task.isCancelled {
                guard let self, !self.isRunning, UIApplication.shared.applicationState == .active else { return }
                // A background re-label for a new reader goes first; it takes seconds.
                if self.maintenanceTask != nil {
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                let waiting = FetchDescriptor<Episode>(
                    predicate: #Predicate { $0.needsFullModelRead || $0.modelPending },
                    sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
                let pending = (try? context.fetch(waiting)) ?? []
                // A few tries in all, across launches (pass 27, his request),
                // then the reader's cuts stay for good.
                for episode in pending where ModelFinder.catchUpTriesSoFar(episode.guid) >= ModelFinder.catchUpTries {
                    episode.modelPending = false
                    episode.needsFullModelRead = false
                    episode.finderNote = "Found by the reader: the on-device model couldn't read it in \(ModelFinder.catchUpTries) tries"
                    ModelFinder.setCatchUpTries(episode.guid, nil)
                    BackgroundLog.shared.note("Keeping the reader's cuts: the on-device model couldn't read it in \(ModelFinder.catchUpTries) tries — \(episode.title)")
                }
                try? context.save()
                var list = pending.filter { $0.modelPending || $0.needsFullModelRead }
                    .filter { !self.modelCatchUpTried.contains($0.guid) }
                var old = false
                if list.isEmpty, !byApple, let next = self.oldEpisodeForModel(excluding: self.modelCatchUpTried) {
                    list = [next]
                    old = true
                }
                self.modelCatchUpRemaining = list.count
                guard let episode = list.first else { return }
                let lease: HeavyWorkCoordinator.Lease
                do {
                    lease = try await HeavyWorkCoordinator.shared.acquire(owner: "catchup:" + episode.guid, priority: .maintenance)
                } catch { return }
                defer { HeavyWorkCoordinator.shared.release(lease) }
                guard !Task.isCancelled, !self.isRunning else { return }
                self.modelCatchUpTried.insert(episode.guid)
                self.modelCatchUpTitle = episode.title
                let lines = await episode.loadTranscript()
                guard lines.count >= 10 else {
                    episode.needsFullModelRead = false
                    episode.modelPending = false
                    episode.modelVersion = ModelFinder.version
                    try? context.save()
                    continue
                }
                let segments = lines.map { TranscriptSegment(text: $0.text, start: $0.start, end: $0.end,
                                                             words: $0.words ?? []) }
                // Counted before the read, so a read iOS ends by closing the
                // app still counts as a try.
                let tries = ModelFinder.catchUpTriesSoFar(episode.guid) + 1
                ModelFinder.setCatchUpTries(episode.guid, tries)
                do {
                    JobHeartbeat.shared.startJob()
                    let seconds = try await self.detectAndSave(episode, segments: segments,
                                                               silences: episode.silenceRanges,
                                                               inserted: episode.insertedSpans,
                                                               produced: episode.producedSpans,
                                                               context: context, settings: settings,
                                                               quiet: true, finder: request)
                    let run = self.lastFinderRun
                    if run?.byModel == true || run?.finder == "apple" {
                        if run?.finder == "apple" {
                            episode.modelPending = false
                            try? context.save()
                        }
                        ModelFinder.setCatchUpTries(episode.guid, nil)
                    } else if run?.deferred == true {
                        // He left the app: not a try. The rest wait for him.
                        ModelFinder.setCatchUpTries(episode.guid, tries - 1)
                        self.modelCatchUpTried.remove(episode.guid)
                        return
                    }
                    if old, run?.byModel == true { Self.countOldEpisodeRead() }
                    BackgroundLog.shared.note((run?.logLine(totalSeconds: seconds) ?? "Checked")
                                              + (old ? " · an older episode, while charging" : " · catching up") + " — \(episode.title)")
                    self.recordTiming(episode, seconds: seconds, audioSeconds: segments.last?.end ?? episode.duration,
                                      relabel: true, run: run)
                    if PlayerEngine.shared.currentEpisode?.guid == episode.guid {
                        PlayerEngine.shared.refreshSkipRanges()
                    }
                    CountsCache.invalidate(episode.podcast)
                } catch {
                    return
                }
            }
        }
    }

    /// A catch-up read in the timing log, like a re-label's.
    private func recordTiming(_ episode: Episode, seconds: Double, audioSeconds: Double,
                              relabel: Bool, run: ModelFinder.Run?) {
        let battery = UIDevice.current.batteryState
        TimingLog.shared.record(ProcessingTiming(
            date: .now, show: episode.podcast?.title ?? "", episode: episode.title,
            audioSeconds: audioSeconds, transcribeSeconds: nil, analyzeSeconds: nil, detectSeconds: seconds,
            thermalAtStart: Diagnostics.thermalName, thermalAtEnd: Diagnostics.thermalName,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            onPower: battery == .charging || battery == .full,
            foreground: UIApplication.shared.applicationState == .active,
            device: Diagnostics.deviceModel, build: BuildInfo.commit,
            adFree: nil, detectorVersion: AdDetector.version, relabel: relabel, finder: run))
    }

    private func stopModelCatchUp() {
        modelCatchUpTask?.cancel()
        modelCatchUpTask = nil
        modelCatchUpRemaining = 0
        modelCatchUpTitle = nil
        modelCatchUpToken = UUID()
    }

    /// An episode the reader alone labelled, for the model to read — at most
    /// five a day, only while the app is open and the phone is charging.
    private func oldEpisodeForModel(excluding tried: Set<String>) -> Episode? {
        guard let context = modelContext, Self.oldEpisodeReadsToday() < ModelFinder.oldEpisodesPerDay else { return nil }
        let battery = UIDevice.current.batteryState
        guard battery == .charging || battery == .full else { return nil }
        let current = ModelFinder.version
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.lastProcessedAt != nil && $0.modelVersion < current },
            sortBy: [SortDescriptor(\.lastProcessedAt, order: .reverse)])
        descriptor.fetchLimit = 10
        return ((try? context.fetch(descriptor)) ?? []).first { !tried.contains($0.guid) && $0.hasTranscript }
    }

    private static let oldReadsKey = "modelOldEpisodeReads"

    private static func oldEpisodeReadsToday() -> Int {
        guard let entry = UserDefaults.standard.dictionary(forKey: oldReadsKey),
              let day = entry["day"] as? String, day == today else { return 0 }
        return entry["count"] as? Int ?? 0
    }

    private static func countOldEpisodeRead() {
        UserDefaults.standard.set(["day": today, "count": oldEpisodeReadsToday() + 1], forKey: oldReadsKey)
    }

    private static var today: String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    // MARK: - Keeping processed episodes current (D14, D22)

    /// The maintenance loop, held so a job someone asks for can stop it.
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var maintenanceToken = UUID()
    @ObservationIgnored private var styleTask: Task<Void, Never>?
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
            // Pass 25: a re-label is PodSkipper's own reader over a stored
            // transcript — seconds of the processor, no Apple model — so it
            // also runs on battery while he has the app open. Away from the
            // app on battery, still nothing starts on its own.
            guard battery == .charging || battery == .full
                    || UIApplication.shared.applicationState == .active else { return false }
        }
        return true
    }

    /// Re-labels, from their stored transcripts, the episodes whose cuts an
    /// older ad finder made (D22): newest first, one at a time, and only
    /// while nothing else is running. Never downloads or transcribes; cuts
    /// the listener touched are kept by `detectAndSave`.
    func maintain(limit: Int = 100) {
        guard maintenanceTask == nil, modelCatchUpTask == nil, !isRunning, !pausedLine.isPaused, backgroundJob == nil, mayMaintain(),
              let context = modelContext, let settings else { return }
        let token = UUID()
        maintenanceToken = token
        maintenanceTask = Task { [weak self] in
            defer { if self?.maintenanceToken == token { self?.maintenanceTask = nil } }
            let current = AdDetector.version
            for _ in 0..<limit {
                guard let self, !Task.isCancelled, !self.isRunning, self.mayMaintain() else { return }
                var descriptor = FetchDescriptor<Episode>(
                    predicate: #Predicate { $0.lastProcessedAt != nil && $0.detectorVersion < current },
                    sortBy: [SortDescriptor(\.lastProcessedAt, order: .reverse)])
                descriptor.fetchLimit = 1
                guard let episode = try? context.fetch(descriptor).first else { return }
                do {
                    let lease = try await HeavyWorkCoordinator.shared.acquire(owner: "maintenance:" + episode.guid, priority: .maintenance)
                    defer { HeavyWorkCoordinator.shared.release(lease) }
                    try Task.checkCancellation()
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
                        // Its own count of unanswered questions (pass 22).
                        JobHeartbeat.shared.startJob()
                        let seconds = try await self.detectAndSave(episode, segments: segments,
                                                                   silences: episode.silenceRanges,
                                                                   inserted: episode.insertedSpans,
                                                                   produced: episode.producedSpans,
                                                                   context: context, settings: settings, quiet: true,
                                                                   finder: .readerOnly)
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
                            adFree: nil, detectorVersion: current, relabel: true, finder: self.lastFinderRun))
                        if PlayerEngine.shared.currentEpisode?.guid == episode.guid {
                            PlayerEngine.shared.refreshSkipRanges()
                        }
                        self.classifyMissingStyles([episode])
                    } catch {
                        // The model is unavailable or the task was stopped: try
                        // again another time rather than marking it done.
                        return
                    }
                } catch { return }
                // Release the resource before resting between episodes.
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
        maintenanceToken = UUID()
    }

    /// How each found ad was delivered — host-read, and played for laughs —
    /// for the keep-host-reads and keep-funny-reads switches (funny reads are
    /// kept by default). PodSkipper's reader settles produced spots itself
    /// (stitched in, a recording heard in other episodes, small print); the
    /// rest is one short question per ad to Apple's model, asked only when
    /// iOS lets it answer at once — on screen, or on power — and never as
    /// part of a job, so finding ads never waits for it (pass 25). An ad not
    /// yet known to be a bit is cut. With no episodes given: the one playing
    /// and the Up Next queue.
    func classifyMissingStyles(_ only: [Episode]? = nil) {
        guard styleTask == nil, let context = modelContext, AdDetector.styleQuestionsAllowed else { return }
        var episodes: [Episode]
        if let only {
            episodes = only
        } else {
            let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.isInQueue })
            episodes = (try? context.fetch(descriptor)) ?? []
            if let playing = PlayerEngine.shared.currentEpisode { episodes.insert(playing, at: 0) }
        }
        styleTask = Task { [weak self] in
            guard let self else { return }
            defer { self.styleTask = nil }
            for episode in episodes.prefix(10) {
                let missing = episode.adSegments.filter { $0.kind == .ad && $0.deliveryRaw.isEmpty && !$0.isReviewed }
                guard !missing.isEmpty else { continue }
                let lease: HeavyWorkCoordinator.Lease
                do {
                    lease = try await HeavyWorkCoordinator.shared.acquire(owner: "styles:" + episode.guid, priority: .maintenance)
                } catch { return }
                defer { HeavyWorkCoordinator.shared.release(lease) }
                guard !Task.isCancelled else { return }
                let lines = await episode.loadTranscript()
                var changed = false
                for segment in missing {
                    guard AdDetector.styleQuestionsAllowed, !self.isRunning || self.currentEpisodeGUID != episode.guid else { break }
                    let text = lines.filter { $0.start < segment.end && $0.end > segment.start }.map(\.text).joined(separator: " ")
                    guard !text.isEmpty else { continue }
                    let probe = DetectedSegment(start: segment.start, end: segment.end, kind: .ad, sponsor: segment.sponsor, confidence: segment.confidence)
                    if let style = await self.detector.classifyStyle(of: probe, text: text) {
                        guard !Task.isCancelled else { return }
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
        // Into his line, all at once, so the Activity screen shows them and a
        // relaunch keeps them. They used to go straight to `process` one
        // after another and never appeared in the line at all (pass 21).
        let jobs = episodes.filter { !isProcessing($0) }.compactMap { addToLine($0) }
        for (index, job) in jobs.enumerated() {
            queueRemaining = jobs.count - index - 1
            await job.value
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
            $0.processingState != .ready && $0.processingState != .failed && !stoppedByUser.contains($0.guid)
        }
        guard !worth.isEmpty, !pausedLine.isPaused else { return }
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
                guard episode.processingState != .ready,
                      !self.stoppedByUser.contains(episode.guid) else { continue }
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
        // Callers such as publishing join the real task, including an
        // existing rerun whose episode still has older ready results.
        if pausedLine.contains(episode.guid) { resumeLine() }
        jobs.deferRetry(episode.guid, until: nil)
        if isProcessing(episode) {
            if stalledSince != nil { await restart(episode) }
            else if let job = userTasks[episode.guid] ?? currentJob { await job.value }
            return
        }
        guard let job = addToLine(episode) else { return }
        await job.value
    }

    /// Several at once (a selection): all join the line in this order at
    /// once. They used to be asked for one after another, each waiting for
    /// the one before it to *finish*, so the line showed one episode and the
    /// rest existed only in a loop that a relaunch forgot (pass 21).
    func processNow(_ episodes: [Episode]) {
        if episodes.contains(where: { pausedLine.contains($0.guid) }) { resumeLine() }
        for episode in episodes where !isProcessing(episode) { _ = addToLine(episode) }
    }

    /// Joins the line now, synchronously, and returns the job's task. The
    /// wait for its turn runs in a task of its own, so whatever asked (a
    /// sheet, a row) going away can't cancel it out of the line.
    @ObservationIgnored private var userTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var userTaskTokens: [String: UUID] = [:]

    @discardableResult
    private func scheduleUserJob(_ episode: Episode) -> Task<Void, Never> {
        let guid = episode.guid
        if let existing = userTasks[guid] { return existing }
        let token = UUID()
        userTaskTokens[guid] = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.userTaskTokens[guid] == token {
                    self.userTasks[guid] = nil
                    self.userTaskTokens[guid] = nil
                    Task { @MainActor [weak self] in self?.resumeUnfinished() }
                }
            }
            await self.process(episode, origin: .user)
        }
        userTasks[guid] = task
        return task
    }

    @discardableResult
    private func addToLine(_ episode: Episode) -> Task<Void, Never>? {
        if let existing = userTasks[episode.guid] { return existing }
        guard jobs.storageError == nil else {
            BackgroundLog.shared.note(jobs.storageError ?? "Processing history is unavailable")
            return nil
        }
        if !waitingQueue.contains(episode.guid) { enqueue(episode.guid) }
        cancelBackgroundWork()
        if isRunning, currentOrigin == .automatic { cancelCurrentJob() }
        BackgroundLog.shared.note("Joined the line (\(waitingQueue.count) waiting): \(episode.title)")
        let task = scheduleUserJob(episode)
        if pausedLine.isPaused { resumeLine() }
        return task
    }

    /// His jobs waiting their turn, first in line first. Reported (23 Sep):
    /// Find Ads on a second episode took the first one's place instead of
    /// joining the line, and the same episode could be queued twice.
    var waitingQueue: [String] {
        get { jobs.waiting }
        set { jobs.setWaitingOrder(newValue) }
    }
    /// Jobs of his finished, and in total, since the line was last empty —
    /// the banner's "2/5".
    private(set) var batchDone = 0
    private(set) var batchTotal = 0

    /// The first episode in line (kept for older callers).
    var waitingToProcess: String? { waitingQueue.first }

    var resourceWaitingReason: String? {
        guard !isRunning, let first = waitingQueue.first else { return nil }
        if let retry = jobs.record(first)?.retryAfter, retry > .now {
            return retry == .distantFuture ? "Waiting until you open PodSkipper or choose Resume"
                : "Waiting briefly before retrying after an interruption"
        }
        guard let owner = resources.current?.owner else { return nil }
        if owner.hasPrefix("benchmark:") { return "Waiting for the model comparison to finish" }
        return "Waiting for the previous task to release its resources"
    }

    func isWaiting(_ guid: String?) -> Bool {
        guard let guid else { return false }
        return waitingQueue.contains(guid)
    }

    private func enqueue(_ guid: String) {
        if !isRunning && waitingQueue.isEmpty { batchDone = 0; batchTotal = 0; prepCredit = [:] }
        markStopped(guid, false)
        waitingQueue.append(guid)
        batchTotal += 1
        // Written down the moment it joins the line, not when its turn
        // comes. Reported (27 Sep): an episode he added to the line was
        // gone later. The line lived only in memory, and the app crashed
        // (a separate bug, fixed) while it waited; after the relaunch only
        // the job that had started came back.
        setUnfinished(guid, true)
    }

    /// Stops his running job for good: it is not picked up again later.
    /// The transcript and answers so far are kept for next time.
    ///
    /// Reported (24 Sep): Stop didn't stop an automatic job stuck in
    /// transcription. The transcriber ignored the cancel, and the job the
    /// app had given itself started the same episode again a few seconds
    /// later. Now Stop lets go of a step that doesn't end within four
    /// seconds (as Restart does), and the app doesn't pick the episode up by
    /// itself again: only Find Ads does.
    func stopJob(_ episode: Episode) {
        guard isProcessing(episode) else { return }
        let guid = episode.guid
        setUnfinished(guid, false)
        markStopped(guid, true)
        dropPrep(guid)
        BackgroundLog.shared.note("Stopped by you at \(stage.label) \(Int(overallFraction * 100))%")
        stopping = true
        let token = jobToken
        if currentOrigin == .automatic {
            cancelBackgroundWork()
            deferredSpeculative.removeAll { $0.guid == guid }
        }
        cancelCurrentJob()
        Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(4)
            while let self, self.isRunning, self.jobToken == token, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let self, self.isRunning, self.jobToken == token else { return }
            BackgroundLog.shared.note("Stop: the step didn't end by itself within 4 s; let go of it")
            self.endJob(token, abandoned: true)
            if episode.processingState != .ready { episode.processingState = .notStarted }
            try? self.modelContext?.save()
        }
    }

    // MARK: - Pause and resume (task 14)

    /// Pauses his line: the running job stops at the end of its step, keeping
    /// its download, transcript and answers (the same things Stop keeps), and
    /// it and everything waiting behind it are held, in order, until he
    /// resumes. Held jobs are not outstanding work, so continued processing
    /// ends and nothing else starts.
    ///
    /// A step that can't be interrupted (a model window, a transcription
    /// chunk) finishes first; `pausing` is true until then. Like Stop, a step
    /// that hasn't ended within four seconds is let go of, and the log says so.
    func pauseJob(_ episode: Episode) {
        guard isProcessing(episode), !pausing, !stopping else { return }
        let guid = episode.guid
        pausing = true
        pausedLine.hold(running: guid, waiting: waitingQueue)
        // Out of the live line, so nothing starts behind it when it ends.
        // The tasks waiting their turn see they are gone and return.
        for held in pausedLine.guids { setUnfinished(held, false) }
        waitingQueue = []
        cancelBackgroundWork()
        deferredSpeculative.removeAll()
        BackgroundLog.shared.note("Paused by you at \(stage.label) \(Int(overallFraction * 100))% (\(pausedLine.guids.count) held)")
        let token = jobToken
        cancelCurrentJob()
        Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(4)
            while let self, self.isRunning, self.jobToken == token, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard let self, self.isRunning, self.jobToken == token else { return }
            BackgroundLog.shared.note("Pause: the step didn't end by itself within 4 s; let go of it")
            self.endJob(token, abandoned: true)
            if episode.processingState != .ready { episode.processingState = .notStarted }
            try? self.modelContext?.save()
        }
    }

    /// Carries on from where it stopped: everything held rejoins the line in
    /// its old order. The transcript and answers are reused, so it continues
    /// from the same place rather than starting again.
    func resumeLine() {
        guard pausedLine.isPaused, let context = modelContext else { return }
        let order = pausedLine.release()
        BackgroundLog.shared.note("Resumed by you (\(order.count) in the line)")
        for guid in order where !waitingQueue.contains(guid) {
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
            descriptor.fetchLimit = 1
            guard let episode = try? context.fetch(descriptor).first else { continue }
            // If Pause is still unwinding, its task schedules the resumed
            // record when cleanup ends. Keep this episode in its old place.
            enqueue(guid)
            if !isProcessing(episode) { _ = scheduleUserJob(episode) }
        }
    }

    /// Pull to refresh on the activity window (his 24 Sep report: it checked
    /// feeds instead). Re-reads the line, drops anything already finished,
    /// flags a job that hasn't moved for a minute so Restart shows at once,
    /// asks iOS again to carry on, and picks up a paused job of his.
    func refreshLine() async {
        jobs.flush()
        if let context = modelContext {
            for guid in waitingQueue {
                var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
                descriptor.fetchLimit = 1
                if (try? context.fetch(descriptor).first) == nil {
                    cancelWaiting(guid)
                }
            }
        }
        if isRunning {
            let last = max(lastProgressAt, JobHeartbeat.shared.last)
            if Date().timeIntervalSince(last) > 60, stalledSince == nil { stalledSince = last }
            if currentOrigin == .user { BackgroundWork.shared.workStarted() }
        } else {
            resumeUnfinished()
        }
        BackgroundLog.shared.note("Line refreshed by you: \(isRunning ? "\(stage.label) \(Int(overallFraction * 100))%" : "nothing running"), \(waitingQueue.count) waiting")
        try? await Task.sleep(for: .milliseconds(400))
    }

    /// Errors hit while he was away, per episode: tried again twice, then
    /// left for when he's back (pass 21b).
    @ObservationIgnored private var awayRetries: [String: Int] = [:]

    /// Stop was pressed and the job hasn't ended yet (up to 4 s): the
    /// button says Stopping… rather than looking ignored.
    private(set) var stopping = false

    /// Episodes he stopped. The app's own work (getting Up Next ready,
    /// the overnight window) leaves them alone until he presses Find Ads.
    var stoppedByUser: Set<String> { jobs.stopped }

    private func markStopped(_ guid: String, _ on: Bool) {
        if on { jobs.stop(guid) } else { jobs.permitRetry(guid) }
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

    /// Drag to reorder on the Activity screen. The next job is simply
    /// whichever is first when the current one ends.
    func moveInLine(from offsets: IndexSet, to destination: Int) {
        waitingQueue.move(fromOffsets: offsets, toOffset: destination)
        saveLineOrder()
    }

    /// A paused job he doesn't want resumed (swipe on the Activity screen).
    func forgetPaused(_ guid: String) {
        if pausedLine.contains(guid) {
            pausedLine.drop(guid)
                // Stopped, not just dropped: the app must not pick it up itself.
            markStopped(guid, true)
        }
        setUnfinished(guid, false)
        dropPrep(guid)
    }

    /// Takes an episode out of the line before it starts.
    func cancelWaiting(_ guid: String) {
        guard waitingQueue.contains(guid) else { return }
        markStopped(guid, true)
        batchTotal = max(batchDone, batchTotal - 1)
        setUnfinished(guid, false)
        dropPrep(guid)
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

    // MARK: - Getting the next job ready while the model waits (pass 20)
    //
    // His 24 Sep diagnostics: with the phone locked, iOS makes the on-device
    // model wait (3–15 times per trip away) and then ends the task whose bar
    // has stopped moving. The model is the only step iOS slows like that.
    // So while his job waits on it away from the app, the next job in his
    // line does everything that needs no model — download, transcript,
    // silences, fingerprints, the ad-free comparison — and the Lock Screen
    // bar keeps moving with real work. When that job's turn comes it goes
    // straight to finding ads.

    /// The ad-free comparison's share of the "Finding ads" step.
    static let adFreeShare = 0.03

    struct Prepared {
        var inserted: [InsertedSpan]
        /// Nil when getting ready stopped short of the fingerprints (pass
        /// 21b: in the background it only downloads and compares).
        var produced: [AdPrints.Produced]?
        var adFree: AdFreeCopy.Outcome?
    }
    @ObservationIgnored private var prepared: [String: Prepared] = [:]
    @ObservationIgnored private var prepJob: Task<Void, Never>?
    /// The episode being got ready ahead of its turn.
    private(set) var preparingGUID: String?
    /// Each prepared (or preparing) episode's share of its job already done.
    @ObservationIgnored private var prepCredit: [String: Double] = [:]
    /// The running job's share done ahead of its turn.
    @ObservationIgnored private var currentCredit = 0.0

    /// Jobs finished plus the share of the ones under way, 0...batchTotal —
    /// the Lock Screen's number. Only ever rises while the line runs.
    var batchCompleted: Double {
        let current = isRunning && currentOrigin == .user ? currentCredit + (1 - currentCredit) * overallFraction : 0
        return min(Double(max(1, batchTotal)), Double(batchDone) + current + prepCredit.values.reduce(0, +))
    }

    func isPreparing(_ guid: String?) -> Bool { guid != nil && preparingGUID == guid }

    func startPrepIfUseful() {
        guard prepJob == nil, isRunning, currentOrigin == .user, stage == .detecting,
              UIApplication.shared.applicationState == .background,
              let context = modelContext, let settings else { return }
        // Not on a hot phone (pass 21). His 27 Sep Diagnostics: getting the
        // next one ready (a second transcriber beside the model) ran while
        // the phone went to "serious", and iOS ends background tasks first
        // under that kind of pressure. His own job matters more than a head
        // start on the next.
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            BackgroundLog.shared.note("Not getting the next one ready: the phone is hot")
            return
        default: break
        }
        for guid in waitingQueue.prefix(2) where prepared[guid] == nil {
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
            descriptor.fetchLimit = 1
            guard let episode = try? context.fetch(descriptor).first, !episode.isVideo,
                  episode.processingState != .ready else { continue }
            let plan = Self.plan(for: episode)
            let total = Stage.ordered.reduce(0) { $0 + (plan[$1] ?? 0) }
            let ahead = plan[.downloading] ?? 0   // only the download is done ahead now (pass 21b)
            let share = total > 0 ? ahead / total : 0
            preparingGUID = guid
            BackgroundLog.shared.note("Getting the next one ready while this one finishes — \(episode.title)")
            prepJob = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.prepare(episode, share: share, settings: settings, context: context)
                if self.preparingGUID == guid { self.preparingGUID = nil }
                self.prepJob = nil
                self.startPrepIfUseful()
            }
            return
        }
    }

    private func notePrep(_ guid: String, share: Double, _ fraction: Double, transcribing: Double? = nil) {
        if currentEpisodeGUID == guid {
            // Its turn came while it was still being got ready: its own row
            // and bar follow the transcript being made.
            if let transcribing { stage = .transcribing; stageFraction = max(stageFraction, transcribing) }
        } else if prepared[guid] == nil {
            prepCredit[guid] = max(prepCredit[guid] ?? 0, share * fraction)
        }
    }

    private func prepare(_ episode: Episode, share: Double, settings: AppSettings, context: ModelContext) async {
        let guid = episode.guid
        do {
            let hasAudio = episode.analysableFileURL != nil
            if !hasAudio {
                let filename = try await download(episode)
                episode.localFilename = filename
                FileIndex.insert(filename)
                LibraryTotals.shared.invalidate()
                try? context.save()
            }
            notePrep(guid, share: share, 0.1)
            try Task.checkCancellation()
            // Only fetch the bytes ahead. Comparing decoded audio waits for
            // the episode's owned heavy-work slot, preserving phone memory.
            prepared[guid] = Prepared(inserted: [], produced: nil, adFree: nil)
            notePrep(guid, share: share, 1)
            BackgroundLog.shared.note("Got ready ahead (download): \(episode.title)")
        } catch {
            prepCredit[guid] = nil
            BackgroundLog.shared.note("Getting ahead stopped (\(Task.isCancelled ? "cancelled" : error.localizedDescription)): \(episode.title)")
        }
    }

    /// The ad-free comparison's answer, waited for at most two minutes.
    private static func awaitAdFree(_ job: Task<AdFreeCopy.Outcome, Never>?) async -> AdFreeCopy.Outcome? {
        guard let job else { return nil }
        return await withTaskGroup(of: AdFreeCopy.Outcome?.self) { group in
            group.addTask { await job.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(120))
                job.cancel()
                return nil
            }
            var result: AdFreeCopy.Outcome?
            for await value in group {
                if let value { result = value; group.cancelAll() }
            }
            return result ?? AdFreeCopy.Outcome()
        }
    }

    /// Drops what was got ready for an episode taken out of the line.
    private func dropPrep(_ guid: String) {
        if preparingGUID == guid { prepJob?.cancel() }
        prepared[guid] = nil
        prepCredit[guid] = nil
    }

    /// Waits for the getting-ready of this episode, if it's under way, before
    /// its own job does the same work twice.
    private func joinPrep(_ guid: String) async {
        guard preparingGUID == guid, let prep = prepJob else { return }
        stage = .downloading
        await withTaskCancellationHandler {
            await prep.value
        } onCancel: {
            prep.cancel()
        }
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
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled else { return }
            if !DemoData.isEnabled, (Self.lastFeedRefresh.map { Date.now.timeIntervalSince($0) >= 30 * 60 } ?? true) {
                _ = await self.refreshAllFeeds(queueNewEpisodes: queueNewEpisodes)
            }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            // Do not compete with the first interactive scroll on a hot phone.
            // Catalogue indexing and transcript migration are useful housekeeping,
            // but they are not launch-critical work.
            if UIApplication.shared.applicationState == .active,
               Diagnostics.thermalName == "nominal",
               !ProcessInfo.processInfo.isLowPowerModeEnabled {
                LibraryIndexStatus.shared.indexCatalogues()
                await LibraryIndexStatus.shared.moveTranscriptsToFiles()
            }
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { return }
            self.maintain()
            self.classifyMissingStyles()
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
            // Fetched, not `model(for:)`: that never says no, and an
            // identifier that names nothing comes back as a shell whose
            // first property read is a crash.
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.persistentModelID == id })
            descriptor.fetchLimit = 1
            guard let episode = try? context.fetch(descriptor).first else { continue }
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

    /// Only live or queued owners protect data. Historical completion and
    /// explicit stops do not prevent the listener from reclaiming storage.
    var protectedCleanupGUIDs: Set<String> {
        let processing = jobs.records.values.filter { $0.status == .queued || $0.status == .running }.map(\.guid)
        let publishing = PublishQueue.shared.jobs.filter { !$0.state.isFinished }.map(\.episodeGUID)
        let owners = [resources.current?.owner].compactMap { $0 } + resources.waitingOwners
        return Self.cleanupProtectedGUIDs(active: [currentEpisodeGUID, preparingGUID,
            PlayerEngine.shared.currentEpisode?.guid, FeedPublisher.shared.currentEpisodeGUID],
            queued: Set(processing + publishing), owners: owners).union(VideoAudio.protectedGUIDs)
    }

    static func cleanupProtectedGUIDs(active: [String?], queued: Set<String>, owners: [String]) -> Set<String> {
        var guids = queued.union(active.compactMap { $0 })
        for owner in owners {
            for prefix in ["episode:", "catchup:", "maintenance:", "styles:", "video:", "publish:"]
                where owner.hasPrefix(prefix) {
                let guid = String(owner.dropFirst(prefix.count))
                if !guid.isEmpty { guids.insert(guid) }
            }
        }
        return guids
    }

    /// Called only after explicit transcript/cache deletion succeeds, after
    /// every reader of that episode has unwound. Pause/stop intent is kept.
    @discardableResult
    func invalidateDeletedTranscript(_ guid: String, keepDownloadStage: Bool = true) -> Bool {
        guard !protectedCleanupGUIDs.contains(guid),
              jobs.invalidateTranscriptCheckpoint(guid, keepDownloadStage: keepDownloadStage) else { return false }
        prepared[guid] = nil
        prepCredit[guid] = nil
        return true
    }

    /// Delete downloaded audio. Transcripts and detected ads are kept, so a
    /// cleared episode only needs re-downloading, not re-analysing.
    ///
    /// Enumeration runs off the main thread. Each short unlink shares an
    /// actor turn with its live ownership check, with a yield between chunks.
    /// Failed files keep their references and do not count as freed space.
    @discardableResult
    func clearDownloads(in directory: URL = FileStore.episodesDirectory,
                        removeItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
                        retire: @escaping @Sendable (String) -> Void = { FileIndex.remove($0) }) async
        -> (files: Int, bytes: Int64, failed: Int, kept: Int) {
        guard let context = modelContext else { return (0, 0, 0, 0) }
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate {
            $0.localFilename != nil || $0.extractedAudioFilename != nil
        })
        guard let episodes = try? context.fetch(descriptor) else { return (0, 0, 1, 0) }
        let referenced = Set(episodes.flatMap { [$0.localFilename, $0.extractedAudioFilename].compactMap { $0 } })
        let files = await Task.detached(priority: .userInitiated) { () -> Set<String> in
            let fm = FileManager.default
            return Set(((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                .map(\.lastPathComponent))
        }.value
        var result = FileStore.DeletionResult(), kept = Set<String>()
        var protectedNames = Set<String>(), companions = Set<String>()
        var unknownWriter = false
        for (index, name) in files.union(referenced).sorted().enumerated() {
            if Task.isCancelled { break }
            // Recheck in the same actor turn as unlinking. A background
            // deletion with an old snapshot could remove a newly started job.
            if index % 16 == 0 {
                if index > 0 { await Task.yield() }
                if Task.isCancelled { break }
                let protected = protectedCleanupGUIDs
                let live = episodes + [currentEpisode, PlayerEngine.shared.currentEpisode].compactMap { $0 }
                protectedNames = Set(live.filter { protected.contains($0.guid) }
                    .flatMap { [$0.localFilename, $0.extractedAudioFilename].compactMap { $0 } })
                companions = Set(protectedNames.map { MediaExtractor.audioFilename(for: $0) })
                // A queued/prepared episode can acquire a filename after the
                // initial database snapshot. Its bytes are temporarily an
                // unreferenced file here, even after its downloader finishes.
                unknownWriter = !protected.isEmpty || preparingGUID != nil ||
                    (isRunning && stage == .downloading) || FeedPublisher.shared.isPublishing
            }
            if protectedNames.contains(name) || companions.contains(name) || VideoAudio.protectedFilenames.contains(name)
                || (!referenced.contains(name) && unknownWriter) {
                kept.insert(name); continue
            }
            let one = FileStore.deleteNamedFiles([name], in: directory, removeItem: removeItem, retire: retire)
            result.removed.formUnion(one.removed); result.absent.formUnion(one.absent)
            result.failed.formUnion(one.failed); result.bytes += one.bytes
        }
        for episode in episodes {
            if let name = episode.localFilename, result.canRetireAudioReference(name) { episode.localFilename = nil }
            if let name = episode.extractedAudioFilename, result.canRetireAudioReference(name) { episode.extractedAudioFilename = nil }
        }
        LibraryTotals.shared.invalidate()
        var saveFailures = 0
        do { try context.save() } catch { saveFailures = 1 }
        return (result.removed.count, result.bytes, result.failed.count + saveFailures, kept.count)
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
        let pending = Array(queued.filter {
            $0.processingState != .ready && (origin == .user || !stoppedByUser.contains($0.guid))
        }.prefix(limit))
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
        let ownership = VideoAudio.protect(guid: episode.guid)
        defer { VideoAudio.release(ownership) }
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
        // Keep the original extension; AVAudioFile cares.
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let filename = "\(UUID().uuidString).\(ext)"
        let destination = FileStore.episodesDirectory.appendingPathComponent(filename)

        // Pass 24: the bar moves with the bytes. His 29 Sep Diagnostics
        // (81eb4a3): "iOS ended the carry-on task early after 31 s at
        // Downloading audio 0%" — the old one-shot download said nothing
        // until the whole file was in, so iOS saw a job standing still.
        let box = DownloadTaskBox()
        let token = jobToken
        let watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.jobToken == token, self.isRunning,
                      self.currentEpisodeGUID == episode.guid, self.stage == .downloading else { return }
                if let fraction = box.fraction, fraction > 0 { self.stageFraction = min(0.99, fraction) }
            }
        }
        defer { watcher.cancel() }
        let response: URLResponse = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URLResponse, Error>) in
                // The temporary file is gone once this handler returns, so it
                // is moved inside it.
                let task = Self.downloadSession.downloadTask(with: url) { tempURL, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let tempURL, let response else { continuation.resume(throwing: URLError(.badServerResponse)); return }
                    do {
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: tempURL, to: destination)
                        continuation.resume(returning: response)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.set(task)
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            box.cancel()
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: destination)
            throw URLError(.badServerResponse)
        }
        return filename
    }

    // MARK: - Background scheduling

    /// Register at launch. iOS decides when to actually run this — typically
    /// overnight while charging on Wi-Fi, which is exactly when you want an
    /// hour of transcription happening.
    static func registerBackgroundTask(handler: @escaping @Sendable () async -> Void) {
        // Registering a name Info.plist doesn't declare stops the app at
        // launch; under an unexpected bundle ID it simply goes without.
        guard BackgroundIDs.isDeclaredForThisApp else { return }
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
    static var refreshTaskID: String { BackgroundIDs.refresh }

    static func registerRefreshTask(handler: @escaping @Sendable () async -> Void) {
        guard BackgroundIDs.isDeclaredForThisApp else { return }
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
        Task {
            do { try await BackgroundWork.submit(request) }
            catch { BackgroundLog.shared.note("iOS did not schedule background work: \(BackgroundWork.describe(error))") }
        }
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
        Task {
            do { try await BackgroundWork.submit(request) }
            catch { BackgroundLog.shared.note("iOS did not schedule background work: \(BackgroundWork.describe(error))") }
        }
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

/// The running download, shared between the pipeline (which reads its
/// progress twice a second) and the cancellation handler (pass 24).
private final class DownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?

    func set(_ task: URLSessionDownloadTask) { lock.withLock { self.task = task } }
    func cancel() { lock.withLock { task }?.cancel() }

    /// Nil until the server has said how big the file is.
    var fraction: Double? {
        guard let progress = lock.withLock({ task?.progress }), progress.totalUnitCount > 0 else { return nil }
        return progress.fractionCompleted
    }
}
