import XCTest
import SwiftData
@testable import PodSkipper

/// Pass 41: library pages read only what their rows draw, and a change made
/// elsewhere to an episode not loaded here re-reads a page only when that
/// episode now belongs on it; range selection.
@MainActor
final class Pass41Tests: XCTestCase {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    func testChangesElsewhereCountOnlyWhenTheyBelong() throws {
        let container = try container()
        // Saved in a context of its own: the page's (main) context never
        // loads these, as with a back catalogue merged in the background.
        let writer = ModelContext(container)
        let show = Podcast(feedURL: "https://example.invalid/a", title: "A")
        writer.insert(show)
        let plain = Episode(guid: "plain", title: "Plain", episodeDescription: "", audioURL: "https://example.invalid/1.mp3",
                            publishedAt: .now, duration: 60)
        let saved = Episode(guid: "saved", title: "Saved", episodeDescription: "", audioURL: "https://example.invalid/2.mp3",
                            publishedAt: .now, duration: 60)
        saved.isStarred = true
        for episode in [plain, saved] { episode.podcast = show; writer.insert(episode) }
        try writer.save()

        let page = container.mainContext
        XCTAssertNil(page.registeredModel(for: plain.persistentModelID) as Episode?, "not loaded on the page's context")
        let kind = EpisodeCollectionView.Kind.starred
        XCTAssertFalse(kind.anyBelong([plain.persistentModelID], in: page), "an unsaved episode's change doesn't re-read Saved")
        XCTAssertTrue(kind.anyBelong([plain.persistentModelID, saved.persistentModelID], in: page))
        XCTAssertFalse(kind.anyBelong([], in: page))
        XCTAssertTrue(EpisodeCollectionView.Kind.latest.anyBelong([plain.persistentModelID], in: page))
        XCTAssertFalse(EpisodeCollectionView.Kind.downloaded.anyBelong([plain.persistentModelID], in: page), "no file")
    }

    /// The page's read brings the row's columns, not the transcript text.
    func testPageReadLeavesTheTranscriptBehind() throws {
        let container = try container()
        let writer = ModelContext(container)
        let episode = Episode(guid: "t", title: "T", episodeDescription: "", audioURL: "https://example.invalid/t.mp3",
                              publishedAt: .now, duration: 60)
        episode.isStarred = true
        episode.transcriptText = String(repeating: "words ", count: 20_000)
        writer.insert(episode)
        try writer.save()

        let found = try container.mainContext.fetch(EpisodeCollectionView.Kind.starred.descriptor())
        XCTAssertEqual(found.map(\.title), ["T"])
        XCTAssertTrue(found[0].isStarred)
        // Still there when asked for (a fault, read on demand).
        XCTAssertEqual(found[0].transcriptText?.count, 120_000)
    }

    /// Token-by-token readings reach the screen at most four times a second;
    /// the first and the finished one always do.
    func testMeterReadingsAreCoalesced() {
        let box = WorkMeterBox(WorkMeter(parts: [], readRate: 100, writeRate: 10, loadSeconds: 0, ratesKnown: true))
        func reading(_ f: Double) -> WorkMeterBox.Reading {
            .init(fraction: f, secondsLeft: 10, worstSecondsLeft: 20, confident: true, speedKnown: true)
        }
        XCTAssertTrue(box.shouldPublish(reading(0.1)))
        let sent = (0..<50).filter { _ in box.shouldPublish(reading(0.2)) }.count
        XCTAssertEqual(sent, 0, "fifty tokens at once: none until a quarter second has passed")
        XCTAssertTrue(box.shouldPublish(reading(1)), "the finished reading always goes")
        XCTAssertTrue(box.shouldPublish(reading(0.5), every: 0))
    }
}
