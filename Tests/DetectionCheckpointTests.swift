import XCTest
@testable import PodSkipper

@MainActor
final class DetectionCheckpointTests: XCTestCase {
    private final class Writer: @unchecked Sendable {
        private let lock = NSLock()
        private var blocked = false
        private var entered = false
        private var failed = false
        private var count = 0
        private let gate = DispatchSemaphore(value: 0)
        func blockNext() { lock.withLock { blocked = true; entered = false } }
        func fail(_ value: Bool) { lock.withLock { failed = value } }
        func release() { gate.signal() }
        var didEnter: Bool { lock.withLock { entered } }
        var writes: Int { lock.withLock { count } }
        func write(_ data: Data, _ url: URL) throws {
            let wait = lock.withLock { () -> Bool in
                count += 1
                if blocked { blocked = false; entered = true; return true }
                return false
            }
            if wait, gate.wait(timeout: .now() + 5) == .timedOut { throw CocoaError(.fileWriteUnknown) }
            if lock.withLock({ failed }) { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        }
    }

    private var folder: URL!
    private let guid = "disposable-episode"
    private var current: URL { DetectionCheckpoint.fileURL(guid: guid, cacheDirectory: folder) }

    override func setUpWithError() throws {
        folder = URL.temporaryDirectory.appending(path: "CheckpointTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition())
    }

    func testConcurrentFlushesPersistBothEarlierAndLaterAnswers() async throws {
        let writer = Writer()
        let checkpoint = DetectionCheckpoint(guid: guid, cacheDirectory: folder, write: writer.write)
        checkpoint.cache.set("first", "first answer")
        writer.blockNext()
        let first = Task.detached { checkpoint.save() }
        try await waitUntil { writer.didEnter }
        let second = Task.detached {
            checkpoint.cache.set("second", "second answer")
            return checkpoint.save()
        }
        writer.release()
        let firstSaved = await first.value, secondSaved = await second.value
        XCTAssertTrue(firstSaved); XCTAssertTrue(secondSaved)
        let reopened = DetectionCheckpoint(guid: guid, cacheDirectory: folder)
        XCTAssertEqual(reopened.cache.get("first"), "first answer")
        XCTAssertEqual(reopened.cache.get("second"), "second answer")
        XCTAssertEqual(reopened.reused, 2)
    }

    func testDiscardWaitsForInFlightWriteAndLateCallbacksCannotResurrectFile() async throws {
        let writer = Writer()
        let checkpoint = DetectionCheckpoint(guid: guid, cacheDirectory: folder, write: writer.write)
        let stale = checkpoint.cache
        stale.set("old", "old answer")
        writer.blockNext()
        let save = Task.detached { checkpoint.save() }
        try await waitUntil { writer.didEnter }
        let discard = Task.detached { checkpoint.discard() }
        writer.release()
        let saved = await save.value, discarded = await discard.value
        XCTAssertTrue(saved); XCTAssertTrue(discarded)
        for index in 0..<20 { stale.set("late-\(index)", "late reply") }
        XCTAssertFalse(checkpoint.save())
        XCTAssertNil(stale.get("old")); XCTAssertEqual(checkpoint.reused, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertEqual(writer.writes, 1)
    }

    func testFailedWriteRetainsAnswersForRetryAndAutomaticFlushSurvivesRelaunch() throws {
        let writer = Writer()
        let checkpoint = DetectionCheckpoint(guid: guid, cacheDirectory: folder, write: writer.write)
        writer.fail(true)
        for index in 0..<8 { checkpoint.cache.set("key-\(index)", "reply-\(index)") }
        XCTAssertNotNil(checkpoint.storageError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        writer.fail(false)
        XCTAssertTrue(checkpoint.save()); XCTAssertNil(checkpoint.storageError)
        let restored = DetectionCheckpoint(guid: guid, cacheDirectory: folder)
        XCTAssertEqual(restored.reused, 8)
        for index in 0..<8 { XCTAssertEqual(restored.cache.get("key-\(index)"), "reply-\(index)") }
        XCTAssertEqual(writer.writes, 2)
    }

    func testLegacyHistoryIsPreservedAndNotPromotedIntoVerifiedReplies() throws {
        let legacy = DetectionCheckpoint.legacyFileURL(guid: guid, cacheDirectory: folder)
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = try JSONEncoder().encode(["old request digest": "legacy reply"])
        try original.write(to: legacy)
        let checkpoint = DetectionCheckpoint(guid: guid, cacheDirectory: folder)
        XCTAssertEqual(checkpoint.reused, 0)
        checkpoint.cache.set("verified request", "new reply")
        XCTAssertTrue(checkpoint.save()); XCTAssertTrue(checkpoint.discard())
        XCTAssertEqual(try Data(contentsOf: legacy), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertEqual(Set(DetectionCheckpoint.fileURLs(guid: guid, cacheDirectory: folder)), [legacy, current])
    }

    func testUnreadableCurrentCacheStaysUnchangedAndDoesNotAcceptNewReplies() throws {
        try FileManager.default.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("unreadable checkpoint".utf8); try original.write(to: current)
        let checkpoint = DetectionCheckpoint(guid: guid, cacheDirectory: folder)
        XCTAssertNotNil(checkpoint.storageError)
        checkpoint.cache.set("fresh", "reply")
        XCTAssertFalse(checkpoint.save()); XCTAssertFalse(checkpoint.discard())
        XCTAssertEqual(try Data(contentsOf: current), original)
    }

    func testFailedDiscardIsTerminalAndPreservesFileForExplicitCleanupRetry() throws {
        let writer = Writer()
        let checkpoint = DetectionCheckpoint(guid: guid, cacheDirectory: folder, write: writer.write,
            remove: { _ in throw CocoaError(.fileWriteNoPermission) })
        checkpoint.cache.set("request", "reply"); XCTAssertTrue(checkpoint.save())
        let original = try Data(contentsOf: current)
        XCTAssertFalse(checkpoint.discard()); XCTAssertNotNil(checkpoint.storageError)
        checkpoint.cache.set("late", "reply"); XCTAssertFalse(checkpoint.save())
        XCTAssertNil(checkpoint.cache.get("request")); XCTAssertEqual(writer.writes, 1)
        XCTAssertEqual(try Data(contentsOf: current), original)
    }
}
