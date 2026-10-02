import XCTest
@testable import PodSkipper

@MainActor
final class ProcessingJobProjectionTests: XCTestCase {
    private final class Probe: @unchecked Sendable {
        struct Counts {
            var archives = 0
            var projectionKeys: [String] = []
        }
        private let lock = NSLock()
        private var counts = Counts()
        private var failArchive = false
        private var date = Date(timeIntervalSince1970: 1_700_000_000)

        @MainActor var persistence: ProcessingJobStore.Persistence {
            var persistence = ProcessingJobStore.Persistence.live
            persistence.writeArchive = { [self] data, url in
                let fail = lock.withLock { counts.archives += 1; return failArchive }
                if fail { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .atomic)
            }
            persistence.writeProjection = { [self] values, key, defaults in
                lock.withLock { counts.projectionKeys.append(key) }
                defaults.set(values, forKey: key)
            }
            persistence.now = { [self] in lock.withLock { date } }
            return persistence
        }
        func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
        func fail(_ enabled: Bool) { lock.withLock { failArchive = enabled } }
        func reset() { lock.withLock { counts = Counts() } }
        var snapshot: Counts { lock.withLock { counts } }
    }

    private struct Saved: Decodable {
        var version: Int
        var jobs: [String: ProcessingJob]
    }
    private var defaults: UserDefaults!
    private var suite: String!
    private var folder: URL!
    private var file: URL { folder.appending(path: "jobs.json") }
    private let selection = ProcessingEngineSelection(engine: "reader", modelID: "reader-v1", modelName: "Reader")

