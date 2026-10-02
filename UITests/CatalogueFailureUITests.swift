import XCTest

final class CatalogueFailureUITests: XCTestCase {
    func testFailureRemainsVisibleWithReadableMessageAndReachableRetryInBothOrientations() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["-UITestScreenshots", "1", "-CatalogueFailureDemo"]
        app.launch()
        if app.buttons["Skip"].waitForExistence(timeout: 5) { app.buttons["Skip"].tap() }
        let library = app.tabBars.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10)); library.tap()
        let title = app.staticTexts["Episode catalogue needs another try"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        let message = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Free some space, then retry.'")).firstMatch
        XCTAssertTrue(message.exists)
        let retry = app.buttons["library.catalogue.retry"].firstMatch
        XCTAssertTrue(retry.exists); XCTAssertTrue(retry.isHittable)
        capture("catalogue-failure-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return frame.width > frame.height
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 8), .completed)
        XCTAssertTrue(title.exists); XCTAssertTrue(message.exists)
        XCTAssertTrue(retry.isHittable)
        capture("catalogue-failure-landscape")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
