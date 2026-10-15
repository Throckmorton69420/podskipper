import XCTest

/// Pass 40 lab: how long a tap on the Downloaded page takes to answer, on the
/// simulator's own library (not the demo one), with and without the store
/// busy the way back-catalogue indexing keeps it busy (`-LabStoreWrites`,
/// debug builds). Run only when asked:
///
///   TEST_RUNNER_LAB_REAL_LIBRARY=1 [TEST_RUNNER_LAB_WRITES=1] xcodebuild test … \
///     -only-testing:PodSkipperUITests/ResponsivenessLabUITests
///
/// Prints one line per tap and a summary ("LAB tap→page median … max …").
final class ResponsivenessLabUITests: XCTestCase {
    func testDownloadedPageAnswersTaps() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["LAB_REAL_LIBRARY"] == "1", "lab measurement; set LAB_REAL_LIBRARY=1")
        let app = XCUIApplication()
        if env["LAB_WRITES"] == "1" { app.launchArguments += ["-LabStoreWrites", "60"] }
        app.launch()
        let library = app.tabBars.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        // LAB_VISIT_TABS=1: open every tab first, so pages kept alive in
        // other tabs are part of the measurement.
        if env["LAB_VISIT_TABS"] == "1" {
            for tab in ["Up Next", "New", "Settings"] {
                let button = app.tabBars.buttons[tab].firstMatch
                if button.waitForExistence(timeout: 3) { button.tap(); sleep(2) }
            }
            let search = app.tabBars.buttons["Search"].firstMatch
            if search.exists { search.tap(); sleep(2) }
        }
        library.tap()
        let downloaded = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Downloaded")).firstMatch
        for _ in 0..<6 where !(downloaded.exists && downloaded.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(downloaded.waitForExistence(timeout: 5))
        downloaded.tap()
        let list = app.descendants(matching: .any).matching(identifier: "collection.Downloaded").firstMatch
        let page = app.descendants(matching: .any).matching(identifier: "EpisodePage").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10), "Downloaded page")
        // LAB_IDLE=<s>: stay on the page without touching it (no
        // accessibility queries), for a profiler attached to the app.
        if let idle = env["LAB_IDLE"].flatMap(Double.init) {
            print("LAB idle start")
            Thread.sleep(forTimeInterval: idle)
            print("LAB idle end")
        }
        let rows = list.cells
        XCTAssertGreaterThan(rows.count, 0, "the simulator's library has downloads")

        var open: [Double] = [], back: [Double] = []
        for i in 0..<10 {
            let row = rows.element(boundBy: i % min(rows.count, 4))
            guard row.waitForExistence(timeout: 5) else { continue }
            let t0 = Date()
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.4)).tap()
            XCTAssertTrue(page.waitForExistence(timeout: 15), "episode page \(i)")
            open.append(Date().timeIntervalSince(t0))
            let t1 = Date()
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(list.waitForExistence(timeout: 15))
            back.append(Date().timeIntervalSince(t1))
            print(String(format: "LAB tap %d: open %.2f s, back %.2f s", i + 1, open.last!, back.last!))
        }
        func summary(_ xs: [Double]) -> String {
            let s = xs.sorted()
            guard !s.isEmpty else { return "none" }
            return String(format: "median %.2f s · max %.2f s · n %d", s[s.count / 2], s.last!, s.count)
        }
        print("LAB writes=\(env["LAB_WRITES"] ?? "0") tap→page \(summary(open)) · back→list \(summary(back))")
    }
}
