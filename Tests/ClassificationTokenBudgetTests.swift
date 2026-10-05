import XCTest
@testable import PodSkipper

final class ClassificationTokenBudgetTests: XCTestCase {
    func testActualBuild303SamplesFitTheCatalogContext() {
        XCTAssertEqual(ClassificationTokenBudget.answerTokens(input: 2_092, capacity: 4_096), 2_003)
        XCTAssertEqual(ClassificationTokenBudget.answerTokens(input: 2_198, capacity: 4_096), 1_897)
    }
    func testLeavesRoomForTerminationAndRejectsUnusableOrOversizedRequests() {
        XCTAssertEqual(ClassificationTokenBudget.answerTokens(input: 3_839, capacity: 4_096), 256)
        XCTAssertNil(ClassificationTokenBudget.answerTokens(input: 3_840, capacity: 4_096))
        XCTAssertNil(ClassificationTokenBudget.answerTokens(input: 5_000, capacity: 4_096))
        XCTAssertEqual(ClassificationTokenBudget.answerTokens(input: 100, capacity: 4_096), 2_048)
        XCTAssertEqual(ClassificationTokenBudget.answerTokens(input: 2_092, capacity: 0), 2_048)
    }
}
