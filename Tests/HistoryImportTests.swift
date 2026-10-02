import XCTest
import SwiftData
@testable import PodSkipper

@MainActor
final class HistoryImportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let feed = "https://example.invalid/Show.xml"

    private func data(_ rows: [[String: Any]], version: Any = 3,
                      format: String = HistoryImport.format,
                      shows: [[String: Any]] = []) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["format": format, "version": version,
                                                    "shows": shows, "episodes": rows])
    }
    private func row(_ guid: String, title: String? = nil, feedURL: String? = nil,
                     played: Int = 0, position: Double = 0, date: Double? = nil,
                     source: Int? = nil, count: Int? = nil, marked: Double? = nil,
                     saved: Int = 0) -> [String: Any] {
        var row: [String: Any] = ["feedURL": feedURL ?? feed, "guid": guid, "played": played,
                                 "playhead": position, "saved": saved]
        if let title { row["title"] = title }
        if let date { row["lastPlayed"] = date }
        if let source { row["playStateSource"] = source }
        if let count { row["playCount"] = count }
        if let marked { row["lastUserMarkedPlayed"] = marked }
        return row
    }
    private func library() throws -> ModelContainer {
        try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }
    @discardableResult
    private func episode(_ guid: String, title: String = "Episode", feedURL: String? = nil,
                         in container: ModelContainer) -> Episode {
        let context = container.mainContext
        let address = feedURL ?? feed
        let existing = (try? context.fetch(FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == address })))?.first
        let show = existing ?? Podcast(feedURL: address, title: "Show")
        if existing == nil {
            show.dateAdded = now.addingTimeInterval(-1_000_000)
            context.insert(show)
        }
        let e = Episode(guid: guid, title: title, episodeDescription: "", audioURL: "https://example.invalid/a.mp3",
                        publishedAt: now.addingTimeInterval(-100), duration: 100)
        context.insert(e); e.podcast = show; e.isNew = true
        return e
    }
    private struct Snapshot: Equatable {
        var played: Bool
        var position: Double
        var last: Date?
        var new: Bool
        var starred: Bool
        var queued: Bool
    }
    private func snapshot(_ guid: String, in container: ModelContainer) throws -> Snapshot {
        let context = ModelContext(container)
        let e = try XCTUnwrap(context.fetch(FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })).first)
        return Snapshot(played: e.isPlayed, position: e.playbackPosition, last: e.lastPlayedAt,
                        new: e.isNew, starred: e.isStarred, queued: e.isInQueue)
    }

    func testURLCanonicalizationPreservesCaseSensitivePathsQueriesAndNonRootSlashes() {
        XCTAssertEqual(HistoryImport.normal("HTTP://EXAMPLE.INVALID:80/Show.xml?token=AbC#ignored"),
                       "https://example.invalid/Show.xml?token=AbC")
        XCTAssertEqual(HistoryImport.normal("https://EXAMPLE.INVALID:443/"), "https://example.invalid")
        XCTAssertNotEqual(HistoryImport.normal(feed), HistoryImport.normal("https://example.invalid/show.xml"))
        XCTAssertNotEqual(HistoryImport.normal("https://example.invalid/Show/"), HistoryImport.normal("https://example.invalid/Show"))
        XCTAssertNotEqual(HistoryImport.normal("https://example.invalid/Show?token=AbC"), HistoryImport.normal("https://example.invalid/Show?token=abc"))
        XCTAssertEqual(HistoryImport.normal("file:///private/data"), "")
        XCTAssertEqual(HistoryImport.normal("not a feed"), "")
    }

    func testUnsupportedOrMissingVersionsAndWrongFormatFailBeforeFollowingAnyFeed() async throws {
        let container = try library()
        var requests = 0
        let shows: [[String: Any]] = [["feedURL": feed, "subscribed": 1]]
        for (version, format) in [(0 as Any, HistoryImport.format), (4 as Any, HistoryImport.format),
                                  (NSNull() as Any, HistoryImport.format), (3 as Any, "something-else")] {
            let archive = try data([], version: version, format: format, shows: shows)
            XCTAssertFalse(HistoryImport.isHistoryFile(archive))
            do {
                _ = try await HistoryImport.importData(archive, into: container.mainContext, fetchFeed: { _ in
                    requests += 1
                    return ParsedFeed()
                })
                XCTFail("Invalid metadata must reject the entire import")
            } catch is HistoryImport.ImportError { }
        }
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Podcast>()), 0)
        for version in 1...3 { XCTAssertTrue(HistoryImport.isHistoryFile(try data([], version: version))) }
    }

    func testMissingShowFeedFailureIsReportedBeforeApplyingHistory() async throws {
        let container = try library()
        episode("existing", in: container); try container.mainContext.save()
        let archive = try data([row("existing", played: 1, count: 1)],
            shows: [["feedURL": "https://example.invalid/Missing.xml", "subscribed": 1]])
        do {
            _ = try await HistoryImport.importData(archive, into: container.mainContext,
                fetchFeed: { _ in throw URLError(.notConnectedToInternet) })
            XCTFail("A missing catalogue must not be silently omitted from a successful import")
        } catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
        XCTAssertFalse(try snapshot("existing", in: container).played)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Podcast>()), 1)
    }

    func testSourceSixDefaultsDoNotManufacturePlayedLastPlayedOrNewCutoffs() async throws {
        let container = try library()
        episode("default", in: container)
        try container.mainContext.save()
        let file = try HistoryImport.decode(data([row("default", played: 1, date: now.timeIntervalSince1970,
                                                       source: 6, count: 0)]))
        let index = LibraryIndex(modelContainer: container)
        let result = try await index.applyHistory(file, now: now)
        let value = try snapshot("default", in: container)
        XCTAssertFalse(value.played); XCTAssertNil(value.last); XCTAssertTrue(value.new)
        XCTAssertEqual(result.markedPlayed, 0)
        let counts = await index.computeCounts()
        XCTAssertNil(counts.perShow[feed]?.latestListenedPublishedAt)
    }

    func testExplicitMarkedPlayedIsPreservedWithoutInventingAListeningDate() async throws {
        let container = try library()
        let local = episode("local", in: container)
        local.isPlayed = true; local.isNew = false; local.isInQueue = true
        episode("marked", in: container)
        try container.mainContext.save()
        let file = try HistoryImport.decode(data([
            row("local", date: now.timeIntervalSince1970, source: 6),
            row("marked", played: 1, date: now.timeIntervalSince1970, source: 6, marked: now.timeIntervalSince1970 - 100)
        ]))
        let result = try await LibraryIndex(modelContainer: container).applyHistory(file, now: now)
        XCTAssertEqual(result.markedPlayed, 1); XCTAssertEqual(result.markedUnplayed, 0)
        XCTAssertTrue(try snapshot("local", in: container).played)
        XCTAssertTrue(try snapshot("local", in: container).queued, "A default row must not alter the local queue choice")
        let marked = try snapshot("marked", in: container)
        XCTAssertTrue(marked.played); XCTAssertNil(marked.last); XCTAssertFalse(marked.new)
    }

    func testDefaultPlayedEndPositionsAreNotPartialListeningAndPreserveLocalPlayedChoices() async throws {
        let container = try library()
        episode("default", in: container)
        let local = episode("local", in: container)
        local.isPlayed = true; local.isNew = false
        try container.mainContext.save()
        let file = try HistoryImport.decode(data([
            row("default", played: 1, position: 99, date: now.timeIntervalSince1970, source: 6, count: 0),
            row("default", played: 1, position: 100, date: now.timeIntervalSince1970, source: 6, count: 0),
            row("local", played: 1, position: 100, date: now.timeIntervalSince1970, source: 6, count: 0)
        ]))
        let result = try await LibraryIndex(modelContainer: container).applyHistory(file, now: now)
        XCTAssertEqual(result.markedPlayed, 0); XCTAssertEqual(result.resumePoints, 0)
        let value = try snapshot("default", in: container)
        XCTAssertFalse(value.played); XCTAssertNil(value.last); XCTAssertTrue(value.new)
        XCTAssertTrue(try snapshot("local", in: container).played)
        XCTAssertNil(try snapshot("local", in: container).last)
    }

    func testGenuineCompletedAndPartialListeningEstablishCutoffsAndResumePoints() async throws {
        let container = try library()
        let completed = episode("completed", in: container); completed.isInQueue = true
        episode("partial", in: container)
        try container.mainContext.save()
        let file = try HistoryImport.decode(data([
            row("completed", played: 1, date: now.timeIntervalSince1970 - 10, source: 6, count: 1),
            row("partial", position: 35, date: now.timeIntervalSince1970 - 20, source: 6)
        ]))
        let index = LibraryIndex(modelContainer: container)
        let result = try await index.applyHistory(file, now: now)
        XCTAssertEqual(result.markedPlayed, 1); XCTAssertEqual(result.resumePoints, 1)
        let done = try snapshot("completed", in: container), partial = try snapshot("partial", in: container)
        XCTAssertTrue(done.played); XCTAssertFalse(done.queued); XCTAssertNotNil(done.last)
        XCTAssertFalse(partial.played); XCTAssertEqual(partial.position, 35); XCTAssertNotNil(partial.last)
        XCTAssertFalse(partial.new)
        let counts = await index.computeCounts()
        XCTAssertNotNil(counts.perShow[feed]?.latestListenedPublishedAt)
    }

    func testRepeatedTitleFallbackIsAmbiguousAndGuidAlwaysWinsAcrossFeedAliases() async throws {
        let container = try library()
        let a = episode("a", title: "Repeated", in: container)
        let b = Episode(guid: "b", title: "Repeated", episodeDescription: "", audioURL: "", publishedAt: now, duration: 100)
        container.mainContext.insert(b); b.podcast = a.podcast
        episode("other", title: "Repeated", feedURL: "https://example.invalid/Other.xml", in: container)
        try container.mainContext.save()
        var exact = row("b", title: "Repeated", feedURL: "https://example.invalid/Other.xml", played: 1, count: 1)
        exact["originalFeedURL"] = feed
        let file = try HistoryImport.decode(data([
            row("rewritten", title: " Repeated ", played: 1, count: 1), exact
        ]))
        let result = try await LibraryIndex(modelContainer: container).applyHistory(file, now: now)
        XCTAssertEqual(result.ambiguous, 1); XCTAssertEqual(result.markedPlayed, 1)
        XCTAssertFalse(try snapshot("a", in: container).played)
        XCTAssertTrue(try snapshot("b", in: container).played)
        XCTAssertFalse(try snapshot("other", in: container).played)
    }

    func testUniqueTitleFallbackRemainsScopedAndPathCaseCannotMatchAnotherShow() async throws {
        let container = try library()
        episode("unique", title: "Unique Title", in: container)
        episode("lowercase", title: "Unique Title", feedURL: "https://example.invalid/show.xml", in: container)
        try container.mainContext.save()
        let file = try HistoryImport.decode(data([
            row("rewritten", title: "  UNIQUE   TITLE ", played: 1, count: 1),
            row("missing", title: "Unknown", feedURL: "https://example.invalid/Absent.xml", played: 1, count: 1)
        ]))
        let result = try await LibraryIndex(modelContainer: container).applyHistory(file, now: now)
        XCTAssertEqual(result.markedPlayed, 1); XCTAssertEqual(result.otherShows, 1)
        XCTAssertTrue(try snapshot("unique", in: container).played)
        XCTAssertFalse(try snapshot("lowercase", in: container).played)
    }

    func testDuplicateConflictingRowsArePermutationIndependentAndIdempotent() async throws {
        let rows = [
            row("done", played: 1, date: now.timeIntervalSince1970 - 30, source: 6, count: 1),
            row("done", played: 0, date: now.timeIntervalSince1970, source: 6, saved: 1),
            row("partial", position: 80, date: now.timeIntervalSince1970 - 20, source: 1),
            row("partial", position: 15, date: now.timeIntervalSince1970 - 10, source: 1),
            row("partial", position: 50, date: now.timeIntervalSince1970 - 10, source: 1),
            row("partial", position: 0, date: now.timeIntervalSince1970, source: 6)
        ]
        var expected: [Snapshot]?
        for order in [rows, Array(rows.reversed()), [rows[3], rows[0], rows[5], rows[2], rows[1], rows[4]]] {
            let container = try library()
            episode("done", in: container); episode("partial", in: container)
            try container.mainContext.save()
            let file = try HistoryImport.decode(data(order))
            let index = LibraryIndex(modelContainer: container)
            let result = try await index.applyHistory(file, now: now)
            XCTAssertEqual(result.markedPlayed, 1); XCTAssertEqual(result.resumePoints, 1)
            XCTAssertEqual(result.duplicateRows, 4)
            let snapshots = try [snapshot("done", in: container), snapshot("partial", in: container)]
            if let expected { XCTAssertEqual(snapshots, expected) } else { expected = snapshots }
            XCTAssertEqual(snapshots[1].position, 50, "Equal genuine timestamps use the larger position; the later default date cannot win")
            XCTAssertEqual(snapshots[1].last, now.addingTimeInterval(-10))
            XCTAssertEqual(snapshots[0].last, now.addingTimeInterval(-30), "The later default timestamp cannot win")
            XCTAssertTrue(snapshots[0].starred)
            let again = try await index.applyHistory(file, now: now)
            XCTAssertEqual(again.markedPlayed, 0); XCTAssertEqual(again.resumePoints, 0)
            XCTAssertEqual(again.starred, 0); XCTAssertEqual(again.alreadyPlayed, 1)
        }
    }

    func testOlderOrUndatedImportedResumeCannotOverwriteNewerLocalListening() async throws {
        let container = try library()
        let local = episode("local", in: container)
        local.playbackPosition = 40; local.lastPlayedAt = now.addingTimeInterval(-10); local.isNew = false
        try container.mainContext.save()
        let index = LibraryIndex(modelContainer: container)
        for rows in [[row("local", position: 80, date: now.timeIntervalSince1970 - 20, source: 1)],
                     [row("local", position: 90)]] {
            let result = try await index.applyHistory(HistoryImport.decode(data(rows)), now: now)
            XCTAssertEqual(result.resumePoints, 0)
            XCTAssertEqual(try snapshot("local", in: container).position, 40)
        }
    }

    func testLegacyVersionsAndCorruptDatesStayConservativeWithoutUndoingLocalChoices() async throws {
        let container = try library()
        episode("legacy1", in: container); episode("legacy2", in: container)
        episode("bad", in: container)
        try container.mainContext.save()
        let index = LibraryIndex(modelContainer: container)
        _ = try await index.applyHistory(HistoryImport.decode(data([
            row("legacy1", played: 1, date: now.timeIntervalSince1970)
        ], version: 1)), now: now)
        _ = try await index.applyHistory(HistoryImport.decode(data([
            row("legacy2", played: 1, date: now.timeIntervalSince1970)
        ], version: 2)), now: now)
        _ = try await index.applyHistory(HistoryImport.decode(data([
            row("bad", played: 0, position: Double.greatestFiniteMagnitude,
                date: Double.greatestFiniteMagnitude, source: 1),
            row("bad", played: 0, position: 200, date: -1, source: 1)
        ])), now: now)
        XCTAssertFalse(try snapshot("legacy1", in: container).played)
        XCTAssertNil(try snapshot("legacy1", in: container).last)
        XCTAssertTrue(try snapshot("legacy2", in: container).played)
        XCTAssertNil(try snapshot("legacy2", in: container).last)
        let bad = try snapshot("bad", in: container)
        XCTAssertEqual(bad.position, 0); XCTAssertNil(bad.last); XCTAssertTrue(bad.new)
    }
}
