import XCTest
import SwiftData
@testable import PodSkipper

@MainActor
final class StationOrderTests: XCTestCase {
    func testExistingSortValuesAndDefaultsRemainCompatible() {
        XCTAssertEqual(FilterSort.allCases.filter { $0 != .manual }.map(\.rawValue),
                       ["Newest first", "Oldest first", "Shortest first", "Longest first", "By show"])
        for station in SmartFilter.defaults() {
            XCTAssertFalse(station.groupByShow)
            XCTAssertTrue(station.manualEpisodeGUIDs.isEmpty)
            XCTAssertEqual(station.sort, .newest)
        }
        let station = SmartFilter(name: "Future")
        station.sortRaw = "Future sort"
        XCTAssertEqual(station.sort, .newest)
        XCTAssertEqual(station.sortRaw, "Future sort", "Reading a future value must not rewrite stored history")
    }

    func testManualOrderDeduplicatesRanksAndAppendsNewMatchesDeterministically() {
        let a = episode("A", date: 100), b = episode("B", date: 200)
        let c = episode("C", date: 400), d = episode("D", date: 400)
        let station = SmartFilter(name: "Manual")
        station.sort = .manual
        station.manualEpisodeGUIDs = ["B", "", "B", "gone", "A"]
        XCTAssertEqual(station.apply(to: [a, d, c, b]).map(\.guid), ["B", "A", "C", "D"])
        XCTAssertEqual(station.apply(to: [c, b, d, a]).map(\.guid), ["B", "A", "C", "D"])
        XCTAssertEqual(station.manualEpisodeGUIDs, ["B", "", "B", "gone", "A"])
    }

    func testEveryAutomaticSortHasStableTies() {
        let a = episode("A", date: 100), b = episode("B", date: 100)
        let station = SmartFilter(name: "Stable")
        for sort in FilterSort.allCases where sort != .manual {
            station.sort = sort
            XCTAssertEqual(station.apply(to: [b, a]).map(\.guid), ["A", "B"], sort.rawValue)
        }
    }

    func testManualRanksDoNotOverrideMembershipOrNewestPerShow() {
        let show = podcast("One", feed: "one")
        let old = episode("old", date: 100, show: show)
        let fresh = episode("fresh", date: 200, show: show)
        let archived = episode("archived", date: 400, show: show); archived.isArchived = true
        let played = episode("played", date: 300, show: show); played.isPlayed = true
        let station = SmartFilter(name: "Latest")
        station.perShow = 1; station.sort = .manual
        station.manualEpisodeGUIDs = ["old", "archived", "played", "fresh"]
        XCTAssertEqual(station.apply(to: [old, fresh, archived, played]).map(\.guid), ["fresh"])
        station.onlyUnplayed = false
        XCTAssertEqual(station.apply(to: [old, fresh, archived, played]).map(\.guid), ["played"])
    }

    func testHiddenEpisodeRetainsManualRankWhenRulesChangeAndItReturns() {
        let a = episode("A"), b = episode("B"), c = episode("C")
        let station = SmartFilter(name: "Rules")
        station.sort = .manual; station.manualEpisodeGUIDs = ["C", "B", "A"]
        b.isPlayed = true
        XCTAssertEqual(station.apply(to: [a, b, c]).map(\.guid), ["C", "A"])
        station.manualEpisodeGUIDs = StationEpisodeOrder.replacingVisibleOrder(
            existing: station.manualEpisodeGUIDs, with: ["A", "C"])
        XCTAssertEqual(station.manualEpisodeGUIDs, ["A", "B", "C"])
        b.isPlayed = false
        XCTAssertEqual(station.apply(to: [c, b, a]).map(\.guid), ["A", "B", "C"])
    }

    func testReorderPreservesHiddenSlotsAndIgnoresDuplicateOrEmptyGUIDs() {
        XCTAssertEqual(StationEpisodeOrder.replacingVisibleOrder(
            existing: ["A", "hidden", "B", "A", ""], with: ["B", "A", "C", "B", ""]),
            ["B", "hidden", "A", "C"])
        XCTAssertEqual(StationEpisodeOrder.replacingVisibleOrder(existing: ["hidden"], with: []), ["hidden"])
    }

