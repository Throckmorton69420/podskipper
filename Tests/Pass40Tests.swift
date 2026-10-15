import XCTest
import SwiftData
@testable import PodSkipper

/// Pass 40: heat policy (keep reading, pause only when critical, with a
/// resume rule), heat timeline, answers that run out of room.
final class Pass40Tests: XCTestCase {
    override func tearDown() {
        ThermalPacing.stateOverride = nil
        ThermalPacing.policyOverride = nil
        ThermalPacing.criticalLimit = 5 * 60
        HeatLog.reset()
        super.tearDown()
    }

    // MARK: Heat policy

    func testSeriousKeepsReadingByDefault() async throws {
        ThermalPacing.stateOverride = .serious
        let before = ThermalPacing.cooledSeconds()
        try await ThermalPacing.beforePart(status: { _ in XCTFail("no wait line at serious") },
                                           sleep: { _ in XCTFail("no rest at serious") })
        XCTAssertEqual(ThermalPacing.cooledSeconds(), before, accuracy: 0.001, "nothing counted as waiting")
        XCTAssertNil(ThermalPacing.wait)
    }

    func testComparisonPolicyStillRests() async throws {
        ThermalPacing.policyOverride = .restBetweenParts
        ThermalPacing.stateOverride = .serious
        var slept = 0
        try await ThermalPacing.beforePart(status: { _ in }, sleep: { _ in slept += 1 })
        XCTAssertEqual(slept, 20)
    }

    /// Critical pauses; once out of critical it waits for `resumeTicks`
    /// seconds in a row, and a return to critical starts the count again.
    func testCriticalResumesOnlyAfterStayingOutOfCritical() async throws {
        ThermalPacing.stateOverride = .critical
        var ticks = 0
        // critical, serious ×3, critical again, then serious from there on.
        let script: [ProcessInfo.ThermalState] = [.serious, .serious, .serious, .critical]
        try await ThermalPacing.beforePart(status: { _ in }, sleep: { _ in
            ticks += 1
            ThermalPacing.stateOverride = ticks <= script.count ? script[ticks - 1] : .serious
        })
        // 1 critical tick, 3 cool, 1 critical, then 10 cool in a row.
        XCTAssertEqual(ticks, 1 + 3 + 1 + ThermalPacing.resumeTicks)
        XCTAssertNil(ThermalPacing.wait)
    }

