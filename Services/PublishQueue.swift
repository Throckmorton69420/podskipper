import Foundation
import Observation
import SwiftData

/// Episodes waiting to be published, worked through one at a time.
///
/// Reported: select several episodes, press Publish, and it did one and
/// stopped — Publish had to be pressed again for the next. Two things caused
/// it. The button only counted episodes that had already been through Find
/// Ads, so anything else in the selection was silently left out; and a second
/// press while the first was running was refused rather than remembered.
///
/// Now a press adds every selected episode to this queue and returns. The
/// queue finds ads first for any that need it, then publishes, and moves on to
/// the next without being asked. Waiting jobs can be reordered or removed from
/// the detail sheet; the one in progress cannot be reordered, only finished.
@MainActor
@Observable
final class PublishQueue {

    static let shared = PublishQueue()

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let episodeID: PersistentIdentifier
        let title: String
        let showTitle: String
        var state: State = .waiting

        enum State: Equatable {
            case waiting
            /// No connection; carries on by itself when one comes back.
            case offline
            case findingAds
            case publishing
            case done(String)
            case failed(String)

            var isFinished: Bool {
                switch self {
                case .done, .failed: return true
                default: return false
                }
            }
        }
    }

    private(set) var jobs: [Job] = []
    private var worker: Task<Void, Never>?
    private var context: ModelContext?

    var waiting: [Job] { jobs.filter { $0.state == .waiting } }
    var current: Job? { jobs.first { $0.state == .findingAds || $0.state == .publishing || $0.state == .offline } }
    var isWaitingForConnection: Bool { jobs.contains { $0.state == .offline } }
    var failedCount: Int { jobs.filter { if case .failed = $0.state { return true } else { return false } }.count }
    var finished: [Job] { jobs.filter { $0.state.isFinished } }
    var isRunning: Bool { worker != nil }

    private init() {}

    func configure(context: ModelContext) {
        self.context = context
    }

    /// Adds episodes to the end of the queue, skipping any already waiting or
    /// in progress, and starts working if it was idle.
    func enqueue(_ episodes: [Episode]) {
        let busy = Set(jobs.filter { !$0.state.isFinished }.map(\.episodeID))
        for episode in episodes where !busy.contains(episode.persistentModelID) {
            jobs.append(Job(episodeID: episode.persistentModelID,
                            title: episode.title,
                            showTitle: episode.podcast?.title ?? ""))
        }
        FeedPublisher.shared.note("Queued \(episodes.count) episode\(episodes.count == 1 ? "" : "s") to publish.")
        start()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        // Offsets arrive relative to the waiting list the sheet shows.
        var list = waiting
        list.move(fromOffsets: source, toOffset: destination)
        let others = jobs.filter { $0.state != .waiting }
        let active = others.filter { !$0.state.isFinished }
        let done = others.filter { $0.state.isFinished }
        jobs = done + active + list
    }

    func remove(_ job: Job) {
        guard job.state == .waiting || job.state.isFinished else { return }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
    }

    private func start() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.run()
            self?.worker = nil
        }
        BackgroundWork.shared.workStarted()
    }

    private func run() async {
        let pipeline = ProcessingPipeline.shared
        let publisher = FeedPublisher.shared
        while let index = jobs.firstIndex(where: { $0.state == .waiting }) {
            guard let context,
                  let episode = context.model(for: jobs[index].episodeID) as? Episode,
                  let podcast = episode.podcast else {
                jobs[index].state = .failed("No longer in the library.")
                continue
            }
            let id = jobs[index].id

            // With no connection, wait for one rather than fail. Reported from
            // a train: a job failed for want of signal, and the bar then said
            // both "failed" and "finished".
            await waitForConnection(id, title: episode.title)

            if episode.processingState != .ready {
                set(id, .findingAds)
                publisher.note("Finding ads in “\(episode.title)” before publishing it.")
                // Wait for any job someone else started, rather than run two
                // transcriptions at once.
                while pipeline.isRunning { try? await Task.sleep(for: .milliseconds(500)) }
                await pipeline.process(episode)
                if episode.processingState != .ready, NetworkStatus.shared.isOffline {
                    // Lost the connection part-way: put it back and wait.
                    await waitForConnection(id, title: episode.title)
                    set(id, .findingAds)
                    await pipeline.process(episode)
                }
                guard episode.processingState == .ready else {
                    set(id, .failed("Couldn't find ads in this one."))
                    publisher.note("Finding ads failed for “\(episode.title)” — skipped.")
                    continue
                }
            }

            set(id, .publishing)
            while publisher.isPublishing { try? await Task.sleep(for: .milliseconds(500)) }
            publisher.configure(context: context, pipeline: pipeline)
            var attempts = 0
            while true {
                attempts += 1
                do {
                    let result = try await publisher.publish(podcast, only: [episode])
                    set(id, .done(result.episodesPublished > 0 ? "Added to the feed." : "Already up."))
                } catch {
                    if attempts < 4, NetworkStatus.isConnectivity(error) || NetworkStatus.shared.isOffline {
                        await waitForConnection(id, title: episode.title)
                        set(id, .publishing)
                        continue
                    }
                    set(id, .failed(error.localizedDescription))
                    publisher.note("“\(episode.title)” failed: \(error.localizedDescription)")
                }
                break
            }
        }
        if !jobs.isEmpty {
            publisher.note("Queue finished.")
        }
    }

    private func waitForConnection(_ id: UUID, title: String) async {
        guard NetworkStatus.shared.isOffline else { return }
        set(id, .offline)
        FeedPublisher.shared.note("No connection — “\(title)” will carry on when there is one.")
        await NetworkStatus.shared.waitUntilOnline()
        // A moment for the connection to settle before asking it for anything.
        try? await Task.sleep(for: .seconds(2))
    }

    private func set(_ id: UUID, _ state: Job.State) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
    }

    /// For the Lock Screen progress and the banner.
    var snapshot: BackgroundWork.Snapshot? {
        guard let current else { return nil }
        let remaining = waiting.count
        let publisher = FeedPublisher.shared
        let pipeline = ProcessingPipeline.shared
        let fraction = current.state == .findingAds ? pipeline.overallFraction : publisher.overallFraction
        var subtitle = current.state == .offline ? "Waiting for a connection"
            : current.state == .findingAds ? "Finding ads" : "Publishing"
        if remaining > 0 { subtitle += " · \(remaining) more queued" }
        return .init(title: current.title, subtitle: subtitle, fraction: fraction)
    }
}
