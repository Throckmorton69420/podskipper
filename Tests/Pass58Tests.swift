import SwiftData
import XCTest
@testable import PodSkipper

/// Pass 58 (Apple Podcasts 27.2–27.3 parity): Home's Continue Playing and
/// New Episodes, and taking an episode off either.
@MainActor
final class Pass58HomeTests: XCTestCase {
    private var suites: [String] = []
    private var container: ModelContainer!

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        container = nil
        super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let suite = "Pass58Tests." + UUID().uuidString
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func library(_ specs: [(guid: String, show: String, published: Double, position: Double, played: Bool, lastPlayed: Double?)]) throws -> [Episode] {
        container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self, Bookmark.self,
                                       SmartFilter.self, ListeningSession.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        var shows: [String: Podcast] = [:]
        var out: [Episode] = []
        for s in specs {
            let show = shows[s.show] ?? {
                let p = Podcast(feedURL: "https://example.invalid/\(s.show).xml", title: s.show)
                container.mainContext.insert(p)
                shows[s.show] = p
                return p
            }()
            let e = Episode(guid: s.guid, title: s.guid, episodeDescription: "", audioURL: "https://example.invalid/\(s.guid).mp3",
                            publishedAt: Date(timeIntervalSince1970: s.published), duration: 3_600)
            e.podcast = show
            e.playbackPosition = s.position
            e.isPlayed = s.played
            e.lastPlayedAt = s.lastPlayed.map { Date(timeIntervalSince1970: $0) }
            container.mainContext.insert(e)
            out.append(e)
        }
        try container.mainContext.save()
        return out
    }

    func testContinuePlayingIsStartedUnfinishedNewestListenFirst() throws {
        let eps = try library([
            ("a", "S1", 100, 600, false, 5_000),
            ("b", "S1", 200, 10, false, 6_000),      // barely started: not here
            ("c", "S2", 300, 900, true, 7_000),      // finished: not here
            ("d", "S2", 400, 1_200, false, 8_000),
        ])
        let shown = HomeShelves.continuePlaying(eps, removals: .init()).map(\.guid)
        XCTAssertEqual(shown, ["d", "a"])
    }

    func testRemovedFromContinuePlayingComesBackWhenPlayedAgain() throws {
        let eps = try library([("a", "S1", 100, 600, false, 5_000)])
        let shelves = HomeShelves(defaults: defaults())
        shelves.remove(guid: "a", from: .continuePlaying, at: Date(timeIntervalSince1970: 6_000))
        XCTAssertTrue(HomeShelves.continuePlaying(eps, removals: shelves.removals).isEmpty)
        eps[0].lastPlayedAt = Date(timeIntervalSince1970: 7_000)
        XCTAssertEqual(HomeShelves.continuePlaying(eps, removals: shelves.removals).map(\.guid), ["a"])
    }

    func testNewEpisodesNewestFirstTwoPerShowAndRemovalStays() throws {
        let eps = try library([
            ("s1-old", "S1", 100, 0, false, nil),
            ("s1-mid", "S1", 200, 0, false, nil),
            ("s1-new", "S1", 300, 0, false, nil),
            ("s2-new", "S2", 250, 0, false, nil),
            ("s2-played", "S2", 400, 0, true, nil),
            ("s2-started", "S2", 350, 120, false, 9_000),
        ])
        XCTAssertEqual(HomeShelves.newEpisodes(eps, removals: .init()).map(\.guid), ["s1-new", "s2-new", "s1-mid"])
        let shelves = HomeShelves(defaults: defaults())
        shelves.remove(guid: "s1-new", from: .newEpisodes, at: Date(timeIntervalSince1970: 1_000))
        eps[2].lastPlayedAt = Date(timeIntervalSince1970: 2_000)   // a removal from New Episodes doesn't lapse
        XCTAssertEqual(HomeShelves.newEpisodes(eps, removals: shelves.removals).map(\.guid), ["s2-new", "s1-mid", "s1-old"])
    }