    func testGroupingUsesFeedIdentityAndFirstEpisodeOrderWithMatchingPlaybackFlattening() {
        let firstShow = podcast("Same Title", feed: "one"), secondShow = podcast("Same Title", feed: "two")
        let a = episode("A", show: firstShow), b = episode("B", show: secondShow)
        let c = episode("C", show: firstShow), d = episode("D", show: secondShow)
        let station = SmartFilter(name: "Grouped")
        station.sort = .manual; station.manualEpisodeGUIDs = ["B", "A", "D", "C"]
        station.groupByShow = true
        let resolved = station.apply(to: [a, b, c, d])
        XCTAssertEqual(resolved.map(\.guid), ["B", "D", "A", "C"])
        let groups = StationEpisodeOrder.groups(in: resolved)
        XCTAssertEqual(groups.map(\.id), ["feed:\(secondShow.feedURL)", "feed:\(firstShow.feedURL)"])
        XCTAssertEqual(groups.map(\.title), ["Same Title", "Same Title"])
        XCTAssertEqual(groups.flatMap(\.episodes).map(\.guid), resolved.map(\.guid))
        station.groupByShow = false
        XCTAssertEqual(station.apply(to: [d, c, b, a]).map(\.guid), ["B", "A", "D", "C"])
    }

    func testGroupingAndNewestPerShowUseStableMembershipBeforeManualRank() {
        let one = podcast("One", feed: "one"), two = podcast("Two", feed: "two")
        let a = episode("A", date: 100, show: one), b = episode("B", date: 100, show: one)
        let c = episode("C", date: 200, show: two)
        let station = SmartFilter(name: "Per Show")
        station.sort = .manual; station.perShow = 1; station.groupByShow = true
        station.manualEpisodeGUIDs = ["B", "C", "A"]
        XCTAssertEqual(station.apply(to: [b, c, a]).map(\.guid), ["C", "A"])
    }

    func testStationOrdersAreIndependentOfOtherStationsAndGlobalQueue() throws {
        let container = try memoryContainer(), context = container.mainContext
        let a = episode("A"), b = episode("B")
        let first = SmartFilter(name: "First", order: 9), second = SmartFilter(name: "Second", order: 2)
        for episode in [a, b] { context.insert(episode) }
        context.insert(first); context.insert(second)
        a.isInQueue = true; a.queueOrder = 7; a.playbackPosition = 40
        first.manualEpisodeGUIDs = ["A", "B"]; first.sort = .manual
        second.manualEpisodeGUIDs = ["A", "B"]; second.sort = .manual
        try StationOrderStore.save(["B", "A"], for: first) { try context.save() }
        XCTAssertEqual(first.apply(to: [a, b]).map(\.guid), ["B", "A"])
        XCTAssertEqual(second.apply(to: [a, b]).map(\.guid), ["A", "B"])
        XCTAssertEqual(first.order, 9); XCTAssertEqual(second.order, 2)
        XCTAssertEqual(a.queueOrder, 7); XCTAssertTrue(a.isInQueue); XCTAssertFalse(b.isInQueue)
        XCTAssertEqual(a.playbackPosition, 40)
    }

    func testGroupedManualOrderDrivesQueueAllAndPlayAllWithoutCollisions() throws {
        let container = try memoryContainer(), context = container.mainContext
        let one = podcast("One", feed: "one"), two = podcast("Two", feed: "two")
        context.insert(one); context.insert(two)
        let a = episode("A", show: one), b = episode("B", show: two), c = episode("C", show: one)
        let unrelated = episode("existing")
        for e in [a, b, c, unrelated] { context.insert(e) }
        unrelated.isInQueue = true; unrelated.queueOrder = 50
        a.isInQueue = true; a.queueOrder = 50; a.playbackPosition = 31
        let station = SmartFilter(name: "Grouped")
        station.sort = .manual; station.manualEpisodeGUIDs = ["B", "A", "C"]
        station.groupByShow = true; station.showFeedURLs = [one.feedURL, two.feedURL]
        context.insert(station); try context.save()
        let resolved = station.episodes(in: context)
        XCTAssertEqual(resolved.map(\.guid), ["B", "A", "C"])
        let appended = try StationQueue.enqueue(resolved, in: context, placement: .append, refreshDerivedState: false)
        XCTAssertEqual(appended.map(\.guid), ["A", "existing", "B", "C"])
        let playback = try StationQueue.enqueue(resolved, in: context, placement: .playFirst, refreshDerivedState: false)
        XCTAssertEqual(playback.map(\.guid), ["B", "A", "C", "existing"])
        XCTAssertEqual(playback.map(\.queueOrder), [0, 1, 2, 3])
        XCTAssertTrue(playback.first === b)
        XCTAssertEqual(a.playbackPosition, 31)
    }

    func testSaveFailureRestoresOnlyStationOrderAndSort() {
        let station = SmartFilter(name: "Failure")
        station.sort = .oldest; station.manualEpisodeGUIDs = ["hidden", "A", "B"]
        station.groupByShow = true
        let listening = episode("listening"); listening.playbackPosition = 40
        XCTAssertThrowsError(try StationOrderStore.save(["B", "A"], for: station) { throw URLError(.cannotWriteToFile) })
        XCTAssertEqual(station.sort, .oldest)
        XCTAssertEqual(station.manualEpisodeGUIDs, ["hidden", "A", "B"])
        XCTAssertTrue(station.groupByShow)
        XCTAssertEqual(listening.playbackPosition, 40)
    }

