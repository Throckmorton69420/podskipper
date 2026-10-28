import SwiftData
import XCTest
@testable import PodSkipper

/// Pass 47: his 28 Oct exports (6eb218a, iOS 27.2). Playback resumed from an
/// earlier place after reopening; Core AI Qwen3 4B closed PodSkipper at a
/// 1,093-token part.
@MainActor
final class Pass47PlaybackRestoreTests: XCTestCase {
    private var container: ModelContainer!
    private var episode: Episode!

    override func setUp() async throws {
        container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self, Bookmark.self,
                                       SmartFilter.self, ListeningSession.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        episode = Episode(guid: "p47-ep", title: "Episode", episodeDescription: "", audioURL: "https://example.invalid/1.mp3",
                          publishedAt: Date(timeIntervalSince1970: 1_000), duration: 3_600)
        container.mainContext.insert(episode)
        PlaybackState.clear()
    }

    override func tearDown() async throws {
        PlaybackState.clear()
    }

    private func snapshot(_ position: Double, savedAt: Date?) -> PlaybackState.Snapshot {
        PlaybackState.Snapshot(guid: "p47-ep", position: position, rate: 1, savedAt: savedAt)
    }

    func testTheSnapshotWinsOverAnOlderRecord() {
        // His 22 Oct trace: paused at 1,233 s; the library still said 443 s.
        episode.setPosition(443, at: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(PlaybackState.fresherPosition(for: episode, snapshot: snapshot(1_233.1, savedAt: Date(timeIntervalSince1970: 3_000))),
                       1_233.1)
    }

    func testAnUndatedRecordFromBeforeThisPassLosesToTheSnapshot() {
        episode.playbackPosition = 443
        XCTAssertEqual(PlaybackState.fresherPosition(for: episode, snapshot: snapshot(1_233.1, savedAt: nil)), 1_233.1)
    }

    func testANewerRecordWins() {
        // Marked played, or another device's later pause, after the snapshot.
        episode.setPosition(0, at: Date(timeIntervalSince1970: 5_000))
        XCTAssertNil(PlaybackState.fresherPosition(for: episode, snapshot: snapshot(1_233.1, savedAt: Date(timeIntervalSince1970: 3_000))))
    }

    func testAnotherEpisodesSnapshotIsIgnored() {
        episode.playbackPosition = 443
        let other = PlaybackState.Snapshot(guid: "other", position: 1_233, rate: 1, savedAt: .now)
        XCTAssertNil(PlaybackState.fresherPosition(for: episode, snapshot: other))
    }

    func testRestoringBringsTheRecordUpToThePauseEvenWithoutAFile() throws {
        // Streamed (not downloaded): nothing goes into the player, but
        // playing it from its show must start where it was paused.
        episode.setPosition(443, at: Date(timeIntervalSince1970: 2_000))
        PlaybackState.save(guid: "p47-ep", position: 1_233.1, rate: 1)
        XCTAssertNil(PlaybackState.restoreEpisode(in: container.mainContext), "not downloaded: nothing to load")
        XCTAssertEqual(episode.playbackPosition, 1_233.1)
        XCTAssertNotNil(episode.playbackPositionChangedAt)
    }

    func testStartUsesTheAdoptedPosition() {
        episode.playbackPosition = 443
        PlaybackState.save(guid: "p47-ep", position: 1_233.1, rate: 1)
        PlaybackState.adoptFresherPosition(into: episode)
        XCTAssertEqual(PlaybackStart.resolve(requested: nil, saved: episode.playbackPosition, duration: 3_600, intro: 0), 1_233.1)
    }
}

final class Pass47CoreAIMemoryTests: XCTestCase {
    func testTheSequentialEngineMakesItsWholeMemoryAtLoad() {
        // Qwen3 4B's bundle holds 40,960; the phone reads 2,047 on the
        // sequential engine — the memory is made at 2,048 once.
        XCTAssertEqual(CoreAIBundleLimits.heldMemory(bundleContext: 40_960, route: .sequential), 2_048)
        XCTAssertEqual(CoreAIBundleLimits.heldMemory(bundleContext: 1_500, route: .sequential), 1_500)
    }

