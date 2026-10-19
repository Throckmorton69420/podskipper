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
    /// Pass 42: Pass 41's edge check counted ticks and passed while the list
    /// barely moved on his phone. This one checks what he asked for: the
    /// viewport moves screens while one finger rests at the edge, the run
    /// is one unbroken block from the row it started on, the same holds
    /// upwards when unticking, and scrolling beside the ticks changes
    /// nothing. LAB_PAGE as `testPageScrolls`; LAB_HOLD seconds at the
    /// bottom edge (default 6).
    func testDragSelectScrollsOn() throws {
        let env = ProcessInfo.processInfo.environment
        let target = try XCTUnwrap(env["LAB_PAGE"], "lab measurement; set LAB_PAGE")
        let hold = Double(env["LAB_HOLD"] ?? "") ?? 6
        let app = XCUIApplication()
        app.launch()
        let library = app.tabBars.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 20))
        library.tap()
        let isShow = target.hasPrefix("show:")
        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", isShow ? String(target.dropFirst(5)) : target)).firstMatch
        for _ in 0..<10 where !(entry.exists && entry.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(entry.waitForExistence(timeout: 5), target)
        entry.tap()
        sleep(2)
        if isShow {
            app.buttons["More"].firstMatch.tap()
            let select = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Select")).firstMatch
            XCTAssertTrue(select.waitForExistence(timeout: 3)); select.tap()
        } else {
            app.buttons["collection.menu"].firstMatch.tap()
            app.buttons["Select"].firstMatch.tap()
        }
        sleep(1)
        let id = isShow ? "SelectableEpisode" : "SelectableRow"
        let rows = app.descendants(matching: .any).matching(identifier: id)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        if isShow { app.swipeUp(velocity: .slow); app.swipeUp(velocity: .slow); sleep(1) }

        struct Seen { let label: String; let selected: Bool; let frame: CGRect }
        func onScreen() -> [Seen] {
            let all = rows.allElementsBoundByIndex
            return all.filter { $0.isHittable }
                .map { Seen(label: $0.label, selected: $0.isSelected, frame: $0.frame) }
                .sorted { $0.frame.minY < $1.frame.minY }
        }
        func selectedCount() -> Int {
            let title = app.navigationBars.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", "Selected")).firstMatch
            guard title.waitForExistence(timeout: 3) else { return 0 }
            return Int(title.label.split(separator: " ").first ?? "") ?? 0
        }
        func tickPoint(_ frame: CGRect, dy: CGFloat) -> XCUICoordinate {
            app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.minX + 22, dy: dy))
        }
        func shoot(_ name: String) {
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        /// Scrolls up beside the ticks until `label` is on screen, keeping
        /// the rows in list order (each screen's new rows go in front).
        func walkUp(to label: String) -> [Seen] {
            var ordered: [Seen] = onScreen()
            for _ in 0..<40 where !ordered.contains(where: { $0.label == label }) {
                let mid = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.35))
                mid.press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.7)))
                usleep(400_000)
                let screen = onScreen()
                guard let join = screen.firstIndex(where: { s in ordered.contains { $0.label == s.label } }) else {
                    ordered = screen + ordered; continue
                }
                ordered = Array(screen[..<join]) + ordered
            }
            return ordered
        }

        // 1. Down: start on the first row, rest one finger at the bottom edge.
        let first = try XCTUnwrap(onScreen().first { $0.frame.minY > 130 })
        let lowest = try XCTUnwrap(onScreen().last)
        let startCount = selectedCount()
        XCTAssertEqual(startCount, 0)
        tickPoint(first.frame, dy: first.frame.midY)
            .press(forDuration: 0.2, thenDragTo: tickPoint(first.frame, dy: lowest.frame.maxY - 20),
                   withVelocity: .slow, thenHoldForDuration: hold)
        sleep(1)
        let down = selectedCount()
        let afterDown = onScreen()
        shoot("p42-lab-down")
        print("LAB p42 \(target): visible \(afterDown.count), held \(hold) s at the bottom → \(down) selected; top now \(afterDown.first?.label.prefix(40) ?? "-")")
        XCTAssertFalse(afterDown.contains { $0.label == first.label }, "the list moved on: the first row has left the screen")
        XCTAssertGreaterThan(down, afterDown.count * 2, "more than two screens chosen in one hold")
        XCTAssertTrue(afterDown.dropLast(2).allSatisfy(\.selected), "every row above the finger is ticked")

        // 2. Up, unticking: start on the last ticked row, rest at the top.
        // Clear of the actions bar floating over the list's bottom.
        let barTop = app.buttons["Selection Actions"].firstMatch.frame.minY
        let lastTicked = try XCTUnwrap(afterDown.last { $0.selected && $0.frame.midY < barTop - 20 })
        let topRow = try XCTUnwrap(afterDown.first)
        tickPoint(lastTicked.frame, dy: lastTicked.frame.midY)
            .press(forDuration: 0.2, thenDragTo: tickPoint(lastTicked.frame, dy: topRow.frame.minY + 30),
                   withVelocity: .slow, thenHoldForDuration: 1.5)
        sleep(1)
        let up = selectedCount()
        let afterUp = onScreen()
        shoot("p42-lab-up-untick")
        print("LAB p42 \(target): held at the top while unticking → \(up) selected; top now \(afterUp.first?.label.prefix(40) ?? "-")")
        XCTAssertNotEqual(afterUp.first?.label, topRow.label, "the list moved up")
        XCTAssertLessThan(up, down - afterDown.count, "more than a screen unticked in one hold")

        // 3. Back to the start beside the ticks: nothing changes, and what
        // is ticked is one block from the first row.
        let walked = walkUp(to: first.label)
        XCTAssertEqual(selectedCount(), up, "scrolling beside the ticks chose nothing")
        let from = try XCTUnwrap(walked.firstIndex { $0.label == first.label })
        let run = walked[from...].prefix { $0.selected }
        print("LAB p42 \(target): walked \(walked.count) rows; block from the first row \(run.count), title \(up)")
        XCTAssertEqual(run.count, up, "the ticked rows are one unbroken block from the row the run started on")
        XCTAssertFalse(walked[..<from].contains { $0.selected }, "nothing above the first row")
        shoot("p42-lab-walked-back")
        app.navigationBars.buttons["Done"].firstMatch.tap()
    }
}
