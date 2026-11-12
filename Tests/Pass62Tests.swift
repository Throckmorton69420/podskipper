import XCTest
import SwiftData
@testable import PodSkipper

/// Pass 62 (his 8 Nov phone run on 61362ba / 2d2f608).

// MARK: A1 — the PodSkipper Test keeps the finished results

@MainActor
final class Pass62PodTestRunTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appending(path: "p62-\(UUID().uuidString)")
        suite = "p62-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func run(_ state: PodTestRun.State, started: Double, readerDone: Int, modelDone: Int = 0) -> PodTestRun {
        let guids = (0..<11).map { "g\($0)" }
        func reads(_ done: Int) -> [PodTestRun.Read] {
            guids.enumerated().map { i, g in
                i < done ? .init(guid: g, outcome: .completed, cuts: [PodTestCut(start: 0, end: 10, kind: "ad")]) : .init(guid: g)
            }
        }
        return PodTestRun(runID: UUID(), started: Date(timeIntervalSince1970: started), state: state, appBuild: "t", device: "t",
                          packVersion: 1,
                          engines: [.init(engine: "reader", name: "Reader", kind: .reader, reads: reads(readerDone)),
                                    .init(engine: "m", name: "Model", kind: .mlx, reads: reads(modelDone))])
    }

    /// His export: run D26EC86F finished every read; 6933DC0A was stopped at
    /// 0 reads and C2EFA6DA interrupted after 1. The finished run's table stays.
    func testAStoppedRunNeverHidesTheFinishedOne() {
        let finished = run(.completed, started: 1_000, readerDone: 11, modelDone: 11)
        let stoppedAtZero = run(.stopped, started: 2_000, readerDone: 0)
        let interruptedAtOne = run(.interrupted, started: 3_000, readerDone: 1)
        XCTAssertEqual(PodTestRunner.resultsRun(in: [finished, stoppedAtZero, interruptedAtOne])?.runID, finished.runID)
        XCTAssertNil(PodTestRunner.resultsRun(in: [stoppedAtZero]))
        // No finished run: the one that read most.
        let partial = run(.interrupted, started: 4_000, readerDone: 11, modelDone: 3)
        XCTAssertEqual(PodTestRunner.resultsRun(in: [stoppedAtZero, partial, interruptedAtOne])?.runID, partial.runID)
        // A later unfinished run that read more models than the finished one takes the table.
        let small = run(.completed, started: 1_000, readerDone: 11, modelDone: 2)
        let bigger = run(.stopped, started: 5_000, readerDone: 11, modelDone: 9)
        XCTAssertEqual(PodTestRunner.resultsRun(in: [small, bigger])?.runID, bigger.runID)
    }

    func testKeepEarlierResultsSetsTheStoppedRunAside() throws {
        let store = PodTestStore(url: dir.appending(path: "runs.json"))
        let finished = run(.completed, started: 1_000, readerDone: 11, modelDone: 11)
        let stoppedAtZero = run(.stopped, started: 2_000, readerDone: 0)
        try store.save([finished, stoppedAtZero])
        let runner = PodTestRunner(store: store, pack: .bundled(), defaults: defaults)
        XCTAssertEqual(runner.unfinished?.runID, stoppedAtZero.runID, "Resume / Start Over / Keep Earlier Results are offered")
        XCTAssertEqual(runner.resultsRun?.runID, finished.runID, "the finished table shows meanwhile")
        runner.dismissUnfinished()
        XCTAssertNil(runner.unfinished, "back to Run the Test")
        XCTAssertEqual(runner.runs.map(\.runID), [finished.runID], "a run that read nothing is removed")
        XCTAssertEqual(store.load().map(\.runID), [finished.runID], "and that is saved")
        XCTAssertEqual(runner.resultsRun?.runID, finished.runID)

        // One that read something is kept, set aside.
        let partial = run(.interrupted, started: 3_000, readerDone: 4)
        try store.save([finished, partial])
        let again = PodTestRunner(store: store, pack: .bundled(), defaults: defaults)
        XCTAssertEqual(again.unfinished?.runID, partial.runID)
        again.dismissUnfinished()
        XCTAssertNil(again.unfinished)
        XCTAssertEqual(again.runs.count, 2)
        XCTAssertEqual(again.runs.last?.dismissed, true)
        XCTAssertEqual(PodTestStore(url: dir.appending(path: "runs.json")).load().last?.dismissed, true)
    }

    /// B1: every downloaded model has its own switch; the chosen ones start on.
    func testEachFinderHasItsOwnSwitch() {
        let runner = PodTestRunner(store: PodTestStore(url: dir.appending(path: "runs.json")), pack: .bundled(), defaults: defaults)
        let plans = runner.plans()
        XCTAssertEqual(plans.first?.kind, .reader)
        XCTAssertEqual(Set(plans.map(\.id)).count, plans.count, "one switch per engine, not per kind")
        XCTAssertTrue(plans.contains { $0.kind == .cpu && $0.engine == CPUReading.selected.engineID })
        let chosen = PodTestRunner.Plan(engine: "a", name: "A", kind: .mlx, chosen: true)
        let other = PodTestRunner.Plan(engine: "b", name: "B", kind: .mlx, chosen: false)
        XCTAssertTrue(runner.isIncluded(chosen))
        XCTAssertFalse(runner.isIncluded(other), "other downloaded models are offered off")
        runner.setIncluded(other, true)
        runner.setIncluded(chosen, false)
        let relaunched = PodTestRunner(store: PodTestStore(url: dir.appending(path: "runs.json")), pack: .bundled(), defaults: defaults)
        XCTAssertTrue(relaunched.isIncluded(other))
        XCTAssertFalse(relaunched.isIncluded(chosen))
    }
}

