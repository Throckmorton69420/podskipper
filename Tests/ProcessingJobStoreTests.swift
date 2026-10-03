import XCTest
@testable import PodSkipper

@MainActor
final class ProcessingJobStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var folder: URL!
    private var file: URL { folder.appending(path: "jobs.json") }
    private let selection = ProcessingEngineSelection(engine: "coreAI", modelID: "model-a", modelName: "A")

    override func setUp() {
        super.setUp()
        suite = "ProcessingJobTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        folder = URL.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testExplicitTranscriptCleanupPreservesIntentAndInvalidatesSavedStages() throws {
        let store = ProcessingJobStore(file: file, defaults: defaults)
        for status in [ProcessingJob.Status.paused, .stopped, .interrupted, .completed] {
            let guid = status.rawValue
            let attempt = try XCTUnwrap(store.begin(guid, title: guid, origin: "user", selection: selection))
            store.progress(guid, id: attempt.id, stage: "downloading", fraction: 1)
            store.progress(guid, id: attempt.id, stage: "analyzing", fraction: 1)
            store.progress(guid, id: attempt.id, stage: "transcribing", fraction: 1)
            store.progress(guid, id: attempt.id, stage: "detecting", fraction: 0.5)
            XCTAssertTrue(store.finish(guid, id: attempt.id, status: status, reason: "Keep this intent"))
            let before = try XCTUnwrap(store.record(guid))
            XCTAssertTrue(store.invalidateTranscriptCheckpoint(guid))
            let restored = ProcessingJobStore(file: file, defaults: defaults)
            let after = try XCTUnwrap(restored.record(guid))
            XCTAssertEqual(after.status, before.status)
            XCTAssertEqual(after.reason, before.reason)
            XCTAssertEqual(after.order, before.order)
            XCTAssertEqual(after.selection, before.selection)
            XCTAssertEqual(after.completedStages, ["downloading"])
            XCTAssertEqual(after.stageFraction, 0)
            XCTAssertNotEqual(after.id, before.id)
            store.progress(guid, id: before.id, stage: "detecting", fraction: 1)
            XCTAssertEqual(store.record(guid)?.stageFraction, 0)
            XCTAssertTrue(store.invalidateTranscriptCheckpoint(guid, keepDownloadStage: false))
            XCTAssertEqual(store.record(guid)?.completedStages, [])
            XCTAssertEqual(store.record(guid)?.status, before.status)
        }
    }

    func testLegacyMigrationKeepsOrderAndExplicitPauseAndStopWin() {
        defaults.set(["a", "b", "c", "d", "a"], forKey: "unfinishedUserJobs")
        defaults.set(["c", "a", "d"], forKey: PausedLine.key)
        defaults.set(["d"], forKey: "stoppedByUser")
        let store = ProcessingJobStore(file: file, defaults: defaults)
        XCTAssertEqual(store.outstanding, ["b"])
        XCTAssertEqual(store.paused, ["c", "a"])
        XCTAssertEqual(store.stopped, ["d"])
        XCTAssertEqual(store.records.count, 4)
        XCTAssertNil(store.storageError)
    }

    func testModelEnableSnapshotPreservesLegacyRecordsAndRelaunch() throws {
        let old = Data(#"{"engine":"coreAI","modelID":"a","modelName":"A"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ProcessingEngineSelection.self, from: old).enabled)
        let store = ProcessingJobStore(file: file, defaults: defaults)
        var disabled = selection
        disabled.enabled = false
        _ = try XCTUnwrap(store.begin("disabled", title: "Disabled", origin: "user", selection: disabled))
        let restored = ProcessingJobStore(file: file, defaults: defaults)
        XCTAssertEqual(restored.record("disabled")?.selection?.enabled, false)
        XCTAssertNil(restored.storageError)
    }

    func testQueueReorderingAndDuplicatesSurviveRelaunch() {
        let store = ProcessingJobStore(file: file, defaults: defaults)
        store.setWaitingOrder(["a", "b", "a", "c"])
        store.setWaitingOrder(["c", "a", "b"])
        let restored = ProcessingJobStore(file: file, defaults: defaults)
        XCTAssertEqual(restored.waiting, ["c", "a", "b"])
        XCTAssertEqual(restored.records.count, 3)
        XCTAssertEqual(defaults.stringArray(forKey: "unfinishedUserJobs"), ["c", "a", "b"])
    }

    func testStoppedEpisodesNeverDisappearAfterTwoHundredLaterStops() {
        let stopped = (0..<350).map { "stopped-\($0)" }
        defaults.set(stopped, forKey: "stoppedByUser")
        let store = ProcessingJobStore(file: file, defaults: defaults)
        store.stop("latest")
        let restored = ProcessingJobStore(file: file, defaults: defaults)
        XCTAssertEqual(restored.stopped.count, 351)
        XCTAssertTrue(restored.stopped.contains("stopped-0"))
        restored.setWaitingOrder(["stopped-0"])
        XCTAssertTrue(restored.waiting.isEmpty)
        XCTAssertNil(restored.begin("stopped-0", title: "Old", origin: "automatic", selection: selection))
        restored.permitRetry("stopped-0")
        restored.setWaitingOrder(["stopped-0"])
        XCTAssertEqual(restored.waiting, ["stopped-0"])
    }

    func testInterruptedJobKeepsCheckpointAndOriginalModelOnResume() throws {
        let store = ProcessingJobStore(file: file, defaults: defaults)
        let job = try XCTUnwrap(store.begin("a", title: "A", origin: "user", selection: selection))
        store.progress("a", id: job.id, stage: "transcribing", fraction: 1)
        store.progress("a", id: job.id, stage: "detecting", fraction: 0.4)
        let restored = ProcessingJobStore(file: file, defaults: defaults)
        XCTAssertEqual(restored.record("a")?.status, .interrupted)
        XCTAssertEqual(restored.record("a")?.completedStages, ["transcribing"])
        XCTAssertEqual(restored.record("a")?.checkpointKey, "a")
        let next = try XCTUnwrap(restored.begin("a", title: "A", origin: "user",
            selection: ProcessingEngineSelection(engine: "coreAI", modelID: "model-b", modelName: "B")))
        XCTAssertEqual(next.selection, selection)
        XCTAssertNotEqual(next.id, job.id)
        XCTAssertFalse(restored.finish("a", id: job.id, status: .completed))
    }

    func testPausedAndStoppedJobsRejectLateSuccessAndStayDistinct() throws {
        let store = ProcessingJobStore(file: file, defaults: defaults)
        let a = try XCTUnwrap(store.begin("a", title: "A", origin: "user", selection: selection))
        store.setWaitingOrder(["b"])
        store.pause(["a", "b"])
        XCTAssertFalse(store.finish("a", id: a.id, status: .completed))
        XCTAssertTrue(store.outstanding.isEmpty)
        XCTAssertEqual(store.paused, ["a", "b"])
        store.stop("a")
        let restored = ProcessingJobStore(file: file, defaults: defaults)
        XCTAssertEqual(restored.record("a")?.status, .stopped)
        XCTAssertEqual(restored.record("b")?.status, .paused)
        XCTAssertFalse(restored.finish("a", id: a.id, status: .completed))
    }

    func testCompletedRerunCapturesNewModelAndRetryDelaySurvivesRelaunch() throws {
        let store = ProcessingJobStore(file: file, defaults: defaults)
        let first = try XCTUnwrap(store.begin("a", title: "A", origin: "user", selection: selection))
        XCTAssertTrue(store.finish("a", id: first.id, status: .completed))
        store.setWaitingOrder(["a"])
        let nextSelection = ProcessingEngineSelection(engine: "model", modelID: "b", modelName: "B")
        let next = try XCTUnwrap(store.begin("a", title: "A", origin: "user", selection: nextSelection))
        XCTAssertEqual(next.selection, nextSelection)
        XCTAssertNotEqual(first.id, next.id)
        store.finish("a", id: next.id, status: .interrupted, reason: "System interruption")
        let date = Date.now.addingTimeInterval(20)
        store.deferRetry("a", until: date)
        let restored = ProcessingJobStore(file: file, defaults: defaults)
        XCTAssertEqual(restored.record("a")?.retryAfter, date)
        restored.clearRetryDelays()
        XCTAssertNil(restored.record("a")?.retryAfter)
    }

    func testCorruptOrFutureArchiveIsPreservedAndBlocksNewWork() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for bytes in [Data("broken".utf8), Data(#"{"version":999,"jobs":{}}"#.utf8)] {
            try bytes.write(to: file)
            let store = ProcessingJobStore(file: file, defaults: defaults)
            XCTAssertNotNil(store.storageError)
            store.setWaitingOrder(["a"])
            XCTAssertNil(store.begin("a", title: "A", origin: "user", selection: selection))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }
}
