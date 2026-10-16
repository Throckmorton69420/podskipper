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

    /// Pass 41 lab: scroll one page up and down for a profiler attached to
    /// the app. LAB_PAGE is a Library row ("Downloaded", "Latest Episodes",
    /// "Saved") or "show:<title>"; LAB_SCROLLS swipes each way (default 8).
    /// Prints "LAB scroll start/end" around the swipes.
    func testPageScrolls() throws {
        let env = ProcessInfo.processInfo.environment
        let target = try XCTUnwrap(env["LAB_PAGE"], "lab measurement; set LAB_PAGE")
        let scrolls = Int(env["LAB_SCROLLS"] ?? "") ?? 8
        let app = XCUIApplication()
        app.launch()
        let library = app.tabBars.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        if target.hasPrefix("show:") {
            let title = String(target.dropFirst(5))
            let show = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
            for _ in 0..<10 where !(show.exists && show.isHittable) { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(show.waitForExistence(timeout: 5), title)
            show.tap()
        } else if target != "Library" {
            let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", target)).firstMatch
            for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(row.waitForExistence(timeout: 5), target)
            row.tap()
        }
        sleep(3)
        print("LAB scroll start \(target)")
        let t0 = Date()
        for _ in 0..<scrolls { app.swipeUp(velocity: .fast) }
        for _ in 0..<scrolls { app.swipeDown(velocity: .fast) }
        print(String(format: "LAB scroll end %@ %.1f s", target, Date().timeIntervalSince(t0)))
        sleep(2)
    }

    /// Pass 41 lab: on a long list of the simulator's own library (LAB_PAGE as
    /// above), Select, then hold a finger on the first tick and slide to
    /// the bottom edge: the list scrolls on and the run carries past the
    /// screen. Then a plain scroll, and Done.
    func testDragSelectLongList() throws {
        let env = ProcessInfo.processInfo.environment
        let target = try XCTUnwrap(env["LAB_PAGE"], "lab measurement; set LAB_PAGE")
        let app = XCUIApplication()
        app.launch()
        let library = app.tabBars.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 20))
        library.tap()
        let row = target.hasPrefix("show:")
            ? app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", String(target.dropFirst(5)))).firstMatch
            : app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", target)).firstMatch
        for _ in 0..<10 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.waitForExistence(timeout: 5), target)
        row.tap()
        sleep(2)
        if target.hasPrefix("show:") {
            app.buttons["More"].firstMatch.tap()
            let select = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Select")).firstMatch
            XCTAssertTrue(select.waitForExistence(timeout: 3)); select.tap()
        } else {
            app.buttons["collection.menu"].firstMatch.tap()
            app.buttons["Select"].firstMatch.tap()
        }
        sleep(1)
        let id = target.hasPrefix("show:") ? "SelectableEpisode" : "SelectableRow"
        let rows = app.descendants(matching: .any).matching(identifier: id)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        // A show page's episodes start under its header: bring them up
        // first (a swipe on the rows, away from the ticks).
        if target.hasPrefix("show:") { app.swipeUp(velocity: .slow); app.swipeUp(velocity: .slow); sleep(1) }
        let candidates = (0..<min(rows.count, 14)).map { rows.element(boundBy: $0) }.filter { $0.isHittable }
        let first = try XCTUnwrap(candidates.first { $0.frame.minY > 120 })
        let visible = candidates.filter { $0.frame.minY >= first.frame.minY }.count
        let tick = first.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).withOffset(CGVector(dx: 22, dy: 0))
        let window = app.windows.firstMatch.frame
        let bottom = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: tick.screenPoint.x, dy: window.maxY - 165))
        tick.press(forDuration: 0.2, thenDragTo: bottom, withVelocity: .slow, thenHoldForDuration: 3)
        sleep(1)
        let title = app.navigationBars.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "Selected")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        let count = Int(title.label.split(separator: " ").first ?? "") ?? 0
        print("LAB drag-select \(target): visible \(visible), after holding at the bottom edge \(title.label)")
        XCTAssertGreaterThan(count, visible, "the run carried past the rows on screen")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "p41-lab-edge"; shot.lifetime = .keepAlways; add(shot)
        app.swipeDown(velocity: .fast)
        sleep(1)
        XCTAssertEqual(title.label, "\(count) Selected", "scrolling chose nothing")
        app.navigationBars.buttons["Done"].firstMatch.tap()
    }
}
