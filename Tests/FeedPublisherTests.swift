import XCTest
import SwiftData
@testable import PodSkipper

@MainActor
final class FeedPublisherTests: XCTestCase {
    private var folder: URL!
    private var container: ModelContainer!
    private var show: Podcast!
    private var downloads = 0
    private var cuts: [[ClosedRange<Double>]] = []
    private var fileKeys: [String] = []
    private var feeds: [(key: String, xml: String)] = []
    private var failFeed = false
    private var afterCut: (@MainActor () -> Void)?
    private var uploadWaiter: CheckedContinuation<Void, Never>?
    private var delayUpload = false

    override func setUpWithError() throws {
        folder = URL.temporaryDirectory.appending(path: "FeedPublisherTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        show = Podcast(feedURL: "https://example.invalid/show.xml", title: "Original Title")
        container.mainContext.insert(show)
    }
    override func tearDown() {
        uploadWaiter?.resume(); uploadWaiter = nil
        try? FileManager.default.removeItem(at: folder)
        container = nil; super.tearDown()
    }
    private func episode(_ guid: String) -> Episode {
        let episode = Episode(guid: guid, title: guid, episodeDescription: "", audioURL: "https://example.invalid/\(guid).mp3",
                              publishedAt: .now, duration: 60)
        container.mainContext.insert(episode); episode.podcast = show; episode.processingState = .ready
        return episode
    }
    private func publisher() -> FeedPublisher {
        let operations = FeedPublisher.Operations(workingDirectory: folder, credentials: {
            .init(accountID: "unused", accessKeyID: "unused", secretAccessKey: "unused", bucket: "unused",
                  publicBaseURL: "https://example.invalid/public")
        }, download: { episode in
            self.downloads += 1
            return self.folder.appending(path: "original-" + episode.guid)
        }, cut: { _, ranges, url in
            self.cuts.append(ranges)
            try Data("cut audio".utf8).write(to: url)
            self.afterCut?()
            return .init(url: url, duration: 50, byteCount: 9, secondsRemoved: 10)
        }, uploadFile: { _, key in
            self.fileKeys.append(key)
            if self.delayUpload { await withCheckedContinuation { self.uploadWaiter = $0 } }
            return URL(string: "https://example.invalid/public/" + key)!
        }, uploadFeed: { data, key in
            self.feeds.append((key, String(decoding: data, as: UTF8.self)))
            if self.failFeed { throw URLError(.networkConnectionLost) }
            return URL(string: "https://example.invalid/public/" + key)!
        })
        let publisher = FeedPublisher(operations: operations)
        publisher.configure(context: container.mainContext)
        return publisher
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition())
    }

    func testBatchDedupPreservesEarlierEpisodesAndRenameKeepsFeedURL() async throws {
        let a = episode("a"), b = episode("b")
        b.publishedURL = "https://example.invalid/earlier.m4a"
        b.publishedAdVersion = b.adSegmentsFingerprint
        b.publishedDuration = 60; b.publishedByteCount = 99
        let publisher = publisher()
        let first = try await publisher.publish(show, only: [a, a])
        XCTAssertEqual(first.episodesPublished, 1); XCTAssertEqual(first.episodesInFeed, 2)
        XCTAssertEqual(fileKeys.count, 1)
        XCTAssertEqual(feeds.first?.xml.components(separatedBy: "<item>").count, 3)
        let feed = first.feedURL
        show.title = "Renamed"
        let second = try await publisher.publish(show, only: [a])
        XCTAssertEqual(second.feedURL, feed)
        XCTAssertEqual(second.episodesPublished, 0); XCTAssertEqual(second.episodesAlreadyUp, 1)
        XCTAssertEqual(fileKeys.count, 1); XCTAssertEqual(feeds[0].key, feeds[1].key)
    }

