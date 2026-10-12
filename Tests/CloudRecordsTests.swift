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
    private func sync(_ device: Device, at seconds: TimeInterval) -> CloudRecords.Outcome {
        CloudRecords.sync(context: device.context, store: store, defaults: device.defaults,
                          now: Date(timeIntervalSince1970: 2_000_000_000 + seconds))
    }

    func testShowSettingsBookmarksStationsAndCorrectionsReachTheOtherDevice() throws {
        let phone = try device(), pad = try device()
        sync(phone, at: 0); sync(pad, at: 1)

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
        let sent = sync(phone, at: 10)
        XCTAssertEqual(sent.sent[.shows], 1)
        XCTAssertEqual(sent.sent[.cuts], 1)

        let received = sync(pad, at: 20)
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
        XCTAssertTrue(sync(pad, at: 21).sent.isEmpty)
        XCTAssertTrue(sync(phone, at: 22).sent.isEmpty)
    }

    func testDeletingABookmarkOrStationReachesTheOtherDevice() throws {
        let phone = try device(), pad = try device()
        phone.context.insert(Bookmark(timestamp: 42, episode: phone.episode))
        phone.context.insert(SmartFilter(name: "Gym"))
        try phone.context.save()
        sync(phone, at: 0); sync(pad, at: 1)
        XCTAssertEqual(try pad.context.fetch(FetchDescriptor<Bookmark>()).count, 1)

        for b in try phone.context.fetch(FetchDescriptor<Bookmark>()) { phone.context.delete(b) }
        for f in try phone.context.fetch(FetchDescriptor<SmartFilter>()) { phone.context.delete(f) }
        try phone.context.save()
        sync(phone, at: 10); sync(pad, at: 11)
        XCTAssertEqual(try pad.context.fetch(FetchDescriptor<Bookmark>()).count, 0)
        XCTAssertEqual(try pad.context.fetch(FetchDescriptor<SmartFilter>()).count, 0)
    }

    /// Both devices corrected the same episode since they last synced: each
    /// keeps its own, and the one that syncs later wins on the other only
    /// once that one hasn't changed it again.
    func testCorrectionsMadeHereAreNeverOverwritten() throws {
        let phone = try device(), pad = try device()
        sync(phone, at: 0); sync(pad, at: 1)
        phone.episode.adSegments[0].userVerdict = .confirmed
        phone.episode.correctionLogData = Data("[1]".utf8)
        pad.episode.adSegments[0].userVerdict = .notAnAd
        pad.episode.correctionLogData = Data("[2]".utf8)
        try phone.context.save(); try pad.context.save()

        sync(phone, at: 10)
        let padOutcome = sync(pad, at: 11)
        XCTAssertEqual(padOutcome.conflictsKeptHere, 1)
        XCTAssertEqual(pad.episode.adSegments[0].userVerdict, .notAnAd, "the pad's own correction stays")
        // The phone hasn't changed it since: it takes the pad's later one.
        sync(phone, at: 12)
        XCTAssertEqual(phone.episode.adSegments[0].userVerdict, .notAnAd)
    }

    /// A new device's first sync takes the cloud's settings instead of
    /// sending its own defaults over them.
    func testFirstSyncOnANewDeviceTakesTheCloudsSettings() throws {
        let phone = try device()
        phone.defaults.set(1.6, forKey: "speed")
        phone.defaults.set(true, forKey: "smartSpeed")
        phone.defaults.set("Bass Booster", forKey: "eqPreset")
        phone.defaults.set(false, forKey: "chargingOnly") // device setting: never synced
        sync(phone, at: 0)

        let pad = try device()
        pad.defaults.set(1.0, forKey: "speed")
        pad.defaults.set(true, forKey: "chargingOnly")
        let outcome = sync(pad, at: 5)
        XCTAssertTrue(outcome.settingsChanged)
        XCTAssertEqual(pad.defaults.double(forKey: "speed"), 1.6)
        XCTAssertTrue(pad.defaults.bool(forKey: "smartSpeed"))
        XCTAssertEqual(pad.defaults.string(forKey: "eqPreset"), "Bass Booster")
        XCTAssertTrue(pad.defaults.bool(forKey: "chargingOnly"), "device settings stay")
        // And the phone's next sync doesn't bounce anything back.
        XCTAssertTrue(sync(phone, at: 6).sent.isEmpty)
    }

    /// A record for a show or episode this device doesn't have yet waits.
    func testRecordsForMissingEpisodesWaitAndApplyLater() throws {
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
        sync(phone, at: 0)

        let pad = try device()
        XCTAssertEqual(sync(pad, at: 1).waiting, 1)
        let arrived = Episode(guid: "ep-2", title: "Later", episodeDescription: "", audioURL: "https://example.invalid/2.mp3",
                              publishedAt: .now, duration: 100)
        arrived.podcast = pad.show
        pad.context.insert(arrived)
        try pad.context.save()
        sync(pad, at: 2)
        XCTAssertEqual(arrived.adSegments.first?.userVerdict, .confirmed)
    }
}
