import XCTest
import SwiftData
@testable import PodSkipper

/// Pass 33: the "Library Recovery — SwiftDataError error 1" screen (his 9 Oct
/// screenshot). Every test here works on a throwaway store in a temporary
/// folder, never on a real library.
@MainActor
final class Pass33StoreTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pass33-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var storeURL: URL { folder.appendingPathComponent("library.store") }

    private func fullContainer() throws -> ModelContainer {
        let config = ModelConfiguration(schema: LibraryStore.schema, url: storeURL)
        return try ModelContainer(for: LibraryStore.schema, configurations: [config])
    }

    /// The hazard this pass removes. Before Pass 33 an App Intent that ran
    /// before the app had published its library opened the same store with
    /// only Podcast, Episode and AdSegment. This test shows what such an open
    /// does to a store that has bookmarks, listening history and stations.
    func testOpeningTheStoreWithASmallerSchemaLosesTheOtherTables() throws {
        do {
            let container = try fullContainer()
            let context = container.mainContext
            let podcast = Podcast(feedURL: "https://example.com/feed", title: "Show")
            let episode = Episode(guid: "g1", title: "One", episodeDescription: "", audioURL: "https://example.com/1.mp3", publishedAt: .now, duration: 60)
            context.insert(podcast)
            context.insert(episode)
            episode.podcast = podcast
            context.insert(Bookmark(timestamp: 12, episode: episode))
            context.insert(ListeningSession(seconds: 30))
            context.insert(SmartFilter(name: "Commute"))
            try context.save()
        }
        do {
            // What `AppLibrary.resolvedContext()` used to do, against this store.
            let small = Schema([Podcast.self, Episode.self, AdSegment.self])
            let config = ModelConfiguration(schema: small, url: storeURL)
            let container = try ModelContainer(for: small, configurations: [config])
            _ = try container.mainContext.fetchCount(FetchDescriptor<Episode>())
        }
        let container = try fullContainer()
        let context = container.mainContext
        let episodes = try context.fetchCount(FetchDescriptor<Episode>())
        let bookmarks = try context.fetchCount(FetchDescriptor<Bookmark>())
        let sessions = try context.fetchCount(FetchDescriptor<ListeningSession>())
        let stations = try context.fetchCount(FetchDescriptor<SmartFilter>())
        // Measured on the iOS 27 simulator: the smaller open is a migration
        // that drops the three models it doesn't name (Core Data logs
        // "entities being removed"). This is why nothing may open the
        // library with anything but `LibraryStore.schema`.
        XCTAssertEqual(episodes, 1)
        XCTAssertEqual(bookmarks, 0)
        XCTAssertEqual(sessions, 0)
        XCTAssertEqual(stations, 0)
    }

    /// Every container the app makes uses the one full schema.
    func testTheAppHasOneFullSchema() {
        let names = Set(LibraryStore.schema.entities.map(\.name))
        XCTAssertEqual(names, ["Podcast", "Episode", "AdSegment", "Bookmark", "Chapter",
                               "ListeningSession", "SmartFilter"])
    }

    /// A failed open says what failed: stage, store file, the real error
    /// (not "error 1"), and leaves the store where it was.
    func testAFailedOpenReportsTheRealErrorAndKeepsTheStore() throws {
        // A directory where the store file should be cannot be opened as SQLite.
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        let marker = storeURL.appendingPathComponent("keep-me")
        try Data("x".utf8).write(to: marker)

        let result = LibraryStore.openContainer(at: storeURL)
        guard case .failure(let failure) = result else {
            return XCTFail("A directory cannot be opened as a store")
        }
        XCTAssertEqual(failure.stage, .container)
        XCTAssertEqual(failure.storePath, storeURL.path)
        XCTAssertFalse(failure.detail.isEmpty)
        XCTAssertFalse(failure.detail == "The operation couldn’t be completed. (SwiftData.SwiftDataError error 1.)",
                       "The report must carry more than the bridged code")
        XCTAssertTrue(failure.report.contains("library.store"))
        // Nothing was deleted or replaced.
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    /// Two callers asking at the same moment get the same container: the
    /// store is never opened twice in one process.
    func testConcurrentRequestsShareOneOpen() async throws {
        let store = LibraryStore(url: storeURL)
        async let a = store.container()
        async let b = store.container()
        let (first, second) = try await (a, b)
        XCTAssertTrue(first === second)
        XCTAssertEqual(store.openCount, 1)
    }

    /// A failed open is not cached forever: Try Again really tries again.
    func testTryAgainOpensAfterAFailureClears() async throws {
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        let store = LibraryStore(url: storeURL)
        do {
            _ = try await store.container()
            XCTFail("Should fail while a folder is in the way")
        } catch {}
        try FileManager.default.removeItem(at: storeURL)
        let container = try await store.container()
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Episode>()), 0)
        XCTAssertEqual(store.openCount, 2)
    }
}
