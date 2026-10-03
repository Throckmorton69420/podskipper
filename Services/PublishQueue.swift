import Foundation
import Observation
import SwiftData

/// One durable publishing request per episode. Selected batches, automatic
/// publishing and relaunch recovery all join this same ordered line.
@MainActor
@Observable
final class PublishQueue {
    static let shared = PublishQueue(store: .shared)

    struct Job: Identifiable, Equatable {
        let id: UUID
        let episodeGUID: String
        let title: String
        let showTitle: String
        let reason: String?
        var state: State
        enum State: Equatable {
            case waiting, offline, findingAds, publishing, done(String), failed(String), cancelled(String)
            var isFinished: Bool {
                switch self { case .done, .failed, .cancelled: return true; default: return false }
            }
        }
    }

    typealias Publisher = @MainActor (Episode, Podcast) async throws -> String
    typealias Sleep = @MainActor (Duration) async throws -> Void
    @ObservationIgnored private let store: PublishingJobStore
    @ObservationIgnored private let injectedPipeline: ProcessingPipeline?
    @ObservationIgnored private let injectedPublisher: Publisher?
    @ObservationIgnored private let offline: @MainActor () -> Bool
    @ObservationIgnored private let sleep: Sleep
    @ObservationIgnored private let note: @MainActor (String) -> Void
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var workerToken: UUID?
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var context: ModelContext?
    private var suspended = false

    init(store: PublishingJobStore, pipeline: ProcessingPipeline? = nil,
         publisher: Publisher? = nil, isOffline: (@MainActor () -> Bool)? = nil,
         sleep: Sleep? = nil, note: (@MainActor (String) -> Void)? = nil) {
        self.store = store; injectedPipeline = pipeline; injectedPublisher = publisher
        offline = isOffline ?? { NetworkStatus.shared.isOffline }
        self.sleep = sleep ?? { try await Task.sleep(for: $0) }
        self.note = note ?? { FeedPublisher.shared.note($0) }
    }

    var storageError: String? { store.storageError }
    var jobs: [Job] {
        store.records.map { record in
            let state: Job.State
            switch record.status {
            case .queued: state = .waiting
            case .offline: state = .offline
            case .findingAds: state = .findingAds
            case .publishing: state = .publishing
            case .done: state = .done(record.reason ?? "Added to the feed.")
            case .failed: state = .failed(record.reason ?? "Publishing failed.")
            case .cancelled: state = .cancelled(record.reason ?? "Publishing cancelled by you")
            }
            return Job(id: record.id, episodeGUID: record.guid, title: record.title,
                       showTitle: record.showTitle, reason: record.reason, state: state)
        }
    }
    var waiting: [Job] { jobs.filter { $0.state == .waiting } }
    var current: Job? { jobs.first { $0.state == .findingAds || $0.state == .publishing || $0.state == .offline } }
    var isWaitingForConnection: Bool { jobs.contains { $0.state == .offline } }
    var failedCount: Int { store.records.filter { $0.status == .failed }.count }
    var finished: [Job] { jobs.filter { $0.state.isFinished } }
    var isRunning: Bool { worker != nil }

    func configure(context: ModelContext, resume: Bool = true) {
        self.context = context
        if resume { self.resume() } else { start() }
    }

    @discardableResult
    func enqueue(_ episodes: [Episode], automatically: Bool = false) -> Int {
        let candidates = automatically ? episodes.filter {
            $0.publishedURL == nil || $0.publishedAdVersion != $0.adSegmentsFingerprint
        } : episodes
        let count = store.enqueue(candidates.map { ($0.guid, $0.title, $0.podcast?.title ?? "") },
                                  allowRetry: !automatically)
        if count > 0 { note("Queued \(count) episode\(count == 1 ? "" : "s") to publish.") }
        if let error = storageError { note(error) }
        if automatically { start() } else { resume() }
        return count
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ids = waiting.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        store.reorderWaiting(ids)
    }
    func remove(_ job: Job) {
        if job.state == .waiting { _ = store.cancel(job.id) }
        else { store.remove(job.id) }
    }
    func clearFinished() { store.clearFinished() }

