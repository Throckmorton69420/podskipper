import XCTest
import SwiftData
@testable import PodSkipper

@MainActor
final class DestinationParityTests: XCTestCase {
    private func route(title: String = "Daily Update", audioURL: String? = nil, guid: String? = nil,
                       date: Date? = nil, feedURL: String? = "https://example.invalid/feed.xml", showID: Int? = nil) -> PreviewEpisodeRoute {
        PreviewEpisodeRoute(feedURL: feedURL, showID: showID, showName: "Repeated Show", showArtworkURL: nil,
            title: title, artworkURL: nil, publishedAt: date, duration: nil, summary: nil, audioURL: audioURL, guid: guid)
    }

    private func repeatedItems() throws -> [ParsedItem] {
        try FeedParser.parse(Data("""
        <rss version="2.0"><channel><title>Repeated Show</title>
        <item><guid>old-guid</guid><title>Daily Update</title><pubDate>Mon, 28 Sep 2026 10:00:00 GMT</pubDate>
        <enclosure url="https://example.invalid/old.mp3" type="audio/mpeg"/></item>
        <item><guid>new-guid</guid><title>Daily Update</title><pubDate>Tue, 29 Sep 2026 10:00:00 GMT</pubDate>
        <enclosure url="https://example.invalid/new.mp3" type="audio/mpeg"/></item>
        </channel></rss>
        """.utf8)).items
    }

    func testFeedRowCarriesResolvedAddressAndExactGUIDDespiteRepeatedTitles() throws {
        let items = try repeatedItems()
        let wanted = try XCTUnwrap(items.first { $0.guid == "new-guid" })
        let resolvedFeed = "https://example.invalid/resolved-feed.xml"
        let preview = PreviewEpisodeRoute(item: wanted, feedURL: resolvedFeed, showID: 42,
                                          showName: "Repeated Show", showArtworkURL: nil)
        XCTAssertEqual(preview.feedURL, resolvedFeed)
        XCTAssertEqual(preview.guid, "new-guid")
        XCTAssertEqual(preview.audioURL, wanted.audioURL)
        XCTAssertEqual(PreviewEpisodeIdentity.item(for: preview, in: items)?.guid, "new-guid")
        XCTAssertEqual(PreviewEpisodeIdentity.item(for: preview, in: Array(items.reversed()))?.guid, "new-guid")
    }

    func testEnclosureIdentityBeatsRepeatedTitleAndMissingExplicitIdentityDoesNotFallback() throws {
        let items = try repeatedItems()
        XCTAssertEqual(PreviewEpisodeIdentity.item(for: route(audioURL: "https://example.invalid/new.mp3"), in: items)?.guid, "new-guid")
        XCTAssertNil(PreviewEpisodeIdentity.item(for: route(guid: "missing-guid"), in: items))
        XCTAssertNil(PreviewEpisodeIdentity.item(for: route(audioURL: "https://example.invalid/missing.mp3"), in: items))
    }

    func testAmbiguousTitleIsRejectedAndDateCanDisambiguateDirectoryEntry() throws {
        let items = try repeatedItems()
        XCTAssertNil(PreviewEpisodeIdentity.item(for: route(), in: items))
        let wanted = try XCTUnwrap(items.first { $0.guid == "new-guid" })
        XCTAssertEqual(PreviewEpisodeIdentity.item(for: route(date: wanted.publishedAt), in: items)?.guid, wanted.guid)
        XCTAssertEqual(PreviewEpisodeIdentity.item(for: route(), in: [wanted])?.guid, wanted.guid)
    }

    func testDuplicateGUIDRequiresUniqueEnclosureAndDuplicateEnclosureIsRejected() throws {
        var items = try repeatedItems()
        items[1].guid = items[0].guid
        XCTAssertNil(PreviewEpisodeIdentity.item(for: route(guid: items[0].guid), in: items))
        XCTAssertEqual(PreviewEpisodeIdentity.item(for: route(audioURL: items[1].audioURL, guid: items[0].guid), in: items)?.audioURL,
                       items[1].audioURL)
        items[1].audioURL = items[0].audioURL
        XCTAssertNil(PreviewEpisodeIdentity.item(for: route(audioURL: items[0].audioURL), in: items))
    }

    func testLibraryShowResolutionRequiresExactFeedAndRejectsAmbiguousTitle() {
        let first = Podcast(feedURL: "https://example.invalid/one.xml", title: "Repeated Show", author: "One",
                            summary: "", artworkURL: nil, category: "")
        let second = Podcast(feedURL: "https://example.invalid/two.xml", title: "Repeated Show", author: "Two",
                             summary: "", artworkURL: nil, category: "")
        let shows = [first, second]
        XCTAssertNil(PreviewEpisodeIdentity.podcast(for: route(feedURL: nil), resolvedFeedURL: nil, in: shows))
        XCTAssertNil(PreviewEpisodeIdentity.podcast(for: route(feedURL: nil, showID: 42), resolvedFeedURL: nil, in: [first]))
        XCTAssertTrue(PreviewEpisodeIdentity.podcast(for: route(feedURL: nil, showID: 42),
            resolvedFeedURL: second.feedURL, in: shows) === second)
        XCTAssertNil(PreviewEpisodeIdentity.podcast(for: route(feedURL: "https://example.invalid/missing.xml"),
            resolvedFeedURL: nil, in: [first]))
    }

    func testLibraryEpisodeResolutionUsesSameExactRulesAsFeedPreview() throws {
        let episodes = try repeatedItems().map(Episode.init(item:))
        let wanted = try XCTUnwrap(episodes.first { $0.guid == "new-guid" })
        XCTAssertNil(PreviewEpisodeIdentity.episode(for: route(), in: episodes))
        XCTAssertTrue(PreviewEpisodeIdentity.episode(for: route(guid: wanted.guid), in: episodes) === wanted)
    }

