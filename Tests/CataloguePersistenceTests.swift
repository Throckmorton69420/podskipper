import XCTest
import SwiftData
@testable import PodSkipper

@MainActor
final class CataloguePersistenceTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func library() throws -> ModelContainer {
        try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    private func show(in container: ModelContainer, name: String = "Show") throws -> Podcast {
        let show = Podcast(feedURL: "https://example.invalid/\(name).xml", title: name)
        show.lastRefreshed = date.addingTimeInterval(-100)
        container.mainContext.insert(show)
        try container.mainContext.save()
        return show
    }
    private func feed(_ count: Int) -> ParsedFeed {
        var feed = ParsedFeed(); feed.title = "Show"
        feed.items = (0..<count).map { number in
            var item = ParsedItem(); item.guid = "episode-\(number)"; item.title = "Episode \(number)"
            item.audioURL = "https://example.invalid/\(number).mp3"; item.publishedAt = date
            return item
        }
        return feed
    }
    private func episodes(in container: ModelContainer) throws -> [Episode] {
        try ModelContext(container).fetch(FetchDescriptor<Episode>())
    }
    private func savedShow(in container: ModelContainer) throws -> Podcast {
        try XCTUnwrap(ModelContext(container).fetch(FetchDescriptor<Podcast>()).first)
    }
    private enum Failure: Error { case disk }
    private final class Saver: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        let failAt: Int?
        let cancelAfter: Int?
        init(failAt: Int? = nil, cancelAfter: Int? = nil) { self.failAt = failAt; self.cancelAfter = cancelAfter }
        func save(_ context: ModelContext) throws {
            lock.lock(); calls += 1; let count = calls; lock.unlock()
            if count == failAt { throw Failure.disk }
            try context.save()
            if count == cancelAfter { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }

    func testFirstFailedSaveReportsNoIDsNoCompletionAndDoesNotDiscardMainEdits() async throws {
        let container = try library(), show = try show(in: container)
        show.title = "Unsaved user edit"
        let index = LibraryIndex(modelContainer: container), saver = Saver(failAt: 1)
        do { _ = try await index.merge(feed(3), into: show.persistentModelID, markComplete: true, save: saver.save); XCTFail() }
        catch let error as LibraryIndex.MergeFailure {
            XCTAssertEqual(error.committed.added, 0); XCTAssertTrue(error.committed.freshIDs.isEmpty)
        }
        XCTAssertTrue(try episodes(in: container).isEmpty)
        let stored = try savedShow(in: container)
        XCTAssertEqual(stored.lastRefreshed, date.addingTimeInterval(-100)); XCTAssertNil(stored.catalogueIndexedAt)
        XCTAssertEqual(show.title, "Unsaved user edit"); XCTAssertTrue(container.mainContext.hasChanges)
    }

    func testSuccessfulPrivateMergePreservesPendingMainEditsAndCompletionOnLaterSave() async throws {
        let container = try library(), show = try show(in: container)
        var original = feed(1).items[0]; original.guid = "original"
        let episode = Episode(item: original); episode.podcast = show
        container.mainContext.insert(episode); try container.mainContext.save()
        show.title = "Keep this title"; episode.playbackPosition = 35
        _ = try await LibraryIndex(modelContainer: container).merge(feed(51), into: show.persistentModelID, markComplete: true)
        XCTAssertEqual(show.title, "Keep this title"); XCTAssertEqual(episode.playbackPosition, 35)
        let beforeSave = try savedShow(in: container)
        print("CATALOGUE-CONFLICT before main save: mainMarker=\(String(describing: show.catalogueIndexedAt)), storedMarker=\(String(describing: beforeSave.catalogueIndexedAt)), mainEpisodes=\(show.episodes.count), storedEpisodes=\(beforeSave.episodes.count)")
        try container.mainContext.save()
        let stored = try savedShow(in: container)
        print("CATALOGUE-CONFLICT after main save: marker=\(String(describing: stored.catalogueIndexedAt)), relationships=\(stored.episodes.count)")
        XCTAssertEqual(stored.title, "Keep this title"); XCTAssertNotNil(stored.catalogueIndexedAt)
        XCTAssertEqual(try episodes(in: container).count, 52)
        XCTAssertEqual(try episodes(in: container).first { $0.guid == "original" }?.playbackPosition, 35)
    }

    func testPartialSaveKeepsOnlyDurableBatchAndRetryIsIdempotent() async throws {
        let container = try library(), show = try show(in: container)
        let index = LibraryIndex(modelContainer: container), saver = Saver(failAt: 2)
        do { _ = try await index.merge(feed(51), into: show.persistentModelID, markComplete: true, save: saver.save); XCTFail() }
        catch let error as LibraryIndex.MergeFailure {
            XCTAssertEqual(error.committed.added, 50); XCTAssertEqual(error.committed.freshIDs.count, 50)
            XCTAssertEqual(Set(error.committed.freshIDs), Set(try episodes(in: container).map(\.persistentModelID)))
        }
        XCTAssertEqual(try episodes(in: container).count, 50)
        XCTAssertNil(try savedShow(in: container).catalogueIndexedAt)
        let retry = try await index.merge(feed(51), into: show.persistentModelID, markComplete: true)
        XCTAssertEqual(retry.added, 1); XCTAssertEqual(retry.freshIDs.count, 1)
        XCTAssertEqual(try episodes(in: container).count, 51)
        XCTAssertNotNil(try savedShow(in: container).catalogueIndexedAt)
    }

    func testFinalMarkerFailureAfterFullBatchCanRetryWithoutReinsertingEpisodes() async throws {
        let container = try library(), show = try show(in: container)
        let index = LibraryIndex(modelContainer: container), saver = Saver(failAt: 2)
        do { _ = try await index.merge(feed(50), into: show.persistentModelID, markComplete: true, save: saver.save); XCTFail() }
        catch let error as LibraryIndex.MergeFailure { XCTAssertEqual(error.committed.added, 50) }
        XCTAssertNil(try savedShow(in: container).catalogueIndexedAt)
        let result = try await index.merge(feed(50), into: show.persistentModelID, markComplete: true)
        XCTAssertEqual(result.added, 0); XCTAssertTrue(result.freshIDs.isEmpty)
        XCTAssertNotNil(try savedShow(in: container).catalogueIndexedAt)
    }

    func testCancellationAfterSaveRetainsCheckpointWithoutCompletionMarker() async throws {
        let container = try library(), show = try show(in: container)
        let index = LibraryIndex(modelContainer: container), saver = Saver(cancelAfter: 1)
        let fixture = feed(51), id = show.persistentModelID
        let task = Task.detached { try await index.merge(fixture, into: id, markComplete: true, save: saver.save) }
        do { _ = try await task.value; XCTFail() }
        catch let error as LibraryIndex.MergeFailure {
            XCTAssertTrue(error.cause is CancellationError); XCTAssertEqual(error.committed.added, 50)
        }
        XCTAssertEqual(try episodes(in: container).count, 50)
        XCTAssertNil(try savedShow(in: container).catalogueIndexedAt)
    }

    func testAlreadyCancelledMergeWritesNothing() async throws {
        let container = try library(), show = try show(in: container)
        let index = LibraryIndex(modelContainer: container), fixture = feed(1), id = show.persistentModelID
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await index.merge(fixture, into: id, markComplete: true)
        }
        do { _ = try await task.value; XCTFail() }
        catch let error as LibraryIndex.MergeFailure { XCTAssertTrue(error.cause is CancellationError) }
        XCTAssertTrue(try episodes(in: container).isEmpty)
    }

