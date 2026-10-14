import XCTest
@testable import PodSkipper

/// Pass 37 (his 14 Oct phone on 4fdd2b7 and his requests): episode notes
/// without WebKit, the chart's zoom and its two-finger guard, and Gemma 4's
/// word tables.
@MainActor
final class Pass37Tests: XCTestCase {

    // MARK: Notes (the 30 s background watchdog in NSAttributedString's HTML import)

    func testNotesKeepLinksAndReadLikeStrip() {
        let html = #"<p>Thanks to <a href="https://example.com/sponsor?a=1&amp;b=2">our sponsor</a>!</p><ul><li>One</li><li>Two &amp; three</li></ul><script>x()</script>"#
        let notes = HTMLText.linked(html)
        let text = String(notes.characters)
        XCTAssertEqual(text, "Thanks to our sponsor!\n• One\n• Two & three")
        let links = notes.runs.compactMap { run -> (String, URL)? in
            run.link.map { (String(notes[run.range].characters), $0) }
        }
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.0, "our sponsor")
        XCTAssertEqual(links.first?.1.absoluteString, "https://example.com/sponsor?a=1&b=2")
    }

    func testNotesIgnoreUnsafeLinksAndPlainText() {
        XCTAssertNil(HTMLText.linked(#"<a href="javascript:alert(1)">x</a>"#).runs.first?.link)
        XCTAssertEqual(String(HTMLText.linked("Plain text,\n  no markup.").characters), "Plain text, no markup.")
        XCTAssertEqual(String(HTMLText.linked("").characters), "")
        XCTAssertEqual(String(HTMLText.linked("a<br/>b<br>c").characters), "a\nb\nc")
    }

    // MARK: Chart zoom

    func testZoomPanStaysInsideTheRange() {
        XCTAssertEqual(EQCurvePanel.clampPan(-0.2, zoom: 2), 0)
        XCTAssertEqual(EQCurvePanel.clampPan(0.9, zoom: 2), 0.5, accuracy: 0.0001)
        XCTAssertEqual(EQCurvePanel.clampPan(0.3, zoom: 1), 0)
        XCTAssertEqual(EQCurvePanel.clampPan(0.3, zoom: 0.92), 0, "Below 1× there is nothing to slide")
        XCTAssertEqual(EQCurvePanel.ramp(1.0, from: 1.25, to: 1.5), 0)
        XCTAssertEqual(EQCurvePanel.ramp(1.375, from: 1.25, to: 1.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(EQCurvePanel.ramp(3, from: 2.2, to: 2.5), 1)
        XCTAssertEqual(EQCurvePanel.markLabel(1_400), "1.4k")
        XCTAssertEqual(EQCurvePanel.markLabel(16_000), "16k")
        XCTAssertEqual(EQCurvePanel.markLabel(45), "45")
    }

    /// A pinch that starts with a finger on a knob: the second finger lands
    /// within 75 ms, so the knob's strength is put back.
    func testSecondFingerSoonAfterRevertsTheKnob() {
        let gate = ChartTouchGate()
        var reverted: Double?
        gate.fingers(1, at: 10.000)
        gate.dragBegan(.sibilance, strength: 6, revert: { reverted = $0 })
        gate.fingers(2, at: 10.050)
        XCTAssertEqual(reverted, 6)
        XCTAssertTrue(gate.twoFingers)
        XCTAssertTrue(gate.stopped.contains(.sibilance))
        gate.dragEnded(.sibilance)
        gate.fingers(0, at: 10.4)
        XCTAssertFalse(gate.twoFingers)
        XCTAssertTrue(gate.stopped.isEmpty)
    }

    /// A deliberate drag later joined by a second finger keeps its value
    /// and stops following the finger.
    func testLateSecondFingerKeepsTheKnobWhereItIs() {
        let gate = ChartTouchGate()
        var reverted: Double?
        gate.fingers(1, at: 5.0)
        gate.dragBegan(.dialogue, strength: 4, revert: { reverted = $0 })
        gate.fingers(2, at: 6.2)
        XCTAssertNil(reverted)
        XCTAssertTrue(gate.stopped.contains(.dialogue))
    }

    func testSampleGridIsDenserForZoom() {
        XCTAssertEqual(EQCurvePanel.sampleHz.count, 193)
        XCTAssertEqual(EQCurvePanel.sampleHz.first!, 20, accuracy: 0.001)
        XCTAssertEqual(EQCurvePanel.sampleHz.last!, 20_000, accuracy: 0.01)
    }

    // MARK: Gemma 4 word tables

    func testGemmaTablesCompleteOnlyWithBothFiles() throws {
        let bundle = FileManager.default.temporaryDirectory.appending(path: "gemma-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let tables = bundle.appending(path: CoreAIModelLibrary.gemmaTablesFolder)
        try FileManager.default.createDirectory(at: tables, withIntermediateDirectories: true)
        XCTAssertFalse(CoreAIModelLibrary.tablesComplete(in: bundle))
        try Data([1]).write(to: tables.appending(path: "embed_per_layer.i8"))
        XCTAssertFalse(CoreAIModelLibrary.tablesComplete(in: bundle))
        try Data().write(to: tables.appending(path: "embed_per_layer.scale.f32"))
        XCTAssertFalse(CoreAIModelLibrary.tablesComplete(in: bundle), "An empty file isn't a table")
        try Data([1]).write(to: tables.appending(path: "embed_per_layer.scale.f32"))
        XCTAssertTrue(CoreAIModelLibrary.tablesComplete(in: bundle))
    }

    // MARK: Settings writes off the main thread

    func testPreferenceWriterWrites() {
        let suite = "Pass37Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        PreferenceWriter.set("x", forKey: "k", in: defaults)
        PreferenceWriter.flush()
        XCTAssertEqual(defaults.string(forKey: "k"), "x")
    }

    // MARK: Plug rounds put in front of the model

    func testPlugRoundCue() {
        XCTAssertTrue(ModelFinder.plugRound(" Let's real quick, let's do some plugs."))
        XCTAssertTrue(ModelFinder.plugRound("Mark Norman, what are you plugging, my friend?"))
        XCTAssertTrue(ModelFinder.plugRound("We should have said, do you have anything to plug?"))
        XCTAssertFalse(ModelFinder.plugRound("I plugged the charger in and it died."))
        XCTAssertFalse(ModelFinder.plugRound("Spark plugs are expensive now."))
    }

    func testPlugRoundIsRead() {
        var lines: [TimedLine] = []
        for i in 0..<600 { lines.append(TimedLine(text: "We talk about nothing in particular \(i).", start: Double(i * 10), end: Double(i * 10 + 9))) }
        lines[354].text = "Let's real quick, let's do some plugs."
        let ranges = ModelFinder.focusRanges(lines: lines, readerCuts: [], duration: 6000, evidence: [], hints: [])
        let read = Set(ranges.flatMap { Array($0) })
        XCTAssertTrue(read.contains(354))
        XCTAssertTrue(read.contains(380), "Minutes after the cue are read too")
        XCTAssertFalse(read.contains(250), "Not the whole episode")
    }
}
