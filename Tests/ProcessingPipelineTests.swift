import XCTest
import SwiftData
@testable import PodSkipper

@MainActor
final class ProcessingPipelineTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var container: ModelContainer!
    private var store: ProcessingJobStore!
    private var resources: HeavyWorkCoordinator!
    private var file: URL { folder.appending(path: "jobs.json") }
    private let engine = ProcessingEngineSelection(engine: "reader", modelID: nil, modelName: nil)

    override func setUpWithError() throws {
        suite = "PipelineTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        folder = URL.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        store = ProcessingJobStore(file: file, defaults: defaults)
        resources = HeavyWorkCoordinator()
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
        container = nil
        super.tearDown()
    }
    private func episode(_ guid: String) -> Episode {
        let episode = Episode(guid: guid, title: guid, episodeDescription: "", audioURL: "https://example.invalid/audio.mp3",
                              publishedAt: .now, duration: 60)
        container.mainContext.insert(episode)
        return episode
    }
    private func pipeline(_ worker: @escaping ProcessingPipeline.Worker) -> ProcessingPipeline {
        let pipeline = ProcessingPipeline(jobs: store, resources: resources, worker: worker)
        pipeline.configure(context: container.mainContext, settings: AppSettings())
        return pipeline
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition())
    }

    func testBatchOrderDuplicatePreventionAndJoiningExistingJob() async throws {
        let a = episode("a"), b = episode("b"), c = episode("c")
        var started: [String] = []
        let pipeline = pipeline { episode, _ in
            started.append(episode.guid)
            XCTAssertEqual(self.resources.current?.owner, "episode:" + episode.guid)
            try await Task.sleep(for: .milliseconds(60))
        }
        pipeline.processNow([a, b, a, c])
        XCTAssertEqual(pipeline.waitingQueue, ["a", "b", "c"])
        try await waitUntil { started == ["a"] }
        await pipeline.processNow(a) // must join, not return before completion
        XCTAssertEqual(store.record("a")?.status, .completed)
        try await waitUntil { store.record("c")?.status == .completed }
        XCTAssertEqual(started, ["a", "b", "c"])
        try await waitUntil { !resources.isBusy }
    }

    func testRelaunchResumesInterruptedHeadBeforeWaitingJobs() async throws {
        _ = episode("a"); _ = episode("b"); _ = episode("c")
        store.setWaitingOrder(["a", "b", "c"])
        _ = store.begin("a", title: "a", origin: "user", selection: engine)
        store.setWaitingOrder(["b", "c"])
        store = ProcessingJobStore(file: file, defaults: defaults)
        var started: [String] = []
        let pipeline = pipeline { episode, _ in started.append(episode.guid) }
        pipeline.resumeUnfinished()
        try await waitUntil { store.record("c")?.status == .completed }
        XCTAssertEqual(started, ["a", "b", "c"])
    }

    func testPauseHoldsEntireLineAndResumeKeepsOrder() async throws {
        let a = episode("a"), b = episode("b")
        var started: [String] = []
        var firstAttempt = true
        let pipeline = pipeline { episode, _ in
            started.append(episode.guid)
            if firstAttempt {
                firstAttempt = false
                try await Task.sleep(for: .seconds(20))
            }
        }
        pipeline.processNow([a, b])
        try await waitUntil { pipeline.isProcessing(a) }
        pipeline.pauseJob(a)
        try await waitUntil { !pipeline.isRunning }
        XCTAssertEqual(store.paused, ["a", "b"])
        XCTAssertEqual(started, ["a"])
        XCTAssertFalse(resources.isBusy)
        pipeline.resumeLine()
        try await waitUntil { store.record("b")?.status == .completed }
        XCTAssertEqual(started, ["a", "a", "b"])
    }

    func testStopStaysStoppedAndCancelledWorkerCannotSaveLateSuccess() async throws {
        let a = episode("a"), b = episode("b")
        var started: [String] = []
        var attemptedLateSuccess = false
        let pipeline = pipeline { episode, token in
            started.append(episode.guid)
            if episode.guid == "a" {
                do { try await Task.sleep(for: .seconds(20)) }
                catch {
                    // A decoder/model may finish its own cleanup after cancellation.
                    // Deliberately delay without responding to the cancelled flag.
                    await Task.detached { try? await Task.sleep(for: .milliseconds(100)) }.value
                    XCTAssertEqual(self.resources.current?.owner, "episode:a")
                    attemptedLateSuccess = true
                    XCTAssertFalse(self.store.finish("a", id: token, status: .completed))
                }
            }
        }
        pipeline.processNow([a, b])
        try await waitUntil { pipeline.isProcessing(a) }
        pipeline.stopJob(a)
        try await waitUntil { store.record("b")?.status == .completed }
        XCTAssertTrue(attemptedLateSuccess)
        XCTAssertEqual(store.record("a")?.status, .stopped)
        pipeline.resumeUnfinished()
        await pipeline.process(a) // automatic work must respect Stop
        XCTAssertEqual(started, ["a", "b"])
        XCTAssertFalse(resources.isBusy)
    }

    func testComparisonOwnsResourcesUntilItFinishesAndUserQueueThenRuns() async throws {
        let a = episode("a")
        let comparison = try XCTUnwrap(resources.tryAcquire(owner: "benchmark:test"))
        var didRun = false
        let pipeline = pipeline { _, _ in didRun = true }
        pipeline.processNow([a])
        try await waitUntil { resources.waitingOwners == ["episode:a"] }
        XCTAssertFalse(didRun)
        XCTAssertEqual(pipeline.resourceWaitingReason, "Waiting for the model comparison to finish")
        resources.release(comparison)
        try await waitUntil { store.record("a")?.status == .completed }
        XCTAssertTrue(didRun)
    }
}