    func testThePipelinedEnginesHoldTheirCap() {
        XCTAssertEqual(CoreAIBundleLimits.heldMemory(bundleContext: 8_192, route: .runtimeGrammar), 1_024)
        XCTAssertEqual(CoreAIBundleLimits.heldMemory(bundleContext: 8_192, route: .pipelinedPrimed), 1_024)
    }

    func testStaticShapeAndTheMacAreLeftAlone() {
        XCTAssertNil(CoreAIBundleLimits.heldMemory(bundleContext: 4_096, route: .staticShape))
        XCTAssertNil(CoreAIBundleLimits.heldMemory(bundleContext: 4_096, route: .sequential, iOS: false))
    }

    func testQwen3FourBPartsAreNoLongerHeldUnderACeiling() {
        let plan = ModelPromptPlan.coreAI(id: "qwen3-4b", name: "Qwen3 4B", template: "", context: 2_047)
        XCTAssertNil(plan.promptCeiling)
        XCTAssertFalse(plan.identity.contains("ceiling"))
    }
}

/// Pass 47: his corrections teach the Reader only while they still hold.
final class Pass47LearnerTests: XCTestCase {
    private typealias Learner = OnDeviceReaderLearner

    private func delta(_ action: String, _ start: Double, _ end: Double, _ kind: String) -> CorrectionDelta {
        CorrectionDelta(date: .now, action: action, start: start, end: end, kind: kind, contains: [kind], predictions: [],
                        grade: CutGrade(recall: 1, precision: 1, labelAgreement: 1, fragments: 1, score: 100),
                        finder: "", absorbed: 0, key: "\(action)\(start)")
    }

    /// Whiskey Ginger (Ryan Hamilton): an added "ad" of 2,442–3,707 s he
    /// later removed; his locks inside it still stand.
    private let sentences = (0..<500).map { Sentence(text: "s\($0)", start: Double($0) * 10, end: Double($0) * 10 + 9) }
    private let current: [Learner.CurrentCut] = [
        .init(start: 2_518, end: 2_550, kind: "ad"), .init(start: 2_550, end: 2_578, kind: "crossPromo"),
        .init(start: 2_580, end: 2_608, kind: "ad"),
    ]

    func testARemovedAddTeachesNothing() {
        let labels = Learner.goldLabels(sentences: sentences, deltas: [delta("add", 2_442, 3_707, "ad")], current: current)
        XCTAssertTrue(labels.isEmpty, "the removed 21 minutes are not an ad: \(labels.count) labels")
    }

    func testEachSentenceTakesTheKindOfTheCutOverItNow() {
        let labels = Learner.goldLabels(sentences: sentences, deltas: [delta("lock", 2_518, 2_608, "ad")], current: current)
        XCTAssertEqual(labels[253]?.label, 1, "2,530 s: ad")
        XCTAssertEqual(labels[256]?.label, 3, "2,560 s: the promo for another show, not the delta's 'ad'")
        XCTAssertEqual(labels[259]?.label, 1)
    }

    func testAReviewedEpisodeKeepsTheLabsBalanceAndItsCap() {
        let long: [Learner.CurrentCut] = [.init(start: 100, end: 2_000, kind: "ad")]
        let labels = Learner.goldLabels(sentences: sentences, deltas: [delta("lock", 100, 2_000, "ad")], current: long)
        let promo = labels.values.filter { $0.label != 0 }.reduce(Float(0)) { $0 + $1.weight }
        let show = labels.values.filter { $0.label == 0 }.reduce(Float(0)) { $0 + $1.weight }
        XCTAssertGreaterThan(show, 0, "the show he left alone teaches too")
        XCTAssertLessThanOrEqual(promo + show, Learner.goldEpisodeCap * Learner.goldWeight + 0.01)
        XCTAssertLessThan(promo / (promo + show), 0.75, "not ~100 % promos any more")
    }

    func testANotAnAdStillClearStillTeachesTheShow() {
        let labels = Learner.goldLabels(sentences: sentences, deltas: [delta("notAnAd", 300, 330, "show"), delta("lock", 2_518, 2_550, "ad")],
                                        current: current)
        XCTAssertEqual(labels[31]?.label, 0)
        let undone = Learner.goldLabels(sentences: sentences, deltas: [delta("notAnAd", 2_518, 2_550, "show")], current: current)
        XCTAssertNil(undone[253], "a Not an Ad where a cut stands again teaches nothing")
    }

