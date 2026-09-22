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
        // Set before the first launch rather than by terminating and
        // relaunching inside the test: that relaunch left xcodebuild waiting
        // forever after the runner had finished.
        if name.contains("testLoupePreview") { app.launchArguments += ["-LoupePreview"] }
        // Points a demo show at a real YouTube channel (see DemoData).
        if name.contains("testPassTen") { app.launchArguments += ["-YouTubeDemo"] }
        if name.contains("testPassTwelve") { app.launchArguments += ["-HLSDemo", "-UnknownShelfDemo"] }
        if name.contains("testPassEleven") { app.launchArguments += ["-YouTubeDemo", "-StatusDemo"] }
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


                // Pass 13 editor. Nudge the start later twice, zoom in, move
                // the playhead by tapping a line, and check the cut now says
                // Edited with the original drawn behind it.
                let later = app.buttons["NudgeStartLater"].firstMatch
                if later.waitForExistence(timeout: 3) {
                    // Inside the sheet, which opens at half height: drag its
                    // list up (a drag on the sheet also raises it to full).
                    for _ in 0..<3 where !later.isHittable {
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
                        settle(timeout: 1)
                    }
                    settle(timeout: 2)
                    // The sheet can still be settling from the drag, and a tap
                    // that lands mid-move goes nowhere: tap until it says
                    // Edited, at most three times.
                    for _ in 0..<3 where app.staticTexts["EditorStatus"].firstMatch.label != "Edited" {
                        let button = app.buttons["NudgeStartLater"].firstMatch
                        if button.isHittable { button.tap() } else { _ = tapCentre(of: button) }
                        settle(timeout: 1.5)
                    }
                } else {
                    XCTFail("No nudge buttons in the opened cut.")
                }
                let zoomButton = app.buttons["TrimZoom"].firstMatch
                if zoomButton.exists, zoomButton.isHittable { zoomButton.tap(); zoomButton.tap() }
                let line = app.buttons["TranscriptLine1"].firstMatch
                if line.exists, line.isHittable { line.tap() }
                settle(timeout: 1)
                let status = app.staticTexts["EditorStatus"].firstMatch
                XCTAssertTrue(status.waitForExistence(timeout: 2) && status.label == "Edited",
                              "After two nudges the cut should say Edited, it says \(status.exists ? status.label : "nothing")")
                XCTAssertTrue(app.buttons["RevertCut"].firstMatch.exists,
                              "An edited cut should offer Revert to what was found.")
                capture("p7-editor-edited")

                // And playing, from the playhead the line tap put there. The
                // transcript only highlights a line while something plays.
                let preview = app.buttons["Hear what was cut"].firstMatch
                if preview.waitForExistence(timeout: 3) {
                    if preview.isHittable { preview.tap() } else { _ = tapCentre(of: preview) }
                    settle(timeout: 2)
                    capture("p6-skip-report-playing")
                    let stop = app.buttons["Stop preview"].firstMatch
                    if stop.exists, stop.isHittable { stop.tap() }
                }

                // The playhead's own bar, and the five-second steps: the
                // handles must not move when these are used.
                let scrub = app.otherElements["ScrubBar"].firstMatch
                let before = app.staticTexts["EditorStatus"].firstMatch.label
                if scrub.waitForExistence(timeout: 2), scrub.isHittable {
                    scrub.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
                        .press(forDuration: 0.05,
                               thenDragTo: scrub.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)))
                    settle(timeout: 1)
                }
                let back5 = app.buttons["EditorBack5"].firstMatch
                if back5.exists, back5.isHittable { back5.tap(); settle(timeout: 1) }
                XCTAssertEqual(app.staticTexts["EditorStatus"].firstMatch.label, before,
                               "Scrubbing or stepping must not move the cut's edges.")
                capture("p7b-scrubbed")

                let lock = app.buttons["LockCut"].firstMatch
                if lock.exists, lock.isHittable { lock.tap(); settle(timeout: 1); capture("p8-editor-locked") }

                let add = app.buttons["AddCut"].firstMatch
                if add.waitForExistence(timeout: 2) {
                    add.tap()
                    settle(timeout: 2)
                    capture("p9-added-cut")
                    XCTAssertTrue(app.staticTexts["Added by you"].firstMatch.waitForExistence(timeout: 2)
                                  || app.staticTexts["EditorStatus"].firstMatch.exists,
                                  "Adding a cut should open it.")
                }
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
            }
        }
    }

    /// The seek bar's loupe, which only exists while a finger is down, so the
    /// app is launched with a flag that holds it open for the picture.
    func testLoupePreview() throws {
        _ = app.wait(for: .runningForeground, timeout: 10)
        dismissOnboarding()
        guard ["Quiet Hours", "Hard Drive Full", "The Long Way Round"]
            .contains(where: { tapAnything($0) && app.buttons["More"].waitForExistence(timeout: 3) })
        else { XCTFail("Could not open a show."); return }
        settle()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play'")).firstMatch
        if play.waitForExistence(timeout: 4) {
            if play.isHittable { play.tap() } else { _ = tapCentre(of: play) }
            settle(timeout: 2)
            let playNow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play now'")).firstMatch
            if playNow.waitForExistence(timeout: 2), playNow.isHittable { playNow.tap() }
            settle(timeout: 3)
        }
        let mini = app.descendants(matching: .any).matching(identifier: "MiniPlayer").firstMatch
        guard mini.waitForExistence(timeout: 6) else { XCTFail("Nothing playing."); return }
        if mini.isHittable { mini.tap() } else { _ = tapCentre(of: mini) }
        settle(timeout: 3)
        capture("s1-loupe-open")
    }

    /// "1:23 of 2:00" → 83.
    static func seconds(_ value: String?) -> Double? {
        guard let first = value?.components(separatedBy: " of ").first else { return nil }
        let parts = first.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// The fourth pass: the whole-app size setting at both ends, touch and
    /// hold on an episode, selection on the show page itself, Play Next from
    /// that menu actually reaching Up Next, and the tab bar after scrolling.
    func testPassFour() throws {
        _ = app.wait(for: .runningForeground, timeout: 10)
        dismissOnboarding()

        guard ["Quiet Hours", "Hard Drive Full", "The Long Way Round"]
            .contains(where: { tapAnything($0) && app.buttons["More"].waitForExistence(timeout: 3) })
        else {
            capture("r0-FAILED-no-show")
            XCTFail("Could not open a show.")
            return
        }
        settle()
        capture("r1-show-default-size")

        // Touch and hold an episode row.
        let title = app.staticTexts.matching(identifier: "EpisodeTitle").element(boundBy: 1)
        var queuedTitle: String?
        if title.waitForExistence(timeout: 3) {
            scrollIntoView(title)
            queuedTitle = title.label
            title.press(forDuration: 1.0)
            settle(timeout: 2)
            capture("r2-row-context-menu")
            let playNext = app.buttons["Play Next"].firstMatch
            if playNext.waitForExistence(timeout: 2) {
                playNext.tap()
            } else if app.buttons["Remove from Up Next"].firstMatch.exists {
                // Already queued in demo data; that still proves the menu.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
            } else {
                XCTFail("Touch and hold did not show the episode menu.")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
            }
            settle(timeout: 2)
        }

        // Selection, from the show's ⋯.
        let more = app.buttons["More"].firstMatch
        if more.waitForExistence(timeout: 3) {
            scrollIntoView(more)
            if more.isHittable { more.tap() } else { _ = tapCentre(of: more) }
            settle(timeout: 2)
            if app.buttons["Select Episodes"].firstMatch.waitForExistence(timeout: 2) {
                app.buttons["Select Episodes"].firstMatch.tap()
                settle(timeout: 2)
                let rows = app.descendants(matching: .any).matching(identifier: "SelectableEpisode")
                for index in 0..<2 where rows.count > index {
                    let row = rows.element(boundBy: index)
                    scrollIntoView(row)
                    if row.isHittable { row.tap() } else { _ = tapCentre(of: row) }
                }
                settle(timeout: 2)
                capture("r3-selecting-full-rows")
                if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
                settle(timeout: 2)
            }
        }

        // Scrolled down: the tab bar should minimise, Apple-style.
        app.swipeUp(); app.swipeUp()
        settle(timeout: 2)
        capture("r4-scrolled-tab-bar")
        app.swipeDown(); app.swipeDown(); app.swipeDown()
        settle(timeout: 2)

        if tapTab("Up Next") {
            settle(timeout: 3)
            capture("r5-up-next")
            if let queuedTitle {
                let found = app.staticTexts[queuedTitle].firstMatch.waitForExistence(timeout: 3)
                XCTAssertTrue(found, "Play Next did not put “\(queuedTitle)” in Up Next.")
            }
        }

        // The size setting, both ends.
        for (name, value) in [("largest", 1.0), ("smallest", 0.0)] {
            guard tapTab("Settings") else { break }
            settle(timeout: 3)
            let slider = app.sliders.firstMatch
            var tries = 0
            while !(slider.exists && slider.isHittable), tries < 4 { app.swipeUp(); tries += 1 }
            if slider.exists {
                slider.adjust(toNormalizedSliderPosition: CGFloat(value))
                settle(timeout: 3)
                capture("r6-settings-\(name)")
                if tapTab("Library") {
                    settle(timeout: 3)
                    capture("r7-library-\(name)")
                }
            } else {
                capture("r6-FAILED-no-size-slider")
                XCTFail("No size slider in Settings.")
            }
        }
        // Back to the default for later tests.
        if tapTab("Settings") {
            settle(timeout: 2)
            let slider = app.sliders.firstMatch
            if slider.exists { slider.adjust(toNormalizedSliderPosition: 0.4) }
            settle(timeout: 2)
        }
    }

    /// The eighth pass: a video episode playing with its picture following
    /// the sound (the frame shows its own clock, to compare with the time
    /// under the bar), Audio and back, searching the transcript in the
    /// player, the episode page's People / More from / You Might Also Like,
    /// Stations, the Lock Screen card's preview, and searching by a person.
    /// The ninth pass: the date under the player's title, a transcript tap
    /// leaving a "where you were" ring on the scrubber, the year headings and
    /// Explicit / Bonus / Trailer marks on a show page, pulling a show page to
    /// refresh, Mark Filtered as Played, the New and Search tabs, and the
    /// Lock Screen card without buttons.
    func testPassNine() throws {
        _ = app.wait(for: .runningForeground, timeout: 10)
        dismissOnboarding()
        settle(timeout: 3)

        guard tapTab("Up Next") else { XCTFail("No Up Next tab."); return }
        settle(timeout: 3)
        capture("n00-upnext")
        let playAll = app.buttons["Play All"].firstMatch
        if playAll.waitForExistence(timeout: 3) {
            if playAll.isHittable { playAll.tap() } else { _ = tapCentre(of: playAll) }
            settle(timeout: 3)
        }
        let mini = app.descendants(matching: .any).matching(identifier: "MiniPlayer").firstMatch
        guard mini.waitForExistence(timeout: 6) else { XCTFail("Nothing playing."); return }
        if mini.isHittable { mini.tap() } else { _ = tapCentre(of: mini) }
        sleep(3)
        let dateLine = app.staticTexts["PlayerShowAndDate"].firstMatch
        XCTAssertTrue(dateLine.waitForExistence(timeout: 3), "No show and date line in the player.")
        XCTAssertTrue(dateLine.label.contains("·"), "The player's line has no date: \(dateLine.label)")
        capture("n01-player-date")

        let transcript = app.buttons["Transcript"].firstMatch
        if transcript.waitForExistence(timeout: 3) {
            transcript.tap()
            sleep(2)
            let lines = app.descendants(matching: .any).matching(identifier: "TranscriptLine")
            // Tap lines until one moves playback far enough to leave a ring.
            // Not every line does: the list is lazy, so only lines near the
            // current one exist; a hop of a second or two leaves no ring by
            // design; and a line inside a cut ad is skipped straight past,
            // back to about where you were — all three happened in earlier
            // runs of this test.
            let seekBar = app.descendants(matching: .any)["SeekBar"].firstMatch
            var ringed = false
            for index in 0..<min(lines.count, 8) {
                let target = lines.element(boundBy: index)
                guard target.exists else { continue }
                let before = (seekBar.value as? String) ?? "?"
                if target.isHittable { target.tap() } else if !tapCentre(of: target) { continue }
                usleep(700_000)
                let after = (seekBar.value as? String) ?? ""
                print("line \(index) '\(target.label.prefix(30))': \(before) -> \(after)")
                // A ring under the playhead is no evidence of anything.
                if let at = after.components(separatedBy: "was at ").last,
                   after.contains("was at"),
                   let now = Self.seconds(after), let was = Self.seconds(at),
                   abs(now - was) > 5 {
                    ringed = true; break
                }
            }
            capture("n02-transcript-jump-ring")
            XCTAssertTrue(ringed, "No 'where you were' ring on the scrubber after a transcript tap.")
            let artwork = app.buttons["Artwork"].firstMatch
            if artwork.exists { artwork.tap() }
        }
        let close = app.buttons["Close player"].firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() } else { app.swipeDown() }
        settle(timeout: 3)

        // A show page with a back catalogue across years.
        if tapTab("Library") {
            settle(timeout: 2)
            _ = tapTab("Library")
            settle(timeout: 2)
        }
        guard tapAnything("Hard Drive Full") else { XCTFail("No Hard Drive Full show."); return }
        settle(timeout: 3)
        let heading = app.descendants(matching: .any).matching(identifier: "YearHeading").firstMatch
        var tries = 0
        while !(heading.exists && heading.isHittable), tries < 8 { app.swipeUp(); tries += 1 }
        settle(timeout: 2)
        capture("n03-year-headings")
        XCTAssertTrue(heading.exists, "No year heading on a show with episodes from last year.")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Bonus'")).firstMatch.exists
                      || app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Bonus'")).firstMatch.exists,
                      "No Bonus mark on the bonus episode.")
        app.swipeUp(); settle(timeout: 2)
        capture("n03b-year-headings-more")

        // Pull to refresh, from the top of the show page.
        for _ in 0..<10 { app.swipeDown(velocity: .fast) }
        settle(timeout: 2)
        let top = app.windows.firstMatch
        top.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: top.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        usleep(600_000)
        capture("n04-show-pull-to-refresh")
        settle(timeout: 4)

        // Mark Filtered as Played.
        if tapAnything("All Episodes") {
            settle(timeout: 1)
            if tapAnything("Unplayed") {
                settle(timeout: 2)
                if tapAnything("Unplayed") {
                    settle(timeout: 1)
                    if tapAnything("Mark Filtered as Played") {
                        settle(timeout: 2)
                        capture("n05-mark-filtered-confirm")
                        let cancel = app.buttons["Cancel"].firstMatch
                        if cancel.exists { cancel.tap() }
                        settle(timeout: 1)
                    } else {
                        XCTFail("No Mark Filtered as Played in the filter menu.")
                    }
                }
                // Back to All Episodes so the choice does not stick.
                if tapAnything("Unplayed") { _ = tapAnything("All Episodes") }
                settle(timeout: 1)
            }
        }
        back(); settle(timeout: 2)
        // The tab bar shrinks after scrolling; bring it back before tapping.
        if !app.tabBars.buttons["New"].firstMatch.isHittable { app.swipeDown(); settle(timeout: 2) }

        if tapTab("New") {
            settle(timeout: 5)
            capture("n06-new")
        } else {
            XCTFail("No New tab.")
        }
        if tapTab("Search") {
            settle(timeout: 3)
            capture("n07-search")
            XCTAssertTrue(app.buttons["CategoryTile"].firstMatch.waitForExistence(timeout: 12)
                          || app.staticTexts["Categories"].firstMatch.exists,
                          "The Search tab does not open on the categories.")
        } else {
            XCTFail("No Search tab.")
        }

        if tapTab("Settings") {
            settle(timeout: 3)
            let toggle = app.switches.matching(NSPredicate(format: "label CONTAINS 'Lock Screen'")).firstMatch
            var tries = 0
            while !(toggle.exists && toggle.isHittable), tries < 6 { app.swipeUp(); tries += 1 }
            if toggle.exists {
                if (toggle.value as? String) != "1" { toggle.switches.firstMatch.tap() }
                settle(timeout: 3)
                let preview = app.descendants(matching: .any)["LockScreenCardPreview"].firstMatch
                if preview.exists { scrollIntoView(preview) }
                settle(timeout: 2)
                capture("n08-lock-screen-card")
            }
        }
    }

    /// The tenth pass: Apple's own New page and Search categories, a category
    /// page, and the other additions of the pass.
    /// Pass 12: native HLS video from a real feed, an unfamiliar Apple shelf,
    /// and the iCloud / CarPlay / widgets page.
    func testPassTwelve() throws {
        _ = app.wait(for: .runningForeground, timeout: 10)
        dismissOnboarding()
        settle(timeout: 3)

        // New, with a shelf of a type this version doesn't know.
        guard tapTab("New") else { XCTFail("No New tab."); return }
        let unknown = app.staticTexts["Unfamiliar Shelf (test)"].firstMatch
        XCTAssertTrue(unknown.waitForExistence(timeout: 20), "The unfamiliar shelf was dropped.")
        sleep(3)
        capture("v01-new-unknown-shelf")

        // Settings → iCloud, CarPlay & Widgets.
        expandTabBar(for: "Settings")
        guard tapTab("Settings") else { XCTFail("No Settings tab."); return }
        settle(timeout: 2)
        let link = app.buttons["PaidFeaturesLink"].firstMatch
        for _ in 0..<12 where !(link.exists && link.isHittable) { app.swipeUp() }
        if link.exists { link.tap() } else { XCTFail("No iCloud, CarPlay & Widgets row.") }
        settle(timeout: 2)
        capture("v02-paid-features")
        app.swipeUp(); sleep(1)
        capture("v03-widget-gallery")
        back(); settle(timeout: 1)

        // The real HLS demo feed: its episode, played, with the picture on.
        expandTabBar(for: "Library")
        if tapTab("Library") { settle(timeout: 2); _ = tapTab("Library"); settle(timeout: 2) }
        for _ in 0..<4 { app.swipeDown(velocity: .fast) }
        guard tapAnything("HLS Video Podcast") else { XCTFail("The HLS demo show wasn't added."); return }
        settle(timeout: 3)
        capture("v04-hls-show")
        // The episode row's own play pill (23 minutes), not the show's.
        let play = app.buttons.matching(NSPredicate(format: "label == 'Play' AND value CONTAINS '23m'")).firstMatch
        guard play.waitForExistence(timeout: 10) else { XCTFail("No play button on the HLS episode."); return }
        scrollIntoView(play)
        if play.isHittable { play.tap() } else { _ = tapCentre(of: play) }
        sleep(1)
        capture("v04b-after-play-tap")
        // The question's countdown plays it (the button's label carries the
        // countdown, and a tap races it).
        sleep(7)
        // The mp3 downloads first (27 MB), then plays.
        let mini = app.descendants(matching: .any).matching(identifier: "MiniPlayer").firstMatch
        let playing = NSPredicate(format: "label CONTAINS[c] 'changed my mind'")
        for _ in 0..<30 {
            if mini.exists, mini.descendants(matching: .any).matching(playing).firstMatch.exists { break }
            sleep(2)
        }
        capture("v04c-mini-hls")
        if mini.isHittable { mini.tap() } else { _ = tapCentre(of: mini) }
        let toggle = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Video'")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 30), "No Video / Audio switch for the HLS episode.")
        sleep(20)
        capture("v05-hls-player-video")
        sleep(10)
        capture("v06-hls-player-video-later")
    }

    /// Pass 11: the status sheet a notification opens, the activity bar
    /// pinned on Library and Up Next, and the YouTube sheet's ways out.
    func testPassEleven() throws {
        _ = app.wait(for: .runningForeground, timeout: 10)
        dismissOnboarding()

        // Launched as if a failure notification had been tapped.
        let card = app.descendants(matching: .any).matching(identifier: "EpisodeStatusCard").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "The status sheet did not open.")
        sleep(1)
        capture("u01-status-failed")
        let retry = app.buttons["StatusRetry"].firstMatch
        if retry.waitForExistence(timeout: 3) {
            retry.tap()
            usleep(700_000)
            capture("u02-status-after-retry")
            sleep(2)
            capture("u03-status-later")
        } else {
            XCTFail("No Try Again on a failed episode.")
        }
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 3) { done.tap() }
        settle(timeout: 1)
        capture("u04-library-after-status")
        app.swipeUp(); usleep(600_000)
        capture("u05-library-scrolled")
        expandTabBar(for: "Up Next")
        _ = tapTab("Up Next")
        usleep(800_000)
        capture("u06-upnext")
        app.swipeUp(); usleep(600_000)
        capture("u07-upnext-scrolled")
        for _ in 0..<30 {
            if !app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Finding ads'")).firstMatch.exists { break }
            sleep(2)
        }
        capture("u08-upnext-after-work")

        // The YouTube sheet and its ways out.
        let mini = app.descendants(matching: .any).matching(identifier: "MiniPlayer").firstMatch
        expandTabBar(for: "Library")
        if tapTab("Library") { settle(timeout: 2); _ = tapTab("Library"); settle(timeout: 2) }
        for _ in 0..<4 { app.swipeDown(velocity: .fast) }
        guard tapAnything("Quiet Hours") else { XCTFail("Couldn't open Quiet Hours."); return }
        settle(timeout: 3)
        let play = app.buttons.matching(NSPredicate(format: "label == 'Play' AND value CONTAINS 'h ' AND value != '1h 34m'")).firstMatch
        guard play.waitForExistence(timeout: 3) else { XCTFail("No play button."); return }
        scrollIntoView(play)
        if play.isHittable { play.tap() } else { _ = tapCentre(of: play) }
        sleep(2)
        if mini.waitForExistence(timeout: 4) {
            if mini.isHittable { mini.tap() } else { _ = tapCentre(of: mini) }
        }
        let watch = app.buttons["WatchOnYouTube"].firstMatch
        XCTAssertTrue(watch.waitForExistence(timeout: 15), "No Watch on YouTube.")
        if watch.exists {
            watch.tap()
            sleep(8)
            capture("u09-youtube-sheet")
            XCTAssertTrue(app.buttons["OpenInYouTubeApp"].exists, "No YouTube App button.")
            XCTAssertTrue(app.buttons["OpenInSafari"].exists, "No Safari button.")
            let share = app.buttons["ShareYouTubeLink"].firstMatch
            if share.exists {
                share.tap()
                sleep(3)
                capture("u10-youtube-share-sheet")
            } else {
                XCTFail("No Share Link button.")
            }
        }
    }

    func testPassTen() throws {
        _ = app.wait(for: .runningForeground, timeout: 10)
        dismissOnboarding()
        settle(timeout: 3)

        guard tapTab("New") else { XCTFail("No New tab."); return }
        sleep(8)
        capture("t01-new-top")
        for (index, swipes) in [2, 2, 2, 3, 3].enumerated() {
            for _ in 0..<swipes { app.swipeUp() }
            sleep(2)
            capture(String(format: "t%02d-new-scrolled", index + 2))
        }
        for _ in 0..<14 { app.swipeDown(velocity: .fast) }
        settle(timeout: 2)
        // A show from the page opens its preview.
        let firstShow = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'The Daily' OR label CONTAINS[c] 'Crime Junkie'")).firstMatch
        if firstShow.waitForExistence(timeout: 4) {
            if firstShow.isHittable { firstShow.tap() } else { _ = tapCentre(of: firstShow) }
            sleep(5)
            capture("t07-show-from-new")
            back(); settle(timeout: 2)
        }

        if !app.tabBars.buttons["Search"].firstMatch.isHittable { app.swipeDown(); settle(timeout: 2) }
        guard tapTab("Search") else { XCTFail("No Search tab."); return }
        let tile = app.buttons["CategoryTile"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15), "Apple's category tiles did not load.")
        sleep(3)
        capture("t08-search-categories")
        app.swipeUp(); sleep(2)
        capture("t09-search-categories-more")
        app.swipeDown(); app.swipeDown(); settle(timeout: 1)
        let comedy = app.buttons.matching(NSPredicate(format: "identifier == 'CategoryTile' AND label == 'Comedy'")).firstMatch
        if comedy.waitForExistence(timeout: 3) {
            scrollIntoView(comedy)
            if comedy.isHittable { comedy.tap() } else { _ = tapCentre(of: comedy) }
            sleep(7)
            capture("t10-category-comedy")
            app.swipeUp(); app.swipeUp(); sleep(2)
            capture("t11-category-comedy-more")
            back(); settle(timeout: 2)
        } else {
            XCTFail("No Comedy tile.")
        }

        // Watch on YouTube, for a show whose channel is set.
        let mini = app.descendants(matching: .any).matching(identifier: "MiniPlayer").firstMatch
        expandTabBar(for: "Library")
        if tapTab("Library") { settle(timeout: 2); _ = tapTab("Library"); settle(timeout: 2) }
        for _ in 0..<4 { app.swipeDown(velocity: .fast) }
        let quiet = tapAnything("Quiet Hours")
        XCTAssertTrue(quiet, "Couldn't open Quiet Hours from the Library.")
        if quiet {
            settle(timeout: 3)
            capture("t14-show-with-seasons-and-youtube")
            let play = app.buttons.matching(NSPredicate(format: "label == 'Play' AND value CONTAINS 'h ' AND value != '1h 34m'")).firstMatch
            if play.waitForExistence(timeout: 3) {
                scrollIntoView(play)
                if play.isHittable { play.tap() } else { _ = tapCentre(of: play) }
                sleep(2)
                if mini.waitForExistence(timeout: 4) {
                    if mini.isHittable { mini.tap() } else { _ = tapCentre(of: mini) }
                }
                let watch = app.buttons["WatchOnYouTube"].firstMatch
                XCTAssertTrue(watch.waitForExistence(timeout: 15), "No Watch on YouTube for an episode that is on the channel.")
                capture("t15-player-watch-on-youtube")
                if watch.exists {
                    watch.tap()
                    sleep(10)
                    capture("t16-youtube-player")
                    let done = app.buttons["Done"].firstMatch
                    if done.waitForExistence(timeout: 3) { done.tap() }
                    sleep(2)
                    capture("t17-back-from-youtube")
                }
                let close = app.buttons["Close player"].firstMatch
                if close.waitForExistence(timeout: 3) { close.tap() } else { app.swipeDown() }
                settle(timeout: 2)
            } else {
                XCTFail("No play button for the renamed demo episode.")
            }

            // The unprocessed episode: the question appears; swiping it away
            // plays nothing.
            // Up off the bottom, where the mini player would take the tap.
            app.swipeUp()
            settle(timeout: 1)
            let night = app.buttons.matching(NSPredicate(format: "label == 'Play' AND value == '1h 34m'")).firstMatch
            if night.waitForExistence(timeout: 3) {
                scrollIntoView(night)
                if night.isHittable { night.tap() } else { _ = tapCentre(of: night) }
                let question = app.staticTexts["Ads haven't been found yet"].firstMatch
                if question.waitForExistence(timeout: 4) {
                    capture("t18-play-question")
                    // A real drag of the sheet off the bottom of the screen:
                    // `swipeDown` on the headline was too short to dismiss it,
                    // so the countdown simply ran out — which is not what is
                    // being tested.
                    let from = question.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    let to = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.99))
                    from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .fast, thenHoldForDuration: 0)
                    let gone = question.waitForNonExistence(timeout: 2)
                    XCTAssertTrue(gone, "The question could not be swiped away.")
                    sleep(7)   // longer than the countdown
                    capture("t19-after-swiping-question-away")
                    XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Twenty-Four Hour Bakery'"))
                                    .allElementsBoundByIndex.contains { $0.frame.minY > app.windows.firstMatch.frame.height * 0.7 },
                                   "Swiping the question away still started the episode.")
                } else {
                    capture("t18-no-question")
                    XCTFail("No question for an unprocessed episode.")
                }
            }

            // Hide Played and seasons live in the filter menu.
            back(); settle(timeout: 2)
        }
        // Skipping forward at the end goes on to the next episode.
        expandTabBar(for: "Up Next")
        guard tapTab("Up Next") else { XCTFail("No Up Next tab."); return }
        settle(timeout: 3)
        let playAll = app.buttons["Play All"].firstMatch
        if playAll.waitForExistence(timeout: 3) {
            if playAll.isHittable { playAll.tap() } else { _ = tapCentre(of: playAll) }
            settle(timeout: 3)
        }
        if mini.waitForExistence(timeout: 6) {
            if mini.isHittable { mini.tap() } else { _ = tapCentre(of: mini) }
            sleep(3)
            let line = app.staticTexts["PlayerShowAndDate"].firstMatch
            let before = line.exists ? line.label : ""
            capture("t12-before-skip-to-end")
            let skips = app.buttons.matching(NSPredicate(format: "label == 'Skip forward'"))
            for _ in 0..<6 {
                if let button = skips.allElementsBoundByIndex.first(where: { $0.isHittable }) { button.tap() }
                usleep(700_000)
            }
            sleep(4)
            let after = line.exists ? line.label : ""
            capture("t13-after-skip-to-end")
            print("skip to end: '\(before)' -> '\(after)'")
            XCTAssertNotEqual(before, after, "Skipping forward at the end did not move on to the next episode.")
            let close = app.buttons["Close player"].firstMatch
            if close.waitForExistence(timeout: 3) { close.tap() } else { app.swipeDown() }
            settle(timeout: 2)
        } else {
            XCTFail("Nothing playing for the skip-to-end check.")
        }

        expandTabBar(for: "Library")
        if tapTab("Library") { settle(timeout: 2); _ = tapTab("Library"); settle(timeout: 2) }
        for _ in 0..<4 { app.swipeDown(velocity: .fast) }
        if tapAnything("The Long Way Round") {
            settle(timeout: 3)
            if tapAnything("All Episodes") {
                settle(timeout: 1)
                capture("t20-show-filter-menu-seasons")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
            }
            back(); settle(timeout: 2)
        }
        for _ in 0..<4 { app.swipeDown(velocity: .fast) }
        let recent = tapAnything("Recently Played")
        XCTAssertTrue(recent, "No Recently Played in the Library.")
        if recent {
            settle(timeout: 2)
            capture("t21-recently-played")
            back()
        }
    }

    /// Measures whether a list jitters once it is back at the top.
    ///
    /// A stutter cannot be seen in a still, but it can be measured: after
    /// flicking back to the top, the first row and the navigation bar should
    /// sit at one position. Their positions are sampled for three seconds and
    /// written out; more than one distinct value means something moved on its
    /// own. Run with work in progress too, since the activity bar above the
    /// list is one of the things that can move it.
    func testTopJitter() throws {
        _ = app.wait(for: .runningForeground, timeout: 10)
        dismissOnboarding()
        settle(timeout: 3)
        var report = ""

        func sample(_ label: String) {
            let bar = app.navigationBars.firstMatch
            let row = app.cells.firstMatch
            var bars: [String] = [], rows: [String] = []
            for _ in 0..<14 {
                bars.append(String(format: "%.1f", bar.exists ? bar.frame.height : -1))
                rows.append(String(format: "%.1f", row.exists ? row.frame.minY : -1))
                usleep(150_000)
            }
            let distinctBars = Set(bars).count, distinctRows = Set(rows).count
            report += "\(label): bar heights \(bars.joined(separator: ",")) | first row y \(rows.joined(separator: ","))\n"
            report += "  distinct bar=\(distinctBars) row=\(distinctRows)\n"
            XCTAssertLessThanOrEqual(distinctRows, 1, "\(label): the list moved by itself at the top.")
        }

        func flickDownAndBack(_ label: String) {
            app.swipeUp(velocity: .fast); app.swipeUp(velocity: .fast)
            usleep(800_000)
            app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast)
            usleep(1_200_000)
            capture("j-\(label)")
            sample(label)
        }

        _ = tapTab("Library"); settle(timeout: 3)
        flickDownAndBack("library-idle")
        _ = tapTab("Up Next"); settle(timeout: 3)
        flickDownAndBack("upnext-idle")

        // With work running: Up Next's ⋯ → Process All.
        let more = app.navigationBars.buttons["More"].firstMatch
        if more.waitForExistence(timeout: 3) {
            more.tap()
            let process = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Process All'")).firstMatch
            if process.waitForExistence(timeout: 2) { process.tap() } else { app.swipeDown() }
            sleep(2)
        }
        flickDownAndBack("upnext-busy")
        _ = tapTab("Library"); settle(timeout: 3)
        flickDownAndBack("library-busy")

        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"], !dir.isEmpty {
            try? report.write(to: URL(fileURLWithPath: dir).appendingPathComponent("jitter.txt"),
                              atomically: true, encoding: .utf8)
        }
        let note = XCTAttachment(string: report); note.name = "jitter"; note.lifetime = .keepAlways
        add(note)
    }

    func testPassEight() throws {
        _ = app.wait(for: .runningForeground, timeout: 10)
        dismissOnboarding()
        settle(timeout: 3)

        guard tapTab("Up Next") else { XCTFail("No Up Next tab."); return }
        settle(timeout: 3)
        let playAll = app.buttons["Play All"].firstMatch
        if playAll.waitForExistence(timeout: 3) {
            if playAll.isHittable { playAll.tap() } else { _ = tapCentre(of: playAll) }
            settle(timeout: 3)
        }
        let mini = app.descendants(matching: .any).matching(identifier: "MiniPlayer").firstMatch
        guard mini.waitForExistence(timeout: 6) else { XCTFail("Nothing playing."); return }
        if mini.isHittable { mini.tap() } else { _ = tapCentre(of: mini) }
        sleep(4)
        capture("u01-video-playing")
        sleep(5)
        capture("u02-video-5s-later")
        let audio = app.buttons["VideoModeAudio"].firstMatch
        XCTAssertTrue(audio.waitForExistence(timeout: 3), "No Video / Audio switch.")
        if audio.exists {
            audio.tap(); sleep(2)
            capture("u03-audio-only")
            let video = app.buttons["VideoModeVideo"].firstMatch
            if video.exists { video.tap(); sleep(3); capture("u04-video-again") }
        }

        // Search the transcript.
        let transcript = app.buttons["Transcript"].firstMatch
        if transcript.waitForExistence(timeout: 3) {
            transcript.tap()
            settle(timeout: 2)
            let field = app.textFields["TranscriptSearch"].firstMatch
            if field.waitForExistence(timeout: 3) {
                field.tap()
                field.typeText("tickets")
                settle(timeout: 2)
                capture("u05-transcript-search")
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' of '")).firstMatch.exists,
                              "No match count in the transcript search.")
            } else {
                XCTFail("No search field in the transcript.")
            }
            let artwork = app.buttons["Artwork"].firstMatch
            if artwork.exists { artwork.tap() }
        }
        let close = app.buttons["Close player"].firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() } else { app.swipeDown() }
        settle(timeout: 3)

        // An episode's page, from a show page.
        if tapTab("Library") {
            settle(timeout: 2)
            _ = ["Hard Drive Full", "Quiet Hours"].contains(where: { tapAnything($0) && app.buttons["More"].waitForExistence(timeout: 3) })
            settle(timeout: 2)
        }
        let title = app.staticTexts.matching(identifier: "EpisodeTitle").element(boundBy: 0)
        if title.waitForExistence(timeout: 3) {
            scrollIntoView(title)
            title.press(forDuration: 1.0)
            settle(timeout: 2)
            let details = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == 'Episode Details'")).firstMatch
            if details.waitForExistence(timeout: 2) {
                // By position: the menu is its own window, and the element
                // query that found it can't always resolve it again to tap.
                details.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                settle(timeout: 4)
                capture("u06a-episode-page")
                app.swipeUp(); app.swipeUp()
                settle(timeout: 3)
                capture("u06-episode-page-more")
                back(); settle(timeout: 2)
                back(); settle(timeout: 2)
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
            }
        }

        // Stations.
        if tapTab("Library") {
            settle(timeout: 2)
            _ = tapTab("Library")
            if tapAnything("Stations") {
                settle(timeout: 3)
                capture("u07-stations")
                back(); settle(timeout: 2)
            } else {
                XCTFail("No Stations in the Library.")
            }
        }

        // The Lock Screen card, previewed in Settings.
        if tapTab("Settings") {
            settle(timeout: 3)
            let toggle = app.switches.matching(NSPredicate(format: "label CONTAINS 'Lock Screen'")).firstMatch
            var tries = 0
            while !(toggle.exists && toggle.isHittable), tries < 6 { app.swipeUp(); tries += 1 }
            if toggle.exists {
                if (toggle.value as? String) != "1" { toggle.switches.firstMatch.tap() }
                settle(timeout: 3)
                let preview = app.descendants(matching: .any)["LockScreenCardPreview"].firstMatch
                if preview.exists { scrollIntoView(preview) }
                settle(timeout: 2)
                capture("u08-lock-screen-card")
                XCTAssertTrue(app.descendants(matching: .any)["LockScreenCardPreview"].firstMatch.exists,
                              "No Lock Screen card preview in Settings.")
            }
        }

        // Search by a person's name.
        if tapTab("Search") {
            settle(timeout: 3)
            var field = app.searchFields.firstMatch
            if !field.waitForExistence(timeout: 4) {
                app.swipeDown(); app.swipeDown(); settle(timeout: 2)
                field = app.searchFields.firstMatch
            }
            if field.exists {
                field.tap()
                field.typeText("Tom Segura")
                settle(timeout: 6)
                capture("u09-search-person")
            }
        }
    }

    /// The seventh pass: Publish… from an episode's menu and from the
    /// selection bar, the show page with no title in the bar when scrolled,
    /// Up Next's continuation list and compact card, the player's Video /
    /// Audio switch on a video episode, searching words said in episodes, and
    /// a favourite category shelf.
    func testPassSeven() throws {
        _ = app.wait(for: .runningForeground, timeout: 10)
        dismissOnboarding()
        settle(timeout: 3)

        guard ["Hard Drive Full", "Quiet Hours", "The Long Way Round"]
            .contains(where: { tapAnything($0) && app.buttons["More"].waitForExistence(timeout: 3) })
        else { capture("t01-FAILED-no-show"); XCTFail("Could not open a show."); return }
        settle()

        // Publish… from an episode's menu.
        let title = app.staticTexts.matching(identifier: "EpisodeTitle").element(boundBy: 0)
        if title.waitForExistence(timeout: 3) {
            scrollIntoView(title)
            title.press(forDuration: 1.0)
            settle(timeout: 2)
            capture("t01-episode-menu")
            let publish = app.buttons["Publish…"].firstMatch
            XCTAssertTrue(publish.exists, "No Publish… in the episode's menu on a show page.")
            if publish.exists {
                publish.tap()
                settle(timeout: 2)
                capture("t02-publish-from-episode")
                XCTAssertTrue(app.navigationBars["1 to Publish"].exists
                              || app.staticTexts["1 to Publish"].exists,
                              "Publish… did not open publishing with the episode ticked.")
                let done = app.buttons["Done"].firstMatch
                if done.exists { done.tap() }
                settle(timeout: 2)
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
            }
        }

        // Publish from the selection bar.
        let more = app.buttons["More"].firstMatch
        if more.waitForExistence(timeout: 3) {
            scrollIntoView(more)
            if more.isHittable { more.tap() } else { _ = tapCentre(of: more) }
            settle(timeout: 2)
            if app.buttons["Select Episodes"].firstMatch.waitForExistence(timeout: 2) {
                app.buttons["Select Episodes"].firstMatch.tap()
                settle(timeout: 2)
                let rows = app.descendants(matching: .any).matching(identifier: "SelectableEpisode")
                for index in 0..<2 where rows.count > index {
                    let row = rows.element(boundBy: index)
                    scrollIntoView(row)
                    if row.isHittable { row.tap() } else { _ = tapCentre(of: row) }
                }
                settle(timeout: 1)
                capture("t03-selection-bar")
                let barPublish = app.buttons["Publish"].firstMatch
                if barPublish.exists, barPublish.isHittable {
                    barPublish.tap()
                    settle(timeout: 2)
                    capture("t04-publish-from-selection")
                    let title = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'to Publish'")).firstMatch
                    XCTAssertTrue(title.exists && !(title.label.hasPrefix("0")),
                                  "Publish in the selection bar lost the selection.")
                } else {
                    XCTFail("No Publish in the selection bar.")
                }
                let done = app.buttons["Done"].firstMatch
                if done.exists { done.tap() }
                settle(timeout: 2)
            }
        }

        // Scrolled: nothing written in the bar.
        app.swipeUp(); app.swipeUp()
        settle(timeout: 2)
        capture("t05-show-scrolled-no-title")
        app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast)
        settle(timeout: 2)

        // Play Up Next — its first episode is the demo's video episode.
        if tapTab("Up Next") {
            settle(timeout: 3)
            let playAll = app.buttons["Play All"].firstMatch
            if playAll.waitForExistence(timeout: 3) {
                if playAll.isHittable { playAll.tap() } else { _ = tapCentre(of: playAll) }
                settle(timeout: 3)
            }
            capture("t06-up-next-playing")
            app.swipeUp(); app.swipeUp()
            settle(timeout: 2)
            capture("t07-up-next-continuation")
            app.swipeDown(); app.swipeDown(); app.swipeDown()
            settle(timeout: 2)
        }

        let mini = app.descendants(matching: .any).matching(identifier: "MiniPlayer").firstMatch
        if mini.waitForExistence(timeout: 5) {
            if mini.isHittable { mini.tap() } else { _ = tapCentre(of: mini) }
            settle(timeout: 3)
            capture("t08-player-video")
            let audio = app.buttons["VideoModeAudio"].firstMatch
            if audio.waitForExistence(timeout: 3) {
                audio.tap()
                settle(timeout: 2)
                capture("t09-player-audio-only")
                let video = app.buttons["VideoModeVideo"].firstMatch
                if video.exists { video.tap(); settle(timeout: 1) }
            } else {
                XCTFail("No Video / Audio switch on the video episode.")
            }
            let close = app.buttons["Close player"].firstMatch
            if close.waitForExistence(timeout: 3) { close.tap() } else { app.swipeDown() }
            settle(timeout: 3)
        }

        // Words said in episodes.
        if tapTab("Search") {
            settle(timeout: 3)
            var field = app.searchFields.firstMatch
            if !field.waitForExistence(timeout: 4) {
                app.swipeDown(); app.swipeDown()
                settle(timeout: 2)
                field = app.searchFields.firstMatch
            }
            XCTAssertTrue(field.waitForExistence(timeout: 4), "No search field on Discover.")
            if field.exists {
                field.tap()
                field.typeText("presale")
                settle(timeout: 5)
                capture("t10-search-said")
                XCTAssertTrue(app.staticTexts["Said in Your Episodes"].waitForExistence(timeout: 6),
                              "No transcript results for a word the demo transcripts contain.")
                let cancel = app.buttons["Cancel"].firstMatch
                if cancel.exists { cancel.tap() }
                settle(timeout: 2)
            }
            // A favourite category.
            let comedy = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Comedy'")).firstMatch
            var tries = 0
            while !(comedy.exists && comedy.isHittable), tries < 6 { app.swipeUp(); tries += 1 }
            if comedy.exists {
                comedy.press(forDuration: 1.0)
                settle(timeout: 2)
                let add = app.buttons["Add to Favourites"].firstMatch
                if add.waitForExistence(timeout: 2) {
                    add.tap()
                    settle(timeout: 6)
                    for _ in 0..<8 { app.swipeDown() }
                    settle(timeout: 3)
                    capture("t11-favourite-shelf")
                }
            }
        }
    }

    /// The sixth pass: the Publish tab folded into the Library, the feed
    /// badge, publish actions on an episode's menu, Up Next's informative
    /// rows and the ready-ahead card opened, an episode's own page, the star
    /// flipping at once, the collapsed mini player with its cover and date, and
    /// the catalogue indexing line in Settings.
    func testPassSix() throws {
        _ = app.wait(for: .runningForeground, timeout: 10)
        dismissOnboarding()
        settle(timeout: 3)
        capture("s01-library")
        XCTAssertFalse(app.tabBars.buttons["Publish"].exists, "The Publish tab is still there.")

        if openFeeds() {
            settle(timeout: 3)
            capture("s02-ad-free-feeds")
            back(); settle(timeout: 2)
        } else {
            capture("s02-FAILED-no-feeds-row")
            XCTFail("No Ad-Free Feeds row in the Library.")
        }

        // The grid, scrolled to the covers, for the feed badge.
        app.swipeUp()
        settle(timeout: 2)
        capture("s03-library-grid-badges")
        app.swipeDown(); app.swipeDown()
        settle(timeout: 2)

        guard ["Hard Drive Full", "Quiet Hours", "The Long Way Round"]
            .contains(where: { tapAnything($0) && app.buttons["More"].waitForExistence(timeout: 3) })
        else {
            capture("s04-FAILED-no-show"); XCTFail("Could not open a show."); return
        }
        settle()
        let title = app.staticTexts.matching(identifier: "EpisodeTitle").element(boundBy: 0)
        if title.waitForExistence(timeout: 3) {
            scrollIntoView(title)
            title.press(forDuration: 1.0)
            settle(timeout: 2)
            capture("s04-episode-menu")
            let feedItem = app.buttons.matching(NSPredicate(
                format: "label == 'Publish to Feed' OR label == 'Remove from Feed' OR label == 'Find Ads and Publish'")).firstMatch
            let details = app.buttons["Episode Details"].firstMatch
            XCTAssertTrue(details.exists, "No Episode Details in the episode menu.")
            _ = feedItem // Only offered with storage set up; the demo has none.
            if details.exists {
                details.tap()
                settle(timeout: 3)
                capture("s05-episode-detail")
                back(); settle(timeout: 2)
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
            }
        }

        // Scroll the show page quickly: nothing to assert, but the frames
        // before and after should show the header collapsing into the bar.
        app.swipeUp(velocity: .fast)
        settle(timeout: 1)
        capture("s06-show-scrolled")
        app.swipeDown(velocity: .fast); app.swipeDown(velocity: .fast)
        settle(timeout: 2)

        if tapTab("Up Next") {
            settle(timeout: 3)
            capture("s07-up-next")
            let header = app.buttons["ReadyAheadHeader"].firstMatch
            if header.waitForExistence(timeout: 3) {
                header.tap()
                settle(timeout: 2)
                capture("s08-ready-ahead-open")
            }
            app.swipeUp()
            settle(timeout: 2)
            capture("s09-up-next-rows")
            app.swipeDown(); app.swipeDown()
            settle(timeout: 2)
        }

        // Play something and look at the player's star.
        let playAll = app.buttons["Play All"].firstMatch
        if playAll.waitForExistence(timeout: 3) {
            if playAll.isHittable { playAll.tap() } else { _ = tapCentre(of: playAll) }
            settle(timeout: 2)
            let playNow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play now'")).firstMatch
            if playNow.waitForExistence(timeout: 2), playNow.isHittable { playNow.tap() }
            settle(timeout: 3)
        }
        let mini = app.descendants(matching: .any).matching(identifier: "MiniPlayer").firstMatch
        if mini.waitForExistence(timeout: 6) {
            capture("s10-mini-expanded")
            if mini.isHittable { mini.tap() } else { _ = tapCentre(of: mini) }
            settle(timeout: 3)
            let star = app.buttons["Star"].firstMatch
            let unstar = app.buttons["Unstar"].firstMatch
            if star.waitForExistence(timeout: 3) {
                star.tap()
                // No settle: the icon has to have changed straight away.
                XCTAssertTrue(unstar.waitForExistence(timeout: 0.6), "The star did not fill at once.")
                capture("s11-starred")
            } else if unstar.exists {
                unstar.tap()
                XCTAssertTrue(star.waitForExistence(timeout: 0.6), "The star did not clear at once.")
                capture("s11-unstarred")
            }
            let close = app.buttons["Close player"].firstMatch
            if close.waitForExistence(timeout: 3) { close.tap() } else { app.swipeDown() }
            settle(timeout: 3)
        }

        // Collapsed mini player, beside the minimised tab bar.
        if tapTab("Library") {
            settle(timeout: 2)
            app.swipeUp(); app.swipeUp()
            settle(timeout: 2)
            capture("s12-mini-inline")
            app.swipeDown(); app.swipeDown(); app.swipeDown()
            settle(timeout: 2)
        }

        if tapTab("Settings") {
            settle(timeout: 3)
            let row = app.descendants(matching: .any).matching(identifier: "LibraryIndexRow").firstMatch
            var tries = 0
            while !(row.exists && row.isHittable), tries < 8 { app.swipeUp(); tries += 1 }
            settle(timeout: 1)
            capture("s13-settings-index")
            XCTAssertTrue(row.exists, "No catalogue line above the history import.")
        }
    }

    /// Everything the third pass added, each photographed in the state that
    /// shows it: the star filled, the bookmark with its count, the bookmarks
    /// page, a peeked spot on the timeline and a held commit, the audio and
    /// what-was-skipped sheets at half height, Up Next's ready-ahead card,
    /// automatic downloads, and the publish queue's activity sheet.
    func testPassThree() throws {
        _ = app.wait(for: .runningForeground, timeout: 10)
        dismissOnboarding()

        guard ["Quiet Hours", "Hard Drive Full", "The Long Way Round"]
            .contains(where: { tapAnything($0) && app.buttons["More"].waitForExistence(timeout: 3) })
        else {
            capture("q0-FAILED-no-show")
            XCTFail("Could not open a show.")
            return
        }
        settle()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play'")).firstMatch
        if play.waitForExistence(timeout: 4) {
            if play.isHittable { play.tap() } else { _ = tapCentre(of: play) }
            settle(timeout: 2)
            let playNow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play now'")).firstMatch
            if playNow.waitForExistence(timeout: 2), playNow.isHittable { playNow.tap() }
            settle(timeout: 4)
        }
        let mini = app.descendants(matching: .any).matching(identifier: "MiniPlayer").firstMatch
        guard mini.waitForExistence(timeout: 6) else {
            capture("q0-FAILED-no-mini")
            XCTFail("Nothing started playing.")
            return
        }
        if mini.isHittable { mini.tap() } else { _ = tapCentre(of: mini) }
        settle(timeout: 3)
        capture("q1-player")

        // Demo data may already have it starred; tap whichever it is and
        // check that it flips.
        let star = app.buttons["Star"].firstMatch
        let unstar = app.buttons["Unstar"].firstMatch
        if star.waitForExistence(timeout: 3) {
            star.tap()
            settle(timeout: 2)
            capture("q2-starred")
            XCTAssertTrue(unstar.waitForExistence(timeout: 2), "The star did not change state.")
        } else if unstar.exists {
            unstar.tap()
            settle(timeout: 2)
            capture("q2-unstarred")
            XCTAssertTrue(star.waitForExistence(timeout: 2), "The star did not change state.")
            star.tap()
            settle(timeout: 2)
            capture("q2-starred-again")
        } else {
            XCTFail("No Star button in the player.")
        }

        let bookmark = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Bookmark'")).firstMatch
        if bookmark.waitForExistence(timeout: 3) {
            bookmark.tap()
            settle(timeout: 2)
            capture("q3-bookmark-alert")
            let field = app.alerts.textFields.firstMatch
            if field.waitForExistence(timeout: 2) {
                field.typeText("Great bit")
                app.alerts.buttons["Save"].firstMatch.tap()
            }
            settle(timeout: 2)
            capture("q4-bookmark-badge")
            let counted = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == 'Bookmark, 1 saved'")).firstMatch
            XCTAssertTrue(counted.waitForExistence(timeout: 3), "The bookmark button did not show a count.")

            counted.press(forDuration: 0.9)
            settle(timeout: 3)
            capture("q5-bookmarks-sheet")
            if !tapAnything("Done") { app.swipeDown() }
            settle(timeout: 2)
        } else {
            XCTFail("No bookmark button in the player.")
        }

        // Peek: a tap that must not seek.
        let bar = app.descendants(matching: .any).matching(identifier: "SeekBar").firstMatch
        if bar.waitForExistence(timeout: 3) {
            let before = bar.value as? String ?? ""
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
            settle(timeout: 1)
            capture("q6-peek-mark")
            let afterTap = bar.value as? String ?? ""
            // Time moves on by a second or two while playing; a seek to 80%
            // of the episode moves it by far more.
            capture("q6b-peek-value-\(before.prefix(5))-\(afterTap.prefix(5))")
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 1.4)
            settle(timeout: 1)
            capture("q7-held-commit")
            let afterHold = bar.value as? String ?? ""
            capture("q7b-hold-value-\(afterHold.prefix(5))")

            // Paused, drag half the bar's width, press play: playback must
            // start where the drag left it. Reported: it started from where
            // it was before the drag.
            let pause = app.buttons["Pause"].firstMatch
            if pause.waitForExistence(timeout: 2) { pause.tap() }
            settle(timeout: 1)
            let start = Self.seconds(bar.value as? String)
            let from = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
            let to = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5))
            // A drag released without holding still is only a preview: it
            // must spring back.
            from.press(forDuration: 0.05, thenDragTo: to)
            settle(timeout: 1)
            let previewed = Self.seconds(bar.value as? String)
            capture("q7b2-preview-sprang-back-\(Int(start ?? -1))-to-\(Int(previewed ?? -1))")
            if let start, let previewed {
                XCTAssertLessThan(abs(previewed - start), 3, "A drag without a hold moved playback.")
            }
            // Drag and hold still: the tether breaks and it moves.
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.9)
            settle(timeout: 1)
            let dragged = Self.seconds(bar.value as? String)
            capture("q7c-paused-drag-\(Int(start ?? -1))-to-\(Int(dragged ?? -1))")
            let play = app.buttons["Play"].firstMatch
            if play.waitForExistence(timeout: 2) { play.tap() }
            Thread.sleep(forTimeInterval: 1.5)
            let playing = Self.seconds(bar.value as? String)
            capture("q7d-played-from-\(Int(playing ?? -1))")
            if let start, let dragged, let playing {
                XCTAssertGreaterThan(abs(dragged - start), 10, "A paused drag did not move the position.")
                XCTAssertLessThan(abs(playing - dragged), 6,
                                  "Play started at \(playing)s, not where the drag left it (\(dragged)s).")
            } else {
                XCTFail("Could not read the seek bar's value.")
            }
        } else {
            XCTFail("No seek bar found.")
        }

        if tapAnything("Audio") {
            settle(timeout: 3)
            capture("q8-audio-sheet")
            // Dragged to its tallest: it must still be glass, not grey.
            let grabber = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.53))
            grabber.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
            settle(timeout: 2)
            capture("q8b-audio-sheet-tall")
            if app.buttons["Done"].firstMatch.waitForExistence(timeout: 2) {
                app.buttons["Done"].firstMatch.tap()
            }
            settle(timeout: 3)
        }
        // Paused first: a skip while the menu is open changes its "Last skip"
        // section, and the demo episode is two minutes of mostly ads.
        let pauseAgain = app.buttons["Pause"].firstMatch
        if pauseAgain.exists { pauseAgain.tap() }
        let more = app.buttons["More"].firstMatch
        if more.waitForExistence(timeout: 3) {
            for _ in 0..<6 where !more.isHittable { Thread.sleep(forTimeInterval: 0.5) }
        }
        if more.exists, more.isHittable {
            more.tap()
            settle(timeout: 2)
            if app.buttons["What was skipped"].firstMatch.waitForExistence(timeout: 3) {
                app.buttons["What was skipped"].firstMatch.tap()
                settle(timeout: 3)
                capture("q9-skip-sheet")
                if !tapAnything("Done") { app.swipeDown() }
                settle(timeout: 2)
            }
        }
        let close = app.buttons["Close player"].firstMatch
        if close.waitForExistence(timeout: 3) { close.tap() } else { app.swipeDown() }
        settle(timeout: 3)

        if tapTab("Up Next") {
            settle(timeout: 3)
            capture("q10-up-next")
        }

        if openFeeds() {
            settle(timeout: 3)
            if tapAnything("Hard Drive Full") || tapAnything("The Long Way Round") {
                settle(timeout: 3)
                let rows = app.descendants(matching: .any).matching(identifier: "SelectableEpisode")
                if rows.count == 0 { _ = tapAnything("Select All") }
                for index in 0..<2 where rows.count > index {
                    let row = rows.element(boundBy: index)
                    scrollIntoView(row)
                    if row.isHittable { row.tap() } else { _ = tapCentre(of: row) }
                }
                settle(timeout: 2)
                capture("q11-publish-selected")
                let publish = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Publish ('")).firstMatch
                if publish.waitForExistence(timeout: 3), publish.isHittable {
                    publish.tap()
                    settle(timeout: 2)
                    capture("q12-queued")
                    let banner = app.buttons.matching(NSPredicate(format: "label CONTAINS 'queued' OR label CONTAINS 'Publishing' OR label CONTAINS 'Finding' OR label CONTAINS 'finished'")).firstMatch
                    if banner.waitForExistence(timeout: 6), banner.isHittable {
                        banner.tap()
                        settle(timeout: 2)
                        capture("q13-activity-expanded")
                        let collapse = app.buttons["Collapse"].firstMatch
                        XCTAssertTrue(collapse.waitForExistence(timeout: 3), "The activity bar did not open.")
                        if collapse.exists { collapse.tap() }
                        settle(timeout: 2)
                        capture("q13b-activity-collapsed")
                    } else {
                        capture("q13-FAILED-no-banner")
                        XCTFail("No activity bar after publishing.")
                    }
                }
            }
        }

        if tapTab("Settings") {
            settle(timeout: 3)
            var found = false
            for _ in 0..<6 {
                let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Automatic Downloads'")).firstMatch
                if row.exists, row.isHittable { row.tap(); found = true; break }
                app.swipeUp()
            }
            settle(timeout: 3)
            capture(found ? "q14-auto-downloads" : "q14-FAILED-no-auto-downloads")
            if !found { XCTFail("No Automatic Downloads row in Settings.") }
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
        if openFeeds() {
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
        visitTab("Search", shot: "d0-discover")
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
        openRow("Stations", then: "03-stations")
        openRow("Bookmarks", then: "04-bookmarks")
        openRow("Statistics", then: "05-stats")
        openRow("Latest Episodes", then: "05b-latest")

        // Tabs, in an order chosen so that nothing depends on a screen that
        // cannot be left. Discover is at the very bottom of this method.
        visitTab("Up Next", shot: "07-upnext")
        if openFeeds() { settle(); capture("08-feeds"); back(); settle(timeout: 2) }
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
        visitTab("New", shot: "06-new"); visitTab("Search", shot: "06-search")
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
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        // Also straight to a folder on the Mac when one is given
        // (TEST_RUNNER_SHOT_DIR), so a run that never finishes writing its
        // result bundle still leaves its pictures behind.
        if let dir = ProcessInfo.processInfo.environment["SHOT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
            try? screenshot.pngRepresentation.write(to: url)
        }
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
    /// The Publish tab is gone; its list is Library → Ad-Free Feeds.
    private func openFeeds() -> Bool {
        guard tapTab("Library") else { return false }
        settle(timeout: 2)
        // Twice: the first tap on the Library tab only pops to its root.
        _ = tapTab("Library")
        settle(timeout: 2)
        return tapAnything("Ad-Free Feeds")
    }

    /// The tab bar shrinks to one button after a scroll down. A small scroll
    /// the other way brings it back; failing that, tapping the shrunken
    /// button does.
    private func expandTabBar(for name: String) {
        let tab = app.tabBars.buttons[name].firstMatch
        if tab.exists && tab.isHittable { return }
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
        settle(timeout: 1)
        if tab.exists && tab.isHittable { return }
        let any = app.tabBars.buttons.firstMatch
        if any.exists { _ = tapCentre(of: any); settle(timeout: 1) }
    }

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
