import XCTest
import SwiftData
@testable import PodSkipper

/// Pass 58 (L21): catalogue merges whose saves fail say so, store nothing
/// half-way, don't mark the show complete, and leave listening edits alone.
@MainActor
final class Pass58CatalogueSaveTests: XCTestCase {
    private let feedURL = "https://example.invalid/catalogue.xml"
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("p58-catalogue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                   ofItemAtPath: folder.appendingPathComponent(name).path)
        }
        try? FileManager.default.removeItem(at: folder)
    }

    private var storeURL: URL { folder.appendingPathComponent("library.store") }

    private func container(allowsSave: Bool = true) throws -> ModelContainer {
        try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self,
                           configurations: ModelConfiguration(url: storeURL, allowsSave: allowsSave))
    }

    private func item(_ guid: String, title: String? = nil, daysAgo: Double, video: String? = nil) -> ParsedItem {
        var item = ParsedItem()
        item.guid = guid
        item.title = title ?? guid
        item.audioURL = "https://example.invalid/\(guid).mp3"
        item.publishedAt = Date.now.addingTimeInterval(-daysAgo * 86_400)
        item.duration = 1_800
        item.videoURL = video
        return item
    }

    /// A show already refreshed once (so new episodes count as fresh).
    @discardableResult
    private func seedShow(in container: ModelContainer, episodes: [(String, String)] = []) throws -> PersistentIdentifier {
        let context = ModelContext(container)
        let show = Podcast(feedURL: feedURL, title: "Catalogue Show")
        show.lastRefreshed = Date.now.addingTimeInterval(-3 * 86_400)
        context.insert(show)
        for (guid, title) in episodes {
            let e = Episode(guid: guid, title: title, episodeDescription: "", audioURL: "https://example.invalid/\(guid).mp3",
                            publishedAt: Date.now.addingTimeInterval(-30 * 86_400), duration: 1_800)
            context.insert(e)
            e.podcast = show
        }
        try context.save()
        return show.persistentModelID
    }

    private func showID(in container: ModelContainer) throws -> PersistentIdentifier {
        let address = feedURL
        return try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == address })).first)
            .persistentModelID
    }

    /// Makes the store's files unwritable, so SQLite refuses every write.
    private func lockStore() throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o444],
                                                  ofItemAtPath: folder.appendingPathComponent(name).path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    }

    func testFailedSaveIsReportedAndNothingIsMarkedComplete() async throws {
        let writable = try container()
        try seedShow(in: writable)
        try lockStore()
        let locked = try container()
        let index = LibraryIndex(modelContainer: locked)
        var feed = ParsedFeed()
        feed.title = "Catalogue Show"
        feed.items = (0..<120).map { item("g\($0)", daysAgo: Double($0) / 10) }

        let result = await index.merge(feed, into: try showID(in: locked), markComplete: true)

        XCTAssertNotNil(result.saveError, "a refused write must not pass as done")
        XCTAssertEqual(result.added, 0)
        XCTAssertTrue(result.freshIDs.isEmpty, "fresh IDs would name episodes that were never stored")
        let check = ModelContext(locked)
        XCTAssertEqual(try check.fetchCount(FetchDescriptor<Episode>()), 0)
        XCTAssertNil(try check.fetch(FetchDescriptor<Podcast>()).first?.catalogueIndexedAt)
    }

    func testRetryAfterAFailedSaveStoresEverything() async throws {
        let writable = try container()
        try seedShow(in: writable)
        var feed = ParsedFeed()
        feed.items = (0..<120).map { item("g\($0)", daysAgo: Double($0) / 100) }
        try lockStore()
        do {
            let locked = try container()
            let failed = await LibraryIndex(modelContainer: locked).merge(feed, into: try showID(in: locked), markComplete: true)
            XCTAssertNotNil(failed.saveError)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.appendingPathComponent(name).path)
        }
        let again = try container()
        let result = await LibraryIndex(modelContainer: again).merge(feed, into: try showID(in: again), markComplete: true)

        XCTAssertNil(result.saveError)
        XCTAssertEqual(result.added, 120)
        XCTAssertEqual(result.freshIDs.count, 120)
        let check = ModelContext(again)
        XCTAssertEqual(try check.fetchCount(FetchDescriptor<Episode>()), 120)
        XCTAssertNotNil(try check.fetch(FetchDescriptor<Podcast>()).first?.catalogueIndexedAt)
    }

    /// A listening position changed on the main context, saved before or
    /// after a merge that touched the same episode, survives with the
    /// merge's own changes.
    func testListeningEditsSurviveACatalogueMerge() async throws {
        let library = try container()
        let id = try seedShow(in: library, episodes: [("e1", "First"), ("e2", "Second")])
        let main = library.mainContext
        let episodes = try main.fetch(FetchDescriptor<Episode>(sortBy: [SortDescriptor(\.guid)]))
        episodes[0].playbackPosition = 120          // pending, saved after the merge
        episodes[1].playbackPosition = 300
        try main.save()
        episodes[1].isStarred = true                // pending again

        var feed = ParsedFeed()
        feed.items = [item("e1", title: "First", daysAgo: 30, video: "https://example.invalid/e1.m3u8"),
                      item("e2", title: "Second", daysAgo: 30, video: "https://example.invalid/e2.m3u8"),
                      item("e3", daysAgo: 0.5)]
        let index = LibraryIndex(modelContainer: library)
        let result = await index.merge(feed, into: id, markComplete: true)
        XCTAssertNil(result.saveError)
        try main.save()
        // Measured (Pass 58): the main context's save of an episode with a
        // pending edit writes back that episode's old details. The next
        // refresh must put them back.
        let again = await index.merge(feed, into: id, markComplete: true)
        XCTAssertNil(again.saveError)

        let check = ModelContext(library)
        let stored = try check.fetch(FetchDescriptor<Episode>(sortBy: [SortDescriptor(\.guid)]))
        XCTAssertEqual(stored.map(\.guid), ["e1", "e2", "e3"])
        XCTAssertEqual(stored[0].playbackPosition, 120)
        XCTAssertEqual(stored[1].playbackPosition, 300)
        XCTAssertTrue(stored[1].isStarred)
        XCTAssertEqual(stored[0].videoURL, "https://example.invalid/e1.m3u8")
        XCTAssertEqual(stored[1].videoURL, "https://example.invalid/e2.m3u8")
        XCTAssertEqual(stored[2].podcast?.feedURL, feedURL)
    }

    /// The actor's context outlives a merge. An episode it loaded before you
    /// listened must not carry its old position back into the store when a
    /// later refresh changes that episode's details.
    func testLaterMergeDoesNotRevertListeningSavedMeanwhile() async throws {
        let library = try container()
        let id = try seedShow(in: library, episodes: [("e1", "First")])
        let index = LibraryIndex(modelContainer: library)
        var feed = ParsedFeed()
        feed.items = [item("e1", title: "First", daysAgo: 30)]
        _ = await index.merge(feed, into: id, markComplete: true)      // e1 now loaded in the actor's context

        let main = library.mainContext
        let e1 = try XCTUnwrap(main.fetch(FetchDescriptor<Episode>()).first)
        e1.playbackPosition = 1_200
        e1.isPlayed = true
        try main.save()

        feed.items = [item("e1", title: "First", daysAgo: 30, video: "https://example.invalid/e1.m3u8")]
        let result = await index.merge(feed, into: id, markComplete: true)
        XCTAssertNil(result.saveError)

        let check = ModelContext(library)
        let stored = try XCTUnwrap(check.fetch(FetchDescriptor<Episode>()).first)
        XCTAssertEqual(stored.playbackPosition, 1_200, "a refresh must never put back an old listening position")
        XCTAssertTrue(stored.isPlayed)
        XCTAssertEqual(stored.videoURL, "https://example.invalid/e1.m3u8")
    }

    /// Apple's catalog: a title stands in for a guid only when it names one
    /// episode on each side.
    func testAppleCatalogMatchesTitlesOnlyWhenUnique() async throws {
        let library = try container()
        let id = try seedShow(in: library, episodes: [("u1", "Unique Title"), ("r1", "Best Of"), ("r2", "Best Of")])
        func apple(_ guid: String, _ title: String, duration: Double) -> AppleCatalog.Item {
            AppleCatalog.Item(appleID: guid, guid: guid, title: title, published: Date.now.addingTimeInterval(-400 * 86_400),
                              duration: duration, audioURL: "https://example.invalid/\(guid).mp3", videoStream: nil,
                              episodeNumber: 0, summary: "", artworkURL: nil, isExplicit: false, kind: "full")
        }
        let result = await LibraryIndex(modelContainer: library).mergeCatalog(
            [apple("apple-u", "Unique Title", duration: 1_500), apple("apple-b", "Best Of", duration: 999)], into: id)

        XCTAssertNil(result.saveError)
        let check = ModelContext(library)
        let byGuid = Dictionary(uniqueKeysWithValues: try check.fetch(FetchDescriptor<Episode>()).map { ($0.guid, $0) })
        XCTAssertEqual(byGuid["u1"]?.cleanDuration, 1_500, "a unique title still links Apple's item to the feed's episode")
        XCTAssertNotEqual(byGuid["r1"]?.cleanDuration, 999, "a repeated title must not pick one of the two")
        XCTAssertNotEqual(byGuid["r2"]?.cleanDuration, 999)
        XCTAssertNotNil(byGuid["apple-b"], "the unmatched older episode is added instead")
        XCTAssertEqual(result.added, 1)
    }
}

