import XCTest

/// Walks the app in the simulator and photographs every screen.
///
/// This exists so the person writing the code can actually see the result.
/// The workflow runs it on a GitHub macOS runner, pulls the images out of the
/// test bundle, and uploads them — which turns "I think this looks right" into
/// "here is what it looks like".
final class ScreenshotTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments += ["-UITestScreenshots", "1"]
        app.launch()
    }

    func testCaptureEveryScreen() throws {
        // Onboarding shows on a fresh install; photograph it, then dismiss.
        sleep(3)
        capture("00-launch")

        if app.buttons["Skip"].waitForExistence(timeout: 4) {
            capture("01-onboarding")
            app.buttons["Skip"].tap()
            sleep(1)
        } else if app.buttons["Get started"].exists {
            app.buttons["Get started"].tap()
            sleep(1)
        }

        capture("02-library")

        // Library collections
        tapIfPresent("Playlists", then: "03-playlists")
        tapIfPresent("Bookmarks", then: "04-bookmarks")
        tapIfPresent("Statistics", then: "05-stats")

        // Tabs
        visitTab("Discover", shot: "06-discover")
        visitTab("Up Next", shot: "07-upnext")
        visitTab("Publish", shot: "08-publish")
        visitTab("Settings", shot: "09-settings")

        // Deeper settings
        if app.staticTexts["Effects and equalizer"].waitForExistence(timeout: 3) {
            app.staticTexts["Effects and equalizer"].tap()
            sleep(1)
            capture("10-audio-effects")
            back()
        }

        visitTab("Library", shot: "11-library-again")
    }

    // MARK: - Helpers

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Taps a row by label, photographs where it lands, then comes back.
    private func tapIfPresent(_ label: String, then shot: String) {
        let element = app.staticTexts[label]
        guard element.waitForExistence(timeout: 3) else { return }
        element.tap()
        sleep(2)
        capture(shot)
        back()
        sleep(1)
    }

    private func visitTab(_ name: String, shot: String) {
        let tab = app.tabBars.buttons[name]
        if tab.waitForExistence(timeout: 4) {
            tab.tap()
        } else if app.buttons[name].exists {
            app.buttons[name].tap()
        } else {
            return
        }
        sleep(2)
        capture(shot)
    }

    private func back() {
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.exists { backButton.tap() }
    }
}