    func testMissingShowThrowsInsteadOfReturningSuccessOrReadingFaultShell() async throws {
        let container = try library(), show = try show(in: container), id = show.persistentModelID
        container.mainContext.delete(show); try container.mainContext.save()
        do { _ = try await LibraryIndex(modelContainer: container).merge(feed(1), into: id, markComplete: true); XCTFail() }
        catch let error as LibraryIndex.MergeFailure {
            XCTAssertTrue(error.cause is LibraryIndex.CatalogueError); XCTAssertEqual(error.committed.added, 0)
        }
    }

    func testDuplicateGuidsAreNotInsertedOrMovedFromAnotherShow() async throws {
        let container = try library(), owner = try show(in: container, name: "Owner")
        let existing = Episode(item: feed(1).items[0]); existing.podcast = owner
        container.mainContext.insert(existing); try container.mainContext.save()
        let target = try show(in: container)
        var fixture = feed(2); fixture.items += fixture.items
        let result = try await LibraryIndex(modelContainer: container).merge(fixture, into: target.persistentModelID, markComplete: true)
        XCTAssertEqual(result.added, 1); XCTAssertEqual(try episodes(in: container).count, 2)
        XCTAssertEqual(try episodes(in: container).first { $0.guid == "episode-0" }?.podcast?.feedURL, owner.feedURL)
    }