    /// Through the store, as Home reads it (column-limited fetches): the
    /// show of each episode must still be there, and a started episode with
    /// no "last played" date (a position from another device) still counts.
    func testHomeFetchesFindStartedAndNewEpisodes() throws {
        _ = try library([
            ("new-a", "S1", 300, 0, false, nil),
            ("new-b", "S2", 200, 0, false, nil),
            ("started-synced", "S1", 100, 900, false, nil),
            ("started-here", "S2", 50, 600, false, 9_000),
        ])
        let context = container.mainContext
        let inProgress = try context.fetch(HomeShelves.inProgressDescriptor())
        XCTAssertEqual(HomeShelves.continuePlaying(inProgress, removals: .init()).map(\.guid), ["started-here", "started-synced"])
        let latest = try context.fetch(HomeShelves.latestDescriptor())
        XCTAssertTrue(latest.allSatisfy { $0.podcast != nil }, "the show didn't come with the fetch")
        XCTAssertEqual(HomeShelves.newEpisodes(latest, removals: .init()).map(\.guid), ["new-a", "new-b"])
    }

    func testRemovalsAreKeptAndOldOnesForgotten() {
        let store = defaults()
        let first = HomeShelves(defaults: store)
        first.remove(guid: "recent", from: .newEpisodes, at: Date())
        first.remove(guid: "ancient", from: .continuePlaying, at: Date(timeIntervalSinceNow: -HomeShelves.forgetAfter - 60))
        let again = HomeShelves(defaults: store)
        XCTAssertTrue(again.removals.isRemoved(guid: "recent", lastPlayedAt: nil, from: .newEpisodes))
        XCTAssertFalse(again.removals.isRemoved(guid: "recent", lastPlayedAt: nil, from: .continuePlaying))
        XCTAssertFalse(again.removals.isRemoved(guid: "ancient", lastPlayedAt: nil, from: .continuePlaying))
    }
}

/// Pass 58: the CPU reader's pacing and prompt (the engine itself is device-only;
/// its lab check is Tools/CPULab).
final class Pass58CPUReadingTests: XCTestCase {
    func testPacedRestKeepsTheAverageAtTheShare() {
        let budget = CPUBudget(mode: .paced, share: 0.45)
        // Two threads busy for 5 s = 10 CPU-seconds: rest until 10 / 0.45 s have passed.
        let rest = budget.rest(cpu: 10, wall: 5)
        XCTAssertEqual(rest, 10 / 0.45 - 5, accuracy: 1e-9)
        XCTAssertEqual(10 / (5 + rest), 0.45, accuracy: 1e-9)
    }

    func testFullSpeedNeverRestsAndRestsAreCapped() {
        XCTAssertEqual(CPUBudget(mode: .full).rest(cpu: 100, wall: 1), 0)
        XCTAssertEqual(CPUBudget(mode: .paced, share: 0.45, maxRest: 90).rest(cpu: 1_000, wall: 1), 90)
        XCTAssertEqual(CPUBudget(mode: .paced).rest(cpu: 0.1, wall: 5), 0)   // already under the share
    }

    func testProcessCPUClockAdvances() {
        let before = CPUBudget.processCPUSeconds()
        var x = 0.0
        for i in 0..<2_000_000 { x += sin(Double(i)) }
        XCTAssertGreaterThan(CPUBudget.processCPUSeconds(), before)
        XCTAssertNotEqual(x, 0)
    }

    func testPromptIsQwenChatWithThinkingOff() {
        let prompt = CPUJudge.chatPrompt(system: "RULES", user: "LINES")
        XCTAssertTrue(prompt.hasPrefix("<|im_start|>system\nRULES<|im_end|>\n<|im_start|>user\nLINES<|im_end|>\n"))
        XCTAssertTrue(prompt.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
    }

    func testCopyIsPinnedAndNotAvailableWithoutTheEngine() {
        XCTAssertEqual(CPUReading.url.absoluteString,
                       "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_0.gguf")
        XCTAssertFalse(CPUReading.engineIncluded)   // the simulator build leaves the engine out
        XCTAssertFalse(CPUReading.isAvailable)
        XCTAssertEqual(CPUReading.twin, .qwen35_4B)
    }
}
