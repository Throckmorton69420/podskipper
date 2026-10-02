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
        bench.save(result(a, .basic, score: 0.5))
        bench.save(result(a, .hard, score: 0.6))
        bench.save(result(b, .basic, score: 0.7))
        bench.save(result(a, .basic, score: 0.9))
        let restored = ModelBench(defaults: defaults, recoverInterrupted: false)
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