/// Pass 58: saves that used to be `try?` report a failure instead of
/// dropping it.
@MainActor
final class Pass58SaveOrReportTests: XCTestCase {
    func testFailedSaveIsRecordedOncePerPlaceAndShownWhileRecent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("p58-saves-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let url = folder.appendingPathComponent("s.store")
        let writable = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self,
                                          configurations: ModelConfiguration(url: url))
        let ok = ModelContext(writable)
        ok.insert(Podcast(feedURL: "https://example.invalid/s.xml", title: "S"))
        XCTAssertTrue(ok.saveOrReport())

        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: folder.appendingPathComponent(name).path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let locked = ModelContext(try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self,
                                                     configurations: ModelConfiguration(url: url)))
        let before = StoreSaveProblems.shared.count
        locked.insert(Podcast(feedURL: "https://example.invalid/t.xml", title: "T"))
        XCTAssertFalse(locked.saveOrReport())
        let place = "Test-\(UUID().uuidString).swift:1"
        StoreSaveProblems.shared.record("disk full", at: place)
        StoreSaveProblems.shared.record("disk full", at: place)
        XCTAssertEqual(StoreSaveProblems.shared.count, before + 2)
        XCTAssertTrue(StoreSaveProblems.shared.isRecent)
        let lines = BackgroundLog.shared.events.filter { $0.text.contains("(\(place))") }
        XCTAssertEqual(lines.count, 1, "one log line per place per ten minutes")
    }
}

/// Pass 58: publishing's request signing against AWS's own SigV4 test suite
/// ("get-vanilla"), so a change to the signer can't silently break uploads.
final class Pass58SigningTests: XCTestCase {
    func testSignatureMatchesAWSGetVanillaVector() {
        let auth = R2Uploader.authorization(
            method: "GET", canonicalURI: "/", canonicalQuery: "",
            headers: ["host": "example.amazonaws.com", "x-amz-date": "20150830T123600Z"],
            payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            amzDate: "20150830T123600Z", region: "us-east-1", service: "service",
            accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
        XCTAssertEqual(auth, "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
                       + "SignedHeaders=host;x-amz-date, "
                       + "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }
}
