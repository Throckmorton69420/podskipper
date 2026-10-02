import XCTest
@testable import PodSkipper

@MainActor
final class PublishingJobStoreTests: XCTestCase {
    private var folder: URL!
    private var file: URL { folder.appending(path: "jobs.json") }
    override func setUpWithError() throws {
        folder = URL.temporaryDirectory.appending(path: "PublishingStoreTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder); super.tearDown() }

    func testBatchDedupOrderRelaunchAndExplicitRetry() throws {
        let store = PublishingJobStore(file: file)
        XCTAssertEqual(store.enqueue([("a", "A", "S"), ("b", "B", "S"), ("a", "A", "S")]), 2)
        let a = try XCTUnwrap(store.records.first)
        let token = try XCTUnwrap(store.begin(a.id))
        XCTAssertTrue(store.transition(a.id, token: token, status: .publishing))
        XCTAssertEqual(store.enqueue([("a", "A", "S"), ("c", "C", "S")]), 1)
        let restored = PublishingJobStore(file: file)
        XCTAssertEqual(restored.pending.map(\.guid), ["a", "b", "c"])
        XCTAssertEqual(restored.pending.first?.status, .queued)
        XCTAssertNil(restored.pending.first?.attemptID)
        XCTAssertFalse(restored.transition(a.id, token: token, status: .done))
        XCTAssertTrue(restored.cancel(a.id))
        XCTAssertEqual(restored.enqueue([("a", "A", "S")]), 1)
        XCTAssertEqual(restored.pending.map(\.guid), ["b", "c", "a"])
        XCTAssertEqual(restored.records.last?.id, a.id)
    }

    func testReorderKeepsActiveHeadAndCancelledRecordCannotAcceptLateSuccess() throws {
        let store = PublishingJobStore(file: file)
        store.enqueue([("a", "A", "S"), ("b", "B", "S"), ("c", "C", "S")])
        let a = store.records[0], b = store.records[1], c = store.records[2]
        let token = try XCTUnwrap(store.begin(a.id))
        XCTAssertTrue(store.transition(a.id, token: token, status: .offline))
        store.reorderWaiting([c.id, b.id])
        XCTAssertEqual(PublishingJobStore(file: file).pending.map(\.guid), ["a", "c", "b"])
        XCTAssertTrue(store.cancel(a.id))
        XCTAssertFalse(store.transition(a.id, token: token, status: .done))
        XCTAssertEqual(store.record(a.id)?.status, .cancelled)
        store.clearFinished()
        XCTAssertEqual(store.pending.map(\.guid), ["c", "b"])
    }

    func testCorruptAndNewerArchivesArePreservedAndBlockEnqueue() throws {
        struct Archive: Encodable { var version = 1; var jobs: [PublishingJob] }
        let a = PublishingJob(guid: "a", title: "A", showTitle: "S", order: 0)
        var b = PublishingJob(guid: "b", title: "B", showTitle: "S", order: 1)
        b.id = a.id
        let overflowing = PublishingJob(guid: "a", title: "A", showTitle: "S", order: Int.max)
        let negative = PublishingJob(guid: "a", title: "A", showTitle: "S", order: -1)
        let invalid = [Data("not json".utf8), Data("{\"version\":2,\"jobs\":[]}".utf8),
                       try JSONEncoder().encode(Archive(jobs: [a, b])),
                       try JSONEncoder().encode(Archive(jobs: [overflowing])),
                       try JSONEncoder().encode(Archive(jobs: [negative]))]
        for data in invalid {
            try data.write(to: file)
            let store = PublishingJobStore(file: file)
            XCTAssertNotNil(store.storageError)
            XCTAssertEqual(store.enqueue([("a", "A", "S")]), 0)
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func testWriteFailureCannotStartAnUnpersistedRequest() throws {
        let blocked = folder.appending(path: "blocked")
        try Data("file".utf8).write(to: blocked)
        let store = PublishingJobStore(file: blocked.appending(path: "jobs.json"))
        XCTAssertEqual(store.enqueue([("a", "A", "S")]), 0)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNotNil(store.storageError)
    }

    func testAutomaticRequestCannotUndoUserCancellationButExplicitRetryCan() throws {
        let store = PublishingJobStore(file: file)
        store.enqueue([("a", "A", "S")])
        let job = try XCTUnwrap(store.records.first)
        XCTAssertTrue(store.cancel(job.id))
        XCTAssertEqual(store.enqueue([("a", "A", "S")], allowRetry: false), 0)
        XCTAssertEqual(store.records.first?.status, .cancelled)
        XCTAssertEqual(store.enqueue([("a", "A", "S")]), 1)
        XCTAssertEqual(store.pending.first?.guid, "a")
    }
}
