import XCTest
@testable import PodSkipper

/// Pass 64 (his 13 Nov message, build 3cee01c exports): Stop, Core AI's
/// disk and load gate, the honest score, the grammar, the cut check's veto,
/// the Reader's kind split, the test queue and its time left, transfers.
@MainActor
final class Pass64Tests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "Pass64Tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }

    // MARK: 1. Stop

    /// The panel ends the moment Stop is pressed, with the stop recorded,
    /// even when the engine keeps going; its late answer is never saved, and
    /// the heavy-work slot is held until the engine has returned.
    func testStopEndsATestAtOnceAndDropsTheLateAnswer() async throws {
        // Its own heavy-work slot: the test host's re-labelling uses the shared one.
        let coordinator = HeavyWorkCoordinator()
        let bench = ModelBench(defaults: defaults, recoverInterrupted: false, coordinator: coordinator)
        let engineDone = Flag()
        bench.start(engine: "p64-slow", name: "Slow engine", sample: .basic) { sample in
            // An engine that ignores cancellation for a while (a C step).
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { c.resume() }
            }
            engineDone.set()
            return BenchResult(engine: "p64-slow", name: "Slow engine", sample: sample, date: .now, score: 0.95)
        }
        try await waitUntil { bench.startedAt != nil }
        let asked = Date()
        bench.stop()
        XCTAssertLessThan(Date().timeIntervalSince(asked), 0.5)
        XCTAssertNil(bench.running, "the panel ends at Stop")
        XCTAssertEqual(bench.result("p64-slow", .basic)?.resolvedOutcome, .stopped)
        XCTAssertTrue(coordinator.isBusy, "the slot stays held while the engine still runs")
        try await waitUntil { engineDone.isSet }
        try await waitUntil { !coordinator.isBusy }
        XCTAssertEqual(bench.history.filter { $0.engine == "p64-slow" }.map(\.resolvedOutcome), [.stopped],
                       "the answer that came after Stop was dropped")
    }

    /// A new test started while the stopped one still unwinds waits for it,
    /// and the old one's clean-up doesn't end the new one's panel.
    func testANewTestWaitsForTheStoppedOneWithoutLosingItsPanel() async throws {
        let bench = ModelBench(defaults: defaults, recoverInterrupted: false, coordinator: HeavyWorkCoordinator())
        bench.start(engine: "p64-a", name: "A", sample: .basic) { sample in
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { c.resume() }
            }
            return BenchResult(engine: "p64-a", name: "A", sample: sample, date: .now, score: 1)
        }
        try await waitUntil { bench.startedAt != nil }
        bench.stop()
        bench.start(engine: "p64-b", name: "B", sample: .hard) { sample in
            BenchResult(engine: "p64-b", name: "B", sample: sample, date: .now, score: 0.5)
        }
        XCTAssertEqual(bench.running, "p64-b")
        XCTAssertTrue(bench.waiting, "B waits for A's engine to return")
        try await waitUntil { !bench.isRunning }
        XCTAssertEqual(bench.result("p64-b", .hard)?.resolvedOutcome, .completed)
        XCTAssertEqual(bench.result("p64-a", .basic)?.resolvedOutcome, .stopped)
    }

    // MARK: 2. Core AI

    func testCoreAILoadGate() {
        let ok = CoreAILoadGate.Facts(compiledCopy: false, prepared: nil, plainFree: 20_000_000_000, modelBytes: 2_000_000_000)
        XCTAssertNil(CoreAILoadGate.refusal(id: "qwen3-4b", name: "Qwen3 4B", facts: ok, closures: nil))
        // Known to close PodSkipper uncompiled: refused until a compiled copy is in.
        let gemma = CoreAILoadGate.refusal(id: "gemma-3-4b-it", name: "Gemma 3 4B", facts: ok, closures: nil)
        XCTAssertEqual(gemma?.contains("compiled for this iPhone on a Mac"), true)
        var compiled = ok; compiled.compiledCopy = true
        XCTAssertNil(CoreAILoadGate.refusal(id: "gemma-3-4b-it", name: "Gemma 3 4B", facts: compiled, closures: nil))
        var prepared = ok; prepared.prepared = true
        XCTAssertNil(CoreAILoadGate.refusal(id: "qwen3.5-4b", name: "Qwen3.5 4B", facts: prepared, closures: nil))
        // Below 5 GB actually free, nothing is prepared on the phone.
        var low = ok; low.plainFree = 4_000_000_000
        XCTAssertEqual(CoreAILoadGate.refusal(id: "qwen3-4b", name: "Qwen3 4B", facts: low, closures: nil)?.hasPrefix("Not enough space"), true)
        // A model that closed PodSkipper while preparing here is refused too.
        let closed = CoreAIStability.Record(count: 1, last: .now, stage: "preparing the model for this iPhone", duringTest: true)
        XCTAssertNotNil(CoreAILoadGate.refusal(id: "nanbeige4.2-3b", name: "Nanbeige", facts: ok, closures: closed))
    }

    func testCoreAIAnswerRoomIsAtLeast512WhereTheModelHoldsIt() {
        XCTAssertEqual(JudgePrompt.Profile.compact.answerTokens, 512)
        XCTAssertEqual(CoreAIAnswerRoom.cap(profile: .compact, context: 4_096), 512)
        XCTAssertEqual(CoreAIAnswerRoom.cap(profile: .compact, context: 2_047), 512)
        XCTAssertEqual(CoreAIAnswerRoom.cap(profile: .compact, context: 1_024), 256, "a 1,024-token bundle keeps room to read")
        XCTAssertEqual(CoreAIAnswerRoom.cap(profile: .candidate, context: 1_024), 110)
    }

    // MARK: 4. Scores, grammar, check

    /// A model that finds nothing scores 0 alone, whatever the Reader's cuts
    /// make of it after the check; the scoreboard leads with the model alone.
    func testScoreboardLeadsWithTheModelAlone() throws {
        var nothing = BenchResult(engine: "p64-mlx", name: "Finds nothing", sample: .hard, date: .now, score: 0.94)
        nothing.rawScore = 0
        nothing.quality = PodTestScore.Quality(skippable: 100, heard: 2, showSeconds: 500, showSecondsCut: 1)
        nothing.rawQuality = PodTestScore.Quality(skippable: 100, heard: 100, showSeconds: 500, showSecondsCut: 0)
        nothing.readTPS = 123
        let rows = Scoreboard.rows(runs: [], pack: nil, history: [nothing])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.headline, "0")
        XCTAssertEqual(row.lines.first?.alone, "0")
        XCTAssertEqual(row.lines.first?.checked, "94")
        XCTAssertEqual(row.lines.first?.adsCut, "0%", "ads cut is the model's own")
        XCTAssertEqual(row.lines.first?.speed, "123")
        // Ranking by the model alone too.
        let bench = ModelBench(defaults: defaults, recoverInterrupted: false)
        bench.save(nothing)
        XCTAssertEqual(bench.score("p64-mlx"), 0)
    }

    func testPodTestKeepsTheModelsOwnCuts() throws {
        let pack = try XCTUnwrap(PodTestPack.bundled())
        let exact = Dictionary(uniqueKeysWithValues: pack.episodes.map { e in
            (e.guid, e.breaks.map { PodTestCut(start: $0.start, end: $0.end, kind: "ad") })
        })
        let run = PodTestRun(runID: UUID(), started: .now, state: .completed, appBuild: "t", device: "t", packVersion: pack.version,
                             engines: [.init(engine: "reader", name: "PodSkipper Reader", kind: .reader,
                                             reads: pack.episodes.map { .init(guid: $0.guid, outcome: .completed, cuts: exact[$0.guid]!) }),
                                       .init(engine: "m", name: "Model", kind: .mlx,
                                             reads: pack.episodes.map { .init(guid: $0.guid, outcome: .completed,
                                                                              cuts: exact[$0.guid]!, rawCuts: []) })])
        let alone = try XCTUnwrap(run.modelAlone("m", pack: pack))
        let checked = try XCTUnwrap(run.comparison("m", pack: pack))
        XCTAssertLessThan(alone.everyday ?? 100, 5, "nothing cut alone scores (next to) nothing")
        XCTAssertGreaterThan(checked.engine.everyday ?? 0, 90)
        // Records from before Pass 64 decode without the field.
        let old = try JSONEncoder().encode(PodTestRun.Read(guid: "g", outcome: .completed))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        object.removeValue(forKey: "rawCuts")
        let decoded = try JSONDecoder.podTest.decode(PodTestRun.Read.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.rawCuts)
    }

    func testGrammarAllowsSpacesTheStretchsLinesAndNoWholeStretch() {
        let free = JudgePrompt.leanGrammar(maxParts: 4)
        XCTAssertTrue(free.contains("ws ::= [ \\n]{0,3}"), "spaces and line breaks where JSON has them")
        XCTAssertTrue(free.contains("\"{\" ws"))
        func rule(_ grammar: String, _ name: String) -> [String] {
            guard let line = grammar.split(separator: "\n").first(where: { $0.hasPrefix(name + " ::= ") }) else { return [] }
            return line.dropFirst(name.count + 5).split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let ten = JudgePrompt.leanGrammar(maxParts: 8, lineCount: 10)
        XCTAssertEqual(rule(ten, "early"), ["\"0\""])
        XCTAssertEqual(rule(ten, "notlast").last, "\"8\"", "a part from line 0 can't end on the last line")
        XCTAssertEqual(rule(ten, "anyline").count, 10)
        XCTAssertEqual(rule(ten, "later").first, "\"1\"")
        let long = JudgePrompt.leanGrammar(maxParts: 8, lineCount: 40)
        XCTAssertEqual(rule(long, "early"), ["\"0\"", "\"1\"", "\"2\""])
        XCTAssertEqual(rule(long, "notlast").last, "\"36\"")
        XCTAssertEqual(JudgePrompt.leanGrammarPass63(maxParts: 8).contains("ws ::="), false)
    }

    func testAnAnswerThatOnlyRestatesTheStretchIsReadAgain() {
        let lines = (0..<40).map { TimedLine(text: "line \($0)", start: Double($0) * 10, end: Double($0) * 10 + 9) }
        func part(_ a: Int, _ b: Int) -> JudgePrompt.RawPart {
            JudgePrompt.RawPart(firstLine: a, lastLine: b, firstWords: "", lastWords: "", label: .paidAd, sponsor: "",
                                funny: false, confidence: 80, why: "")
        }
        let whole = part(0, 39)
        let kept = JudgePrompt.shifted([whole], window: 0..<40, lines: lines)
        XCTAssertTrue(kept.isEmpty)
        XCTAssertTrue(JudgePrompt.restatedOnly(raw: [whole], kept: kept, window: 0..<40, lines: lines, maxShare: nil))
        let small = part(10, 14)
        let keptSmall = JudgePrompt.shifted([small], window: 0..<40, lines: lines)
        XCTAssertFalse(JudgePrompt.restatedOnly(raw: [small], kept: keptSmall, window: 0..<40, lines: lines, maxShare: nil))
        XCTAssertFalse(JudgePrompt.restatedOnly(raw: [], kept: [], window: 0..<40, lines: lines, maxShare: nil),
                       "an empty answer is an answer")
    }

    /// The veto: a model's lines the Reader is sure are conversation, with
    /// nothing selling and no audio proof, don't stand; the selling lines do;
    /// an opener at the very start is proved by where it is.
    func testTheCheckKeepsAModelOutOfTheShowsConversation() {
        var lines: [TimedLine] = []
        for i in 0..<30 { lines.append(TimedLine(text: "So then my dad drove to Nebraska, story \(i).", start: Double(i) * 5, end: Double(i) * 5 + 4.5)) }
        lines.append(TimedLine(text: "It's streaming on Netflix starting Friday, all the tour dates are at samcomedy dot com.", start: 150, end: 154.5))
        lines.append(TimedLine(text: "Get tickets at samcomedy dot com.", start: 155, end: 159.5))
        for i in 32..<60 { lines.append(TimedLine(text: "And that's how the lake trip ended, part \(i).", start: Double(i) * 5, end: Double(i) * 5 + 4.5)) }
        let show = lines.map { $0.text.contains("dot com") ? 0.05 : 1.0 }
        let plug = DetectedSegment(start: 100, end: 159.5, kind: .selfPromo, sponsor: "", confidence: 80)
        var notes: [String] = []
        let kept = ModelCutCheck.vetoConversation([plug], lines: lines, show: show, evidence: [], duration: 300, notes: &notes)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.start ?? 0, 150, accuracy: 0.01, "the conversation before the plug isn't cut")
        XCTAssertEqual(kept.first?.end ?? 0, 159.5, accuracy: 0.01)
        let talk = DetectedSegment(start: 200, end: 260, kind: .crossPromo, sponsor: "", confidence: 80)
        XCTAssertTrue(ModelCutCheck.vetoConversation([talk], lines: lines, show: show, evidence: [], duration: 300, notes: &notes).isEmpty)
        let opener = DetectedSegment(start: 0, end: 9, kind: .intro, sponsor: "", confidence: 80)
        XCTAssertEqual(ModelCutCheck.vetoConversation([opener], lines: lines, show: show, evidence: [], duration: 300, notes: &notes).count, 1)
        // Per line from the Reader's sentences.
        let spans = [ReaderShowSpan(start: 0, end: 4.5, show: 0.2), ReaderShowSpan(start: 5, end: 9.5, show: 0.97)]
        let perLine = ModelCutCheck.lineShow(lines: Array(lines.prefix(2)), spans: spans)
        XCTAssertEqual(perLine, [0.2, 0.97])
        XCTAssertNil(ModelCutCheck.lineShow(lines: lines, spans: []))
    }

    // MARK: 5. The Reader

    func testSentenceKinds() {
        XCTAssertEqual(SegmentDetector.sentenceKind("It's on our Patreon, patreon dot com slash late shift."), .selfPromo)
        XCTAssertEqual(SegmentDetector.sentenceKind("Thanks to Freshbox for supporting the show."), .ad)
        XCTAssertEqual(SegmentDetector.sentenceKind("If you like this show, check out Morning Static, another Wavelength Media podcast."), .crossPromo)
        XCTAssertEqual(SegmentDetector.sentenceKind("Search Morning Static wherever you listen."), .crossPromo)
        XCTAssertEqual(SegmentDetector.sentenceKind("Go to pagecraft dot com and use code SHIFT for ten percent off."), .ad)
        XCTAssertNil(SegmentDetector.sentenceKind("My dad used to fry eggs on the hood of his truck."))
    }

    func testSamplesVersionFiveBasicIsTheFundamentalsAndHardHasTheNewTraps() {
        XCTAssertEqual(BenchSample.hard.version, 5)
        XCTAssertTrue(BenchScript.basic.traps.isEmpty)
        XCTAssertTrue(BenchScript.hard.traps.contains { $0.name == "the comedy riff" })
        XCTAssertFalse(BenchScript.hard.traps.contains { $0.name == "the brand chatter" })
        XCTAssertTrue(BenchScript.hard.lines.contains { $0.text == "So the drum guy. Did he ever actually move out?" })
        XCTAssertFalse(BenchScript.hard.lines.contains { $0.text == "And we're back with Sam Ortiz." })
    }

    // MARK: 7. The test queue, time left, transfers

    func testPaceAndTimeLeftComeFromEachFindersOwnReads() throws {
        let pack = try XCTUnwrap(PodTestPack.bundled())
        let first = try XCTUnwrap(pack.episodes.first)
        var read = PodTestRun.Read(guid: first.guid, outcome: .completed)
        read.seconds = first.duration / 10
        let run = PodTestRun(runID: UUID(), started: .now, state: .stopped, appBuild: "t", device: "t", packVersion: pack.version,
                             engines: [.init(engine: "m", name: "Model", kind: .mlx, reads: [read])])
        let pace = try XCTUnwrap(PodTestRunner.pace("m", runs: [run], pack: pack))
        XCTAssertEqual(pace, 0.1, accuracy: 1e-9)
        XCTAssertNil(PodTestRunner.pace("never-timed", runs: [run], pack: pack))
        // Never timed on a test episode: from its Basic/Hard reading speed.
        XCTAssertEqual(PodTestRunner.baselinePace(readTPS: 140, kind: .mlx) ?? 0, 0.0125, accuracy: 1e-9)
        XCTAssertNil(PodTestRunner.baselinePace(readTPS: 0, kind: .cpu))
        XCTAssertNil(PodTestRunner.baselinePace(readTPS: 140, kind: .apple))
        XCTAssertEqual(PodTestRunPanel.timeLeftLine(.init(seconds: 3_725, untimed: 0)), "About 1:02:05 left")
        XCTAssertEqual(PodTestRunPanel.timeLeftLine(.init(seconds: 60, untimed: 2)), "About 0:01:00 left + 2 finders not timed on this iPhone yet")
        XCTAssertEqual(PodTestRunPanel.timeLeftLine(nil), "Time left: measuring")
    }

    func testTransferLineAndMeter() {
        XCTAssertEqual(TransferText.line(done: 1_230_000_000, total: 2_580_000_000, bytesPerSecond: 412_000_000),
                       "1.23 GB / 2.58 GB · 412.0 MB/s · 0:03 left")
        XCTAssertEqual(TransferText.line(done: 0, total: 1_000_000_000, bytesPerSecond: 0), "0.00 GB / 1.00 GB")
        var meter = TransferMeter()
        let t0 = Date()
        meter.note(done: 0, at: t0)
        meter.note(done: 100_000_000, at: t0.addingTimeInterval(1))
        XCTAssertEqual(meter.bytesPerSecond, 100_000_000, accuracy: 1)
        meter.note(done: 100_000_000, at: t0.addingTimeInterval(1.2))
        XCTAssertEqual(meter.bytesPerSecond, 100_000_000, accuracy: 1, "updates closer than half a second wait")
    }

    func testHeavyModelsFoldAway() {
        XCTAssertTrue(ModelFit.isHeavy(bytes: 6_000_000_000, budgetMB: 5_700))
        XCTAssertFalse(ModelFit.isHeavy(bytes: 2_600_000_000, budgetMB: 5_700))
        XCTAssertFalse(ModelFit.isHeavy(bytes: 0, budgetMB: 5_700))
    }

    func testModelCopierCopiesAFolderWithProgress() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "p64-copy-\(UUID().uuidString)")
        let source = root.appending(path: "source/inner")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 9 << 20).write(to: source.appending(path: "weights.bin"))
        try Data("{}".utf8).write(to: root.appending(path: "source/config.json"))
        let destination = root.appending(path: "dest/model")
        let reports = Reports()
        try ModelCopier.copy(root.appending(path: "source"), to: destination, total: Int64(9 << 20) + 2) { done, _ in reports.add(done) }
        XCTAssertEqual((try? Data(contentsOf: destination.appending(path: "inner/weights.bin")))?.count, 9 << 20)
        XCTAssertTrue(fm.fileExists(atPath: destination.appending(path: "config.json").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appending(path: "dest/.import-model").path), "no staging left")
        XCTAssertEqual(reports.last, Int64(9 << 20) + 2)
        try? fm.removeItem(at: root)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func add(_ v: Int64) { lock.withLock { values.append(v) } }
    var last: Int64? { lock.withLock { values.last } }
}