    func testFitKeepsTheLastEpochTheCheckAccepts() {
        let base = ReaderHead(inputs: 4, mid: 3, outputs: 6,
                              midWeight: (0..<12).map { Float($0 % 5) * 0.1 }, midBias: [0, 0, 0],
                              outWeight: (0..<18).map { Float($0 % 7) * 0.05 }, outBias: Array(repeating: 0, count: 6))
        let data = Learner.Batchable(x: (0..<40).map { Float($0 % 9) * 0.1 }, labels: Array(repeating: 1, count: 10),
                                     weights: Array(repeating: 1, count: 10), inputs: 4)
        let none = Learner.fit(start: base, base: base, data: data, epochs: 4, keep: { _ in false })
        XCTAssertEqual(none, base, "no epoch accepted: the start")
        var seen = 0
        let second = Learner.fit(start: base, base: base, data: data, epochs: 4, keep: { _ in seen += 1; return seen <= 2 })
        XCTAssertNotEqual(second, base)
        XCTAssertNotEqual(second, Learner.fit(start: base, base: base, data: data, epochs: 4), "stopped at the second epoch")
    }
}

/// Pass 47: listening state merges part by part, the newer winning.
@MainActor
final class Pass47ListeningSyncTests: XCTestCase {
    private typealias L = CloudSync.Listening

    func testANewerPauseElsewhereWinsEvenWhenItIsARewind() {
        let here = L(p: 1_800, pa: 1_000, pl: false, st: false, fa: 0, lp: 900)
        let there = L(p: 600, pa: 2_000, pl: false, st: false, fa: 0, lp: 950)
        let merged = CloudSync.merged(local: here, remote: there)
        XCTAssertEqual(merged.p, 600, "his rewind on the iPad, made later, wins")
        XCTAssertEqual(merged.lp, 950)
    }

    func testAnOlderRemotePositionDoesNotMoveThisOne() {
        let here = L(p: 1_800, pa: 3_000, pl: false, st: true, fa: 2_500, lp: 900)
        let there = L(p: 600, pa: 2_000, pl: true, st: false, fa: 1_000, lp: 950)
        let merged = CloudSync.merged(local: here, remote: there)
        XCTAssertEqual(merged.p, 1_800)
        XCTAssertTrue(merged.st)
        XCTAssertFalse(merged.pl)
    }

    func testPlayedAndStarredGoByTheirOwnTime() {
        let here = L(p: 1_800, pa: 3_000, pl: false, st: false, fa: 1_000, lp: nil)
        let there = L(p: 0, pa: 1_500, pl: true, st: false, fa: 4_000, lp: nil)
        let merged = CloudSync.merged(local: here, remote: there)
        XCTAssertTrue(merged.pl, "marked played later elsewhere")
        XCTAssertEqual(merged.p, 1_800, "the position is its own part")
    }

    func testALocalChangeOfPlayedIsStampedNow() {
        let episode = Episode(guid: "s1", title: "E", episodeDescription: "", audioURL: "https://example.invalid/1.mp3",
                              publishedAt: .now, duration: 3_600)
        episode.isPlayed = true
        episode.setPosition(0, at: Date(timeIntervalSince1970: 5_000))
        let now = Date(timeIntervalSince1970: 9_000)
        let record = CloudSync.record(episode, flags: (pl: false, st: false, fa: 1_000), now: now)
        XCTAssertEqual(record.fa, 9_000)
        XCTAssertEqual(record.pa, 5_000)
        XCTAssertEqual(CloudSync.record(episode, flags: (pl: true, st: false, fa: 1_000), now: now).fa, 1_000, "unchanged: its old time")
    }

    func testTheBudgetKeepsTheMostRecentlyChanged() throws {
        var records: [String: L] = [:]
        for i in 0..<4_000 { records["guid-\(i)-" + String(repeating: "x", count: 30)] = L(p: 1, pa: Double(i), pl: false, st: false, fa: 0, lp: nil) }
        let data = CloudSync.encodeWithinBudget(records, budget: 100_000)
        XCTAssertLessThanOrEqual(data.count, 100_000)
        let kept = try JSONDecoder().decode([String: L].self, from: data)
        XCTAssertNotNil(kept["guid-3999-" + String(repeating: "x", count: 30)])
        XCTAssertNil(kept["guid-0-" + String(repeating: "x", count: 30)])
    }
}