    func testFailedFollowSaveRemovesOnlyItsUnsavedInsertionAndNeverCallsMerge() async throws {
        let container = try library(), existing = try show(in: container)
        existing.title = "Keep this edit"
        let following = Podcast(feedURL: "https://example.invalid/new.xml", title: "New")
        container.mainContext.insert(following)
        var merged = false
        do {
            try await EpisodeCatalogue.fill(following, from: feed(1), context: container.mainContext,
                save: { _ in throw Failure.disk }, merge: { _, _ in merged = true; return .init() })
            XCTFail()
        } catch is Failure { }
        XCTAssertFalse(merged); XCTAssertEqual(existing.title, "Keep this edit")
        XCTAssertTrue(following.isDeleted)
        try container.mainContext.save()
        let saved = try ModelContext(container).fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(saved.count, 1); XCTAssertEqual(saved.first?.title, "Keep this edit")
    }

    func testFailedFollowSaveNeverDeletesAnAlreadyPersistedShow() async throws {
        let container = try library(), existing = try show(in: container)
        existing.title = "Keep this pending edit"
        do {
            try await EpisodeCatalogue.fill(existing, from: feed(1), context: container.mainContext,
                save: { _ in throw Failure.disk }, merge: { _, _ in XCTFail(); return .init() })
            XCTFail()
        } catch is Failure { }
        XCTAssertFalse(existing.isDeleted)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertEqual(existing.title, "Keep this pending edit")
    }

