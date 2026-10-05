import XCTest
@testable import PodSkipper

/// Pass 30 (his 5 Oct phone): an open model's answer can no longer remove
/// most of a show. Core AI Qwen3 4B cut ~47 of Bad Friends' 66 minutes;
/// the reader and Apple Intelligence found the two real breaks.
final class Pass30Tests: XCTestCase {
    /// 600 lines of five seconds: conversation, with one host read at
    /// lines 300–319 (25:00–26:40) that names its product and gives an offer.
    private func episode() -> [TimedLine] {
        let talk = ["so we were at the game last night and it was wild",
                    "he kept yelling at the referee the whole time",
                    "and then my brother shows up with a giant sandwich",
                    "honestly the best part was the parking lot",
                    "you remember that guy from the bar on Tuesday"]
        var lines: [TimedLine] = []
        for i in 0..<600 {
            var text = talk[i % talk.count]
            switch i {
            case 300: text = "Liquid IV."
            case 301: text = "I love Liquid IV, one stick and water hydrates you better than water alone."
            case 302...312: text = "Liquid IV has great flavors and I take it on every flight."
            case 315: text = "Go to liquidiv.com and get 20% off your first purchase with code BF at checkout."
            case 318: text = "That's 20% off at liquidiv.com."
            default: break
            }
            lines.append(TimedLine(text: text, start: Double(i) * 5, end: Double(i) * 5 + 4.8))
        }
        return lines
    }

    private func part(_ first: Int, _ last: Int, _ label: JudgeLabel, sponsor: String = "") -> JudgedPart {
        JudgedPart(firstLine: first, lastLine: last, label: label, sponsor: sponsor, funny: false,
                   confidence: 90, why: "test")
    }

    private func check(_ parts: [JudgedPart], reader: [DetectedSegment] = []) -> ModelCutCheck.Outcome {
        let lines = episode()
        return ModelFinder.checkedCuts(from: parts, lines: lines, readerCuts: reader, inserted: [], evidence: [],
                                       silences: [], padding: 0, duration: 3000)
    }

    private func total(_ cuts: [DetectedSegment]) -> Double { cuts.reduce(0) { $0 + $1.end - $1.start } }

    func testFortySevenMinuteHostReadIsCutDownToTheRead() {
        let outcome = check([part(0, 560, .hostReadAd, sponsor: "Liquid IV")])
        XCTAssertLessThan(total(outcome.cuts), 200, "only the read itself may be cut: \(outcome.cuts.map { ($0.start, $0.end) })")
        XCTAssertTrue(outcome.cuts.contains { $0.start <= 1500 && $0.end >= 1590 }, "the read stays cut")
        XCTAssertGreaterThan(outcome.droppedSeconds, 2400)
        XCTAssertFalse(outcome.notes.isEmpty)
    }

    func testConversationLabelledAsAnAdWithNothingSellingIsDropped() {
        let outcome = check([part(20, 120, .hostReadAd, sponsor: "Ford")])
        XCTAssertTrue(outcome.cuts.isEmpty, "\(outcome.cuts.map { ($0.start, $0.end) })")
    }

    func testOutroInTheMiddleOfTheEpisodeIsDropped() {
        let outcome = check([part(200, 230, .outro)])
        XCTAssertTrue(outcome.cuts.isEmpty)
    }

    func testOutroAtTheEndStays() {
        let outcome = check([part(585, 599, .outro)])
        XCTAssertEqual(outcome.cuts.count, 1)
    }

    func testReaderBackedModelCutKeepsTheModelEdges() {
        let reader = DetectedSegment(start: 1500, end: 1600, kind: .ad, sponsor: "Liquid IV", confidence: 95)
        let outcome = check([part(298, 320, .hostReadAd, sponsor: "Liquid IV")], reader: [reader])
        XCTAssertEqual(outcome.cuts.count, 1)
        XCTAssertEqual(outcome.cuts.first?.start ?? 0, 1490, accuracy: 1)
        XCTAssertEqual(outcome.cuts.first?.end ?? 0, 1604.8, accuracy: 1)
    }

    func testReaderSureAdStaysWhenTheModelSaysNothing() {
        let reader = DetectedSegment(start: 1500, end: 1600, kind: .ad, sponsor: "Liquid IV", confidence: 95)
        let outcome = check([], reader: [reader])
        XCTAssertEqual(outcome.cuts.count, 1)
        XCTAssertEqual(outcome.cuts.first?.start, 1500)
    }

    func testModelSayingItIsTheShowVetoesTheReader() {
        let reader = DetectedSegment(start: 1500, end: 1600, kind: .ad, sponsor: "Liquid IV", confidence: 95)
        let outcome = check([part(300, 319, .mockAd)], reader: [reader])
        XCTAssertTrue(outcome.cuts.isEmpty)
    }

    func testOwedReadsAreRememberedAndSettled() {
        let guid = "pass30-" + UUID().uuidString
        ModelFinder.owe(guid)
        XCTAssertEqual(ModelFinder.owedReads.first, guid)
        ModelFinder.settle(guid)
        XCTAssertFalse(ModelFinder.owedReads.contains(guid))
    }

    /// His request: deleting the selected model selects the best-scoring one
    /// left; without scores, the first alphabetically.
    func testReplacementIsBestScoreThenAlphabetical() {
        let order = ModelRanking.bestFirst([
            (id: "c", name: "Charlie", score: nil),
            (id: "b", name: "Bravo", score: 0.6),
            (id: "a", name: "Alpha", score: nil),
            (id: "d", name: "Delta", score: 0.9)])
        XCTAssertEqual(order, ["d", "b", "a", "c"])
    }

    /// His question: "not an ad" now also stops a model's cut, not only the reader's.
    func testHisNotAnAdCorrectionVetoesTheSameModelCut() throws {
        let lines = episode()
        let read = lines[300...318].map(\.text).joined(separator: " ")
        let corrections = [DetectionCorrection(excerpt: read, kind: nil)]
        guard !FeedbackMemory(corrections: corrections).isEmpty else {
            throw XCTSkip("No sentence embedding available on this simulator")
        }
        let parts = [part(300, 318, .hostReadAd, sponsor: "Liquid IV")]
        let plain = ModelFinder.checkedCuts(from: parts, lines: lines, readerCuts: [], inserted: [], evidence: [],
                                            silences: [], padding: 0, duration: 3000)
        XCTAssertFalse(plain.cuts.isEmpty)
        let corrected = ModelFinder.checkedCuts(from: parts, lines: lines, readerCuts: [], inserted: [], evidence: [],
                                                silences: [], padding: 0, duration: 3000, corrections: corrections)
        XCTAssertTrue(corrected.cuts.isEmpty, "\(corrected.cuts.map { ($0.start, $0.end) })")
        XCTAssertTrue(corrected.notes.contains { $0.contains("marked not an ad") })
    }
}
