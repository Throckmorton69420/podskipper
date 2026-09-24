import Foundation
import BackgroundTasks
import UIKit

/// Keeps a job you started running after you leave the app.
///
/// iOS gives a backgrounded app about thirty seconds. Finding ads in an hour
/// of audio takes minutes, and publishing uploads tens of megabytes, so until
/// now leaving the app mid-job froze it until you came back. The earlier
/// suggestion of holding some unrelated permission — location, say — to stay
/// awake is the thing the system is built to catch: it costs battery all day,
/// and a background mode an app does not really use is exactly what gets an
/// app's background time taken away.
///
/// iOS 26 added the supported way: `BGContinuedProcessingTask`, for work the
/// user started in the foreground. The app asks to continue, the system shows
/// its own progress UI on the Lock Screen and in the Dynamic Island, and the
/// app keeps running while it reports progress. The system can still end it
/// under pressure — it ends the tasks reporting the least progress first,
/// which is why progress is updated every second from the real job.
///
/// Unverified on a device: whether on-device transcription and the language
/// model are allowed to run in this state, and whether a sideloaded build
/// signed by KSign keeps the identifier declared in Info.plist.
@MainActor
final class BackgroundWork {

    static let shared = BackgroundWork()

    /// The prefix every continued-processing request is named with.
    ///
    /// Apple requires these identifiers to start with the app's bundle ID and
    /// be declared in Info.plist as a wildcard (`<bundle>.continue.*`), each
    /// request carrying its own unique suffix. Until pass 18 the app asked
    /// with the fixed name `com.yourname.podskipper.continue`, which is not
    /// that form: the request was refused, the thirty-second fallback was all
    /// there was, and processing stopped soon after the screen locked. The
    /// prefix is read from Info.plist itself, so it stays right if the app is
    /// re-signed under another bundle ID.
    static var prefix: String {
        let declared = (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? [])
            .first { $0.hasSuffix(".continue.*") }
        if let declared { return String(declared.dropLast(2)) }
        return (Bundle.main.bundleIdentifier ?? "com.yourname.podskipper") + ".continue"
    }

    struct Snapshot: Equatable {
        var title: String
        var subtitle: String
        var fraction: Double
    }

    /// Asked once a second while work is outstanding. Returns nil when there is
    /// nothing left, which ends the task. Set by the app.
    var status: (@MainActor () -> Snapshot?)?
    /// Whether more work is lined up behind a pause (a queue between jobs).
    var moreToCome: (@MainActor () -> Bool)?

    private var task: BGContinuedProcessingTask?
    private var submitted = false
    private var monitor: Task<Void, Never>?
    private var registered = false
    private var fallback: UIBackgroundTaskIdentifier = .invalid
    private var adoptedAt: Date?

    private init() {}

    /// Kept for the call at launch. Continued-processing identifiers are
    /// registered one at a time, just before each is submitted (Apple's
    /// pattern for them), so there is nothing to do here.
    func register() {
        registered = true
    }

    /// Why the last request was refused, for Diagnostics.
    private(set) var lastRefusal: String?