    func testFailedFeedUpdateReusesCompletedAudioUploadOnRetry() async throws {
        let a = episode("a"), publisher = publisher()
        failFeed = true
        do { _ = try await publisher.publish(show, only: [a]); XCTFail("Expected interrupted feed update") }
        catch { XCTAssertTrue(NetworkStatus.isConnectivity(error)) }
        XCTAssertNotNil(a.publishedURL); XCTAssertNil(show.publishedFeedURL)
        failFeed = false
        let retry = try await publisher.publish(show, only: [a])
        XCTAssertEqual(downloads, 1); XCTAssertEqual(cuts.count, 1); XCTAssertEqual(fileKeys.count, 1)
        XCTAssertEqual(retry.episodesAlreadyUp, 1); XCTAssertEqual(feeds[0].key, feeds[1].key)
    }

    func testRejectedCorrectionChangesAudioIdentityAndLeavesPriorObjectKeyUntouched() async throws {
        let a = episode("a")
        let ad = AdSegment(start: 10, end: 20)
        container.mainContext.insert(ad); ad.episode = a; a.adSegments = [ad]
        let publisher = publisher()
        _ = try await publisher.publish(show, only: [a])
        let previousURL = a.publishedURL
        ad.userVerdict = .notAnAd
        _ = try await publisher.publish(show, only: [a])
        XCTAssertEqual(cuts, [[10...20], []])
        XCTAssertNotEqual(fileKeys[0], fileKeys[1])
        XCTAssertNotEqual(a.publishedURL, previousURL)
        XCTAssertEqual(feeds[0].key, feeds[1].key)
    }

    func testCancellationImmediatelyAfterUploadRejectsLateSuccessAndRetryUsesSameKey() async throws {
        let a = episode("a"), publisher = publisher()
        delayUpload = true
        let task = Task { try await publisher.publish(show, only: [a]) }
        try await waitUntil { uploadWaiter != nil }
        task.cancel(); uploadWaiter?.resume(); uploadWaiter = nil
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(a.publishedURL); XCTAssertNil(show.publishedFeedURL); XCTAssertTrue(feeds.isEmpty)
        XCTAssertFalse(publisher.isPublishing)
        delayUpload = false
        _ = try await publisher.publish(show, only: [a])
        XCTAssertEqual(fileKeys.count, 2); XCTAssertEqual(fileKeys[0], fileKeys[1])
    }

    func testCorrectionsChangingDuringCutCannotBeRecordedAsNewAudio() async throws {
        let a = episode("a")
        let ad = AdSegment(start: 10, end: 20)
        container.mainContext.insert(ad); ad.episode = a; a.adSegments = [ad]
        let publisher = publisher()
        afterCut = { ad.userVerdict = .notAnAd }
        do { _ = try await publisher.publish(show, only: [a]); XCTFail("Expected correction change failure") }
        catch { XCTAssertTrue(error is FeedPublisher.PublishError) }
        XCTAssertTrue(fileKeys.isEmpty); XCTAssertTrue(feeds.isEmpty); XCTAssertNil(a.publishedURL)
    }

    func testFailedRemovalPreservesLocalFeedMembershipUntilServerAcceptsIt() async throws {
        let a = episode("a"), b = episode("b")
        a.publishedURL = "https://example.invalid/a.m4a"; b.publishedURL = "https://example.invalid/b.m4a"
        show.publishedFeedURL = "https://example.invalid/public/feeds/legacy-title-key.xml"
        let publisher = publisher()
        failFeed = true
        do { try await publisher.removeFromFeed([a], of: show); XCTFail("Expected failed feed removal") }
        catch { XCTAssertTrue(NetworkStatus.isConnectivity(error)) }
        XCTAssertNotNil(a.publishedURL); XCTAssertNotNil(b.publishedURL)
        failFeed = false
        try await publisher.removeFromFeed([a], of: show)
        XCTAssertNil(a.publishedURL); XCTAssertNotNil(b.publishedURL)
        XCTAssertEqual(feeds[0].key, "feeds/legacy-title-key.xml")
        XCTAssertEqual(feeds[1].xml.components(separatedBy: "<item>").count, 2)
    }
}
