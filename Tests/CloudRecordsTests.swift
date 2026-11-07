import SwiftData
import XCTest
@testable import PodSkipper

/// Pass 35: two devices, one iCloud key-value store (a dictionary here).
@MainActor
final class CloudRecordsTests: XCTestCase {
    final class FakeStore: CloudRecords.Store {
        var values: [String: Data] = [:]
        func data(forKey key: String) -> Data? { values[key] }
        func setData(_ data: Data?, forKey key: String) { values[key] = data }
    }

    @MainActor struct Device {
        let container: ModelContainer
        let defaults: UserDefaults
        let suite: String
        var context: ModelContext { container.mainContext }
        var show: Podcast { try! context.fetch(FetchDescriptor<Podcast>()).first! }
        var episode: Episode { try! context.fetch(FetchDescriptor<Episode>()).first! }
    }

    private var devices: [Device] = []
    private let store = FakeStore()

    override func tearDown() {
        for device in devices { device.defaults.removePersistentDomain(forName: device.suite) }
        devices = []
        super.tearDown()
    }

    /// The same show and episode on each device (as the feed gives them).
    private func device() throws -> Device {
        let container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self, Bookmark.self,
                                           SmartFilter.self, ListeningSession.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let show = Podcast(feedURL: "https://example.invalid/feed.xml", title: "Show")
        let episode = Episode(guid: "ep-1", title: "Episode", episodeDescription: "", audioURL: "https://example.invalid/1.mp3",
                              publishedAt: Date(timeIntervalSince1970: 1_000), duration: 3_600)
        episode.podcast = show
        container.mainContext.insert(show)
        container.mainContext.insert(episode)
        let cut = AdSegment(start: 100, end: 160)
        cut.episode = episode
        container.mainContext.insert(cut)
        try container.mainContext.save()
        let suite = "CloudRecordsTests." + UUID().uuidString
        let made = Device(container: container, defaults: UserDefaults(suiteName: suite)!, suite: suite)
        devices.append(made)
        return made
    }

    @discardableResult
    private func sync(_ device: Device, at seconds: TimeInterval) async -> CloudRecords.Outcome {
        await CloudRecords.sync(context: device.context, store: store, defaults: device.defaults,
                          now: Date(timeIntervalSince1970: 2_000_000_000 + seconds))
    }

    func testShowSettingsBookmarksStationsAndCorrectionsReachTheOtherDevice() async throws {
        let phone = try device(), pad = try device()
        await sync(phone, at: 0); await sync(pad, at: 1)

        phone.show.playbackSpeedOverride = 1.4
        phone.show.skipIntroSeconds = 12
        phone.context.insert(Bookmark(timestamp: 300, note: "funny bit", episode: phone.episode))
        phone.context.insert(SmartFilter(name: "Commute"))
        let cut = phone.episode.adSegments[0]
        cut.end = 175
        cut.userVerdict = .confirmed
        cut.isLocked = true
        phone.episode.correctionLogData = Data("[]".utf8)
        try phone.context.save()
        let sent = await sync(phone, at: 10)
        XCTAssertEqual(sent.sent[.shows], 1)
        XCTAssertEqual(sent.sent[.cuts], 1)

        let received = await sync(pad, at: 20)
        XCTAssertEqual(pad.show.playbackSpeedOverride, 1.4)
        XCTAssertEqual(pad.show.skipIntroSeconds, 12)
        let bookmarks = try pad.context.fetch(FetchDescriptor<Bookmark>())
        XCTAssertEqual(bookmarks.map(\.note), ["funny bit"])
        XCTAssertEqual(try pad.context.fetch(FetchDescriptor<SmartFilter>()).map(\.name), ["Commute"])
        let padCut = pad.episode.adSegments[0]
        XCTAssertEqual(padCut.end, 175)
        XCTAssertEqual(padCut.userVerdict, .confirmed)
        XCTAssertTrue(padCut.isLocked)
        XCTAssertEqual(received.conflictsKeptHere, 0)

        // Nothing changed: nothing sent either way.
        let outcome1 = await sync(pad, at: 21)
        XCTAssertTrue(outcome1.sent.isEmpty)
        let outcome2 = await sync(phone, at: 22)
        XCTAssertTrue(outcome2.sent.isEmpty)
    }

