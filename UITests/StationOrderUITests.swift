import XCTest

/// Uses only the in-memory demo library: Starred contains two exact episodes.
final class StationOrderUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-UITestScreenshots", "1"]
        app.launch()
    }

    func testCancelSaveReopenGroupAndPlayExactFirstEpisode() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        if app.buttons["Skip"].waitForExistence(timeout: 4) { app.buttons["Skip"].tap() }
        let library = app.tabBars.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10)); library.tap()
        let stations = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Stations'")).firstMatch
        XCTAssertTrue(stations.waitForExistence(timeout: 5)); stations.tap()
        let starred = app.staticTexts["Starred"].firstMatch
        XCTAssertTrue(starred.waitForExistence(timeout: 5)); starred.tap()
        XCTAssertTrue(element("station.options").waitForExistence(timeout: 5))
        let keeperID = "demo-2-0", ferryID = "demo-0-1"
        assertAbove(row(keeperID), row(ferryID))
        capture("station-01-original")

        openOrder()
        dragBefore(ferryID, keeperID)
        assertAbove(orderRow(ferryID), orderRow(keeperID))
        element("station.order.cancel").tap()
        waitForEditorDismissal()
        assertAbove(row(keeperID), row(ferryID))

        openOrder()
        dragBefore(ferryID, keeperID)
        assertAbove(orderRow(ferryID), orderRow(keeperID))
        capture("station-02-reorder-draft")
        element("station.order.save").tap()
        waitForEditorDismissal()
        assertAbove(row(ferryID), row(keeperID))
        capture("station-03-saved")

        openOrder()
        assertAbove(orderRow(ferryID), orderRow(keeperID))
        element("station.order.cancel").tap()
        waitForEditorDismissal()
        element("station.options").tap()
        element("station.settings.open").tap()
        let group = app.switches.matching(identifier: "station.settings.groupByShow").firstMatch
        reveal(group); tapNativeSwitch(group)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: group)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        element("station.settings.save").tap()
        let settingsDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: group)
        XCTAssertEqual(XCTWaiter.wait(for: [settingsDismissed], timeout: 8), .completed)
        XCTAssertTrue(element("station.group.feed:https://example.invalid/demo/0.xml").waitForExistence(timeout: 5))
        XCTAssertTrue(element("station.group.feed:https://example.invalid/demo/2.xml").exists)
        assertAbove(row(ferryID), row(keeperID))
        capture("station-04-grouped")

        XCUIDevice.shared.orientation = .landscapeLeft
        waitForRenderedOrientation(landscape: true)
        reveal(row(ferryID)); XCTAssertTrue(row(ferryID).isHittable)
        capture("station-04b-grouped-landscape")
        XCUIDevice.shared.orientation = .portrait
        waitForRenderedOrientation(landscape: false)
        for _ in 0..<4 where !element("station.playAll").isHittable { app.swipeDown() }

        element("station.playAll").tap()
        let mini = element("MiniPlayer")
        let expected = "The Ferry That Only Runs When It Feels Like It"
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: mini)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 12), .completed,
                       "Play All must switch to the first episode in the saved Station order")
        mini.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        let title = element("PlayerEpisodeTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 8)); XCTAssertEqual(title.label, expected)
        capture("station-05-exact-playback")
    }

    func testGroupingControlPersistsOnStation() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        if app.buttons["Skip"].waitForExistence(timeout: 4) { app.buttons["Skip"].tap() }
        let library = app.tabBars.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10)); library.tap()
        let stations = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Stations'")).firstMatch
        XCTAssertTrue(stations.waitForExistence(timeout: 5)); stations.tap()
        let starred = app.staticTexts["Starred"].firstMatch
        XCTAssertTrue(starred.waitForExistence(timeout: 5)); starred.tap()
        XCTAssertTrue(element("station.options").waitForExistence(timeout: 5))
        element("station.options").tap(); element("station.settings.open").tap()
        let group = app.switches.matching(identifier: "station.settings.groupByShow").firstMatch
        reveal(group)
        let before = XCTAttachment(string: app.debugDescription)
        before.name = "station-toggle-before"; before.lifetime = .keepAlways; add(before)
        capture("station-toggle-before")
        tapNativeSwitch(group)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: group)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        capture("station-toggle-enabled")
        element("station.settings.save").tap()
        XCTAssertTrue(element("station.group.feed:https://example.invalid/demo/2.xml").waitForExistence(timeout: 8))
        capture("station-toggle-groups")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForRenderedOrientation(landscape: true)
        reveal(row("demo-2-0"))
        capture("station-toggle-groups-landscape")
        XCUIDevice.shared.orientation = .portrait
        waitForRenderedOrientation(landscape: false)
    }

    private func waitForRenderedOrientation(landscape: Bool) {
        // Window bounds change before the compositor finishes rotation. Wait
        // for the actual captured image so a transitional frame cannot pass.
        let rendered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let size = XCUIScreen.main.screenshot().image.size
            return landscape ? size.width > size.height : size.height > size.width
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 8), .completed)
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func tapNativeSwitch(_ row: XCUIElement) {
        // SwiftUI Forms expose both the accessibility row and its UISwitch.
        // A tap at the row's center misses the control on iOS 27.
        let control = row.switches.firstMatch
        XCTAssertTrue(control.exists, "Tap the native switch from the captured accessibility hierarchy")
        XCTAssertTrue(control.isHittable)
        control.tap()
    }
    private func row(_ guid: String) -> XCUIElement { element("station.episode.\(guid)") }
    private func orderRow(_ guid: String) -> XCUIElement { element("station.order.episode.\(guid)") }

    private func openOrder() {
        element("station.options").tap(); element("station.order.open").tap()
        XCTAssertTrue(element("station.order.editor").waitForExistence(timeout: 5))
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "station-order-hierarchy"; hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func dragBefore(_ moving: String, _ target: String) {
        let movingCell = app.cells.containing(.any, identifier: "station.order.episode.\(moving)").firstMatch
        let targetCell = app.cells.containing(.any, identifier: "station.order.episode.\(target)").firstMatch
        XCTAssertTrue(movingCell.waitForExistence(timeout: 4)); XCTAssertTrue(targetCell.exists)
        XCTAssertTrue(movingCell.isHittable); XCTAssertTrue(targetCell.isHittable)
        let handle = movingCell.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] 'Reorder'")).firstMatch
        XCTAssertTrue(handle.exists, "Use the native reorder handle rather than a guessed point on the row")
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.7, thenDragTo: targetCell.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.25)))
    }

    private func assertAbove(_ first: XCUIElement, _ second: XCUIElement) {
        let ordered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            first.exists && second.exists && !first.frame.isEmpty && !second.frame.isEmpty
                && first.frame.minY < second.frame.minY
        }, object: first)
        XCTAssertEqual(XCTWaiter.wait(for: [ordered], timeout: 5), .completed)
    }

    private func waitForEditorDismissal() {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element("station.order.editor"))
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 8), .completed)
    }

    private func reveal(_ item: XCUIElement) {
        for _ in 0..<8 {
            if item.exists, item.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(item.isHittable)
    }

    private func capture(_ name: String) {
        // Match ScreenshotTests: capture the display, including presented
        // sheets and orientation, rather than the app's clipped host window.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
