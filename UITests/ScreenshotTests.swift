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

    /// The player and the things reached from it, and nothing else.
    ///
    /// The full tour is twelve minutes and photographs twenty-three screens,
    /// which is the wrong tool for checking one change to the player. Run it
    /// on its own:
    ///
    ///     xcodebuild test -only-testing:PodSkipperScreens/ScreenshotTests/testPlayer …
    ///
    /// About a minute, and it fails loudly rather than waiting if it cannot
    /// get where it is going — the full tour's habit of quietly photographing
    /// the library instead of the show page cost three runs before anyone
    /// noticed.
    func testPlayer() throws {
        _ = app.wait(for: .runningForeground, timeout: 10)
        dismissOnboarding()

        guard ["Quiet Hours", "Hard Drive Full", "The Long Way Round"]
            .contains(where: { tapAnything($0) && app.buttons["More"].waitForExistence(timeout: 3) })
        else {
            capture("p0-FAILED-no-show")
            XCTFail("Could not open a show — nothing below this was tested.")
            return
        }
        settle()

        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play'")).firstMatch
        guard play.waitForExistence(timeout: 4) else {
            capture("p0-FAILED-no-play")
            XCTFail("No play control on the show page.")
            return
        }
        if play.isHittable { play.tap() } else { _ = tapCentre(of: play) }
        settle(timeout: 2)

        // An unprocessed episode asks first. Photograph the question, then
        // take the default.
        capture("p1-play-prompt")
        let playNow = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Play now'")).firstMatch
        if playNow.waitForExistence(timeout: 2), playNow.isHittable { playNow.tap() }
        settle(timeout: 4)

        let mini = app.descendants(matching: .any).matching(identifier: "MiniPlayer").firstMatch
        guard mini.waitForExistence(timeout: 6) else {
            capture("p0-FAILED-no-mini-player")
            XCTFail("Nothing started playing.")
            return
        }
        if mini.isHittable { mini.tap() } else { _ = tapCentre(of: mini) }
        settle(timeout: 3)
        capture("p2-player")

        // The ⋯ menu, and the report behind it. Menu items are tapped
        // directly: `tapAnything` scrolls things into view, and swiping
        // inside an open menu is how the last run wedged itself.
        let more = app.buttons["More"].firstMatch
        if more.waitForExistence(timeout: 3), more.isHittable {
            more.tap()
            settle(timeout: 2)
            capture("p3-menu")
            let report = app.buttons["What was skipped"].firstMatch
            if report.waitForExistence(timeout: 3), report.isHittable {
                report.tap()
                settle(timeout: 3)
                capture("p4-skip-report")

                // Open the first segment. The trimmer, the preview player and
                // the transcript only exist inside an expanded row, so the
                // collapsed list above proves nothing about any of them — and
                // "it looked fine in the screenshot" about a screen that was
                // never actually shown is how this project keeps shipping
                // broken layouts.
                //
                // By the sponsor's name, not by coordinate.
                //
                // The first attempt tapped a normalised point and landed in the
                // gap between the summary and the first row, so the "opened"
                // screenshot was byte-identical to the closed one — which a
                // glance at the file sizes caught and a glance at the picture
                // would not have.
                let row = app.buttons
                    .matching(NSPredicate(format: "label CONTAINS 'Brightwater'")).firstMatch
                if row.waitForExistence(timeout: 3) {
                    if row.isHittable { row.tap() } else { _ = tapCentre(of: row) }
                } else {
                    XCTFail("No segment row to open — the report was empty.")
                }
                settle(timeout: 2)
                capture("p5-skip-report-open")

                // And playing. The transcript only highlights a line while
                // something is playing, so a still of the stopped state does
                // not show the thing that was asked for.
                let preview = app.buttons["Hear what was cut"].firstMatch
                if preview.waitForExistence(timeout: 3), preview.isHittable {
                    preview.tap()
                    settle(timeout: 3)
                    capture("p6-skip-report-playing")
                }
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
            }
        }
    }

    /// The bottom of the screen while something is playing, the episode
    /// selection mode, and a show's publish page.
    ///
    /// The bottom bar was reported twice from a phone: too small to read once
    /// the tab bar has shrunk, and a translucent band that grows above it while
    /// scrolling. Neither is visible in a picture taken at the top of a list
    /// with nothing playing, which is the only state the other tours reach —
    /// so this one starts playback, leaves the player closed, and photographs
    /// the bar at rest, scrolled, and scrolled back.
    func testBottomBarAndSelection() throws {
        _ = app.wait(for: .runningForeground, timeout: 10)
        dismissOnboarding()

        guard ["Quiet Hours", "Hard Drive Full", "The Long Way Round"]
            .contains(where: { tapAnything($0) && app.buttons["More"].waitForExistence(timeout: 3) })
        else {
            capture("b0-FAILED-no-show")
            XCTFail("Could not open a show — nothing below this was tested.")
            return
        }
        settle()

        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play'")).firstMatch
        if play.waitForExistence(timeout: 4) {
            if play.isHittable { play.tap() } else { _ = tapCentre(of: play) }
            settle(timeout: 2)
            let playNow = app.buttons
                .matching(NSPredicate(format: "label BEGINSWITH 'Play now'")).firstMatch
            if playNow.waitForExistence(timeout: 2), playNow.isHittable { playNow.tap() }
            settle(timeout: 4)
        }
        let mini = app.descendants(matching: .any).matching(identifier: "MiniPlayer").firstMatch
        if !mini.waitForExistence(timeout: 6) {
            capture("b0-FAILED-no-mini-player")
            XCTFail("Nothing started playing.")
        }
        capture("b1-show-top-playing")

        app.swipeUp()
        settle(timeout: 2)
        capture("b2-show-scrolled-once")
        app.swipeUp()
        settle(timeout: 2)
        capture("b3-show-scrolled-twice")
        app.swipeDown()
        settle(timeout: 2)
        capture("b4-show-scrolled-back-a-little")
        app.swipeDown(); app.swipeDown()
        settle(timeout: 2)
        capture("b5-show-back-at-top")

        // Selection. Reached from the show's ⋯ menu.
        let more = app.buttons["More"].firstMatch
        if more.waitForExistence(timeout: 3) {
            if more.isHittable { more.tap() } else { _ = tapCentre(of: more) }
            settle(timeout: 2)
            let select = app.buttons["Select Episodes"].firstMatch
            if select.waitForExistence(timeout: 3), select.isHittable {
                select.tap()
                settle(timeout: 2)
                capture("b6-select-empty")
                let rows = app.descendants(matching: .any).matching(identifier: "SelectableEpisode")
                for index in 0..<2 where rows.count > index {
                    let row = rows.element(boundBy: index)
                    if row.isHittable { row.tap() } else { _ = tapCentre(of: row) }
                }
                settle(timeout: 2)
                capture("b7-select-two")
                let actions = app.buttons["Selection Actions"].firstMatch
                if actions.waitForExistence(timeout: 2), actions.isHittable {
                    actions.tap()
                    settle(timeout: 2)
                    capture("b8-select-actions-menu")
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
                    settle(timeout: 2)
                }
                if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
                settle(timeout: 2)
                capture("b9-select-done")
            } else {
                capture("b6-FAILED-no-select-item")
                XCTFail("No Select Episodes item in the show's menu.")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
            }
        }

        // A show's publish page, reached through the Publish tab. Matching a
        // button labelled "Publish" found the tab first, so the last run
        // photographed the tab and called it the show's page.
        if tapTab("Publish") {
            settle(timeout: 3)
            capture("b10-publish-tab")
            if tapAnything("Hard Drive Full") || tapAnything("The Long Way Round") {
                settle(timeout: 3)
                capture("b11-publish-show")
                app.swipeUp()
                settle(timeout: 2)
                capture("b12-publish-show-scrolled")
            } else {
                capture("b11-FAILED-no-publish-show")
                XCTFail("Could not open a show from the Publish tab.")
            }
        }
    }

    /// Pressing play on an episode whose ads have not been found, choosing
    /// Play now, and checking something actually started.
    ///
    /// The previous screenshot run "passed" this while it was broken: it waited
    /// for the mini player to exist, and the mini player exists — showing Up
    /// Next — when nothing is playing at all. This waits for the episode's own
    /// title in it.
    func testPlayPromptStartsPlayback() throws {
        _ = app.wait(for: .runningForeground, timeout: 10)
        dismissOnboarding()
        // The same show-opening dance as the other tours: the first tap on a
        // grid tile can land before the grid has settled.
        let openShow = { () -> Bool in
            self.tapAnything("Quiet Hours") && self.app.buttons["More"].waitForExistence(timeout: 4)
        }
        // The tile's title sits behind the now-playing bar at the top of the
        // library, where a tap lands on the bar instead.
        guard openShow() || { app.swipeUp(); return openShow() }()
        else {
            capture("q0-FAILED-no-show"); XCTFail("Could not open Quiet Hours"); return
        }
        settle()
        let pill = app.buttons.matching(NSPredicate(format: "label == 'Play' AND value == '1h 34m'")).firstMatch
        for _ in 0..<3 where !(pill.exists && pill.isHittable) {
            app.swipeUp()
            settle(timeout: 1)
        }
        guard pill.waitForExistence(timeout: 4) else {
            capture("q0-FAILED-no-pill"); XCTFail("No play pill on the unprocessed episode"); return
        }
        if pill.isHittable { pill.tap() } else { _ = tapCentre(of: pill) }
        settle(timeout: 2)
        capture("q1-prompt")
        let playNow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play now'")).firstMatch
        guard playNow.waitForExistence(timeout: 3) else {
            XCTFail("The prompt did not appear"); return
        }
        playNow.tap()
        let started = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'MiniPlayer' AND label CONTAINS 'Night Shift'"))
            .firstMatch
        let ok = started.waitForExistence(timeout: 8)
        capture("q2-after-play-now")
        XCTAssertTrue(ok, "Play now did not load the episode into the player")
    }

    /// The OPML picker, opened. Selecting a file needs a file in the
    /// simulator's Files app, which a test cannot put there — so this proves
    /// the picker presents in multiple-selection mode, and nothing more.
    func testOPMLPicker() throws {
        _ = app.wait(for: .runningForeground, timeout: 10)
        dismissOnboarding()
        visitTab("Settings", shot: "o0-settings")
        let row = app.buttons["Import OPML"].firstMatch
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
        guard row.exists else { capture("o1-FAILED-no-row"); XCTFail("No Import OPML row"); return }
        row.tap()
        sleep(3)
        capture("o1-picker")
    }

    /// The Discover tab's pages: browse, a category, a show preview, search.
    func testDiscover() throws {
        _ = app.wait(for: .runningForeground, timeout: 10)
        dismissOnboarding()
        visitTab("Discover", shot: "d0-discover")
        sleep(4)
        capture("d1-discover-loaded")
        app.swipeUp()
        settle(timeout: 2)
        capture("d2-discover-scrolled")
        app.swipeUp()
        settle(timeout: 2)
        capture("d3-discover-categories")
        if tapAnything("Comedy") {
            sleep(4)
            capture("d4-category-comedy")
            let firstShow = app.scrollViews.buttons.firstMatch
            if firstShow.waitForExistence(timeout: 4) {
                firstShow.tap()
                sleep(5)
                capture("d5-show-preview")
                app.swipeUp()
                settle(timeout: 2)
                capture("d6-show-preview-episodes")
            }
        }
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
        //
        // In name order rather than one fixed name. Three runs in a row came
        // back with "12-show-detail" showing the library, because the show the
        // tour insisted on is the third tile in the grid and lands below the
        // fold on a phone — and a tap that misses looks exactly like a tap
        // that worked from in here. The first tile is always on screen.
        let opened = ["Quiet Hours", "Hard Drive Full", "The Long Way Round"]
            .contains { name in
                guard tapAnything(name) else { return false }
                settle()
                // Proof it actually went somewhere: the show page has a ⋯ and
                // the library does not.
                return app.buttons["More"].waitForExistence(timeout: 3)
            }
        guard opened else {
            capture("12-show-detail-FAILED-still-in-library")
            return
        }
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

                // The timeline zoomed in.
                //
                // Pinching is the one thing on this screen that cannot be
                // checked by reading the code or by looking at a screenshot of
                // it sitting still, and a zoom that draws its markers in the
                // wrong place is worse than no zoom at all — it would put a
                // cut somewhere other than where it looks like it is.
                let timeline = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label == 'Playback position'"))
                    .firstMatch
                if timeline.waitForExistence(timeout: 3) {
                    timeline.pinch(withScale: 4, velocity: 3)
                    settle(timeout: 2)
                    capture("15a-timeline-zoomed")
                    // And back, which must also work — a zoom you cannot undo
                    // is a trap.
                    timeline.doubleTap()
                    settle(timeout: 2)
                    capture("15a2-timeline-reset")
                }

                // The timeline mid-hold.
                //
                // Holding crops the scale around the finger and names the
                // segment under it, and neither survives the finger lifting —
                // so a screenshot taken after `press(forDuration:)` returns
                // is a picture of a bar at rest and proves nothing.
                //
                // Running the press on another queue to photograph it from
                // this one does not work either: XCUIElement gestures throw
                // "Must be called on the main thread". What does work is the
                // run's own screen recording. This marker attachment is
                // timestamped in the result bundle, the press starts
                // immediately after it, and a frame is pulled out of the
                // video a second later — see Scripts/hold-frame.sh.
                if timeline.exists {
                    capture("15c-marker-before-hold")
                    timeline.press(forDuration: 1.8)
                    settle(timeout: 2)
                }

                // The report of what was cut, reached through the ⋯ menu.
                if tapAnything("More") {
                    settle(timeout: 2)
                    if tapAnything("What was skipped") {
                        settle(timeout: 3)
                        capture("15f-skip-report")
                        _ = tapAnything("Done")
                        settle(timeout: 2)
                    } else {
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
                        settle(timeout: 2)
                    }
                }

                // The ⋯ menu over the player, because it has been reported as
                // showing a ghosted second image of whatever is moving behind
                // it, and that is not something the code can be read for — it
                // has to be looked at.
                if tapAnything("More") {
                    settle(timeout: 2)
                    capture("15b-player-menu")
                    // Dismiss by tapping well away from the menu rather than
                    // picking an item out of it.
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
                    settle(timeout: 2)
                }

                // Put the player away. It is a sheet over everything, so
                // leaving it up meant the next capture — Discover — was a
                // second photograph of the player, six seconds later.
                // "Close player", not "Close" — which is why the last two
                // runs left the sheet up and photographed it again as
                // "06-discover".
                if !tapAnything("Close player") { app.swipeDown() }
                settle(timeout: 2)
            }
        }

        // And now the other half of the story: an episode nobody has found the
        // ads in yet.
        //
        // Every player screenshot until now has been of a processed episode,
        // which is why nobody noticed that the Skip Ads / Skip Intro / Skip
        // Outro switches were being offered on episodes with nothing marked in
        // them at all. The second episode in the demo show is deliberately
        // unprocessed.
        let plays = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play'"))
        if plays.count > 1 {
            let second = plays.element(boundBy: 1)
            scrollIntoView(second)
            if second.isHittable { second.tap() } else { _ = tapCentre(of: second) }
            settle(timeout: 2)

            // Pressing play on an unprocessed episode asks first, on a timer.
            capture("15d-play-prompt")
            // The label is "Play now" with the countdown beside it, so the
            // button's accessibility label is not a fixed string — matched on
            // its prefix instead. If it is missed, the countdown lands on the
            // same answer a few seconds later anyway.
            let playNow = app.buttons
                .matching(NSPredicate(format: "label BEGINSWITH 'Play now'")).firstMatch
            if playNow.waitForExistence(timeout: 2), playNow.isHittable {
                playNow.tap()
            }
            settle(timeout: 4)

            let mini = app.descendants(matching: .any)
                .matching(identifier: "MiniPlayer").firstMatch
            if mini.waitForExistence(timeout: 4) {
                if mini.isHittable { mini.tap() } else { _ = tapCentre(of: mini) }
                settle(timeout: 3)
                capture("15e-player-unprocessed")
                if !tapAnything("Close player") { app.swipeDown() }
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
        // The whole display, not `app.screenshot()`.
        //
        // An open menu is presented in its own window above the app's, so the
        // app's own screenshot does not contain it: the run that went to the
        // trouble of opening the player's ⋯ menu came back with a photograph
        // of the player with no menu in it, which is worse than useless —
        // it looks like evidence that the menu did not open.
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
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
            scrollIntoView(element)
            if element.isHittable {
                element.tap()
                return true
            }
            if tapCentre(of: element) { return true }
        }
        return false
    }

    /// Brings something below the fold into view before trying to tap it.
    ///
    /// XCUITest does not scroll for you, and `tapCentre` deliberately refuses
    /// to send a tap at a point outside the window — correctly, or a missing
    /// element would fire a tap into the corner of the display and the tour
    /// would wander off somewhere unrelated. The consequence was that the
    /// third show in the grid, which sits below the fold on a phone, was
    /// simply unreachable: the show page, its ⋯ menu and its settings sheet
    /// went unphotographed for a whole run and the tour reported no failure,
    /// because "could not tap it" and "chose not to" look the same from here.
    private func scrollIntoView(_ element: XCUIElement, attempts: Int = 2) {
        guard element.exists else { return }
        let window = app.windows.firstMatch.frame
        for _ in 0..<attempts {
            if element.isHittable { return }
            let frame = element.frame
            guard frame.height > 1 else { return }
            if frame.midY > window.maxY - 40 {
                app.swipeUp()
            } else if frame.midY < window.minY + 40 {
                app.swipeDown()
            } else {
                return   // On screen and still not hittable: something is over it.
            }
            // No `settle()` here, and only two attempts.
            //
            // It had five attempts with a settle between each, and
            // `tapAnything` calls this once per candidate kind — so a lookup
            // that was going to fail anyway cost the best part of a minute,
            // four times over, and a tour that used to take four minutes took
            // twelve and then wedged. A swipe lands long before a second is
            // up; the `isHittable` check at the top of the next pass is what
            // actually waits.
        }
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
