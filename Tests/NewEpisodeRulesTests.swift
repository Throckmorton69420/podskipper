import XCTest
@testable import PodSkipper

/// Not wired into any target yet: `project.yml` has no unit-test target and is
/// off limits to cloud sessions. Add one that includes `Tests/` to run these.
final class NewEpisodeRulesTests: XCTestCase {
    let followed = Date(timeIntervalSince1970: 1_000_000)

    func testBackCatalogueIsNotNew() {
        XCTAssertFalse(NewEpisodeRules.startsNew(publishedAt: followed - 86_400, followedAt: followed, isLatestAtFollow: false))
    }
    func testLatestAtFollowIsNew() {
        XCTAssertTrue(NewEpisodeRules.startsNew(publishedAt: followed - 86_400, followedAt: followed, isLatestAtFollow: true))
    }
    func testPublishedAfterFollowIsNew() {
        XCTAssertTrue(NewEpisodeRules.startsNew(publishedAt: followed + 60, followedAt: followed, isLatestAtFollow: false))
    }
    func testArchivedShowIsNeverNew() {
        XCTAssertFalse(NewEpisodeRules.startsNew(publishedAt: followed + 60, followedAt: followed, isLatestAtFollow: true, showArchived: true))
    }
    func testUnheardIsNew() {
        XCTAssertTrue(NewEpisodeRules.isNew(flag: true, isPlayed: false, isArchived: false, playbackPosition: 0, lastPlayedAt: nil))
    }
    func testPlayedStartedOrArchivedIsNotNew() {
        XCTAssertFalse(NewEpisodeRules.isNew(flag: true, isPlayed: true, isArchived: false, playbackPosition: 0, lastPlayedAt: nil))
        XCTAssertFalse(NewEpisodeRules.isNew(flag: true, isPlayed: false, isArchived: false, playbackPosition: 5, lastPlayedAt: nil))
        XCTAssertFalse(NewEpisodeRules.isNew(flag: true, isPlayed: false, isArchived: false, playbackPosition: 0, lastPlayedAt: .now))
        XCTAssertFalse(NewEpisodeRules.isNew(flag: true, isPlayed: false, isArchived: true, playbackPosition: 0, lastPlayedAt: nil))
    }
    func testExistingEpisodesWithoutFlagAreNotNew() {
        XCTAssertFalse(NewEpisodeRules.isNew(flag: false, isPlayed: false, isArchived: false, playbackPosition: 0, lastPlayedAt: nil))
    }
}