    func testManualOrderAndGroupingSurviveDiskReopen() throws {
        let folder = try disposableFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("station.store")
        do {
            let container = try diskContainer(at: url), context = container.mainContext
            let one = podcast("One", feed: "one"), two = podcast("Two", feed: "two")
            context.insert(one); context.insert(two)
            for e in [episode("A", show: one), episode("B", show: two), episode("C", show: one)] { context.insert(e) }
            let station = SmartFilter(name: "Saved", order: 4)
            station.groupByShow = true; context.insert(station)
            try StationOrderStore.save(["C", "B", "A"], for: station) { try context.save() }
        }
        let reopened = try diskContainer(at: url), context = reopened.mainContext
        let station = try XCTUnwrap(context.fetch(FetchDescriptor<SmartFilter>()).first)
        XCTAssertEqual(station.name, "Saved"); XCTAssertEqual(station.order, 4)
        XCTAssertTrue(station.groupByShow); XCTAssertEqual(station.sort, .manual)
        XCTAssertEqual(station.manualEpisodeGUIDs, ["C", "B", "A"])
        XCTAssertEqual(station.episodes(in: context).map(\.guid), ["C", "A", "B"])
    }

    func testCopiedLegacyStoreMigratesAdditiveDefaultsWithoutLosingRulesHistoryOrCorrections() throws {
        let folder = try disposableFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("legacy.store"), copy = folder.appendingPathComponent("migration-copy.store")
        XCTAssertEqual(Schema.entityName(for: StationLegacy.SmartFilter.self), Schema.entityName(for: SmartFilter.self),
                       "The fixture must represent the app's actual old station entity")
        let legacySchema = Schema([Podcast.self, Episode.self, AdSegment.self, Bookmark.self, Chapter.self,
                                   ListeningSession.self, StationLegacy.SmartFilter.self])
        let old = try ModelContainer(for: legacySchema,
            configurations: ModelConfiguration(schema: legacySchema, url: original, cloudKitDatabase: .none))
        let oldContext = old.mainContext
        let show = podcast("Saved Show", feed: "saved"); oldContext.insert(show)
        let episode = episode("preserved", show: show); episode.playbackPosition = 27; episode.isStarred = true
        oldContext.insert(episode)
        let cut = AdSegment(start: 10, end: 20, sponsor: "User correction")
        cut.isLocked = true; cut.origin = "added"; cut.episode = episode; episode.adSegments = [cut]
        let chapter = Chapter(start: 42, title: "Local Chapter", imageURL: "https://example.invalid/image.jpg")
        chapter.episode = episode; episode.chapters = [chapter]
        let station = StationLegacy.SmartFilter(name: "Legacy", order: 8)
        station.onlyUnplayed = false; station.onlyStarred = true; station.withinDays = 0
        station.minMinutes = 5; station.perShow = 3; station.showFeedURLs = [show.feedURL]; station.sortRaw = "Oldest first"
        oldContext.insert(station); try oldContext.save()
        // Existing production backup primitive includes WAL consistently. Only
        // the disposable copy is migrated; the original fixture remains intact.
        try BackupService.copyDatabase(original, to: copy)
        let originalBytes = try Data(contentsOf: original)
        let migrated = try diskContainer(at: copy), context = migrated.mainContext
        let restored = try XCTUnwrap(context.fetch(FetchDescriptor<SmartFilter>()).first)
        XCTAssertEqual(restored.name, "Legacy"); XCTAssertEqual(restored.order, 8)
        XCTAssertFalse(restored.onlyUnplayed); XCTAssertTrue(restored.onlyStarred)
        XCTAssertEqual(restored.minMinutes, 5); XCTAssertEqual(restored.perShow, 3)
        XCTAssertEqual(restored.showFeedURLs, [show.feedURL]); XCTAssertEqual(restored.sort, .oldest)
        XCTAssertFalse(restored.groupByShow); XCTAssertTrue(restored.manualEpisodeGUIDs.isEmpty)
        let restoredEpisode = try XCTUnwrap(context.fetch(FetchDescriptor<Episode>()).first)
        XCTAssertEqual(restoredEpisode.playbackPosition, 27); XCTAssertTrue(restoredEpisode.isStarred)
        XCTAssertEqual(restoredEpisode.chapters.first?.title, "Local Chapter")
        XCTAssertEqual(restoredEpisode.adSegments.first?.origin, "added")
        XCTAssertEqual(restoredEpisode.adSegments.first?.isLocked, true)
        XCTAssertEqual(restored.episodes(in: context).map(\.guid), ["preserved"])
        XCTAssertEqual(try Data(contentsOf: original), originalBytes, "Migration must not touch the rollback source")
        XCTAssertEqual(try oldContext.fetch(FetchDescriptor<StationLegacy.SmartFilter>()).first?.sortRaw, "Oldest first")
    }

