import XCTest
import SwiftData
@testable import PodSkipper

/// Pass 56: what his 31 Oct phone (build da0c477) showed.
final class Pass56StallWatchTests: XCTestCase {
    func testASuspensionIsNotCountedAsTheScreenNotResponding() {
        // His 1,433 s "stall" on Library: paused, suspended, back 24 min later.
        XCTAssertEqual(MainThreadWatch.counted(silent: 1, gap: 1_433, active: false), 0)
        XCTAssertEqual(MainThreadWatch.counted(silent: 2, gap: 1, active: false), 3)
    }

    func testALateTickInFrontStillCounts() {
        // In front iOS doesn't suspend the app: a busy CPU only delays the timer.
        XCTAssertEqual(MainThreadWatch.counted(silent: 3, gap: 4, active: true), 7)
    }
}

final class Pass56StorageTests: XCTestCase {
    func testTheLibraryIsShortOfSpaceOnlyWhenPlainFreeSpaceIsLow() {
        // His recovery screen: "4665 MB for important use, 105 MB plain".
        XCTAssertEqual(LibraryStore.shortOfSpace(free: 105_000_000), 105_000_000)
        XCTAssertNil(LibraryStore.shortOfSpace(free: 4_665_000_000))
        XCTAssertNil(LibraryStore.shortOfSpace(free: nil))
    }

    func testPreparingAModelIsJudgedOnSpaceActuallyFree() {
        let verdict = StorageGuard.check(writing: 2_000_000_000, free: 105_000_000)
        guard case .insufficient = verdict else { return XCTFail("105 MB can't hold a 2 GB preparation") }
        let message = StorageGuard.preparationMessage(for: verdict, name: "Qwen3.5 2B") ?? ""
        XCTAssertTrue(message.contains("Qwen3.5 2B"))
        XCTAssertNil(StorageGuard.preparationMessage(for: .ok, name: "Qwen3.5 2B"))
    }

    func testAClosureWithStorageNearlyFullSaysSoFirst() {
        let note = CoreAIInFlight.Note(id: "qwen3.5-2b", name: "Qwen3.5 2B", episode: "",
                                       stage: "preparing the model for this iPhone", diskMB: 105)
        let said = CoreAIInFlight.launchNote(note)
        XCTAssertTrue(said.contains("105 MB of storage"), said)
        let roomy = CoreAIInFlight.Note(id: "qwen3.5-2b", name: "Qwen3.5 2B", episode: "", stage: "loading", diskMB: 9_000)
        XCTAssertFalse(CoreAIInFlight.launchNote(roomy).contains("MB of storage"))
    }
}

final class Pass56ReadOverrunTests: XCTestCase {
    func testAPromptWithinReasonSaysNothingExtra() {
        XCTAssertNil(CoreAIReadOverrun.message(elapsed: 100, expected: 100, part: "part 1 of 1"))
        XCTAssertNil(CoreAIReadOverrun.message(elapsed: 160, expected: 100, part: "part 1 of 1"))
    }

    func testAPromptFarPastItsUsualSpeedSaysHowLongItHasRead() {
        // "Stuck at 72–73 %": the bar had reached the end of its estimate.
        let said = CoreAIReadOverrun.message(elapsed: 300, expected: 100, part: "part 1 of 1") ?? ""
        XCTAssertTrue(said.contains("5:00"), said)
        XCTAssertTrue(said.contains("1:40"), said)
    }
}

