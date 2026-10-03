import XCTest
@testable import PodSkipper

@MainActor
final class ModelBenchTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "ModelBenchTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testModelsSamplesAndRepeatedRunsSurviveRelaunchSeparately() throws {
        let bench = ModelBench(defaults: defaults, recoverInterrupted: false)
        let a = CoreAIQwen3.benchmarkID(for: "model-a")
        let b = CoreAIQwen3.benchmarkID(for: "model-b")
        var versioned = result(a, .basic, score: 0.5)
        versioned.modelIdentity = "Repo @ pinned-revision / ios"
        bench.save(versioned)
        bench.save(result(a, .hard, score: 0.6))
        bench.save(result(b, .basic, score: 0.7))
        bench.save(result(a, .basic, score: 0.9))
        let restored = ModelBench(defaults: defaults, recoverInterrupted: false)
        XCTAssertEqual(restored.history.first?.modelIdentity, "Repo @ pinned-revision / ios")
        XCTAssertEqual(restored.history.count, 4)
        XCTAssertEqual(Set(restored.history.map(\.runID)).count, 4)
        XCTAssertEqual(restored.result(a, .basic)?.score, 0.9)
        XCTAssertEqual(restored.result(a, .hard)?.score, 0.6)
        XCTAssertEqual(restored.result(b, .basic)?.score, 0.7)
    }

    func testLegacyUnknownModelIsPreservedWithoutRankingOrRelabelling() throws {
        let old = result(CoreAIQwen3.benchmarkID, .hard, score: 1)
        let encoded = try JSONEncoder().encode(old)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "runID")
        object.removeValue(forKey: "policyVersion")
        defaults.set(try JSONSerialization.data(withJSONObject: [old.lookupKey: object]), forKey: "modelBench.results.v1")
        let restored = ModelBench(defaults: defaults, recoverInterrupted: false)
        XCTAssertEqual(restored.history.count, 1)
        XCTAssertEqual(restored.history.first?.engine, CoreAIQwen3.benchmarkID)
        XCTAssertEqual(restored.history.first?.policyVersion, 0)
        XCTAssertNil(restored.score(CoreAIQwen3.benchmarkID))
        XCTAssertNil(restored.result(CoreAIQwen3.benchmarkID(for: "current"), .hard))
    }

    func testCancellationImmediatelyAfterAnswerClearsStateAndSavesNothing() async throws {
        let bench = ModelBench(defaults: defaults, recoverInterrupted: false)
        bench.start(engine: "test", name: "Captured model", sample: .basic) { sample in
            bench.stop()
            return self.result("test", sample, score: 1)
        }
        try await waitUntil { !bench.isRunning }
        XCTAssertNil(bench.runningName)
        XCTAssertNil(bench.runningSample)
        XCTAssertFalse(bench.stopping)
        XCTAssertTrue(bench.history.isEmpty)
        XCTAssertFalse(HeavyWorkCoordinator.shared.isBusy)
        // A subsequent test can acquire the resource and finish normally.
        bench.start(engine: "next", name: "Next model", sample: .hard) { sample in
            self.result("next", sample, score: 0.8)
        }
        try await waitUntil { !bench.isRunning }
        XCTAssertEqual(bench.history.count, 1)
        XCTAssertEqual(bench.history.first?.engine, "next")
    }

    func testFailureReleasesResourceAndRemainsIdentifiable() async throws {
        let bench = ModelBench(defaults: defaults, recoverInterrupted: false)
        bench.start(engine: "failed-model", name: "Captured name", sample: .hard) { _ in
            throw BenchError.unreadableAnswer
        }
        try await waitUntil { !bench.isRunning }
        XCTAssertEqual(bench.history.first?.engine, "failed-model")
        XCTAssertEqual(bench.history.first?.name, "Captured name")
        XCTAssertNotNil(bench.history.first?.error)
        XCTAssertFalse(HeavyWorkCoordinator.shared.isBusy)
    }

    func testUnknownOrChangedSampleIsHistoryWithoutCurrentRanking() throws {
        let bench = ModelBench(defaults: defaults, recoverInterrupted: false)
        var changed = result("old-sample", .basic, score: 1)
        changed.sampleVersion = 0
        bench.save(changed)
        XCTAssertNil(bench.score("old-sample"))
        XCTAssertEqual(bench.history.count, 1)
        var current = result("old-sample", .basic, score: 0.7)
        XCTAssertTrue(current.isComparable)
        current.policyVersion = 0
        XCTAssertFalse(current.isComparable)
        bench.save(result("old-sample", .basic, score: 0.7))
        XCTAssertEqual(bench.score("old-sample"), 0.7)
        XCTAssertEqual(ModelBench(defaults: defaults, recoverInterrupted: false).history.count, 2)
    }

    func testBusyResourceQueuesUserTestAndRunsOnlyAfterRelease() async throws {
        let coordinator = HeavyWorkCoordinator.shared
        let other = try XCTUnwrap(coordinator.tryAcquire(owner: "processing:test"))
        let bench = ModelBench(defaults: defaults, recoverInterrupted: false)
        var ran = false
        bench.start(engine: "queued", name: "Queued model", sample: .basic) { sample in
            ran = true
            return self.result("queued", sample, score: 1)
        }
        try await waitUntil { coordinator.waitingOwners.contains("benchmark:queued") }
        XCTAssertTrue(bench.waiting)
        XCTAssertNil(bench.startedAt)
        XCTAssertFalse(ran)
        XCTAssertEqual(coordinator.current, other)
        coordinator.release(other)
        try await waitUntil { !bench.isRunning }
        XCTAssertTrue(ran)
        XCTAssertEqual(bench.history.count, 1)
        XCTAssertFalse(coordinator.isBusy)
    }

    func testStoppingWaitingTestDoesNotCancelCurrentEpisodeOrSaveResult() async throws {
        let coordinator = HeavyWorkCoordinator.shared
        let other = try XCTUnwrap(coordinator.tryAcquire(owner: "processing:test"))
        defer { coordinator.release(other) }
        let bench = ModelBench(defaults: defaults, recoverInterrupted: false)
        bench.start(engine: "queued", name: "Queued model", sample: .hard) { sample in
            XCTFail("A stopped queued test must never load its model")
            return self.result("queued", sample, score: 1)
        }
        try await waitUntil { !coordinator.waitingOwners.isEmpty }
        bench.stop()
        try await waitUntil { !bench.isRunning }
        XCTAssertTrue(coordinator.waitingOwners.isEmpty)
        XCTAssertEqual(coordinator.current, other)
        XCTAssertTrue(bench.history.isEmpty)
        XCTAssertFalse(bench.waiting)
    }

    func testFailedClassificationRetainsErrorResponseAndMeasurements() {
        var stats = JudgeStats(model: "Qwen3")
        stats.failureDetails = "Inference failed: unsupported tensor shape"
        stats.answerSample = "{\"parts\":["
        stats.generatedTokens = 512
        stats.generateSeconds = 25
        stats.loadSeconds = 3
        let report = JudgeReport(parts: [], failedLines: [0...39], stats: stats)
        let result = ModelBench.classificationResult(report, engine: "coreai.model:qwen3-4b", name: "Qwen3 4B", sample: .basic)
        XCTAssertNil(result.score)
        XCTAssertEqual(result.error, stats.failureDetails)
        XCTAssertEqual(result.answerStart, stats.answerSample)
        XCTAssertEqual(result.seconds, 28)
        XCTAssertEqual(result.writeTPS, 512.0 / 25)
    }

    func testIncompleteAnswerCanBeRecoveredButCannotPassBenchmark() {
        let part = #"{"first_line":13,"last_line":23,"label":"HOST_READ_AD"}"#
        let truncated = "{\"parts\":[" + part + ","
        XCTAssertEqual(JudgePrompt.parse(truncated)?.count, 1)
        XCTAssertNil(JudgePrompt.parseComplete(truncated))
        XCTAssertEqual(JudgePrompt.parseComplete("{\"parts\":[" + part + "]}")?.count, 1)
        XCTAssertEqual(JudgePrompt.parseComplete(#"{"parts":[]}"#)?.count, 0)
        XCTAssertNil(JudgePrompt.parseComplete(#"{"parts":[{"label":"UNKNOWN"}]}"#))
    }

    func testEmptyAnswerAndTokenLimitFailuresRemainDistinct() {
        XCTAssertTrue(ModelAnswerFailure.describe(answer: "", generatedTokens: 512, limit: 512).contains("limit"))
        XCTAssertTrue(ModelAnswerFailure.describe(answer: " ", generatedTokens: 45, limit: 512).contains("no classification"))
        XCTAssertTrue(ModelAnswerFailure.describe(answer: "broken", generatedTokens: 45, limit: 512).contains("invalid"))
    }

    func testFailedRunDoesNotMasqueradeAsZeroAccuracy() {
        let bench = ModelBench(defaults: defaults, recoverInterrupted: false)
        bench.save(BenchResult(engine: "failed", name: "Failed", sample: .basic, date: .now, score: nil, error: "Load failed"))
        XCTAssertNil(bench.score("failed"))
        bench.save(result("failed", .hard, score: 0.8))
        XCTAssertEqual(bench.score("failed"), 0.8)
    }

    private func result(_ engine: String, _ sample: BenchSample, score: Double) -> BenchResult {
        BenchResult(engine: engine, name: engine, sample: sample, date: .now, score: score)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition())
    }
}