// MARK: A2 — Basic and Hard, and the live scoreboard
// Pass 63: the samples are version 4 (real timing, a four-part score); their
// tests and the scoreboard's are in Pass63Tests.

// MARK: A3 / B2 — CPU models

final class Pass62CPUModelTests: XCTestCase {
    func testCatalogIsPinned() {
        // Pass 63: five, with Liquid's LFM3 1.7B.
        XCTAssertEqual(CPUReading.catalog.count, 5)
        XCTAssertEqual(Set(CPUReading.catalog.map(\.id)).count, 5)
        XCTAssertEqual(Set(CPUReading.catalog.map(\.engineID)).count, 5, "each keeps its own results")
        for model in CPUReading.catalog {
            XCTAssertEqual(model.sha256.count, 64)
            XCTAssertEqual(model.revision.count, 40)
            XCTAssertGreaterThan(model.bytes, 500_000_000)
            XCTAssertTrue(model.url.absoluteString.hasPrefix("https://huggingface.co/\(model.repo)/resolve/\(model.revision)/"))
            XCTAssertFalse(LocalModelSpec.all.contains { $0.id == model.engineID })
        }
        // Pass 58's copy keeps its id, file and results.
        XCTAssertEqual(CPUReading.qwen35_4B_q4.engineID, LocalModelSpec.qwen35_4B.id + "#cpu")
        XCTAssertEqual(CPUReading.qwen35_4B_q4.file, "Qwen3.5-4B-Q4_0.gguf")
        // The Instruct 6-bit's CPU twin: the same base model at 6 bits, asked the Instruct way.
        XCTAssertEqual(CPUReading.qwen35_4B_q6.file, "Qwen3.5-4B-Q6_K.gguf")
        XCTAssertEqual(CPUReading.qwen35_4B_q6.twin, .qwen35_4B_instruct)
        XCTAssertEqual(ModelPromptPlan.plan(for: CPUReading.qwen35_4B_q6.twin, folder: nil).profile, .listenerEdges)
        XCTAssertFalse(LocalModelSpec.all.contains(.lfm25_1_2B_cpu), "LFM2.5 1.2B is a CPU model only")
        XCTAssertEqual(ModelPromptPlan.plan(for: .lfm25_1_2B_cpu, folder: nil).family, "LFM2.5")
    }