    override func setUp() {
        super.setUp()
        suite = "ProcessingJobProjectionTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        folder = URL.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }
    private func saved() throws -> Saved {
        try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
    }

    func testMeasuredProgressKeepsDurableArchiveWithoutRewritingUnchangedProjections() throws {
        let historical = (0..<120).map { "stopped-\($0)" }
        defaults.set(historical, forKey: "stoppedByUser")
        let probe = Probe()
        let store = ProcessingJobStore(file: file, defaults: defaults, persistence: probe.persistence)
        let attempt = try XCTUnwrap(store.begin("active", title: "Active", origin: "user", selection: selection))
        probe.reset()

        for step in 1...100 {
            probe.advance(2)
            store.progress("active", id: attempt.id, stage: "detecting", fraction: Double(step) / 100)
        }

        XCTAssertEqual(probe.snapshot.archives, 100, "Keep the existing measured-progress durability interval")
        XCTAssertEqual(probe.snapshot.projectionKeys, [], "A stable queue must not rewrite compatibility defaults")
        let archive = try saved()
        XCTAssertEqual(archive.version, 1)
        XCTAssertEqual(archive.jobs.count, 121)
        XCTAssertEqual(archive.jobs["active"]?.stageFraction, 1)
        XCTAssertEqual(archive.jobs["active"]?.selection, selection)
        XCTAssertEqual(defaults.stringArray(forKey: "unfinishedUserJobs"), ["active"])
        XCTAssertEqual(Set(defaults.stringArray(forKey: "stoppedByUser") ?? []), Set(historical))
    }

    func testReorderPauseStopAndExplicitRetryWriteOnlyChangedProjectionsSynchronously() throws {
        let probe = Probe()
        let store = ProcessingJobStore(file: file, defaults: defaults, persistence: probe.persistence)
        probe.reset()
        store.setWaitingOrder(["a", "b", "c"])
        XCTAssertEqual(probe.snapshot.projectionKeys, ["unfinishedUserJobs"])
        XCTAssertEqual(try saved().jobs["a"]?.status, .queued)

        probe.reset()
        store.setWaitingOrder(["c", "a", "b"])
        XCTAssertEqual(probe.snapshot.projectionKeys, ["unfinishedUserJobs"])
        XCTAssertEqual(defaults.stringArray(forKey: "unfinishedUserJobs"), ["c", "a", "b"])

        probe.reset()
        store.pause(["c", "a"])
        XCTAssertEqual(probe.snapshot.projectionKeys, ["unfinishedUserJobs", PausedLine.key])
        XCTAssertEqual(defaults.stringArray(forKey: "unfinishedUserJobs"), ["b"])
        XCTAssertEqual(defaults.stringArray(forKey: PausedLine.key), ["c", "a"])
        XCTAssertEqual(try saved().jobs["c"]?.status, .paused)

        probe.reset()
        store.stop("c")
        XCTAssertEqual(probe.snapshot.projectionKeys, [PausedLine.key, "stoppedByUser"])
        XCTAssertEqual(defaults.stringArray(forKey: PausedLine.key), ["a"])
        XCTAssertEqual(defaults.stringArray(forKey: "stoppedByUser"), ["c"])
        XCTAssertEqual(try saved().jobs["c"]?.status, .stopped)

        probe.reset()
        store.stop("c")
        XCTAssertEqual(probe.snapshot.archives, 1)
        XCTAssertTrue(probe.snapshot.projectionKeys.isEmpty)
        XCTAssertNil(store.begin("c", title: "C", origin: "automatic", selection: selection))

        probe.reset()
        store.permitRetry("c")
        XCTAssertEqual(probe.snapshot.projectionKeys, ["unfinishedUserJobs", "stoppedByUser"])
        XCTAssertEqual(defaults.stringArray(forKey: "unfinishedUserJobs"), ["b", "c"])
        XCTAssertEqual(defaults.stringArray(forKey: "stoppedByUser"), [])
        XCTAssertEqual(try saved().jobs["c"]?.status, .interrupted)
    }

    func testRelaunchRepairsCompatibilityArraysFromAuthoritativeArchiveAndPreservesIntent() throws {
        let store = ProcessingJobStore(file: file, defaults: defaults)
        store.setWaitingOrder(["a", "b"])
        let previous = try XCTUnwrap(store.begin("a", title: "A", origin: "user", selection: selection))
        store.pause(["held"])
        store.stop("stopped")
        defaults.set(["wrong"], forKey: "unfinishedUserJobs")
        defaults.set(["wrong"], forKey: PausedLine.key)
        defaults.set(["wrong"], forKey: "stoppedByUser")

        let probe = Probe()
        let restored = ProcessingJobStore(file: file, defaults: defaults, persistence: probe.persistence)
        XCTAssertEqual(probe.snapshot.archives, 1)
        XCTAssertEqual(probe.snapshot.projectionKeys, ["unfinishedUserJobs", PausedLine.key, "stoppedByUser"])
        XCTAssertEqual(restored.waiting, ["b"])
        XCTAssertEqual(restored.record("a")?.status, .interrupted)
        XCTAssertEqual(restored.record("a")?.selection, selection)
        XCTAssertEqual(defaults.stringArray(forKey: "unfinishedUserJobs"), ["a", "b"])
        XCTAssertEqual(defaults.stringArray(forKey: PausedLine.key), ["held"])
        XCTAssertEqual(defaults.stringArray(forKey: "stoppedByUser"), ["stopped"])
        XCTAssertFalse(restored.finish("a", id: previous.id, status: .completed))
        XCTAssertNil(restored.begin("stopped", title: "Stopped", origin: "user", selection: selection))

        probe.reset()
        restored.flush()
        XCTAssertEqual(probe.snapshot.archives, 1)
        XCTAssertTrue(probe.snapshot.projectionKeys.isEmpty)
    }

    func testFailedAuthoritativeWriteDoesNotAdvanceMemoAndExplicitFlushRetriesProjections() throws {
        let probe = Probe()
        let store = ProcessingJobStore(file: file, defaults: defaults, persistence: probe.persistence)
        store.setWaitingOrder(["a"])
        let original = try Data(contentsOf: file)
        probe.reset()
        probe.fail(true)
        store.pause(["a"])

        XCTAssertNotNil(store.storageError)
        XCTAssertEqual(probe.snapshot.archives, 1)
        XCTAssertTrue(probe.snapshot.projectionKeys.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(defaults.stringArray(forKey: "unfinishedUserJobs"), ["a"])
        XCTAssertEqual(defaults.stringArray(forKey: PausedLine.key), [])

        probe.fail(false)
        probe.reset()
        store.flush()
        XCTAssertNil(store.storageError)
        XCTAssertEqual(probe.snapshot.archives, 1)
        XCTAssertEqual(probe.snapshot.projectionKeys, ["unfinishedUserJobs", PausedLine.key])
        XCTAssertEqual(try saved().jobs["a"]?.status, .paused)
        XCTAssertEqual(defaults.stringArray(forKey: "unfinishedUserJobs"), [])
        XCTAssertEqual(defaults.stringArray(forKey: PausedLine.key), ["a"])

        probe.reset()
        store.flush()
        XCTAssertEqual(probe.snapshot.archives, 1)
        XCTAssertTrue(probe.snapshot.projectionKeys.isEmpty)
    }

    func testStageChangesAndExplicitFlushRemainDurableWhileLateResultsStayRejected() throws {
        let probe = Probe()
        let store = ProcessingJobStore(file: file, defaults: defaults, persistence: probe.persistence)
        let attempt = try XCTUnwrap(store.begin("a", title: "A", origin: "user", selection: selection))
        probe.reset()
        store.progress("a", id: attempt.id, stage: "transcribing", fraction: 1)
        store.progress("a", id: attempt.id, stage: "detecting", fraction: 0.25)
        XCTAssertEqual(probe.snapshot.archives, 2, "Stage transitions must flush even without a clock advance")
        XCTAssertEqual(try saved().jobs["a"]?.completedStages, ["transcribing"])
        XCTAssertTrue(probe.snapshot.projectionKeys.isEmpty)

        probe.reset()
        for _ in 0..<100 { store.progress("a", id: attempt.id, stage: "detecting", fraction: 0.5) }
        XCTAssertEqual(probe.snapshot.archives, 0)
        XCTAssertEqual(try saved().jobs["a"]?.stageFraction, 0.25)
        store.flush()
        XCTAssertEqual(probe.snapshot.archives, 1)
        XCTAssertEqual(try saved().jobs["a"]?.stageFraction, 0.5)

        store.stop("a")
        let stopped = try Data(contentsOf: file)
        probe.reset()
        store.progress("a", id: attempt.id, stage: "detecting", fraction: 1)
        XCTAssertFalse(store.finish("a", id: attempt.id, status: .completed))
        XCTAssertEqual(probe.snapshot.archives, 0)
        XCTAssertEqual(try Data(contentsOf: file), stopped)
        let restored = ProcessingJobStore(file: file, defaults: defaults)
        XCTAssertEqual(restored.record("a")?.status, .stopped)
        XCTAssertEqual(restored.record("a")?.completedStages, ["transcribing"])
    }

    func testCorruptOrUnsupportedArchiveCannotRewriteCompatibilityProjections() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for bytes in [Data("broken".utf8), Data(#"{"version":999,"jobs":{}}"#.utf8)] {
            try bytes.write(to: file)
            defaults.set(["existing"], forKey: "unfinishedUserJobs")
            let probe = Probe()
            let store = ProcessingJobStore(file: file, defaults: defaults, persistence: probe.persistence)
            store.flush()
            store.setWaitingOrder(["a"])
            XCTAssertNotNil(store.storageError)
            XCTAssertEqual(probe.snapshot.archives, 0)
            XCTAssertTrue(probe.snapshot.projectionKeys.isEmpty)
            XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertEqual(defaults.stringArray(forKey: "unfinishedUserJobs"), ["existing"])
        }
    }
}