    func testCancelledFollowRemovesUnsavedInsertionWithoutDiscardingOtherEdits() async throws {
        let container = try library(), existing = try show(in: container)
        existing.title = "Keep this pending edit"
        let following = Podcast(feedURL: "https://example.invalid/new.xml", title: "New")
        container.mainContext.insert(following)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await EpisodeCatalogue.fill(following, from: self.feed(1), context: container.mainContext,
                merge: { _, _ in XCTFail(); return .init() })
        }
        do { try await task.value; XCTFail() } catch is CancellationError { }
        try container.mainContext.save()
        let saved = try ModelContext(container).fetch(FetchDescriptor<Podcast>())
        XCTAssertEqual(saved.count, 1); XCTAssertEqual(saved.first?.title, "Keep this pending edit")
    }

    func testFollowMergeFailureLeavesPersistedShowAvailableForRetry() async throws {
        let container = try library()
        let following = Podcast(feedURL: "https://example.invalid/new.xml", title: "New")
        container.mainContext.insert(following)
        do {
            try await EpisodeCatalogue.fill(following, from: feed(1), context: container.mainContext,
                merge: { _, _ in throw Failure.disk })
            XCTFail()
        } catch is Failure { }
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<Podcast>()), 1)
        XCTAssertNil(following.catalogueIndexedAt)
    }

    private func catalog(_ guid: String, title: String = "Repeated", published: Date? = nil, audio: String? = nil) -> AppleCatalog.Item {
        AppleCatalog.Item(appleID: guid, guid: guid, title: title, published: published, duration: 123,
            audioURL: audio, videoStream: "https://example.invalid/video.m3u8", episodeNumber: 0,
            summary: "", artworkURL: nil, isExplicit: false, kind: "full")
    }

    func testCatalogFailedSaveRollsBackMetadataAndNewEpisodes() async throws {
        let container = try library(), show = try show(in: container)
        let local = Episode(item: feed(1).items[0]); local.podcast = show
        container.mainContext.insert(local); try container.mainContext.save()
        let saver = Saver(failAt: 1)
        do {
            _ = try await LibraryIndex(modelContainer: container).mergeCatalog([
                catalog(local.guid), catalog("new", audio: "https://example.invalid/new.mp3")],
                into: show.persistentModelID, save: saver.save)
            XCTFail()
        } catch let error as LibraryIndex.MergeFailure { XCTAssertEqual(error.committed.added, 0) }
        let stored = try XCTUnwrap(episodes(in: container).first)
        XCTAssertNil(stored.publicVideoURL); XCTAssertEqual(stored.cleanDuration, 0)
        XCTAssertEqual(try episodes(in: container).count, 1)
    }

    func testRepeatedCatalogTitleDoesNotCopyVideoOrDurationIntoArbitraryEpisode() async throws {
        let container = try library(), show = try show(in: container)
        var fixture = feed(2); fixture.items[0].title = "Repeated"; fixture.items[1].title = "Repeated"
        for item in fixture.items { let episode = Episode(item: item); episode.podcast = show; container.mainContext.insert(episode) }
        try container.mainContext.save()
        let result = try await LibraryIndex(modelContainer: container).mergeCatalog([catalog("rewritten", published: date)], into: show.persistentModelID)
        XCTAssertEqual(result.added, 0)
        XCTAssertTrue(try episodes(in: container).allSatisfy { $0.publicVideoURL == nil && $0.cleanDuration == 0 })
    }

    func testCatalogGuidWinsAndUniqueTitleRequiresMatchingDateOrAudio() async throws {
        let container = try library(), show = try show(in: container)
        let local = Episode(item: feed(1).items[0]); local.podcast = show
        container.mainContext.insert(local); try container.mainContext.save()
        let index = LibraryIndex(modelContainer: container)
        _ = try await index.mergeCatalog([catalog("unknown", title: local.title, published: date.addingTimeInterval(-3600))], into: show.persistentModelID)
        XCTAssertNil(try episodes(in: container).first?.publicVideoURL)
        _ = try await index.mergeCatalog([catalog("rewritten", title: local.title, published: date)], into: show.persistentModelID)
        XCTAssertEqual(try episodes(in: container).first?.cleanDuration, 123)
        _ = try await index.mergeCatalog([catalog(local.guid, title: "Different title")], into: show.persistentModelID)
        XCTAssertEqual(try episodes(in: container).count, 1)
    }

    func testIndexSeesCommittedMarkerFromAnotherContext() async throws {
        let container = try library(), show = try show(in: container)
        let index = LibraryIndex(modelContainer: container)
        let before = await index.unindexedShows(); XCTAssertEqual(before.count, 1)
        let writer = ModelContext(container); writer.autosaveEnabled = false
        let saved = try XCTUnwrap(writer.fetch(FetchDescriptor<Podcast>()).first)
        XCTAssertEqual(saved.persistentModelID, show.persistentModelID)
        saved.catalogueIndexedAt = .now; try writer.save()
        let after = await index.unindexedShows(); XCTAssertTrue(after.isEmpty)
        let summary = await index.indexedSummary(); XCTAssertEqual(summary.indexed, 1)
    }
}
