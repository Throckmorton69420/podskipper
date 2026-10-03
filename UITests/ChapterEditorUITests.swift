import XCTest

/// Exercises local chapter editing on the in-memory demo library.
final class ChapterEditorUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestScreenshots", "1", "-ResetDemoChapterEdits"]
        app.launch()
    }

    func testAddEditCancelValidatePlayAndDeleteChapter() throws {
        if app.buttons["Skip"].waitForExistence(timeout: 4) { app.buttons["Skip"].tap() }
        let quiet = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Quiet Hours'")).firstMatch
        XCTAssertTrue(quiet.waitForExistence(timeout: 10))
        quiet.tap()
        let titles = app.descendants(matching: .any).matching(identifier: "EpisodeTitle")
        XCTAssertTrue(titles.firstMatch.waitForExistence(timeout: 8))
        let title = (0..<min(titles.count, 6)).map { titles.element(boundBy: $0) }
            .first { $0.isHittable && $0.frame.minY > 200 } ?? titles.firstMatch
        title.tap()
        let page = element("EpisodePage")
        XCTAssertTrue(page.waitForExistence(timeout: 8))
        let add = element("episode.chapters.add")
        reveal(add)
        capture("chapter-01-empty")
        add.tap()
        waitForEditor()
        replace("chapter.editor.title", with: "Discarded Chapter")
        element("chapter.editor.cancel").tap()
        waitForEditorDismissal()
        XCTAssertFalse(app.staticTexts["Discarded Chapter"].exists)

        reveal(add)
        add.tap()
        waitForEditor()
        replace("chapter.editor.title", with: "Local Chapter")
        replace("chapter.editor.time", with: "0:30")
        replace("chapter.editor.artwork", with: "file:///private/not-an-artwork")
        element("chapter.editor.save").tap()
        let error = element("chapter.editor.error")
        XCTAssertTrue(error.waitForExistence(timeout: 3))
        let readableError = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            error.exists && !error.frame.isEmpty && self.app.frame.contains(error.frame)
                && !self.app.keyboards.firstMatch.exists
        }, object: error)
        XCTAssertEqual(XCTWaiter.wait(for: [readableError], timeout: 5), .completed,
                       "Validation should be readable with the keyboard dismissed")
        XCTAssertTrue(error.label.contains("complete http or https address"))
        capture("chapter-02-validation")
        replace("chapter.editor.artwork", with: "")
        XCTAssertFalse(error.exists, "Changing the draft must clear its stale validation error")
        replace("chapter.editor.link", with: "https://example.invalid/chapter-notes")
        capture("chapter-03-draft")
        element("chapter.editor.save").tap()
        waitForEditorDismissal()
        let firstPlay = element("chapter.play.0:30")
        reveal(firstPlay)
        XCTAssertTrue(firstPlay.exists)
        capture("chapter-04-added")

        let firstActions = element("chapter.actions.0:30")
        firstActions.tap()
        app.buttons["Edit Chapter"].tap()
        waitForEditor()
        replace("chapter.editor.title", with: "Edited Chapter")
        replace("chapter.editor.time", with: "0:45")
        element("chapter.editor.save").tap()
        waitForEditorDismissal()
        let editedPlay = element("chapter.play.0:45")
        reveal(editedPlay)
        XCTAssertTrue(editedPlay.exists)
        XCTAssertFalse(firstPlay.exists)
        XCTAssertEqual(editedPlay.label, "Play Edited Chapter from 0:45")
        capture("chapter-05-edited")
        editedPlay.tap()
        let mini = element("MiniPlayer")
        let requestedTitle = "A Lighthouse Keeper on the Last Year of the Job"
        let correctEpisode = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", requestedTitle), object: mini)
        XCTAssertEqual(XCTWaiter.wait(for: [correctEpisode], timeout: 10), .completed,
                       "The existing mini player must switch from the preloaded show to the requested episode")
        // The leading artwork/title region opens the player without hitting
        // the transport controls inside the same accessory.
        mini.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        let playerTitle = element("PlayerEpisodeTitle")
        XCTAssertTrue(playerTitle.waitForExistence(timeout: 8))
        XCTAssertEqual(playerTitle.label, requestedTitle)
        let elapsed = element("PlayerElapsedTime")
        XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
        let position = try XCTUnwrap(Double(elapsed.value as? String ?? ""),
                                     "The player should expose its measured source-audio position")
        XCTAssertGreaterThanOrEqual(position, 44.5)
        XCTAssertLessThan(position, 65, "Chapter selection must start near45s, allowing normal playback during presentation")
        capture("chapter-06-played")
        element("PlayerClose").tap()
        let playerGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                  object: element("PlayerPage"))
        XCTAssertEqual(XCTWaiter.wait(for: [playerGone], timeout: 8), .completed)

        let editedActions = element("chapter.actions.0:45")
        reveal(editedActions)
        editedActions.tap()
        app.buttons["Edit Chapter"].tap()
        waitForEditor()
        reveal(element("chapter.editor.delete"))
        element("chapter.editor.delete").tap()
        let confirmation = app.sheets["Delete this chapter?"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        // The native confirmation popover exposes its action as a button
        // containing another button with the same identifier and frame.
        // Scope to this modal and choose its first action explicitly.
        let confirm = confirmation.buttons.matching(identifier: "chapter.editor.confirmDelete").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(confirm.isHittable, "The modal destructive action must be reachable")
        capture("chapter-07-confirm-delete")
        confirm.tap()
        waitForEditorDismissal()
        reveal(add)
        XCTAssertFalse(editedPlay.exists)
        XCTAssertFalse(element("episode.chapters.load").exists,
                       "Removing the last chapter must retain local intent")
        capture("chapter-08-deleted")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<8 {
            if element.exists, !element.frame.isEmpty, app.frame.intersects(element.frame), element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "Expected control was not reachable: \(element.identifier)")
    }

    /// Native sheet contents enter the accessibility tree while their frames
    /// are still below the window. Wait for the transition before hit testing.
    private func waitForEditor() {
        let title = element("chapter.editor.title")
        XCTAssertTrue(title.waitForExistence(timeout: 6))
        let insideWindow = NSPredicate { _, _ in
            title.exists && !title.frame.isEmpty && self.app.frame.contains(title.frame)
        }
        let visible = XCTNSPredicateExpectation(predicate: insideWindow, object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 8), .completed,
                       "The editor must finish presenting before fields can be edited")
    }

    private func waitForEditorDismissal() {
        let title = element("chapter.editor.title")
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 8), .completed,
                       "Successful save/cancel/delete must dismiss the editor")
    }

    private func replace(_ identifier: String, with text: String) {
        let field = element(identifier)
        reveal(field)
        field.tap()
        // Native taps can place the caret at the beginning of existing text.
        // Select the full value through the supported physical-key API first.
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text.isEmpty ? XCUIKeyboardKey.delete.rawValue : text)
        let value = field.value as? String ?? ""
        let actual = value == field.placeholderValue ? "" : value
        XCTAssertEqual(actual, text, "Replacement must update the entire field value")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
