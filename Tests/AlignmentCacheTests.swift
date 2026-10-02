import XCTest
@testable import PodSkipper

final class AlignmentCacheTests: XCTestCase {
    func testLegacyUnreviewedCutsRemainHistoryWithoutSkippingExportingOrVideoMapping() throws {
        let e = Episode(guid: UUID().uuidString, title: "Test", episodeDescription: "", audioURL: "",
                        publishedAt: .now, duration: 100)
        let s = AdSegment(start: 80, end: 100)
        s.insertedAtDownload = true
        s.episode = e; e.adSegments = [s]
        e.insertedSpansData = try JSONEncoder().encode([InsertedSpan(start: 80, end: 100)])
        XCTAssertEqual(e.adSegments.count, 1)
        XCTAssertTrue(e.insertedSpans.isEmpty)
        XCTAssertTrue(e.skipRanges.isEmpty)
        XCTAssertTrue(e.videoGapCandidates.isEmpty)
        XCTAssertEqual(e.adSecondsRemoved, 0)
        XCTAssertFalse(s.canApplyAutomatically)
        XCTAssertEqual(s.status, "Comparison needs review")
        e.insertedSpansPolicyVersion = AdFreeCopy.comparisonPolicyVersion
        XCTAssertTrue(e.skipRanges.isEmpty, "A terminal range remains unsafe even with a current version")
        s.userVerdict = .confirmed
        XCTAssertEqual(e.skipRanges.count, 1, "Explicit user corrections remain usable")
        s.userVerdict = .notAnAd
        XCTAssertTrue(e.skipRanges.isEmpty)
    }

    func testMatchingInteriorEvidenceAppliesOnlyToItsOwnCutAndPreservesUserEdits() throws {
        let e = Episode(guid: UUID().uuidString, title: "Test", episodeDescription: "", audioURL: "",
                        publishedAt: .now, duration: 100)
        let exact = AdSegment(start: 20, end: 30), other = AdSegment(start: 40, end: 50)
        for s in [exact, other] { s.insertedAtDownload = true; s.episode = e }
        e.adSegments = [exact, other]
        e.insertedSpansPolicyVersion = AdFreeCopy.comparisonPolicyVersion
        e.insertedSpansData = try JSONEncoder().encode([InsertedSpan(start: 20, end: 30)])
        XCTAssertTrue(exact.canApplyAutomatically)
        XCTAssertFalse(other.canApplyAutomatically)
        XCTAssertEqual(e.skipRanges, [20...30])
        other.start = 41
        XCTAssertTrue(other.canApplyAutomatically, "A listener's edited cut stays intact")
        XCTAssertEqual(e.adSegments.count, 2)
    }
    func testCorruptReviewedTimingIsRetainedWithoutConstructingInvalidRanges() {
        let e = Episode(guid: UUID().uuidString, title: "Test", episodeDescription: "", audioURL: "",
                        publishedAt: .now, duration: 100)
        for (start, end) in [(30.0, 20.0), (.nan, 30), (0, .infinity), (0, Double.greatestFiniteMagnitude), (-1, 30)] {
            let s = AdSegment(start: start, end: end)
            s.userVerdict = .confirmed; s.episode = e; e.adSegments = [s]
            XCTAssertFalse(s.canApplyAutomatically)
            XCTAssertTrue(e.skipRanges.isEmpty)
            XCTAssertTrue(e.videoGapCandidates.isEmpty)
            XCTAssertEqual(e.adSegments.count, 1)
        }
        XCTAssertEqual(formatDuration(.infinity), "—")
        XCTAssertEqual(SegmentDetector.clock(.nan), "—")
    }

}