    func testCriticalSaysPausedWhileHolding() async throws {
        ThermalPacing.stateOverride = .critical
        var lines: [String] = []
        try await ThermalPacing.beforePart(status: { lines.append($0) }, sleep: { _ in
            ThermalPacing.stateOverride = .fair
        })
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("Paused: iPhone is too hot") }, lines.joined(separator: "\n"))
    }

    func testHoldInsideAPartOnlyWhenCritical() {
        ThermalPacing.stateOverride = .serious
        var slept = 0
        ThermalPacing.holdWhileCritical(sleep: { _ in slept += 1 })
        XCTAssertEqual(slept, 0, "serious never holds the work")

        ThermalPacing.stateOverride = .critical
        let before = ThermalPacing.cooledSeconds()
        ThermalPacing.holdWhileCritical(sleep: { _ in
            slept += 1
            XCTAssertNotNil(ThermalPacing.wait, "the hold shows as a wait")
            if slept == 2 { ThermalPacing.stateOverride = .serious }
        })
        XCTAssertEqual(slept, 2 + ThermalPacing.resumeTicks, "two critical seconds, then ten in a row out of it")
        XCTAssertNil(ThermalPacing.wait)
        XCTAssertGreaterThanOrEqual(ThermalPacing.cooledSeconds(), before)
    }

    // MARK: Heat timeline

    func testTimelineGivesStatesWithTimesAndSecondsInEach() {
        HeatLog.reset()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        HeatLog.record(.nominal, at: t0)
        HeatLog.record(.fair, at: t0.addingTimeInterval(60))
        HeatLog.record(.fair, at: t0.addingTimeInterval(70))   // no change, not a new entry
        HeatLog.record(.serious, at: t0.addingTimeInterval(130))
        let line = HeatLog.timeline(from: t0.addingTimeInterval(30), to: t0.addingTimeInterval(230))
        XCTAssertEqual(line.lines, ["0 s nominal", "+30 s fair", "+100 s serious"])
        XCTAssertEqual(line.seconds["nominal"] ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(line.seconds["fair"] ?? 0, 70, accuracy: 0.01)
        XCTAssertEqual(line.seconds["serious"] ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(HeatLog.state(at: t0.addingTimeInterval(65)), .fair)
    }

    // MARK: Work per minute

    func testClassifiedTokensPerMinuteCountsTheWholeWallClock() {
        var stats = JudgeStats(model: "m")
        stats.startedAt = Date(timeIntervalSince1970: 0)
        stats.finishedAt = Date(timeIntervalSince1970: 240)
        stats.classifiedPromptTokens = 12_000
        XCTAssertEqual(stats.classifiedTokensPerMinute(), 3_000)
        stats.classifiedPromptTokens = 0
        XCTAssertNil(stats.classifiedTokensPerMinute())
    }

    // MARK: Answers that run out of room (his WMBD part 4, 8839e72)

    func testEmptyFreeAnswerAfterAnOverflowIsNotKept() {
        var first = LocalJudge.PartRead(held: true)
        first.ranOutOfRoom = true
        var empty = LocalJudge.PartRead()
        empty.parts = []
        XCTAssertFalse(LocalJudge.keepsRetry(after: first, retry: empty), "\"no ads here\" isn't believed")
        var named = LocalJudge.PartRead()
        named.parts = [JudgePrompt.RawPart(firstLine: 0, lastLine: 3, firstWords: "", lastWords: "", label: .guestPlug, sponsor: "tour dates", funny: false, confidence: 80, why: "")]
        XCTAssertTrue(LocalJudge.keepsRetry(after: first, retry: named))
        var unreadable = LocalJudge.PartRead(held: true)
        unreadable.failure = "not JSON"
        XCTAssertTrue(LocalJudge.keepsRetry(after: unreadable, retry: empty), "an ordinary retry may say nothing was there")
    }

    func testPartReadLogKeepsWhatTheFailedAnswerWrote() {
        var read = LocalJudge.PartRead(held: true)
        read.failure = "The answer ran out of room (320 tokens) before it was complete."
        read.text = #"{"parts":[{"first_line":3,"last_line":9,"label":"GUEST_PLUG""#
        read.generatedTokens = 320
        let line = read.log(attempt: 1)
        XCTAssertTrue(line.hasPrefix("Attempt 1 (held to the format): The answer ran out of room"))
        XCTAssertTrue(line.contains("320 tokens"))
        XCTAssertTrue(line.contains("GUEST_PLUG"))
    }

    // MARK: Saves that matter to a page (his Downloaded lag)

    @MainActor
    func testStoreChangesSaysWhatASaveTouched() throws {
        let container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        var seen: [StoreChanges] = []
        let observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { note in
            if let change = StoreChanges(note, container: container) { MainActor.assumeIsolated { seen.append(change) } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let show = Podcast(feedURL: "https://example.invalid/feed", title: "Show")
        context.insert(show)
        try context.save()
        XCTAssertTrue(seen.last?.changesShowList == true, "a show added changes the show list")

        let episode = Episode(guid: "e1", title: "One", episodeDescription: "", audioURL: "https://example.invalid/1.mp3",
                              publishedAt: .now, duration: 60)
        episode.podcast = show
        context.insert(episode)
        try context.save()
        let added = try XCTUnwrap(seen.last)
        XCTAssertFalse(added.changesShowList, "an episode added doesn't change which shows there are")
        XCTAssertEqual(added.of(Episode.self, added.inserted), [episode.persistentModelID])

        episode.isStarred = true
        try context.save()
        let starred = try XCTUnwrap(seen.last)
        XCTAssertTrue(starred.of(Episode.self, starred.updated).contains(episode.persistentModelID))
        XCTAssertTrue(starred.of(Episode.self, starred.inserted).isEmpty)

        context.delete(show)
        try context.save()
        XCTAssertTrue(seen.last?.changesShowList == true, "a show removed changes the show list")
        XCTAssertFalse(show.isLive, "a deleted show isn't drawn from a kept list")
        XCTAssertTrue(StoreChanges(inserted: [], unknown: true).changesShowList, "a save that says nothing counts as everything")
        let other = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let otherSaves = seen.count
        other.mainContext.insert(Podcast(feedURL: "https://example.invalid/other", title: "Other"))
        try other.mainContext.save()
        XCTAssertEqual(seen.count, otherSaves, "another container's saves are ignored")
    }
}
