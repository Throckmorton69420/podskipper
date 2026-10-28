import XCTest
@testable import PodSkipper

/// Pass 49: Apple Podcasts 27.2's search results open on "Top Results" — the
/// closest shows and episodes — ahead of the Shows and Episodes sections.
final class Pass49TopResultsTests: XCTestCase {
    private func show(_ id: Int, _ title: String) -> PodcastSearchResult {
        PodcastSearchResult(id: id, title: title, author: "Author \(id)", feedURL: "https://example.invalid/\(id).xml",
                            artworkURL: nil, episodeCount: nil, genre: nil)
    }

    private func episode(_ id: Int, _ title: String) -> DiscoverService.EpisodeResult {
        DiscoverService.EpisodeResult(id: id, title: title, showTitle: "Show", feedURL: "https://example.invalid/e.xml",
                                      audioURL: "https://example.invalid/\(id).mp3", artworkURL: nil, releaseDate: nil,
                                      duration: 60, summary: "", showID: nil)
    }

    func testClosenessIgnoresCaseAccentsAndPunctuation() {
        XCTAssertEqual(SearchTopResults.closeness("Quiet", to: "quiet"), 3)
        XCTAssertEqual(SearchTopResults.closeness("Quiet: The Power of Introverts", to: "QUIET"), 2)
        XCTAssertEqual(SearchTopResults.closeness("Fall Asleep To A Quiet History", to: "quiet"), 1)
        XCTAssertEqual(SearchTopResults.closeness("Café Society", to: "cafe"), 2)
        // A word inside another word doesn't count.
        XCTAssertEqual(SearchTopResults.closeness("Quietus", to: "quiet"), 0)
        XCTAssertEqual(SearchTopResults.closeness("Anything", to: "  "), 0)
    }

    func testTheShowThatStartsWithTheWordsComesFirst() {
        let shows = [show(1, "Fall Asleep To A Quiet History"), show(2, "Quiet: The Power of Introverts"),
                     show(3, "A Quiet Mind"), show(4, "Loud")]
        let episodes = [episode(10, "When You Feel Like You Are Failing"), episode(11, "The quiet hour")]
        let top = SearchTopResults.pick(shows: shows, episodes: episodes, term: "quiet")
        XCTAssertEqual(top.map(\.id), ["show-2", "show-1", "episode-11", "show-3"])
        XCTAssertLessThanOrEqual(top.count, SearchTopResults.limit)
    }

    func testEpisodesFillWhenFewShowsMatch() {
        let top = SearchTopResults.pick(shows: [show(1, "Tulsa King Recap")],
                                        episodes: [episode(10, "Tulsa King finale"), episode(11, "Tulsa King s3"),
                                                   episode(12, "Tulsa King cast"), episode(13, "Tulsa King music")],
                                        term: "tulsa king")
        XCTAssertEqual(top.map(\.id), ["show-1", "episode-10", "episode-11", "episode-12"])
    }

    func testNoTitleMatchFallsBackToTheDirectorysFirstOfEach() {
        let top = SearchTopResults.pick(shows: [show(1, "Alpha"), show(2, "Beta")],
                                        episodes: [episode(10, "Gamma")], term: "zeta")
        XCTAssertEqual(top.map(\.id), ["show-1", "episode-10"])
        XCTAssertTrue(SearchTopResults.pick(shows: [], episodes: [], term: "zeta").isEmpty)
    }

    func testEpisodeIDAndFeed() {
        XCTAssertEqual(SearchTopResults.Item.episode(episode(10, "x")).episodeID, 10)
        XCTAssertNil(SearchTopResults.Item.show(show(1, "x")).episodeID)
        XCTAssertEqual(SearchTopResults.Item.show(show(1, "x")).feedURL, "https://example.invalid/1.xml")
    }
}
