import XCTest
@testable import PodSkipper

@MainActor
final class PreviewFeedAddressTests: XCTestCase {
    nonisolated private func show(_ id: Int) -> PodcastSearchResult {
        PodcastSearchResult(id: id, title: "Show \(id)", author: "", feedURL: "https://example.invalid/\(id).xml",
            artworkURL: nil, episodeCount: nil, genre: nil)
    }

    func testKnownFeedPreservesPrivateAddressAndAvoidsDirectoryRequest() async throws {
        let feed = "https://example.invalid/Private.xml?token=fixture"
        let result = try await PreviewFeedAddress.resolve(feedURL: feed, showID: 1) { _ in
            XCTFail("A known feed must not require a directory request"); return []
        }
        XCTAssertEqual(result, feed)
    }

    func testMissingShowIDAndGenuinelyEmptyDirectoryAreUnavailable() async throws {
        let unidentified = try await PreviewFeedAddress.resolve(feedURL: nil, showID: nil) { _ in
            XCTFail("No identity must not launch a request"); return []
        }
        let unavailable = try await PreviewFeedAddress.resolve(feedURL: nil, showID: 1) { _ in [] }
        XCTAssertNil(unidentified)
        XCTAssertNil(unavailable)
    }

    func testBlankFeedCanResolveExactDirectoryShow() async throws {
        let result = try await PreviewFeedAddress.resolve(feedURL: "  ", showID: 2) { [self] ids in
            XCTAssertEqual(ids, [2]); return [show(2)]
        }
        XCTAssertEqual(result, "https://example.invalid/2.xml")
    }

    func testUnexpectedDirectoryShowCannotBeChosenAsThePreviewFeed() async throws {
        let chosen = try await PreviewFeedAddress.resolve(feedURL: nil, showID: 2) { [self] _ in [show(1), show(2)] }
        let absent = try await PreviewFeedAddress.resolve(feedURL: nil, showID: 2) { [self] _ in [show(1)] }
        XCTAssertEqual(chosen, "https://example.invalid/2.xml")
        XCTAssertNil(absent)
    }

    func testDirectoryFailurePropagatesInsteadOfBecomingUnavailable() async {
        do {
            _ = try await PreviewFeedAddress.resolve(feedURL: nil, showID: 1) { _ in throw URLError(.notConnectedToInternet) }
            XCTFail("A connection failure must reach retry UI")
        } catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testCancelledLookupCannotPublishLateFeedAddress() async {
        let started = expectation(description: "Lookup started")
        var finish: CheckedContinuation<Void, Never>?
        let task = Task { @MainActor [self] in
            try await PreviewFeedAddress.resolve(feedURL: nil, showID: 1) { [self] _ in
                await withCheckedContinuation { finish = $0; started.fulfill() }
                return [show(1)]
            }
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        finish?.resume()
        do { _ = try await task.value; XCTFail("A cancelled lookup must not resolve a feed") }
        catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
    }
}
