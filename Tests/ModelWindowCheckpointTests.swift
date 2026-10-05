import XCTest
@testable import PodSkipper

final class ModelWindowCheckpointTests: XCTestCase {
    func testRelaunchReusesCompleteWindowsAndSplitsOnlyUnfinishedWork() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = ModelWindowCheckpoint(checkpoint: DetectionCheckpoint(guid: "episode", cacheDirectory: folder), identity: "exact-request")
        XCTAssertEqual(first.plan(proposed: [0..<8, 6..<14], lineCount: 14, fits: { _ in true }, split: { [$0] }), [0..<8, 6..<14])
        XCTAssertTrue(first.store("complete answer", window: 0..<8))
        // No save/flush at shutdown: each completed window must already be durable.
        let resumed = ModelWindowCheckpoint(checkpoint: DetectionCheckpoint(guid: "episode", cacheDirectory: folder), identity: "exact-request")
        let plan = resumed.plan(proposed: [0..<4, 3..<7, 6..<10, 9..<14], lineCount: 14,
                                fits: { $0.count <= 4 }, split: { [$0.lowerBound..<($0.lowerBound + 4), ($0.lowerBound + 3)..<$0.upperBound] })
        XCTAssertEqual(plan, [0..<8, 6..<10, 9..<14])
        XCTAssertEqual(resumed.answer(0..<8), "complete answer")
        XCTAssertNil(resumed.answer(6..<10))
        let changed = ModelWindowCheckpoint(checkpoint: resumed.checkpoint, identity: "changed-model-or-prompt")
        XCTAssertNil(changed.answer(0..<8))
        XCTAssertEqual(changed.plan(proposed: [0..<4], lineCount: 14, fits: { _ in true }, split: { [$0] }), [0..<4])
    }
    func testTruncatedOrOutOfBoundsSavedPlanCannotSkipUnreadLines() throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let checkpoint = DetectionCheckpoint(guid: "episode", cacheDirectory: folder)
        let saved = ModelWindowCheckpoint(checkpoint: checkpoint, identity: "request")
        for corruptPlan in [[], [0..<4], [0..<20]] as [[Range<Int>]] {
            checkpoint.cache.set("mlx-windows-v1/request", String(data: try JSONEncoder().encode(corruptPlan), encoding: .utf8)!)
            XCTAssertEqual(saved.plan(proposed: [0..<4, 3..<8], lineCount: 8, fits: { _ in true }, split: { [$0] }), [0..<4, 3..<8])
        }
    }

    func testUnreadableCachedAnswerDoesNotPreserveAnOversizedWindow() {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = ModelWindowCheckpoint(
            checkpoint: DetectionCheckpoint(guid: "episode", cacheDirectory: folder),
            identity: "request")
        XCTAssertEqual(saved.plan(proposed: [0..<8], lineCount: 8,
                                  fits: { _ in true }, split: { [$0] }), [0..<8])
        XCTAssertTrue(saved.store("truncated answer", window: 0..<8))
        let resumed = ModelWindowCheckpoint(checkpoint: saved.checkpoint, identity: "request")
        let plan = resumed.plan(proposed: [0..<4, 3..<8], lineCount: 8,
                                fits: { $0.count <= 4 }, split: { [0..<4, 3..<8] },
                                isReusable: { $0 == "complete answer" })
        XCTAssertEqual(plan, [0..<4, 3..<8])
    }

    func testRequestIdentitySeparatesFieldsAndEveryRuntimeInput() {
        let fields = ["model", "revision", "policy", "transcript", "correction"]
        let original = ModelWindowCheckpoint.identity(fields: fields)
        for index in fields.indices {
            var changed = fields; changed[index] += "x"
            XCTAssertNotEqual(original, ModelWindowCheckpoint.identity(fields: changed))
        }
        XCTAssertNotEqual(ModelWindowCheckpoint.identity(fields: ["ab", "c"]), ModelWindowCheckpoint.identity(fields: ["a", "bc"]))
    }
    func testDiscardedCheckpointRejectsLateWindowAnswer() {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let saved = ModelWindowCheckpoint(checkpoint: DetectionCheckpoint(guid: "episode", cacheDirectory: folder), identity: "request")
        XCTAssertTrue(saved.store("answer", window: 0..<4))
        XCTAssertTrue(saved.checkpoint.discard())
        XCTAssertFalse(saved.store("late", window: 4..<8))
        XCTAssertNil(saved.answer(4..<8))
    }
    func testInterruptionCancelsAndJoinsTheWorker() async {
        enum Interruption: Error { case background }
        let cleaned = expectation(description: "Worker released resources")
        do {
            let _: Int = try await InterruptibleOperation.run {
                defer { cleaned.fulfill() }
                try await Task.sleep(for: .seconds(30))
                return 1
            } monitor: {
                try await Task.sleep(for: .milliseconds(30))
                throw Interruption.background
            }
            XCTFail("Interrupted work must not return a result")
        } catch { XCTAssertTrue(error is Interruption) }
        await fulfillment(of: [cleaned], timeout: 1)
    }
    func testForegroundInterruptionIsBufferedBeforeMonitoringStarts() async {
        let center = NotificationCenter()
        let name = Notification.Name("test.scene.resignation")
        let monitor = NotificationInterruption(name, center: center)
        center.post(name: name, object: nil)
        monitor.finish()
        var received = 0
        for await _ in monitor.events { received += 1 }
        XCTAssertEqual(received, 1)
    }

    func testParentCancellationJoinsWorkerAndMonitor() async {
        let started = expectation(description: "worker started")
        let stopped = expectation(description: "worker cleaned up")
        let task = Task {
            try await InterruptibleOperation.run {
                started.fulfill()
                defer { stopped.fulfill() }
                try await Task.sleep(for: .seconds(30))
                return 1
            } monitor: { try await Task.sleep(for: .seconds(30)) }
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled work returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 1)
    }

    func testCompletionCancelsTheMonitor() async throws {
        let value = try await InterruptibleOperation.run {
            try await Task.sleep(for: .milliseconds(10))
            return 42
        } monitor: { try await Task.sleep(for: .seconds(30)) }
        XCTAssertEqual(value, 42)
    }
}
