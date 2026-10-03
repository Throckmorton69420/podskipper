import XCTest
@testable import PodSkipper

@MainActor
final class BackgroundProgressTests: XCTestCase {
    func testWaitingWithoutMeasuredProgressDoesNotAdvance() {
        let waiting = BackgroundWork.Snapshot(title: "Finding ads", subtitle: "Waiting for the model", fraction: 0)
        XCTAssertEqual(BackgroundWork.measuredUnits(waiting, total: 100_000), 0)
        let part = BackgroundWork.Snapshot(title: "Finding ads", subtitle: "Waiting", fraction: 0.25)
        for _ in 0..<100 { XCTAssertEqual(BackgroundWork.measuredUnits(part, total: 100_000), 25_000) }
    }
    func testBatchMeasuresCompletedJobsAndCapsUnfinishedWork() {
        let batch = BackgroundWork.Snapshot(title: "Batch", subtitle: "Second episode", fraction: 0.5, completed: 1.5, jobs: 3)
        XCTAssertEqual(BackgroundWork.measuredUnits(batch, total: 300_000), 150_000)
        let done = BackgroundWork.Snapshot(title: "Batch", subtitle: "Saving", fraction: 1)
        XCTAssertEqual(BackgroundWork.measuredUnits(done, total: 100_000), 99_999)
        let invalid = BackgroundWork.Snapshot(title: "Batch", subtitle: "", fraction: 0, completed: .infinity)
        XCTAssertEqual(BackgroundWork.measuredUnits(invalid, total: 100_000), 0)
    }
}