    func testBackupDatabaseSnapshotRetainsManualRanksAndGroupingAlongsideQueueAndListeningData() throws {
        let folder = try disposableFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.store"), backup = folder.appendingPathComponent("backup.store")
        let container = try diskContainer(at: source), context = container.mainContext
        let station = SmartFilter(name: "Backed Up")
        station.groupByShow = true; station.manualEpisodeGUIDs = ["B", "hidden", "A"]; station.sort = .manual
        let a = episode("A"), b = episode("B")
        a.isInQueue = true; a.queueOrder = 3; a.playbackPosition = 61
        context.insert(station); context.insert(a); context.insert(b); try context.save()
        try BackupService.copyDatabase(source, to: backup)
        let restored = try diskContainer(at: backup), restoredContext = restored.mainContext
        let restoredStation = try XCTUnwrap(restoredContext.fetch(FetchDescriptor<SmartFilter>()).first)
        XCTAssertTrue(restoredStation.groupByShow); XCTAssertEqual(restoredStation.sort, .manual)
        XCTAssertEqual(restoredStation.manualEpisodeGUIDs, ["B", "hidden", "A"])
        XCTAssertEqual(restoredStation.episodes(in: restoredContext).map(\.guid), ["B", "A"])
        let restoredEpisodes = try restoredContext.fetch(FetchDescriptor<Episode>())
        let restoredA = try XCTUnwrap(restoredEpisodes.first { $0.guid == "A" })
        XCTAssertTrue(restoredA.isInQueue); XCTAssertEqual(restoredA.queueOrder, 3); XCTAssertEqual(restoredA.playbackPosition, 61)
    }

    func testSavedMembershipChangesRefreshStationsButUnrelatedOrOtherStoreChangesDoNot() throws {
        let container = try memoryContainer(), context = container.mainContext
        let e = episode("A"); context.insert(e)
        let bookmark = Bookmark(timestamp: 4, episode: e); context.insert(bookmark); try context.save()
        let changed = Notification(name: ModelContext.didSave, object: context,
            userInfo: [ModelContext.NotificationKey.updatedIdentifiers.rawValue: [e.persistentModelID]])
        XCTAssertTrue(StationStoreChanges.affectsStations(changed, context: context))
        let unrelated = Notification(name: ModelContext.didSave, object: context,
            userInfo: [ModelContext.NotificationKey.insertedIdentifiers: Set([bookmark.persistentModelID])])
        XCTAssertFalse(StationStoreChanges.affectsStations(unrelated, context: context))
        let other = try memoryContainer()
        let otherSave = Notification(name: ModelContext.didSave, object: other.mainContext)
        XCTAssertFalse(StationStoreChanges.affectsStations(otherSave, context: context))
    }

    private func episode(_ guid: String, date: TimeInterval = 100, show: Podcast? = nil) -> Episode {
        let episode = Episode(guid: guid, title: guid, episodeDescription: "", audioURL: "https://example.invalid/\(guid).mp3",
                              publishedAt: Date(timeIntervalSince1970: date), duration: 600)
        episode.podcast = show
        return episode
    }

    private func podcast(_ title: String, feed: String) -> Podcast {
        Podcast(feedURL: "https://example.invalid/\(feed).xml", title: title, author: "", summary: "", artworkURL: nil, category: "")
    }

    private func schema() -> Schema {
        Schema([Podcast.self, Episode.self, AdSegment.self, Bookmark.self, Chapter.self, ListeningSession.self, SmartFilter.self])
    }

    private func memoryContainer() throws -> ModelContainer {
        let schema = schema()
        return try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    private func diskContainer(at url: URL) throws -> ModelContainer {
        let schema = schema()
        return try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
    }

    private func disposableFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("station-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

/// Frozen pre-change station model. Keep every stored property and default,
/// and the entity name, identical to the old app; no new rank/group fields.
private enum StationLegacy {
    @Model
    final class SmartFilter {
        var name: String
        var iconName: String
        var colorHex: String
        var order: Int
        var onlyUnplayed: Bool = true
        var onlyDownloaded: Bool = false
        var onlyAdFree: Bool = false
        var onlyStarred: Bool = false
        var withinDays: Int = 0
        var maxMinutes: Int = 0
        var minMinutes: Int = 0
        var showFeedURLs: [String] = []
        var sortRaw: String = "Newest first"
        var perShow: Int = 0

        init(name: String, iconName: String = "line.3.horizontal.decrease.circle", colorHex: String = "FF3080", order: Int = 0) {
            self.name = name; self.iconName = iconName; self.colorHex = colorHex; self.order = order
        }
    }
}
