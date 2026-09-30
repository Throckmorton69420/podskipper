import XCTest
@testable import PodSkipper

/// Not wired into any target yet: `project.yml` has no unit-test target and is
/// off limits to cloud sessions. Add one that includes `Tests/` to run these.
final class PausedLineTests: XCTestCase {
    func testHoldKeepsRunningJobFirstThenTheLine() {
        var line = PausedLine()
        line.hold(running: "a", waiting: ["b", "c"])
        XCTAssertTrue(line.isPaused)
        XCTAssertEqual(line.guids, ["a", "b", "c"])
    }

    func testReleaseReturnsSamePlacesAndUnpauses() {
        var line = PausedLine()
        line.hold(running: "a", waiting: ["b"])
        XCTAssertEqual(line.release(), ["a", "b"])
        XCTAssertFalse(line.isPaused)
    }

    func testHoldingTwiceDoesNotDuplicate() {
        var line = PausedLine()
        line.hold(running: "a", waiting: ["b"])
        line.hold(running: "b", waiting: ["a", "c"])
        XCTAssertEqual(line.guids, ["a", "b", "c"])
    }

    func testDropRemovesOnlyThatJob() {
        var line = PausedLine(guids: ["a", "b", "c"])
        line.drop("b")
        XCTAssertEqual(line.guids, ["a", "c"])
        line.drop("a"); line.drop("c")
        XCTAssertFalse(line.isPaused)
    }

    func testSurvivesRelaunch() {
        let defaults = UserDefaults(suiteName: "PausedLineTests")!
        defaults.removePersistentDomain(forName: "PausedLineTests")
        PausedLine(guids: ["a", "b"]).save(to: defaults)
        XCTAssertEqual(PausedLine.load(from: defaults).guids, ["a", "b"])
        PausedLine().save(to: defaults)
        XCTAssertFalse(PausedLine.load(from: defaults).isPaused)
    }
}