    func testDeletingABookmarkOrStationReachesTheOtherDevice() async throws {
        let phone = try device(), pad = try device()
        phone.context.insert(Bookmark(timestamp: 42, episode: phone.episode))
        phone.context.insert(SmartFilter(name: "Gym"))
        try phone.context.save()
        await sync(phone, at: 0); await sync(pad, at: 1)
        XCTAssertEqual(try pad.context.fetch(FetchDescriptor<Bookmark>()).count, 1)

        for b in try phone.context.fetch(FetchDescriptor<Bookmark>()) { phone.context.delete(b) }
        for f in try phone.context.fetch(FetchDescriptor<SmartFilter>()) { phone.context.delete(f) }
        try phone.context.save()
        await sync(phone, at: 10); await sync(pad, at: 11)
        XCTAssertEqual(try pad.context.fetch(FetchDescriptor<Bookmark>()).count, 0)
        XCTAssertEqual(try pad.context.fetch(FetchDescriptor<SmartFilter>()).count, 0)
    }

    /// Both devices corrected the same episode since they last synced: each
    /// keeps its own, and the one that syncs later wins on the other only
    /// once that one hasn't changed it again.
    func testCorrectionsMadeHereAreNeverOverwritten() async throws {
        let phone = try device(), pad = try device()
        await sync(phone, at: 0); await sync(pad, at: 1)
        phone.episode.adSegments[0].userVerdict = .confirmed
        phone.episode.correctionLogData = Data("[1]".utf8)
        pad.episode.adSegments[0].userVerdict = .notAnAd
        pad.episode.correctionLogData = Data("[2]".utf8)
        try phone.context.save(); try pad.context.save()

        await sync(phone, at: 10)
        let padOutcome = await sync(pad, at: 11)
        XCTAssertEqual(padOutcome.conflictsKeptHere, 1)
        XCTAssertEqual(pad.episode.adSegments[0].userVerdict, .notAnAd, "the pad's own correction stays")
        // The phone hasn't changed it since: it takes the pad's later one.
        await sync(phone, at: 12)
        XCTAssertEqual(phone.episode.adSegments[0].userVerdict, .notAnAd)
    }

    /// A new device's first sync takes the cloud's settings instead of
    /// sending its own defaults over them.
    func testFirstSyncOnANewDeviceTakesTheCloudsSettings() async throws {
        let phone = try device()
        phone.defaults.set(1.6, forKey: "speed")
        phone.defaults.set(true, forKey: "smartSpeed")
        phone.defaults.set("Bass Booster", forKey: "eqPreset")
        phone.defaults.set(false, forKey: "chargingOnly") // device setting: never synced
        await sync(phone, at: 0)

        let pad = try device()
        pad.defaults.set(1.0, forKey: "speed")
        pad.defaults.set(true, forKey: "chargingOnly")
        let outcome = await sync(pad, at: 5)
        XCTAssertTrue(outcome.settingsChanged)
        XCTAssertEqual(pad.defaults.double(forKey: "speed"), 1.6)
        XCTAssertTrue(pad.defaults.bool(forKey: "smartSpeed"))
        XCTAssertEqual(pad.defaults.string(forKey: "eqPreset"), "Bass Booster")
        XCTAssertTrue(pad.defaults.bool(forKey: "chargingOnly"), "device settings stay")
        // And the phone's next sync doesn't bounce anything back.
        let outcome3 = await sync(phone, at: 6)
        XCTAssertTrue(outcome3.sent.isEmpty)
    }

    /// A record for a show or episode this device doesn't have yet waits.
    func testRecordsForMissingEpisodesWaitAndApplyLater() async throws {
        let phone = try device()
        let other = Episode(guid: "ep-2", title: "Later", episodeDescription: "", audioURL: "https://example.invalid/2.mp3",
                            publishedAt: .now, duration: 100)
        other.podcast = phone.show
        phone.context.insert(other)
        let cut = AdSegment(start: 1, end: 9)
        cut.userVerdict = .confirmed
        cut.episode = other
        phone.context.insert(cut)
        other.correctionLogData = Data("[]".utf8)
        try phone.context.save()
        await sync(phone, at: 0)

        let pad = try device()
        let outcome4 = await sync(pad, at: 1)
        XCTAssertEqual(outcome4.waiting, 1)
        let arrived = Episode(guid: "ep-2", title: "Later", episodeDescription: "", audioURL: "https://example.invalid/2.mp3",
                              publishedAt: .now, duration: 100)
        arrived.podcast = pad.show
        pad.context.insert(arrived)
        try pad.context.save()
        await sync(pad, at: 2)
        XCTAssertEqual(arrived.adSegments.first?.userVerdict, .confirmed)
    }
}

