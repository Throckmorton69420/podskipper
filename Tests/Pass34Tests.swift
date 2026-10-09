import XCTest
@testable import PodSkipper

/// Pass 34 (his 9 Oct Diagnostics on 8bbe5dd).
final class Pass34Tests: XCTestCase {

    /// The static-shape prompt is fed in steps no wider than the narrowest
    /// graph, aligned to it, and the last ≤ 8 tokens are left for the first
    /// answer step, which needs the scores at the prompt's end.
    func testStaticPromptIsReadInNarrowSteps() {
        let ends = StaticPrefill.stepEnds(promptCount: 1_952)
        XCTAssertEqual(ends.first, 8)
        XCTAssertEqual(ends.last, 1_944)
        XCTAssertTrue(zip(ends, ends.dropFirst()).allSatisfy { $1 - $0 == 8 })
        XCTAssertTrue((1...8).contains(1_952 - ends.last!))

        XCTAssertEqual(StaticPrefill.stepEnds(promptCount: 8), [], "a short prompt is the answer step's own")
        XCTAssertEqual(StaticPrefill.stepEnds(promptCount: 17), [8, 16])
        XCTAssertEqual(StaticPrefill.stepEnds(promptCount: 40, alreadyRead: 13), [16, 24, 32], "kept tokens: realigned")
        XCTAssertTrue(StaticPrefill.usesSteps(engineName: "StaticShapeEngine"))
        XCTAssertFalse(StaticPrefill.usesSteps(engineName: "CoreAIPipelinedEngine"))
    }
}