    func testChosenModelIsRemembered() {
        let before = UserDefaults.standard.string(forKey: CPUReading.selectionKey)
        defer { UserDefaults.standard.set(before, forKey: CPUReading.selectionKey) }
        UserDefaults.standard.removeObject(forKey: CPUReading.selectionKey)
        XCTAssertEqual(CPUReading.selected, CPUReading.qwen35_4B_q4)
        CPUReading.selected = CPUReading.lfm25_1_2B_q4
        XCTAssertEqual(CPUReading.selected, CPUReading.lfm25_1_2B_q4)
        XCTAssertEqual(CPUReading.displayName, "LFM2.5 1.2B (CPU)")
        XCTAssertEqual(ModelBench.cpuEngineID, CPUReading.lfm25_1_2B_q4.engineID)
        UserDefaults.standard.set("not a model", forKey: CPUReading.selectionKey)
        XCTAssertEqual(CPUReading.selected, CPUReading.qwen35_4B_q4)
    }

    /// The prompt is the same text as before, in two pieces: the shared
    /// start (rules + header) and the part's own lines.
    func testPromptSplitsAtTheSharedStart() {
        let model = CPUReading.qwen35_4B_q4
        let pieces = model.chatPrompt(system: "RULES", header: "Show: S\n", rest: "LINES")
        XCTAssertEqual(pieces.head + pieces.tail, CPUJudge.chatPrompt(system: "RULES", user: "Show: S\nLINES"))
        let liquid = CPUReading.lfm25_1_2B_q4.chatPrompt(system: "R", header: "H", rest: "L")
        XCTAssertEqual(liquid.head + liquid.tail, "<|startoftext|><|im_start|>system\nR<|im_end|>\n<|im_start|>user\nHL<|im_end|>\n<|im_start|>assistant\n")
        XCTAssertEqual(CPUJudge.commonPrefix([1, 2, 3, 4], [1, 2, 9]), 2)
        XCTAssertEqual(CPUJudge.commonPrefix([1, 2], [1, 2, 3]), 2)
    }

    /// 264d9ec5 failed on the phone: "reached its 320-token answer limit".
    func testAnswerRoomAndSplitting() {
        let plan = ModelPromptPlan.plan(for: .qwen35_4B, folder: nil)
        XCTAssertEqual(plan.answerCap, 320)
        XCTAssertGreaterThanOrEqual(CPUJudge.answerCap(plan), 640)
        XCTAssertGreaterThanOrEqual(CPUJudge.answerCap(plan), LocalJudge.heldAnswerCap(plan))
        // A part that still runs out of room is read again in two halves.
        let halves = try? XCTUnwrap(CPUJudge.halves(100..<230))
        XCTAssertEqual(halves?.count, 2)
        XCTAssertEqual(halves?.first?.lowerBound, 100)
        XCTAssertEqual(halves?.last?.upperBound, 230)
        XCTAssertGreaterThan(halves?.first?.upperBound ?? 0, halves?.last?.lowerBound ?? 0, "they overlap a little")
        XCTAssertNil(CPUJudge.halves(0..<11), "too short to split: the complete parts of the answer are kept")
        // Lenient reading keeps the complete parts of an answer cut short.
        let cut = #"{"parts":[{"first_line":2,"last_line":9,"label":"PAID_AD","sponsor":"A"},{"first_line":20,"last_line":2"#
        XCTAssertNil(JudgePrompt.parseComplete(cut))
        XCTAssertEqual(JudgePrompt.parse(cut)?.count, 1)
        XCTAssertEqual(CPUJudge.batchTokens(.full), 256)
        XCTAssertEqual(CPUJudge.batchTokens(.paced), 128)
    }

    // Pass 63: who reads on screen and off is `FinderRouting` now
    // (Pass63RoutingTests); the MLX page's paragraph is gone.
}

// MARK: A4 — exports written as they are made

final class Pass62ExportTests: XCTestCase {
    private var urls: [URL] = []
    override func tearDown() {
        for url in urls { try? FileManager.default.removeItem(at: url) }
        super.tearDown()
    }

