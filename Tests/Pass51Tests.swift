import SwiftData
import XCTest
@testable import PodSkipper

/// Pass 51: ads one device found reach the other before it looks itself —
/// only into an episode it hasn't searched or corrected, only from the same
/// finder, and only for a copy of the same length.
@MainActor
final class Pass51FoundCutsSyncTests: XCTestCase {
    final class FakeStore: CloudRecords.Store {
        var values: [String: Data] = [:]
        func data(forKey key: String) -> Data? { values[key] }
        func setData(_ data: Data?, forKey key: String) { values[key] = data }
    }

    private let store = FakeStore()
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        super.tearDown()
    }

    private func device(processed: Bool) throws -> (ModelContainer, UserDefaults) {
        let container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self, Bookmark.self,
                                           SmartFilter.self, ListeningSession.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let show = Podcast(feedURL: "https://example.invalid/feed.xml", title: "Show")
        let episode = Episode(guid: "ep-1", title: "Episode", episodeDescription: "", audioURL: "https://example.invalid/1.mp3",
                              publishedAt: Date(timeIntervalSince1970: 1_000), duration: 3_600)
        episode.podcast = show
        container.mainContext.insert(show)
        container.mainContext.insert(episode)
        if processed {
            episode.lastProcessedAt = Date(timeIntervalSince1970: 5_000)
            episode.detectorVersion = AdDetector.version
            episode.audioFileLength = 3_612
            for (start, end) in [(100.0, 160.0), (1_800.0, 1_890.0)] {
                let cut = AdSegment(start: start, end: end)
                cut.episode = episode
                container.mainContext.insert(cut)
            }
        }
        try container.mainContext.save()
        let suite = "Pass51Tests." + UUID().uuidString
        suites.append(suite)
        return (container, UserDefaults(suiteName: suite)!)
    }

    private func episode(_ c: ModelContainer) -> Episode { try! c.mainContext.fetch(FetchDescriptor<Episode>()).first! }

    @discardableResult
    private func sync(_ d: (ModelContainer, UserDefaults), at seconds: TimeInterval) -> CloudRecords.Outcome {
        CloudRecords.sync(context: d.0.mainContext, store: store, defaults: d.1,
                          now: Date(timeIntervalSince1970: 2_000_000_000 + seconds))
    }

    func testFoundAdsReachAnEpisodeNotSearchedHere() throws {
        let phone = try device(processed: true), pad = try device(processed: false)
        XCTAssertEqual(sync(phone, at: 0).sent[.found], 1)
        let received = sync(pad, at: 1)
        XCTAssertEqual(received.applied[.found], 1)
        let cuts = episode(pad.0).adSegments.sorted { $0.start < $1.start }
        XCTAssertEqual(cuts.map(\.start), [100, 1_800])
        XCTAssertTrue(cuts.allSatisfy { $0.origin == CloudRecords.syncedOrigin && $0.canApplyAutomatically })
        XCTAssertEqual(episode(pad.0).audioFileLength, 3_612, "the stream is checked against their copy")
        // Synced cuts aren't sent back as this device's own finds.
        XCTAssertNil(sync(pad, at: 2).sent[.found])
    }

    func testNotIntoAnEpisodeSearchedHereOrADifferentCopy() throws {
        let phone = try device(processed: true)
        sync(phone, at: 0)
        let value = CloudRecords.FoundValue(length: 3_612, version: AdDetector.version,
                                            cuts: [.init(s: 1, e: 2, k: "ad")])
        // The containers are kept: an episode outlives its store only as a crash.
        let searchedDevice = try device(processed: true), otherDevice = try device(processed: false)
        let searched = episode(searchedDevice.0)
        XCTAssertFalse(CloudRecords.takesFound(value, into: searched))
        let other = episode(otherDevice.0)
        other.audioFileLength = 3_700   // its own copy, stitched differently
        XCTAssertFalse(CloudRecords.takesFound(value, into: other))
        other.audioFileLength = 3_611
        XCTAssertTrue(CloudRecords.takesFound(value, into: other))
        var older = value; older.version -= 1
        XCTAssertFalse(CloudRecords.takesFound(older, into: other))
    }

    func testCorrectedCutsAreLeftToTheCorrectionsSync() throws {
        let phone = try device(processed: true)
        let ep = episode(phone.0)
        ep.adSegments[0].userVerdict = .confirmed
        ep.correctionLogData = Data("[]".utf8)
        try phone.0.mainContext.save()
        let sent = sync(phone, at: 0)
        XCTAssertNil(sent.sent[.found])
        XCTAssertEqual(sent.sent[.cuts], 1)
    }
}