    /// Cancels publishing, without stopping a Find Ads job another caller owns.
    /// Its durable status changes immediately; the next upload cannot start
    /// until the cancelled operation has actually released its resources.
    func cancel(_ job: Job) {
        guard store.cancel(job.id) else { return }
        if activeID == job.id { worker?.cancel() }
    }
    func retry(_ job: Job) {
        guard let context else { return }
        let guid = job.episodeGUID
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        guard let episode = try? context.fetch(descriptor).first else { return }
        enqueue([episode])
    }

    /// Background expiration checkpoints this line instead of calling it done.
    /// The next configure/resume starts from its original position.
    func interrupt() {
        suspended = true
        if let activeID, let token = store.record(activeID)?.attemptID { store.interrupt(activeID, token: token) }
        worker?.cancel()
    }
    func resume() { suspended = false; start() }

    /// Existing process-and-publish actions join this same line. Cancellation
    /// of their wait leaves saved publishing requests available for recovery.
    func waitForCompletion(of guids: Set<String>) async {
        while store.records.contains(where: { guids.contains($0.guid) && !$0.status.isFinished }) {
            guard storageError == nil, !Task.isCancelled else { return }
            do { try await sleep(.milliseconds(100)) }
            catch { return }
        }
    }

    func completionSummary(for guids: Set<String>) -> FeedPublisher.PublishAllSummary {
        let requested = store.records.filter { guids.contains($0.guid) }
        let missing = guids.count - requested.count
        return .init(requested: guids.count,
                     completed: requested.filter { $0.status == .done }.count,
                     failed: requested.filter { $0.status == .failed }.count,
                     cancelled: requested.filter { $0.status == .cancelled }.count,
                     pending: requested.filter { !$0.status.isFinished }.count,
                     error: storageError ?? (missing > 0 ? "Some publishing history was cleared. Check your feed to confirm those results." : nil))
    }

    private func start() {
        guard worker == nil, context != nil, storageError == nil, !suspended,
              store.pending.contains(where: { $0.status == .queued }) else { return }
        let token = UUID(); workerToken = token
        worker = Task { [weak self] in
            guard let self else { return }
            await self.run()
            if self.workerToken == token {
                self.worker = nil; self.workerToken = nil; self.activeID = nil
                // Enqueues while unwinding a cancelled operation remain saved.
                self.start()
            }
        }
        if injectedPublisher == nil { BackgroundWork.shared.workStarted() }
    }

