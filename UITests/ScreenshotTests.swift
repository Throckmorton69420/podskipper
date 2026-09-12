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
        _ = app.wait(for: .runningForeground, timeout: 10)
        capture("00-launch")

        dismissOnboarding()
        capture("02-library")

        // Library collections.
        openRow("Playlists", then: "03-playlists")
        openRow("Bookmarks", then: "04-bookmarks")
        openRow("Statistics", then: "05-stats")
        openRow("Latest Episodes", then: "05b-latest")

        // Tabs.
        visitTab("Discover", shot: "06-discover")
        visitTab("Up Next", shot: "07-upnext")
        visitTab("Publish", shot: "08-publish")
        visitTab("Settings", shot: "09-settings")

        // Deeper settings.
        if tapAnything("Effects and equalizer") {
            settle()
            capture("10-audio-effects")
            back()
        }

        // A show, then the player — the two screens that changed most, and
        // the two that were never photographed while the seeded library was
        // empty.
        visitTab("Library", shot: "11-library-again")
        openFirstShow()
    }

    private func openFirstShow() {
        // The demo library seeds these, so they are looked up by name rather
        // than by guessing a row index.
        guard tapAnything("The Long Way Round") else { return }
        settle()
        capture("12-show-detail")

        // Scroll down the episode list so the rows, not just the header, are
        // in a picture.
        app.swipeUp()
        settle(timeout: 2)
        capture("13-show-episodes")

        // Start something so the player has real content to draw.
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play'")).firstMatch
        if play.waitForExistence(timeout: 3), play.isHittable {
            play.tap()
            settle(timeout: 3)
            capture("14-playing-show")

            // The mini player expands into the full player.
            let mini = app.otherElements["MiniPlayer"].exists
                ? app.otherElements["MiniPlayer"]
                : app.staticTexts["The Long Way Round"].firstMatch
            if mini.exists, mini.isHittable {
                mini.tap()
                settle(timeout: 3)
                capture("15-player")
            }
        }
    }

    // MARK: - Helpers

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Waits for the app to stop animating instead of sleeping a fixed amount.
    ///
    /// The old version slept one second after dismissing onboarding and then
    /// photographed the library. On a loaded CI runner the sheet was still on
    /// screen, so three different "screens" came back as the same picture of
    /// the onboarding page.
    private func settle(timeout: TimeInterval = 4) {
        _ = app.navigationBars.firstMatch.waitForExistence(timeout: timeout)
        let idle = expectation(description: "idle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { idle.fulfill() }
        wait(for: [idle], timeout: timeout + 1)
    }

    private func dismissOnboarding() {
        guard app.buttons["Skip"].waitForExistence(timeout: 5) else { return }
        capture("01-onboarding")
        app.buttons["Skip"].tap()
        // Wait for the sheet to actually go, rather than assuming it has.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.buttons["Skip"], handler: nil)
        waitForExpectations(timeout: 6)
        settle()
    }

    /// Opens a library row and photographs where it lands.
    ///
    /// Taps the row, not the text inside it. A library row is a single
    /// accessibility Button containing an icon, a label and a chevron — which
    /// is what VoiceOver should hear — so the inner StaticText is by
    /// definition not independently hittable. The previous version tapped
    /// `app.staticTexts[label]` and failed the whole run on "Not hittable".
    private func openRow(_ label: String, then shot: String) {
        guard tapAnything(label) else { return }
        settle()
        capture(shot)
        back()
        settle(timeout: 2)
    }

    /// Tries every reasonable representation of the same control, in the order
    /// they are most likely to be the real tap target.
    @discardableResult
    private func tapAnything(_ label: String) -> Bool {
        let candidates: [XCUIElement] = [
            app.buttons[label],
            app.cells.buttons[label],
            app.cells.containing(.staticText, identifier: label).firstMatch,
            app.staticTexts[label]
        ]
        for element in candidates {
            guard element.waitForExistence(timeout: 2) else { continue }
            guard element.isHittable else { continue }
            element.tap()
            return true
        }
        return false
    }

    /// On iPhone the tabs live in a tab bar. On iPad with the adaptive
    /// sidebar they're list rows, and the sidebar may start collapsed.
    private func visitTab(_ name: String, shot: String) {
        // The tab bar minimises on scroll down (tabBarMinimizeBehavior), so
        // after a screen has been scrolled the tabs are not hittable. Nudging
        // the content back down restores it. Without this the run silently
        // skipped Up Next, Publish and Settings after visiting Discover.
        if !tapTab(name) {
            app.swipeDown()
            settle(timeout: 2)
        }
        if tapTab(name) {
            settle()
            capture(shot)
            return
        }
        let toggle = app.buttons["ToggleSidebar"]
        if toggle.exists, toggle.isHittable {
            toggle.tap()
            settle(timeout: 2)
            if tapTab(name) {
                settle()
                capture(shot)
            }
        }
    }

    @discardableResult
    private func tapTab(_ name: String) -> Bool {
        let tab = app.tabBars.buttons[name]
        if tab.waitForExistence(timeout: 3), tab.isHittable {
            tab.tap(); return true
        }
        return tapAnything(name)
    }

    private func back() {
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.exists, backButton.isHittable { backButton.tap() }
    }
}