    func testFeedHTTPSAliasesPreservePathCaseWhileMediaIdentityStaysExact() throws {
        let show = Podcast(feedURL: "http://Example.Invalid/PrivateFeed.xml?account=one", title: "Repeated Show", author: "One",
                           summary: "", artworkURL: nil, category: "")
        let secure = "https://example.invalid/PrivateFeed.xml?account=one"
        XCTAssertTrue(PreviewEpisodeIdentity.podcast(for: route(feedURL: secure), resolvedFeedURL: nil, in: [show]) === show)
        XCTAssertNil(PreviewEpisodeIdentity.podcast(for: route(feedURL: "https://example.invalid/privatefeed.xml?account=one"),
            resolvedFeedURL: nil, in: [show]))
        XCTAssertNil(PreviewEpisodeIdentity.podcast(for: route(feedURL: "https://example.invalid/PrivateFeed.xml?account=two"),
            resolvedFeedURL: nil, in: [show]))
        let item = ParsedItem(guid: "exact", title: "Daily Update", audioURL: "http://example.invalid/episode.mp3")
        XCTAssertNil(PreviewEpisodeIdentity.item(for: route(audioURL: "https://example.invalid/episode.mp3"), in: [item]))
    }

    func testStationAppendDeduplicatesAndCompactsCollidingQueueOrders() throws {
        let container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let a = episode("A"), b = episode("B"), c = episode("C")
        for e in [a, b, c] { context.insert(e) }
        a.isInQueue = true; a.queueOrder = 4
        b.isInQueue = true; b.queueOrder = 4
        c.playbackPosition = 27
        try context.save()
        let planned = try StationQueue.enqueue([b, c, c], in: context, placement: .append, refreshDerivedState: false)
        XCTAssertEqual(planned.map(\.guid), ["A", "B", "C"])
        XCTAssertEqual(planned.map(\.queueOrder), [0, 1, 2])
        XCTAssertEqual(c.playbackPosition, 27)
        let repeatPlan = try StationQueue.enqueue([b, c], in: context, placement: .append, refreshDerivedState: false)
        XCTAssertEqual(repeatPlan.map(\.guid), planned.map(\.guid), "Repeated Queue All must be idempotent")
        let stored = try ModelContext(container).fetch(FetchDescriptor<Episode>(
            predicate: #Predicate { $0.isInQueue }, sortBy: [SortDescriptor(\.queueOrder)]))
        XCTAssertEqual(stored.map(\.guid), ["A", "B", "C"])
    }

    func testStationPlayAllKeepsVisibleFirstAndStationOrderAheadOfUnrelatedQueue() {
        let notDownloaded = episode("first-unavailable")
        let downloaded = episode("second-ready")
        downloaded.processingState = .ready
        let unrelated = episode("existing")
        let planned = StationQueue.plan(ordered: [notDownloaded, downloaded, downloaded],
                                        existing: [unrelated, downloaded], placement: .playFirst)
        XCTAssertTrue(planned.first === notDownloaded)
        XCTAssertEqual(planned.map(\.guid), ["first-unavailable", "second-ready", "existing"])
    }

    func testCatalogSuccessfulEmptyAndNoResultsFinishLoading() async {
        let loader = CatalogLoader<String>()
        await loader.load { [] }
        XCTAssertEqual(loader.state, .loaded)
        XCTAssertTrue(loader.items.isEmpty)
        await loader.load { throw PodcastSearch.SearchError.noResults }
        XCTAssertEqual(loader.state, .loaded)
        XCTAssertNil(loader.failure)
    }

    func testCatalogNetworkFailurePreservesSnapshotAndRetryCanRecover() async {
        let loader = CatalogLoader<String>()
        await loader.load { ["cached public show"] }
        await loader.load { throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(loader.items, ["cached public show"])
        XCTAssertNotNil(loader.failure)
        await loader.load { ["fresh public show"] }
        XCTAssertEqual(loader.items, ["fresh public show"])
        XCTAssertEqual(loader.state, .loaded)
        XCTAssertNil(loader.failure)
    }

    func testReplacedCatalogRequestCannotOverwriteNewResults() async {
        let loader = CatalogLoader<String>()
        let gate = CatalogGate()
        let old = Task { await loader.load { await gate.wait(); return ["old query"] } }
        await gate.waitUntilStarted()
        loader.reset()
        await loader.load { ["new query"] }
        await gate.release()
        await old.value
        XCTAssertEqual(loader.items, ["new query"])
        XCTAssertEqual(loader.state, .loaded)
    }

    func testCancelledCatalogRequestDoesNotPublishLateSuccessOrError() async {
        let loader = CatalogLoader<String>()
        await loader.load { ["cached"] }
        let gate = CatalogGate()
        let task = Task { await loader.load { await gate.wait(); return ["late response"] } }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.release()
        await task.value
        XCTAssertEqual(loader.items, ["cached"])
        XCTAssertEqual(loader.state, .loaded)
        XCTAssertNil(loader.failure)
    }

    private func episode(_ guid: String) -> Episode {
        Episode(guid: guid, title: guid, episodeDescription: "", audioURL: "https://example.invalid/\(guid).mp3",
                publishedAt: .now, duration: 600)
    }
}

private actor CatalogGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var didStart = false

    func wait() async {
        await withCheckedContinuation { continuation in
            waiter = continuation
            didStart = true
            started?.resume(); started = nil
        }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        waiter?.resume(); waiter = nil
    }
}