    /// Called whenever a job starts. Cheap to call repeatedly.
    ///
    /// The request has to be made while the app is on screen — iOS refuses
    /// one from the background — so a job that starts there (the next in a
    /// queue) relies on the task already running, which stays alive while
    /// any work is left (see `startMonitor`).
    func workStarted() {
        startMonitor()
        guard !submitted, task == nil, let snapshot = status?(),
              UIApplication.shared.applicationState != .background else { return }
        let identifier = Self.prefix + "." + UUID().uuidString.prefix(8)
        let accepted = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in BackgroundWork.shared.adopt(continued) }
        }
        guard accepted else {
            lastRefusal = "identifier \(identifier) not declared"
            BackgroundLog.shared.note("iOS refused to let the job carry on: \(lastRefusal ?? "")")
            beginFallback()
            return
        }
        func request(gpu: Bool) -> BGContinuedProcessingTaskRequest {
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: snapshot.title,
                                                           subtitle: snapshot.subtitle)
            // Queue rather than fail: if the system cannot start it this
            // instant it starts it as soon as it can, and the short fallback
            // covers the gap.
            request.strategy = .queue
            if gpu { request.requiredResources = .gpu }
            return request
        }
        // The graphics chip in the background needs an entitlement a
        // sideloaded build may not carry, so ask with it where the phone
        // supports it and without it if that is refused.
        let wantsGPU = BGTaskScheduler.supportedResources.contains(.gpu)
        do {
            try BGTaskScheduler.shared.submit(request(gpu: wantsGPU))
            submitted = true
            lastRefusal = nil
            BackgroundLog.shared.note("Asked iOS to let the job carry on (\(wantsGPU ? "with" : "without") graphics chip) — accepted")
        } catch {
            do {
                if wantsGPU {
                    try BGTaskScheduler.shared.submit(request(gpu: false))
                    submitted = true
                    lastRefusal = nil
                    BackgroundLog.shared.note("Asked iOS to let the job carry on — accepted without the graphics chip (\(Self.describe(error)))")
                }
                else { throw error }
            } catch {
                // Not permitted or not supported. The thirty-second
                // assertion is all there is then.
                lastRefusal = Self.describe(error)
                BackgroundLog.shared.note("iOS refused to let the job carry on: \(lastRefusal ?? "")")
                beginFallback()
            }
        }
    }

    private func adopt(_ task: BGContinuedProcessingTask) {
        self.task = task
        adoptedAt = .now
        BackgroundLog.shared.note("iOS started the carry-on task")
        task.progress.totalUnitCount = 1000
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.noteInterrupted()
                self?.finish(success: false)
            }
        }
        startMonitor()
    }

    private func startMonitor() {
        guard monitor == nil else { return }
        beginFallback()
        monitor = Task { @MainActor [weak self] in
            var idleTicks = 0
            while !Task.isCancelled {
                guard let self else { return }
                if let snapshot = self.status?() {
                    idleTicks = 0
                    if let task = self.task {
                        task.progress.completedUnitCount = Int64(min(1, max(0, snapshot.fraction)) * 1000)
                        task.updateTitle(snapshot.title, subtitle: snapshot.subtitle)
                    }
                } else {
                    // Grace between one job and the next in a queue: the next
                    // one may be downloading or waiting a moment for the phone
                    // to cool. Once this task ends no new one can be asked for
                    // until the app is on screen again, so it is generous.
                    idleTicks += 1
                    if idleTicks >= (self.moreToCome?() == true ? 90 : 15) {
                        self.finish(success: true)
                        return
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The system stopped the job. It shows its own "failed" notice for that,
    /// which the app can't attach anything to, so remember which episode it
    /// was — opening the app next goes straight to it — and post a
    /// notification of our own that does know.
    private func noteInterrupted() {
        let pipeline = ProcessingPipeline.shared
        let ran = adoptedAt.map { Int(Date().timeIntervalSince($0)) }
        BackgroundLog.shared.note("iOS ended the carry-on task early"
                                  + (ran.map { " after \($0) s" } ?? "")
                                  + (pipeline.isRunning ? " at \(pipeline.stage.label) \(Int(pipeline.overallFraction * 100))%" : "")
                                  + " · model waits so far: \(JobHeartbeat.shared.peekRateLimited)")
        pipeline.saveCheckpointNow()
        guard pipeline.isRunning, let guid = pipeline.currentEpisodeGUID,
              let episode = pipeline.currentEpisode else { return }
        AppRouter.shared.noteInterrupted(guid)
        Task {
            await NotificationService.notifyJobProblem(
                episode, title: "Paused by iOS",
                body: "Everything so far is kept. It carries on by itself when you open PodSkipper.")
        }
    }

    /// iOS's reasons in words he can act on.
    static func describe(_ error: Error) -> String {
        if let error = error as? BGTaskScheduler.Error {
            switch error.code {
            case .unavailable:
                return "Background App Refresh is off for PodSkipper, or Low Power Mode is on (Settings → General → Background App Refresh). The Simulator always says this"
            case .notPermitted:
                return "not permitted — the name it asks with isn't declared for this app (bundle \(Bundle.main.bundleIdentifier ?? "?"))"
            case .tooManyPendingTaskRequests:
                return "too many requests waiting"
            case .immediateRunIneligible:
                return "can't start right now"
            default:
                return error.localizedDescription
            }
        }
        return error.localizedDescription
    }

    /// For Diagnostics: the facts that decide whether iOS lets a job carry on.
    static var facts: [(String, String)] {
        let declared = (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? [])
        let bundle = Bundle.main.bundleIdentifier ?? "?"
        let refresh: String
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: refresh = "On"
        case .denied: refresh = "Off"
        case .restricted: refresh = "Restricted"
        @unknown default: refresh = "Unknown"
        }
        return [
            ("Bundle ID", bundle),
            ("Carry-on name", prefix + ".*"),
            ("Name matches app", prefix.hasPrefix(bundle + ".") ? "Yes" : "No — iOS may refuse"),
            ("Background App Refresh", refresh),
            ("Graphics chip in background", BGTaskScheduler.supportedResources.contains(.gpu) ? "Supported" : "No"),
            ("Declared", declared.joined(separator: ", ")),
        ]
    }

    private func finish(success: Bool) {
        monitor?.cancel()
        monitor = nil
        if task != nil, success { BackgroundLog.shared.note("Carry-on task done: nothing left to do") }
        adoptedAt = nil
        task?.setTaskCompleted(success: success)
        task = nil
        submitted = false
        endFallback()
    }

    private func beginFallback() {
        guard fallback == .invalid else { return }
        fallback = UIApplication.shared.beginBackgroundTask(withName: "PodSkipper.work") { [weak self] in
            Task { @MainActor in self?.endFallback() }
        }
    }

    private func endFallback() {
        guard fallback != .invalid else { return }
        UIApplication.shared.endBackgroundTask(fallback)
        fallback = .invalid
    }
}

/// What happened to jobs around leaving the app and the screen locking, for
/// Settings → Diagnostics (pass 19).
///
/// Processing still paused on his phone after pass 18 and nothing recorded
/// why: whether iOS accepted the request to carry on, when it started the
/// task, when it ended it, how often the model was made to wait. Each of
/// those is now one line here, kept across launches (last 150), shown on the
/// Diagnostics screen and included in the file he shares.
@MainActor
final class BackgroundLog {
    static let shared = BackgroundLog()

    struct Event: Codable, Identifiable, Sendable {
        var id = UUID()
        var date: Date
        var text: String
    }

    private(set) var events: [Event] = []
    private let url = Diagnostics.folder.appending(path: "background.json")

    private init() {
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            events = (try? decoder.decode([Event].self, from: data)) ?? []
        }
    }

    func note(_ text: String) {
        events.insert(Event(date: .now, text: text), at: 0)
        if events.count > 150 { events.removeLast(events.count - 150) }
        let snapshot = events, url = url
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder.iso.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func clear() {
        events = []
        try? FileManager.default.removeItem(at: url)
    }
}
