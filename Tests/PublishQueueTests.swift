import XCTest
import SwiftData
@testable import PodSkipper

@MainActor
final class PublishQueueTests: XCTestCase {
    private var folder: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var container: ModelContainer!
    private var store: PublishingJobStore!
    private var processing: ProcessingJobStore!
    private var queues: [PublishQueue] = []
    private var file: URL { folder.appending(path: "publishing.json") }

    override func setUpWithError() throws {
        suite = "PublishQueueTests." + UUID().uuidString
        folder = URL.temporaryDirectory.appending(path: suite)
        defaults = UserDefaults(suiteName: suite)!
        container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        store = PublishingJobStore(file: file)
        processing = ProcessingJobStore(file: folder.appending(path: "processing.json"), defaults: defaults)
    }
    override func tearDown() {
        queues.forEach { $0.interrupt() }; queues = []
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
        container = nil; super.tearDown()
    }
    private func episode(_ guid: String, ready: Bool = true) -> Episode {
        let podcast = Podcast(feedURL: "https://example.invalid/" + guid, title: "Show " + guid)
        let episode = Episode(guid: guid, title: guid, episodeDescription: "", audioURL: "https://example.invalid/audio.mp3",
                              publishedAt: .now, duration: 60)
        container.mainContext.insert(podcast); container.mainContext.insert(episode)
        episode.podcast = podcast
        episode.processingState = ready ? .ready : .notStarted
        return episode
    }
    private func pipeline(_ worker: @escaping ProcessingPipeline.Worker = { _, _ in XCTFail("Completed detection was repeated") }) -> ProcessingPipeline {
        let pipeline = ProcessingPipeline(jobs: processing, resources: HeavyWorkCoordinator(), worker: worker)
        pipeline.configure(context: container.mainContext, settings: AppSettings())
        return pipeline
    }
    private func queue(pipeline: ProcessingPipeline? = nil, isOffline: @escaping @MainActor () -> Bool = { false },
                       publisher: @escaping PublishQueue.Publisher) -> PublishQueue {
        let queue = PublishQueue(store: store, pipeline: pipeline ?? self.pipeline(), publisher: publisher,
                                 isOffline: isOffline, sleep: { _ in try await Task.sleep(for: .milliseconds(5)) }, note: { _ in })
        queues.append(queue); return queue
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition())
    }

    func testSelectedBatchDeduplicatesAndUsesReadyResultsInOrder() async throws {
        let a = episode("a"), b = episode("b"), c = episode("c")
        var uploaded: [String] = []
        let queue = queue { episode, _ in uploaded.append(episode.guid); return "Added" }
        queue.enqueue([a, b, a, c]); queue.enqueue([a, b])
        XCTAssertEqual(store.pending.map(\.guid), ["a", "b", "c"])
        queue.configure(context: container.mainContext)
        try await waitUntil { store.records.filter { $0.status == .done }.count == 3 }
        XCTAssertEqual(uploaded, ["a", "b", "c"])
        XCTAssertEqual(queue.failedCount, 0)
    }

    func testRelaunchResumesInterruptedUploadBeforeReorderedWaitingEpisodes() async throws {
        _ = episode("a"); _ = episode("b"); _ = episode("c")
        store.enqueue([("a", "A", "S"), ("b", "B", "S"), ("c", "C", "S")])
        let token = try XCTUnwrap(store.begin(store.records[0].id))
        XCTAssertTrue(store.transition(store.records[0].id, token: token, status: .publishing))
        store.reorderWaiting([store.records[2].id, store.records[1].id])
        store = PublishingJobStore(file: file)
        var uploaded: [String] = []
        let queue = queue { episode, _ in uploaded.append(episode.guid); return "Added" }
        queue.configure(context: container.mainContext)
        try await waitUntil { uploaded.count == 3 }
        XCTAssertEqual(uploaded, ["a", "c", "b"])
    }

    func testOfflineCancellationDoesNotPublishOrCountAsFailureAndNextRequestRuns() async throws {
        let a = episode("a"), b = episode("b")
        var offline = true, uploaded: [String] = []
        let queue = queue(isOffline: { offline }) { episode, _ in uploaded.append(episode.guid); return "Added" }
        queue.configure(context: container.mainContext); queue.enqueue([a, b])
        try await waitUntil { queue.isWaitingForConnection }
        queue.cancel(try XCTUnwrap(queue.current))
        offline = false
        try await waitUntil { store.records.last?.status == .done }
        XCTAssertEqual(uploaded, ["b"])
        XCTAssertEqual(store.records.first?.status, .cancelled)
        XCTAssertEqual(queue.failedCount, 0)
    }

    func testLateUploadAfterCancellationCannotSaveSuccessOrOverlapNextUpload() async throws {
        let a = episode("a"), b = episode("b")
        var release: CheckedContinuation<Void, Never>?
        var started: [String] = []
        let queue = queue { episode, _ in
            started.append(episode.guid)
            if episode.guid == "a" { await withCheckedContinuation { release = $0 } }
            return "Late success"
        }
        queue.configure(context: container.mainContext); queue.enqueue([a, b])
        try await waitUntil { release != nil }
        queue.cancel(try XCTUnwrap(queue.current))
        XCTAssertEqual(started, ["a"])
        XCTAssertEqual(store.records[0].status, .cancelled)
        release?.resume(); release = nil
        try await waitUntil { store.records.last?.status == .done }
        XCTAssertEqual(started, ["a", "b"])
        XCTAssertEqual(store.records.first?.status, .cancelled)
    }

    func testConnectivityRetryKeepsDetectionAndQueueOrder() async throws {
        let a = episode("a", ready: false), b = episode("b")
        var detections: [String] = [], uploads: [String] = []
        let pipeline = pipeline { episode, _ in detections.append(episode.guid); episode.processingState = .ready }
        let queue = queue(pipeline: pipeline) { episode, _ in
            uploads.append(episode.guid)
            if uploads.count == 1 { throw URLError(.networkConnectionLost) }
            return "Added"
        }
        queue.configure(context: container.mainContext); queue.enqueue([a, b])
        try await waitUntil { store.records.last?.status == .done }
        XCTAssertEqual(detections, ["a"])
        XCTAssertEqual(uploads, ["a", "a", "b"])
    }

    func testExistingProcessingRerunIsJoinedBeforePublishingReadyEpisode() async throws {
        let a = episode("a")
        var release: CheckedContinuation<Void, Never>?
        var detections = 0, uploads = 0
        let pipeline = pipeline { episode, _ in
            detections += 1
            await withCheckedContinuation { release = $0 }
            episode.processingState = .ready
        }
        pipeline.processNow([a])
        try await waitUntil { release != nil }
        let queue = queue(pipeline: pipeline) { _, _ in uploads += 1; return "Added" }
        queue.configure(context: container.mainContext); queue.enqueue([a])
        try await waitUntil { queue.current?.state == .findingAds }
        XCTAssertEqual(uploads, 0)
        release?.resume(); release = nil
        try await waitUntil { store.records.first?.status == .done }
        XCTAssertEqual(detections, 1); XCTAssertEqual(uploads, 1)
    }

    func testSystemInterruptionAndForegroundResumeWaitForOldUploadCleanup() async throws {
        let a = episode("a"), b = episode("b")
        var release: CheckedContinuation<Void, Never>?
        var started: [String] = [], active = 0, maxActive = 0
        let queue = queue { episode, _ in
            started.append(episode.guid); active += 1; maxActive = max(maxActive, active)
            defer { active -= 1 }
            if started.count == 1 { await withCheckedContinuation { release = $0 } }
            return "Added"
        }
        queue.configure(context: container.mainContext); queue.enqueue([a, b])
        try await waitUntil { release != nil }
        let oldToken = try XCTUnwrap(store.records.first?.attemptID)
        queue.interrupt()
        XCTAssertEqual(store.pending.map(\.guid), ["a", "b"])
        XCTAssertNil(store.pending.first?.attemptID)
        queue.resume() // foreground can arrive before the old call unwinds
        XCTAssertEqual(started, ["a"])
        release?.resume(); release = nil
        try await waitUntil { store.records.last?.status == .done }
        XCTAssertEqual(started, ["a", "a", "b"])
        XCTAssertEqual(maxActive, 1)
        XCTAssertNotEqual(store.records.first?.attemptID, oldToken)
    }

    func testCompletionSummaryIncludesOnlyThisInvocationAndActualOutcomes() throws {
        store.enqueue([("historical", "Old", "S"), ("a", "A", "S"), ("b", "B", "S"), ("c", "C", "S"), ("d", "D", "S")])
        for (index, status) in [(0, PublishingJob.Status.done), (1, .done), (2, .failed)] {
            let job = store.records[index], token = try XCTUnwrap(store.begin(store.records[index].id))
            XCTAssertTrue(store.transition(job.id, token: token, status: status))
        }
        XCTAssertTrue(store.cancel(store.records[3].id))
        let queue = queue { _, _ in XCTFail("Summary must not publish"); return "" }
        let summary = queue.completionSummary(for: ["a", "b", "c", "d"])
        XCTAssertEqual(summary.requested, 4); XCTAssertEqual(summary.completed, 1)
        XCTAssertEqual(summary.failed, 1); XCTAssertEqual(summary.cancelled, 1); XCTAssertEqual(summary.pending, 1)
        XCTAssertTrue(summary.dialogue.contains("1 episode is ready"))
        XCTAssertTrue(summary.dialogue.contains("couldn't publish"))
        XCTAssertFalse(summary.dialogue.contains("Done"))
    }

    func testPublishingSnapshotNeverBorrowsAnotherEpisodesDetectionProgress() async throws {
        let z = episode("z", ready: false), a = episode("a", ready: false)
        var release: CheckedContinuation<Void, Never>?
        defer { release?.resume() }
        var activePipeline: ProcessingPipeline!
        activePipeline = pipeline { episode, _ in
            if episode.guid == "z" {
                activePipeline.stage = .detecting; activePipeline.stageFraction = 0.75
                await withCheckedContinuation { release = $0 }
            }
            episode.processingState = .ready
        }
        activePipeline.processNow([z])
        try await waitUntil { release != nil }
        XCTAssertGreaterThan(activePipeline.overallFraction, 0)
        let queue = queue(pipeline: activePipeline) { _, _ in "Added" }
        queue.configure(context: container.mainContext); queue.enqueue([a])
        try await waitUntil { queue.current?.state == .findingAds }
        let snapshot = try XCTUnwrap(queue.snapshot)
        XCTAssertEqual(snapshot.title, "a")
        XCTAssertEqual(snapshot.fraction, 0)
        XCTAssertEqual(snapshot.subtitle, "Waiting for ad processing")
        release?.resume(); release = nil
        try await waitUntil { store.records.first?.status == .done }
    }

    func testAutomaticEnqueueCannotRestartSystemInterruptedPublishing() async throws {
        let a = episode("a")
        var uploads = 0
        let queue = queue { _, _ in uploads += 1; return "Added" }
        queue.interrupt()
        queue.configure(context: container.mainContext, resume: false)
        XCTAssertEqual(queue.enqueue([a], automatically: true), 1)
        XCTAssertFalse(queue.isRunning); XCTAssertEqual(uploads, 0)
        XCTAssertEqual(store.pending.first?.guid, "a")
        queue.resume()
        try await waitUntil { store.records.first?.status == .done }
        XCTAssertEqual(uploads, 1)
    }
}