@MainActor
final class Pass56FunnyReadTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() async throws { container = nil }

    private func episode() -> Episode {
        let context = container.mainContext
        let show = Podcast(feedURL: "https://example.invalid/los.xml", title: "Legion of Skanks")
        context.insert(show)
        let episode = Episode(guid: "los954", title: "954", episodeDescription: "", audioURL: "https://example.invalid/954.mp3",
                              publishedAt: .now, duration: 6_829)
        context.insert(episode); episode.podcast = show
        return episode
    }

    func testAProducedSpotIsNeverKeptAsFunny() {
        let spot = AdSegment(start: 2_502, end: 2_516, kind: .ad)
        spot.isComedyBit = true; spot.deliveryRaw = "produced"
        XCTAssertFalse(spot.isFunnyHostRead)
        let read = AdSegment(start: 100, end: 160, kind: .ad)
        read.isComedyBit = true; read.deliveryRaw = "host"
        XCTAssertTrue(read.isFunnyHostRead)
        read.kind = .selfPromo
        XCTAssertFalse(read.isFunnyHostRead)
    }

    func testLockingOverOtherCutsDropsTheModelsFunnyFlag() throws {
        // #954: Sheath (flagged funny) locked out over GLD, Brunt and a Patreon plug.
        let episode = episode()
        let context = container.mainContext
        let sheath = AdSegment(start: 2_550, end: 2_735, sponsor: "sheath", kind: .ad)
        sheath.isComedyBit = true; sheath.deliveryRaw = "host"
        let brunt = AdSegment(start: 2_735, end: 2_862, sponsor: "bruntworkware", kind: .ad)
        let patreon = AdSegment(start: 2_862, end: 2_957, kind: .selfPromo)
        for s in [sheath, brunt, patreon] { context.insert(s); s.episode = episode }
        sheath.end = 2_960; sheath.isLocked = true
        XCTAssertEqual(CorrectionLedger.locked(sheath, in: episode, context: context), 2)
        XCTAssertFalse(sheath.isComedyBit)
        XCTAssertFalse(sheath.isFunnyHostRead)
        let settings = AppSettings()
        let saved = settings.keepComedyBitAds
        defer { settings.keepComedyBitAds = saved }
        settings.keepComedyBitAds = true
        XCTAssertFalse(sheath.keptByDelivery(settings), "his locked block is skipped, not played for one funny flag")
    }

    func testABlockSavedBeforeThisPassIsSkippedToo() {
        // Already merged with the flag kept (his saved #954).
        let block = AdSegment(start: 2_550, end: 2_960, sponsor: "sheath", kind: .ad)
        block.isComedyBit = true; block.deliveryRaw = "host"
        block.mergedFromData = try? JSONEncoder().encode([CutGrade.Piece(start: 2_736, end: 2_817, kind: "ad", detail: "", sponsor: "bruntworkware",
                                                                          confidence: 85, delivery: "host", evidence: "")])
        XCTAssertFalse(block.isFunnyHostRead)
    }

    func testHisOwnComedyBitChoiceStands() {
        let choices = CutChoice.choices(for: .ad)
        let bit = try? XCTUnwrap(choices.first { $0.detail == .comedy })
        XCTAssertEqual(bit?.delivery, "host")
        let block = AdSegment(start: 0, end: 60, kind: .ad)
        block.detailRaw = CutDetail.comedy.rawValue
        block.mergedFromData = try? JSONEncoder().encode([CutGrade.Piece(start: 0, end: 30, kind: "ad", detail: "", sponsor: "",
                                                                          confidence: 80, delivery: "", evidence: "")])
        XCTAssertTrue(block.isFunnyHostRead, "what he says it is, even after taking in other cuts")
        CorrectionLedger.dropModelComedyFlag(block)
        block.isComedyBit = true
        CorrectionLedger.dropModelComedyFlag(block)
        XCTAssertTrue(block.isComedyBit)
    }
}

@MainActor
final class Pass56BenchIndexTests: XCTestCase {
    func testRunsPerEngineAreNewestFirstAndFollowNewResults() {
        let defaults = UserDefaults(suiteName: "p56-bench-\(UUID().uuidString)")!
        let bench = ModelBench(defaults: defaults, recoverInterrupted: false)
        XCTAssertTrue(bench.runs("reader").isEmpty)
        bench.save(BenchResult(engine: "reader", name: "Reader", sample: .basic, date: Date(timeIntervalSince1970: 100), score: 0.5))
        bench.save(BenchResult(engine: "reader", name: "Reader", sample: .basic, date: Date(timeIntervalSince1970: 200), score: 0.9))
        bench.save(BenchResult(engine: "apple", name: "Apple", sample: .hard, date: Date(timeIntervalSince1970: 150), score: 0.1))
        XCTAssertEqual(bench.runs("reader").map(\.score), [0.9, 0.5])
        XCTAssertEqual(bench.lastScored("reader", .basic)?.score, 0.9)
        XCTAssertEqual(bench.runs("apple").count, 1)
    }
}