    func testWriterMakesValidJSONInPieces() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "p62-\(UUID().uuidString).json")
        urls.append(url)
        let out = try JSONFileWriter(url: url)
        struct Row: Encodable { var date: Date; var n: Int }
        try out.object { key in
            try key("a") { try out.value(["x": 1, "y": [true, false]] as [String: Any]) }
            try key("b") { try out.encodable([Row(date: Date(timeIntervalSince1970: 0), n: 2)]) }
            try key("big") {
                try out.raw("[")
                for i in 0..<5_000 { try out.raw((i > 0 ? "," : "") + "\(i)") }
                try out.raw("]")
            }
            try key("s") { try out.value("quote \" and\nnewline") }
        }
        try out.close()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((root["a"] as? [String: Any])?["x"] as? Int, 1)
        XCTAssertEqual(((root["b"] as? [[String: Any]])?.first?["date"]) as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual((root["big"] as? [Int])?.count, 5_000)
        XCTAssertEqual(root["s"] as? String, "quote \" and\nnewline")
    }

    /// Deep nesting is written on a thread with a 16 MB stack.
    func testLargeStackRunsDeepWork() async throws {
        let depth = 20_000
        let nested = try await LargeStack.run { () -> Int in
            func dive(_ n: Int) -> Int { n == 0 ? 0 : 1 + dive(n - 1) }
            return dive(depth)
        }
        XCTAssertEqual(nested, depth)
    }

    @MainActor
    func testResultsExportStreamsEachEpisodeWithItsTranscriptAsStored() async throws {
        let container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let show = Podcast(feedURL: "https://example.invalid/feed-\(UUID().uuidString)", title: "Show")
        context.insert(show)
        var episodes: [Episode] = []
        for i in 0..<3 {
            let e = Episode(guid: "p62-\(i)-\(UUID().uuidString)", title: "Episode \(i)", episodeDescription: "",
                            audioURL: "https://example.invalid/\(i).mp3", publishedAt: .now, duration: 600)
            e.podcast = show
            context.insert(e)
            episodes.append(e)
        }
        try context.save()
        let url = try await DetectionExport.file(episodes: episodes, parts: .all, scopeNote: ["partial": false])
        urls.append(url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let rows = try XCTUnwrap(root["episodes"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map { $0["title"] as? String }, ["Episode 0", "Episode 1", "Episode 2"])
        XCTAssertEqual((root["scope"] as? [String: Any])?["episodes"] as? Int, 3)
        XCTAssertEqual(root["schema"] as? Int, 2)
        XCTAssertNotNil(root["timings"] as? [Any])
        XCTAssertTrue(rows[0]["transcript"] is NSNull)
        // A stored transcript is copied in as it is.
        let stored = Data(#"[{"text":"hello","start":0,"end":1}]"#.utf8)
        let spliced = RawJSON.splice(Data(#"{"a":"tok","b":1}"#.utf8), token: "tok", raw: stored)
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: spliced) as? [String: Any])
        XCTAssertEqual(((back["a"] as? [[String: Any]])?.first?["text"]) as? String, "hello")
        XCTAssertTrue(RawJSON.isValue(stored))
        XCTAssertFalse(RawJSON.isValue(Data("not json".utf8)))
    }

    func testDiagnosticsExportReadsBack() async throws {
        let url = try await Diagnostics.exportFile(scope: Diagnostics.Scope(parts: [.device, .background, .modelTests, .timings]))
        urls.append(url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        for key in ["app", "background", "build", "device", "exportedAt", "metricKit", "modelTests", "os", "schema", "scope", "timings"] {
            XCTAssertNotNil(root[key], key)
        }
        XCTAssertEqual((root["scope"] as? [String: Any])?["partial"] as? Bool, true)
    }
}

// MARK: A5 — video with different breaks plays with its own sound

final class Pass62VideoTests: XCTestCase {
    func testDifferentBreaksPlayWithTheVideosOwnSound() {
        // Legion of Skanks #963: audio 6,223 s; the video a different length.
        XCTAssertEqual(VideoSync.fit(videoDuration: 5_890, audioDuration: 6_223, isFile: false, candidates: []), .ownSound)
        // Ads found that don't account for the difference: still its own sound.
        XCTAssertEqual(VideoSync.fit(videoDuration: 5_890, audioDuration: 6_223, isFile: false,
                                     candidates: [[(start: 0, end: 27), (start: 1_294, end: 1_462)]]), .ownSound)
        // Ads that do: the picture follows the audio without them.
        XCTAssertEqual(VideoSync.fit(videoDuration: 6_028, audioDuration: 6_223, isFile: false,
                                     candidates: [[(start: 0, end: 27), (start: 1_294, end: 1_462)]]),
                       .withoutInserted([0...27, 1_294...1_462]))
        XCTAssertEqual(VideoSync.fit(videoDuration: 6_225, audioDuration: 6_223, isFile: false, candidates: []), .same)
        XCTAssertEqual(VideoSync.fit(videoDuration: 100, audioDuration: 6_223, isFile: true, candidates: []), .same)
    }

    func testPositionsMapBetweenTheTwoTimelines() {
        let own = PlayerEngine.OwnSoundVideo(url: URL(string: "https://example.com/v.m3u8")!, audioDuration: 6_000, videoDuration: 5_400)
        XCTAssertEqual(own.videoTime(3_000), 2_700, accuracy: 1e-9)
        XCTAssertEqual(own.audioTime(2_700), 3_000, accuracy: 1e-9)
        XCTAssertEqual(own.videoTime(0), 0)
        XCTAssertEqual(own.videoTime(6_000), 5_399, accuracy: 1e-9, "never past the end")
        XCTAssertEqual(PlayerEngine.OwnSoundVideo.map(10, from: 0, to: 100), 10, "unknown length: unchanged")
    }

    @MainActor
    func testAProblemIsForgottenWhenAskedAgain() {
        let sync = VideoSync()
        sync.unavailable("The video couldn't be loaded.")
        XCTAssertNotNil(sync.problem)
        sync.clearProblem()
        XCTAssertNil(sync.problem)
    }
}

// MARK: The crash he hit mid-pass: MLX memory touched where MLX never loaded

final class Pass62MLXMemoryTests: XCTestCase {
    /// His 7 Nov simulator crash: a Reader/Apple test's end called MLX's
    /// clear_cache, which made MLX's Metal device and aborted. Now nothing
    /// in MLX is touched unless a model loaded, and never in the simulator.
    func testReleasingWithoutAModelTouchesNothing() {
        XCTAssertFalse(MLXMemory.mayRelease)
        MLXMemory.release()   // would abort here before the fix
        MLXMemory.noteLoaded()
        XCTAssertFalse(MLXMemory.mayRelease, "the simulator never touches MLX's memory")
        MLXMemory.release()
    }
}

// MARK: B3 — the Reader learns within the lab's limits

final class Pass62LearnerTests: XCTestCase {
    typealias Learner = OnDeviceReaderLearner

    private func head(_ value: Float) -> ReaderHead {
        ReaderHead(inputs: 2, mid: 2, outputs: 2, midWeight: [1, 0, 0, 1], midBias: [0, 0],
                   outWeight: [value, 0, 0, 1], outBias: [0, 0])
    }

    func testTrustStepTakesThePartThatStaysWithinTheLab() {
        let start = head(1), trained = head(5)
        // His examples: class 0 on the first feature (a bigger weight helps).
        let goal = Learner.Batchable(x: [1, 0, 1, 0], labels: [0, 0], weights: [1, 1], inputs: 2)
        // The lab allows the first output weight up to 2 (a quarter of the way).
        let keep: (ReaderHead) -> Bool = { $0.outWeight[0] <= 2.0 + 1e-6 }
        let stepped = Learner.trustStep(start: start, trained: trained, goal: goal, keep: keep)
        XCTAssertEqual(stepped.fraction, 0.25)
        XCTAssertEqual(stepped.head.outWeight[0], 2, accuracy: 1e-6)
        XCTAssertLessThan(Learner.loss(stepped.head, goal), Learner.loss(start, goal))
        // Nothing allowed: the start stays.
        let none = Learner.trustStep(start: start, trained: trained, goal: goal, keep: { _ in false })
        XCTAssertEqual(none.fraction, 0)
        XCTAssertEqual(none.head, start)
        // A step that doesn't help what he taught it isn't taken.
        let worse = Learner.trustStep(start: start, trained: head(-5), goal: goal, keep: { _ in true })
        XCTAssertEqual(worse.fraction, 0)
    }

    func testARolledBackHeadIsTriedOnceWithTheNewTrainer() {
        var status = Learner.Status()
        status.trainedGold = 2_273; status.trainedSilver = 400; status.rolledBack = true; status.trainedAt = .now
        XCTAssertTrue(Learner.shouldTrain(status: status, gold: 2_273, silver: 400), "same data, new trainer")
        status.trainer = Learner.trainerVersion
        XCTAssertFalse(Learner.shouldTrain(status: status, gold: 2_273, silver: 400), "but only once")
    }
}
