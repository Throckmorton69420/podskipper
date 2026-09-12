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

        // Tabs, in an order chosen so that nothing depends on a screen that
        // cannot be left. Discover is at the very bottom of this method.
        visitTab("Up Next", shot: "07-upnext")
        visitTab("Publish", shot: "08-publish")
        visitTab("Settings", shot: "09-settings")

        // Deeper settings, while still on the Settings tab.
        if tapAnything("Effects and equalizer") {
            settle()
            capture("10-audio-effects")
            back()
            settle(timeout: 2)
        }


        // A show, then the player — the two screens that changed most, and
        // the two that were never photographed while the seeded library was
        // empty.
        visitTab("Library", shot: "11-library-again")
        openFirstShow()

        // Dead last, and nothing after it.
        //
        // Discover is the search-role tab: entering it hands the bottom of
        // the screen to the search field, and the tab bar does not come back
        // — "Library" simply stops existing in the hierarchy. Visiting it
        // before the show meant the show, the player and everything else were
        // never reached. Nothing is scheduled after it now, so it cannot cost
        // anything.
        visitTab("Discover", shot: "06-discover")
    }

    private func openFirstShow() {
        // The demo library seeds these, so they are looked up by name rather
        // than by guessing a row index.
        guard tapAnything("The Long Way Round") else { return }
        settle()
        capture("12-show-detail")

        // The per-show overrides. There are four kinds of segment with their
        // own switch now, plus the fixed trims, so this screen is worth a
        // picture of its own.
        openShowSettings()

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

            // The mini player expands into the full player. It carries an
            // accessibility identifier now; before it did not, so the run fell
            // back to tapping the show title, which did nothing, and the
            // "15-player" screenshot came back byte-identical to the one
            // before it.
            let mini = app.descendants(matching: .any)
                .matching(identifier: "MiniPlayer").firstMatch
            if mini.waitForExistence(timeout: 4) {
                if mini.isHittable { mini.tap() } else { _ = tapCentre(of: mini) }
                settle(timeout: 3)
                capture("15-player")

                // Put the player away. It is a sheet over everything, so
                // leaving it up meant the next capture — Discover — was a
                // second photograph of the player, six seconds later.
                if !tapAnything("Close") { app.swipeDown() }
                settle(timeout: 2)
            }
        }
    }

    /// Opens the ⋯ menu on a show, photographs it and the settings sheet
    /// behind it, then closes both.
    private func openShowSettings() {
        guard tapAnything("More") else { return }
        settle(timeout: 2)
        capture("12b-show-menu")

        guard tapAnything("Show Settings") else {
            // The menu is still open over the show. Dismiss it rather than
            // leaving every later screenshot photographing a popover.
            app.tap()
            settle(timeout: 2)
            return
        }
        settle()
        capture("12c-show-settings")

        // A sheet with a `Button(role: .close)`, which the system labels
        // "Close" — not "Done", and not the back button.
        if !tapAnything("Close") {
            app.swipeDown()
        }
        settle(timeout: 2)
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
    ///
    /// Falls back to tapping the middle of an element's frame. On iPad the
    /// adaptive tab bar's items report `isHittable == false` even while they
    /// are plainly on screen and working, so the previous version silently
    /// skipped Up Next, Publish, the audio effects screen and every screen
    /// after it — an entire run of the iPad job came back nine screenshots
    /// short with no failure to explain it.
    @discardableResult
    private func tapAnything(_ label: String) -> Bool {
        // Every candidate is a firstMatch. An unresolved query throws the
        // moment anything asks it for a frame — and on iPad the floating tab
        // bar nests a button of the same label inside a button, so
        // `app.buttons["Up Next"]` matches two elements and the whole run
        // died on "Multiple matching elements found".
        let candidates: [XCUIElement] = [
            app.buttons[label].firstMatch,
            app.cells.buttons[label].firstMatch,
            app.cells.containing(.staticText, identifier: label).firstMatch,
            app.staticTexts[label].firstMatch
        ]
        for element in candidates {
            guard element.waitForExistence(timeout: 2) else { continue }
            if element.isHittable {
                element.tap()
                return true
            }
            if tapCentre(of: element) { return true }
        }
        return false
    }

    /// Taps an element's centre by coordinate, which does not consult
    /// hittability. Guarded on a sane frame so a zero-sized or off-screen
    /// element doesn't send a tap into the corner of the display.
    private func tapCentre(of element: XCUIElement) -> Bool {
        // `.frame` resolves the query, so this is only ever handed a
        // firstMatch by its callers.
        let frame = element.frame
        guard frame.width > 1, frame.height > 1 else { return false }
        let window = app.windows.firstMatch.frame
        guard window.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return false }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        return true
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
        let tab = app.tabBars.buttons[name].firstMatch
        if tab.waitForExistence(timeout: 3) {
            if tab.isHittable {
                tab.tap(); return true
            }
            if tapCentre(of: tab) { return true }
        }
        return tapAnything(name)
    }

    private func back() {
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.exists, backButton.isHittable { backButton.tap() }
    }
}