    private func run() async {
        let pipeline = injectedPipeline ?? .shared
        while !Task.isCancelled, !suspended, storageError == nil,
              let record = store.pending.first(where: { $0.status == .queued }) {
            guard let token = store.begin(record.id) else { break }
            activeID = record.id
            let id = record.id
            do {
                try check(id, token: token)
                guard let context else { throw QueueError.libraryUnavailable }
                let guid = record.guid
                let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
                guard let episode = try context.fetch(descriptor).first, let podcast = episode.podcast else {
                    throw QueueError.libraryUnavailable
                }
                try await waitForConnection(id, token: token, title: episode.title)
                while episode.processingState != .ready || pipeline.hasOutstandingJob(episode.guid) {
                    try await waitForConnection(id, token: token, title: episode.title)
                    try set(id, token: token, .findingAds)
                    note("Finding ads in “\(episode.title)” before publishing it.")
                    await pipeline.processNow(episode) // joins the actual task, including a ready episode's rerun
                    try check(id, token: token)
                    if episode.processingState != .ready || pipeline.hasOutstandingJob(episode.guid) {
                        guard offline() || pipeline.jobRecord(episode.guid)?.status == .interrupted else {
                            throw QueueError.detectionIncomplete
                        }
                        try set(id, token: token, .offline, reason: "Finding ads was interrupted; waiting to resume")
                        try await sleep(.seconds(3))
                    }
                }

                // Retry connectivity failures without re-running detection.
                // All completed audio uploads remain reusable by FeedPublisher.
                while true {
                    try await waitForConnection(id, token: token, title: episode.title)
                    try set(id, token: token, .publishing)
                    do {
                        let result: String
                        if let injectedPublisher { result = try await injectedPublisher(episode, podcast) }
                        else {
                            let publisher = FeedPublisher.shared
                            if publisher.isPublishing {
                                try set(id, token: token, .publishing, reason: "Waiting for the current feed update")
                            }
                            while publisher.isPublishing {
                                try check(id, token: token)
                                try await sleep(.milliseconds(500))
                            }
                            try check(id, token: token)
                            try set(id, token: token, .publishing)
                            publisher.configure(context: context, pipeline: pipeline)
                            let published = try await publisher.publish(podcast, only: [episode])
                            result = published.episodesPublished > 0 ? "Added to the feed." : "Already up."
                        }
                        try check(id, token: token)
                        try set(id, token: token, .done, reason: result)
                        break
                    } catch {
                        try check(id, token: token)
                        guard NetworkStatus.isConnectivity(error) || offline() else { throw error }
                        try set(id, token: token, .offline, reason: "Connection interrupted; retrying publishing")
                        // Also back off when NWPath is satisfied but the host
                        // is temporarily unreachable. Cancellation wakes sleep.
                        try await sleep(.seconds(3))
                    }
                }
            } catch {
                if Task.isCancelled || error is CancellationError {
                    store.interrupt(id, token: token)
                } else {
                    _ = store.transition(id, token: token, status: .failed, reason: error.localizedDescription)
                    note("“\(record.title)” failed: \(error.localizedDescription)")
                }
            }
            activeID = nil
        }
        if !Task.isCancelled, !suspended, store.pending.isEmpty {
            let failures = store.records.filter { $0.status == .failed }.count
            let cancelled = store.records.filter { $0.status == .cancelled }.count
            if failures > 0 { note("Publishing stopped with \(failures) failed episode\(failures == 1 ? "" : "s").") }
            else if cancelled > 0 { note("Publishing queue finished; \(cancelled) episode\(cancelled == 1 ? " was" : "s were") cancelled.") }
            else { note("Publishing queue finished.") }
        }
    }

    private func waitForConnection(_ id: UUID, token: UUID, title: String) async throws {
        try check(id, token: token)
        guard offline() else { return }
        try set(id, token: token, .offline, reason: "Waiting for a connection")
        note("No connection — “\(title)” will carry on when there is one.")
        while offline() { try await sleep(.milliseconds(500)); try check(id, token: token) }
    }
    private func check(_ id: UUID, token: UUID) throws {
        try Task.checkCancellation()
        guard store.isCurrent(id, token: token), storageError == nil else { throw CancellationError() }
    }
    private func set(_ id: UUID, token: UUID, _ status: PublishingJob.Status, reason: String? = nil) throws {
        guard store.transition(id, token: token, status: status, reason: reason) else {
            throw CancellationError()
        }
    }

    var snapshot: BackgroundWork.Snapshot? {
        guard let current else { return nil }
        let remaining = waiting.count
        let pipeline = injectedPipeline ?? .shared
        let findingThisEpisode = pipeline.currentEpisodeGUID == current.episodeGUID
        let publishingThisEpisode = FeedPublisher.shared.currentEpisodeGUID == current.episodeGUID
        let fraction = current.state == .findingAds ? (findingThisEpisode ? pipeline.overallFraction : 0)
            : current.state == .offline ? 0 : publishingThisEpisode ? FeedPublisher.shared.overallFraction : 0
        var subtitle = current.state == .offline ? "Waiting for a connection"
            : current.state == .findingAds ? (findingThisEpisode ? "Finding ads" : "Waiting for ad processing")
            : publishingThisEpisode ? "Publishing" : "Waiting for the current feed update"
        if remaining > 0 { subtitle += " · \(remaining) more queued" }
        return .init(title: current.title, subtitle: subtitle, fraction: fraction)
    }

    private enum QueueError: LocalizedError {
        case libraryUnavailable, detectionIncomplete
        var errorDescription: String? {
            switch self {
            case .libraryUnavailable: return "This episode or show is no longer in the library."
            case .detectionIncomplete: return "Finding ads has not completed. Resume or retry it before publishing."
            }
        }
    }
}