/// Pass 60 (his 7 Nov export: three 4-s main-thread stalls as the app went
/// to the background, in the records sync): the library is read and the
/// decisions made off the main thread; other devices' records are applied
/// on it in batches; an edit made while the sync ran is never overwritten.
@MainActor
final class Pass60CloudRecordsTests: XCTestCase {
    private let store = CloudRecordsTests.FakeStore()
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    private func device() throws -> (container: ModelContainer, defaults: UserDefaults) {
        let container = try ModelContainer(for: LibraryStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let show = Podcast(feedURL: "https://example.invalid/feed.xml", title: "Show")
        let episode = Episode(guid: "ep-1", title: "Episode", episodeDescription: "", audioURL: "https://example.invalid/1.mp3",
                              publishedAt: Date(timeIntervalSince1970: 1_000), duration: 3_600)
        episode.podcast = show
        container.mainContext.insert(show)
        container.mainContext.insert(episode)
        let cut = AdSegment(start: 100, end: 160)
        cut.episode = episode
        container.mainContext.insert(cut)
        try container.mainContext.save()
        let suite = "Pass60CloudRecordsTests." + UUID().uuidString
        suites.append(suite)
        return (container, UserDefaults(suiteName: suite)!)
    }

    private func episode(_ c: ModelContainer) -> Episode { try! c.mainContext.fetch(FetchDescriptor<Episode>()).first! }

    func testReadOffTheMainThreadAndAppliedInBatches() async throws {
        let phone = try device(), pad = try device()
        for i in 0..<60 { phone.container.mainContext.insert(Bookmark(timestamp: Double(i * 10), note: "b\(i)", episode: episode(phone.container))) }
        try phone.container.mainContext.save()
        let sent = await CloudRecords.sync(context: phone.container.mainContext, store: store, defaults: phone.defaults,
                                           now: Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertTrue(sent.builtOffMain)
        XCTAssertEqual(sent.sent[.bookmarks], 60)
        let received = await CloudRecords.sync(context: pad.container.mainContext, store: store, defaults: pad.defaults,
                                               now: Date(timeIntervalSince1970: 2_000_000_010), batch: 25)
        XCTAssertTrue(received.builtOffMain)
        XCTAssertEqual(received.applied[.bookmarks], 60)
        XCTAssertGreaterThanOrEqual(received.batches, 3)
        XCTAssertEqual(try pad.container.mainContext.fetch(FetchDescriptor<Bookmark>()).count, 60)
        // Nothing changed since: nothing sent or applied again.
        let again = await CloudRecords.sync(context: pad.container.mainContext, store: store, defaults: pad.defaults,
                                            now: Date(timeIntervalSince1970: 2_000_000_020))
        XCTAssertTrue(again.sent.isEmpty)
        XCTAssertTrue(again.applied.isEmpty)
    }

    /// A correction made here after the library was read, before another
    /// device's record was applied: his stays, and goes out next time.
    func testAnEditMadeWhileTheSyncRanIsKept() throws {
        let pad = try device()
        let context = pad.container.mainContext
        let target = episode(pad.container)
        target.adSegments[0].userVerdict = .confirmed
        target.correctionLogData = Data("[1]".utf8)
        try context.save()
        let before = CloudRecords.Ledger.digest(CloudRecords.CutsValue(target))
        // He moves the cut after the snapshot was read.
        target.adSegments[0].end = 190
        let theirs = CloudRecords.CutsValue(cuts: [CloudRecords.CutValue(AdSegment(start: 5, end: 9))], correctionLog: Data("[2]".utf8))
        var applier = CloudRecords.Applier(context: context, defaults: pad.defaults, localCuts: ["ep-1"])
        let result = applier.apply(CloudRecords.Pending(kind: .cuts, id: "ep-1", change: .cuts(theirs), at: .now,
                                                        digest: CloudRecords.Ledger.digest(theirs), localDigest: before))
        XCTAssertEqual(result, .changedHereSince)
        XCTAssertEqual(target.adSegments.map(\.end), [190])
        XCTAssertEqual(target.correctionLogData, Data("[1]".utf8))
        // Unchanged since the snapshot: theirs is applied.
        var second = CloudRecords.Applier(context: context, defaults: pad.defaults, localCuts: ["ep-1"])
        let now = CloudRecords.Ledger.digest(CloudRecords.CutsValue(target))
        XCTAssertEqual(second.apply(CloudRecords.Pending(kind: .cuts, id: "ep-1", change: .cuts(theirs), at: .now,
                                                         digest: CloudRecords.Ledger.digest(theirs), localDigest: now)), .applied)
        try context.save()   // a deleted cut leaves the relationship when saved
        XCTAssertEqual(target.adSegments.map(\.start), [5])
    }

    final class FakeSyncStore: SyncStore, @unchecked Sendable {
        var values: [String: Any] = [:]
        func data(forKey key: String) -> Data? { values[key] as? Data }
        func setData(_ data: Data?, forKey key: String) { values[key] = data }
        func object(forKey key: String) -> Any? { values[key] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
        func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
        var dictionaryRepresentation: [String: Any] { values }
    }

    /// Every episode's listening (position, played, starred), written off
    /// the main thread from its own context.
    func testListeningIsWrittenOffTheMainThread() async throws {
        let phone = try device()
        let target = episode(phone.container)
        target.setPosition(754.3, at: Date(timeIntervalSince1970: 1_900_000_000))
        target.isStarred = true
        try phone.container.mainContext.save()
        let syncStore = FakeSyncStore()
        let wrote = await ListeningWriter(container: phone.container).write(store: syncStore, defaults: phone.defaults,
                                                                           now: Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertTrue(wrote)
        let data = try XCTUnwrap(syncStore.data(forKey: CloudSync.Key.listening))
        let records = try JSONDecoder().decode([String: CloudSync.Listening].self, from: data)
        XCTAssertEqual(records["ep-1"]?.p, 754.3)
        XCTAssertEqual(records["ep-1"]?.st, true)
        let again = await ListeningWriter(container: phone.container).write(store: syncStore, defaults: phone.defaults,
                                                                            now: Date(timeIntervalSince1970: 2_000_000_100))
        XCTAssertFalse(again, "nothing changed: nothing written")
    }

    /// A library like his (hundreds of reviewed and processed episodes, each
    /// with cuts and a correction log; thousands listened to): the main
    /// thread's time with the old way (everything read and decided on it)
    /// against the longest it is held now.
    func testHeavyLibraryKeepsTheMainThreadFree() async throws {
        let phone = try device(), pad = try device()
        for d in [phone, pad] {
            let context = d.container.mainContext
            let show = try XCTUnwrap(context.fetch(FetchDescriptor<Podcast>()).first)
            for i in 0..<400 {
                let e = Episode(guid: "heavy-\(i)", title: "Episode \(i)", episodeDescription: "",
                                audioURL: "https://example.invalid/h\(i).mp3",
                                publishedAt: Date(timeIntervalSince1970: Double(10_000 + i)), duration: 5_400)
                e.podcast = show
                context.insert(e)
                e.lastProcessedAt = Date(timeIntervalSince1970: Double(1_000_000 + i))
                e.audioFileLength = 5_400
                e.detectorVersion = AdDetector.version
                e.lastPlayedAt = Date(timeIntervalSince1970: Double(1_500_000 + i))
                e.setPosition(Double(i * 7), at: Date(timeIntervalSince1970: Double(1_500_000 + i)))
                for k in 0..<10 {
                    let cut = AdSegment(start: Double(k * 500), end: Double(k * 500 + 60), sponsor: "Sponsor \(k)", confidence: 80)
                    cut.episode = e
                    if d.container === phone.container, i < 200, k == 0 { cut.userVerdict = .confirmed }
                    context.insert(cut)
                }
                // Small enough that 200 records stay within the 800 KB a kind may take.
                if d.container === phone.container, i < 200 { e.correctionLogData = Data(repeating: UInt8(i % 250), count: 400) }
            }
            try context.save()
        }
        // The old way: read and decide on the main thread.
        let oldStart = Date()
        let snapshot = CloudRecords.snapshot(phone.container.mainContext, defaults: phone.defaults)
        var scratch = CloudRecords.Outcome()
        _ = CloudRecords.decide(snapshot, store: CloudRecordsTests.FakeStore(), ledger: CloudRecords.Ledger(defaults: phone.defaults),
                                now: Date(timeIntervalSince1970: 2_000_000_000), outcome: &scratch)
        let oldMain = Date().timeIntervalSince(oldStart)
        XCTAssertEqual(snapshot.cuts.count, 200)

        let gaps = MainGaps()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                gaps.tick()
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let sent = await CloudRecords.sync(context: phone.container.mainContext, store: store, defaults: phone.defaults,
                                           now: Date(timeIntervalSince1970: 2_000_000_000))
        let received = await CloudRecords.sync(context: pad.container.mainContext, store: store, defaults: pad.defaults,
                                               now: Date(timeIntervalSince1970: 2_000_000_010))
        ticker.cancel()
        XCTAssertEqual(sent.sent[.cuts], 200)
        XCTAssertEqual(sent.skippedForSize, 0)
        XCTAssertEqual(received.applied[.cuts], 200)
        let reviewedOnPad = try pad.container.mainContext.fetch(FetchDescriptor<Episode>(predicate: #Predicate { $0.correctionLogData != nil }))
        XCTAssertEqual(reviewedOnPad.count, 200)
        print("PASS60-HEAVY old way on the main thread \(String(format: "%.3f", oldMain)) s; now the longest main-thread hold \(String(format: "%.3f", gaps.longest)) s over two syncs (\(received.batches) batches applied)")
        XCTAssertLessThan(gaps.longest, oldMain)
    }

    /// On a disposable copy of a real library (the simulator's, when this
    /// Mac has one: `build/p60/library-copy.store`, from
    /// `build/p60/copy-library.sh`): two syncs as two devices. The main
    /// thread's longest stretch without a turn is measured while the second
    /// applies everything the first sent.
    func testOnACopyOfARealLibrary() async throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/p60/library-copy.store")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("No library copy at \(source.path)") }
        let folder = FileManager.default.temporaryDirectory.appending(path: "pass60-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: source.path + suffix)
            if FileManager.default.fileExists(atPath: from.path) {
                try FileManager.default.copyItem(at: from, to: folder.appending(path: "a.store" + suffix))
                try FileManager.default.copyItem(at: from, to: folder.appending(path: "b.store" + suffix))
            }
        }
        let phone = try LibraryStore.openContainer(at: folder.appending(path: "a.store")).get()
        let pad = try LibraryStore.openContainer(at: folder.appending(path: "b.store")).get()
        let suite = "Pass60Copy." + UUID().uuidString
        suites.append(suite)
        let phoneDefaults = UserDefaults(suiteName: suite + ".a")!, padDefaults = UserDefaults(suiteName: suite + ".b")!
        suites += [suite + ".a", suite + ".b"]
        let episodes = try phone.mainContext.fetchCount(FetchDescriptor<Episode>())
        let listenStart = Date()
        let wroteListening = await ListeningWriter(container: phone).write(store: FakeSyncStore(), defaults: phoneDefaults)
        let listenSeconds = Date().timeIntervalSince(listenStart)
        let listened = CloudSync.listened(ModelContext(phone)).count
        let started = Date()
        let sent = await CloudRecords.sync(context: phone.mainContext, store: store, defaults: phoneDefaults,
                                           now: Date(timeIntervalSince1970: 2_000_000_000))
        let firstSeconds = Date().timeIntervalSince(started)
        // A ticker on the main thread: the longest gap between its turns is
        // the longest the screen could not have been drawn.
        let gaps = MainGaps()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                gaps.tick()
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let secondStart = Date()
        let received = await CloudRecords.sync(context: pad.mainContext, store: store, defaults: padDefaults,
                                               now: Date(timeIntervalSince1970: 2_000_000_010))
        let secondSeconds = Date().timeIntervalSince(secondStart)
        ticker.cancel()
        let longest = gaps.longest
        XCTAssertTrue(sent.builtOffMain)
        XCTAssertTrue(received.builtOffMain)
        // The other copy holds the same records: nothing applied that differs,
        // nothing lost (the copies were identical).
        XCTAssertEqual(try pad.mainContext.fetchCount(FetchDescriptor<Episode>()), episodes)
        print("PASS60-SYNC listening \(listened) episodes written \(wroteListening) in \(String(format: "%.2f", listenSeconds)) s off the main thread")
        print("PASS60-SYNC library \(episodes) episodes; first sync \(String(format: "%.2f", firstSeconds)) s sent \(sent.sent); second \(String(format: "%.2f", secondSeconds)) s applied \(received.applied) in \(received.batches) batches; longest main-thread gap \(String(format: "%.3f", longest)) s")
        XCTAssertLessThan(longest, 1.0, "the main thread was held for \(longest) s")
    }
}

/// The longest time between two turns of a main-thread ticker.
@MainActor
final class MainGaps {
    private(set) var longest = 0.0
    private var last = Date()
    func tick() {
        let now = Date()
        longest = max(longest, now.timeIntervalSince(last))
        last = now
    }
}
