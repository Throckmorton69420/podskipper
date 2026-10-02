import XCTest
@testable import PodSkipper

final class SegmentBrandBoundaryTests: XCTestCase {
    private func sentence(_ text: String, _ start: Double = 0, _ end: Double = 10) -> Sentence {
        Sentence(text: text, start: start, end: end)
    }

    func testShortBrandCannotMatchThePrefixOfAnOrdinaryWord() {
        XCTAssertFalse(SegmentDetector.mentions(sentence("I don't know how to start the day."), ["star"]))
        XCTAssertFalse(SegmentDetector.mentions(sentence("A nocturnal animal lives here."), ["noct"]))
    }

    func testShortBrandCannotMatchAcrossUnrelatedWordBoundaries() {
        XCTAssertFalse(SegmentDetector.mentions(sentence("We restart a conversation."), ["star"]))
    }

    func testExactShortBrandAndRecognizedDomainRemainMatches() {
        XCTAssertTrue(SegmentDetector.mentions(sentence("Star makes this game."), ["star"]))
        XCTAssertTrue(SegmentDetector.mentions(sentence("Visit nocd.com for details."), ["nocd"]))
        XCTAssertTrue(SegmentDetector.mentions(sentence("Go to ring dot com."), ["ring"]))
    }

    func testSplitRecognitionAndLongCompoundBrandsRemainMatches() {
        XCTAssertTrue(SegmentDetector.mentions(sentence("Go to no CD dot com."), ["nocd"]))
        XCTAssertTrue(SegmentDetector.mentions(sentence("Try factormeals today."), ["factor"]))
        XCTAssertTrue(SegmentDetector.mentions(sentence("Try take ultra today."), ["takeultra"]))
    }

    func testForwardGrowthDoesNotCutContentBecauseStartResemblesStar() {
        let sentences = [sentence("Visit Star for this game.", 0, 27),
                         sentence("I don't know how to start the day.", 32, 47)]
        let ad = SegmentFinding(kind: .ad, start: 0, end: 27, sponsor: "Star", confidence: 98,
            startConfidence: 98, endConfidence: 96, firstSentence: 0, lastSentence: 0)
        var log: [String] = []
        let result = SegmentDetector.grow([ad], sentences: sentences,
            votes: [[.advertisement: 98], [.content: 99]], log: &log)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].end, 27)
        XCTAssertEqual(result[0].lastSentence, 0)
    }

    func testBackwardGrowthDoesNotCutContentBecauseStartResemblesStar() {
        let sentences = [sentence("I don't know how to start the day.", 0, 20),
                         sentence("Visit Star for this game.", 25, 47)]
        let ad = SegmentFinding(kind: .ad, start: 25, end: 47, sponsor: "Star", confidence: 98,
            startConfidence: 98, endConfidence: 96, firstSentence: 1, lastSentence: 1)
        var log: [String] = []
        let result = SegmentDetector.grow([ad], sentences: sentences,
            votes: [[.content: 99], [.advertisement: 98]], log: &log)
        XCTAssertEqual(result[0].start, 25)
        XCTAssertEqual(result[0].firstSentence, 1)
    }
}
