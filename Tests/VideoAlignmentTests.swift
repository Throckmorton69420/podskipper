import XCTest
@testable import PodSkipper

/// Stavvy's World #200 (4 Oct): a host's clean video is shorter than the
/// download by the stitched ads, pre-roll included. The stricter ad-free
/// comparison keeps the pre/post-roll out of `inserted`, so the picture needs
/// its own alignment spans that include them.
final class VideoAlignmentTests: XCTestCase {
    func testAlignmentIncludesPreAndPostRollsInOrder() {
        var outcome = AdFreeCopy.Outcome()
        outcome.source = "simplecast"
        outcome.inserted = [InsertedSpan(start: 1_800, end: 1_860)]
        outcome.terminalCandidates = [InsertedSpan(start: 6_100, end: 6_184.5), InsertedSpan(start: 0, end: 90)]
        XCTAssertEqual(outcome.alignmentSpans, [InsertedSpan(start: 0, end: 90),
                                                InsertedSpan(start: 1_800, end: 1_860),
                                                InsertedSpan(start: 6_100, end: 6_184.5)])
        let removed = outcome.alignmentSpans.reduce(0) { $0 + $1.end - $1.start }
        // VideoSync accepts a set whose total explains the length difference
        // within 8 s: 6,184.5 s of audio against a 5,957 s picture.
        XCTAssertLessThanOrEqual(abs(5_957 - (6_184.5 - removed)), 8)
        XCTAssertTrue(outcome.isDefinitiveForVideo)
        // Ad cutting still sees only the interior insert.
        XCTAssertEqual(outcome.inserted.count, 1)
    }

    func testNetworkFailureIsNotKeptButNoReferenceIs() {
        var failed = AdFreeCopy.Outcome()
        failed.source = "simplecast"
        failed.note = "The comparison copy could not be downloaded."
        XCTAssertFalse(failed.isDefinitiveForVideo, "A failure must be measured again next time")
        var same = AdFreeCopy.Outcome()
        same.source = "simplecast"
        same.note = "the reference is not shorter; no inserted cuts were confirmed"
        XCTAssertTrue(same.isDefinitiveForVideo)
        XCTAssertTrue(AdFreeCopy.Outcome().isDefinitiveForVideo, "No ad-free copy to ask: nothing to retry")
    }

    func testMalformedAlignmentGivesNothing() {
        let good = [InsertedSpan(start: 0, end: 90), InsertedSpan(start: 1_800, end: 1_860)]
        XCTAssertEqual(Episode.validAlignment(good.reversed(), duration: 6_184.5), good)
        XCTAssertEqual(Episode.validAlignment([InsertedSpan(start: 0, end: 90), InsertedSpan(start: 80, end: 120)],
                                              duration: 6_184.5), [], "Overlaps are refused")
        XCTAssertEqual(Episode.validAlignment([InsertedSpan(start: 6_000, end: 7_000)], duration: 6_184.5), [],
                       "Past the end of the file is refused")
        XCTAssertEqual(Episode.validAlignment([InsertedSpan(start: 10, end: 10)], duration: 100), [])
    }
}
