import XCTest
import SwiftData
@testable import PodSkipper

/// Pass 31 (his 6 Oct message and Diagnostics).
@MainActor
final class Pass31Tests: XCTestCase {

    private func line(_ text: String, _ start: Double, _ end: Double) -> TimedLine {
        TimedLine(text: text, start: start, end: end)
    }

    private func cut(_ start: Double, _ end: Double, _ kind: SegmentKind, _ sponsor: String = "") -> DetectedSegment {
        DetectedSegment(start: start, end: end, kind: kind, sponsor: sponsor, confidence: 90)
    }

    // MARK: Fragmentation

    /// LoS #958: Sheath ended at 88:05.3 and Body Brain began at 88:06.45.
    func testBackToBackSponsorsAreOneJump() {
        let ranges = SkipJoin.joined([5_166.3...5_285.3, 5_286.45...5_360.7, 6_000...6_030])
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0].lowerBound, 5_166.3)
        XCTAssertEqual(ranges[0].upperBound, 5_360.7)
    }

    func testWordlessGapBetweenTwoAdsIsBridged() {
        let lines = [line("so anyway we were talking about the game", 0, 5),
                     line("and that was the funniest thing I've ever seen", 200, 205)]
        let out = BreakBridge.bridge([cut(10, 60, .ad), cut(80, 140, .ad)], lines: lines)
        XCTAssertEqual(out.cuts.first?.end, 80)
        XCTAssertEqual(out.notes.count, 1)
    }

    func testConversationBetweenTwoCutsIsNotBridged() {
        let lines = (0..<8).map { line("and then my brother shows up with a giant sandwich", 62 + Double($0) * 5, 66 + Double($0) * 5) }
        let out = BreakBridge.bridge([cut(10, 60, .ad), cut(105, 140, .selfPromo)], lines: lines)
        XCTAssertEqual(out.cuts.first?.end, 60)
        XCTAssertTrue(out.notes.isEmpty)
    }

    /// LoS #958, 47:25–50:05: his plug block with 39 s of banter between
    /// the tour plug and the Gas Digital plug. Bridged only once he has
    /// joined a gap like it on this show.
    func testLearnedGapBridgesAPlugBlockOnlyAfterHeTaughtIt() {
        let banter = [line("15 years, you've been included the whole time.", 2_947.98, 2_950.2),
                      line("A few times, me and Lewis got in the bicker wars.", 2_953.08, 2_958.18),
                      line("I was there for one of them.", 2_960.64, 2_961.78)]
        let plugs = [cut(2_845.42, 2_945.48, .selfPromo), cut(2_984.62, 3_004.94, .ad)]
        XCTAssertTrue(BreakBridge.bridge(plugs, lines: banter).notes.isEmpty)
        let lesson = DetectionCorrection(excerpt: "(no words)", kind: .selfPromo, boundary: BreakBridge.lessonTag(39))
        let taught = BreakBridge.learnedGap([lesson])
        XCTAssertEqual(taught, 39)
        let out = BreakBridge.bridge(plugs, lines: banter, learnedGap: taught)
        XCTAssertEqual(out.cuts.first?.end, 2_984.62)
    }

    // MARK: Grades

    func testFragmentedBreakIsPartialCredit() {
        let pieces = [CutGrade.Piece(start: 2_845, end: 2_945, kind: "selfPromo", detail: "tour", sponsor: "", confidence: 78, delivery: "", evidence: ""),
                      CutGrade.Piece(start: 2_984, end: 3_005, kind: "ad", detail: "", sponsor: "", confidence: 43, delivery: "", evidence: "")]
        let grade = CutGrade.grade(start: 2_820, end: 3_005, kinds: ["selfPromo", "ad"], predictions: pieces)
        XCTAssertEqual(grade.fragments, 2)
        XCTAssertGreaterThan(grade.score, 55)
        XCTAssertLessThan(grade.score, 90)
        XCTAssertEqual(grade.precision, 1, accuracy: 0.01)
    }

    func testCleanHitIsAnA() {
        let piece = CutGrade.Piece(start: 100, end: 160, kind: "ad", detail: "", sponsor: "x", confidence: 95, delivery: "host", evidence: "")
        XCTAssertEqual(CutGrade.grade(start: 100, end: 160, kinds: ["ad"], predictions: [piece]).letter, "A")
        XCTAssertEqual(CutGrade.grade(start: 100, end: 160, kinds: ["selfPromo"], predictions: [piece]).letter, "B")
        XCTAssertEqual(CutGrade.grade(start: 100, end: 160, kinds: ["ad"], predictions: []).score, 0)
    }

    /// Locking a cut over the detector's fragments takes them in, keeps
    /// what they said, grades it, and files the bridged gap for the show.
    func testLockingOverFragmentsMergesThemAndKeepsTheirPredictions() throws {
        let container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let show = Podcast(feedURL: "https://example.invalid/los.xml", title: "Legion of Skanks")
        context.insert(show)
        let episode = Episode(guid: "los958", title: "958", episodeDescription: "", audioURL: "https://example.invalid/958.mp3",
                              publishedAt: .now, duration: 7_331)
        context.insert(episode); episode.podcast = show
        let tour = AdSegment(start: 2_845.42, end: 2_945.48, confidence: 78, kind: .selfPromo)
        let patreon = AdSegment(start: 2_984.62, end: 3_004.94, confidence: 43, kind: .ad)
        let elsewhere = AdSegment(start: 5_150, end: 5_285, confidence: 90, kind: .ad)
        for s in [tour, patreon, elsewhere] { context.insert(s); s.episode = episode }
        // He drags the tour plug out over the whole block and locks it.
        tour.start = 2_820; tour.end = 3_005
        tour.isLocked = true
        let absorbed = CorrectionLedger.locked(tour, in: episode, context: context)
        try context.save()
        XCTAssertEqual(absorbed, 1)
        XCTAssertEqual(episode.adSegments.count, 2, "the Patreon fragment is gone from the list")
        let kept = try XCTUnwrap(tour.mergedFromData.flatMap { try? JSONDecoder().decode([CutGrade.Piece].self, from: $0) })
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.start, 2_984.62)
        XCTAssertEqual(tour.containsRaw, "ad")
        let delta = try XCTUnwrap(CorrectionLedger.deltas(for: episode).last)
        XCTAssertEqual(delta.action, "lock")
        XCTAssertEqual(delta.predictions.count, 2, "its own original edges and the fragment's")
        XCTAssertEqual(delta.grade.fragments, 2)
        XCTAssertEqual(BreakBridge.learnedGap(show.corrections), 39, accuracy: 1)
        XCTAssertNotNil(CorrectionLedger.episodeGrade(episode))
    }

    // MARK: Model handling

    func testTemplateWithoutSwitchGetsItsThinkingBlockClosed() {
        let lfm = ModelPromptPlan.plan(id: "LiquidAI/LFM2.5-2.6B-MLX-4bit", modelType: "lfm2",
                                       template: "{{- '<|im_start|>assistant\\n<think>' -}}", downloadBytes: 1_601_108_840)
        XCTAssertEqual(lfm.thinking, .closeOpenBlock)
        XCTAssertEqual(lfm.family, "LFM2.5")
        let qwen = ModelPromptPlan.plan(id: "mlx-community/Qwen3.5-4B-MLX-4bit", modelType: "qwen3_5",
                                        template: "{%- if enable_thinking is defined and enable_thinking is false %}<think>\\n\\n</think>",
                                        downloadBytes: 3_061_129_077)
        XCTAssertEqual(qwen.thinking, .templateSwitch)
        XCTAssertEqual(qwen.profile, .lean)
        XCTAssertLessThan(qwen.answerCap, 1_536)
        let llama = ModelPromptPlan.plan(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", modelType: "llama",
                                         template: "<|start_header_id|>system", downloadBytes: 1_824_807_894)
        XCTAssertEqual(llama.thinking, .none)
        let tiny = ModelPromptPlan.plan(id: "LiquidAI/LFM2.5-350M-MLX-4bit", modelType: "lfm2", template: "", downloadBytes: 226_571_069)
        XCTAssertLessThan(tiny.maxWindowTokens, qwen.maxWindowTokens)
    }

    func testShortAnswerDoesNotShowTheModelASchema() {
        XCTAssertFalse(JudgePrompt.Profile.lean.system.contains("\"properties\""))
        XCTAssertTrue(JudgePrompt.Profile.full.system.contains("\"properties\""))
    }

    /// A model that calls a whole stretch the show is not forced into a cut
    /// label, and that answer doesn't veto the reader's sure ad.
    func testShowPartIsNeitherACutNorAVeto() throws {
        let raw = try XCTUnwrap(JudgePrompt.parse(#"{"parts":[{"first_line":0,"last_line":99,"label":"SHOW","sponsor":"","funny":false}]}"#))
        XCTAssertEqual(raw.first?.label, .show)
        let lines = (0..<100).map { line("talk talk talk about the weekend", Double($0) * 5, Double($0) * 5 + 4.8) }
        let part = try XCTUnwrap(JudgePrompt.resolve(raw[0], lines: lines))
        XCTAssertFalse(part.isCut)
        let sure = cut(200, 260, .ad, "Liquid IV")
        let out = ModelFinder.checkedCuts(from: [part], lines: lines, readerCuts: [sure], inserted: [], evidence: [],
                                          silences: [], padding: 0, duration: 500)
        XCTAssertEqual(out.cuts.count, 1, "the reader's sure ad stays")
    }

    func testGuestPlugKeepsItsFinerKind() {
        let lines = (0..<10).map { line("my new special is on Netflix, go watch it", Double($0) * 5, Double($0) * 5 + 4.8) }
        let part = JudgedPart(firstLine: 2, lastLine: 5, label: .guestPlug, sponsor: "", funny: false, confidence: 90, why: "")
        let cuts = ModelFinder.cuts(from: [part], lines: lines, readerCuts: [], inserted: [], silences: [], padding: 0, duration: 50)
        XCTAssertEqual(cuts.first?.detail, "guest")
        XCTAssertEqual(CutChoice.title(kind: .selfPromo, detailRaw: "guest", deliveryRaw: ""), "The guest's plug")
        XCTAssertEqual(CutChoice.title(kind: .ad, detailRaw: "", deliveryRaw: "host"), "Sponsor ad, read by a host")
        XCTAssertEqual(SegmentKind.crossPromo.label, "Other Podcast")
    }

    /// Each stretch is numbered from 0 for the model, and its answer is
    /// moved back onto the episode's own lines.
    func testStretchIsNumberedFromZeroAndMappedBack() throws {
        let lines = (0..<50).map { line("line number \($0) of the talk", Double($0) * 6, Double($0) * 6 + 5) }
        let user = JudgePrompt.userLocal(show: "S", title: "T", notes: "Brought to you by Liquid IV. Go to quince.com/bf.",
                                         lines: lines, window: 20..<30, spans: [])
        XCTAssertTrue(user.contains("Lines 0–9:"))
        XCTAssertTrue(user.contains("\n0 line number 20 of the talk"))
        XCTAssertTrue(user.contains("starts at 2 min in of a 4 min episode"))
        XCTAssertFalse(user.contains("line number 19"))
        XCTAssertTrue(user.contains("Liquid IV") && user.contains("quince"))
        let raw = try XCTUnwrap(JudgePrompt.parse(#"{"parts":[{"first_line":2,"last_line":4,"label":"PAID_AD","sponsor":"x","funny":false},{"first_line":7,"last_line":12,"label":"PAID_AD","sponsor":"","funny":false},{"first_line":5,"last_line":3,"label":"PAID_AD","sponsor":"","funny":false}]}"#))
        let moved = JudgePrompt.shifted(raw, window: 20..<30)
        XCTAssertEqual(moved.count, 1, "past the stretch, or backwards: dropped")
        XCTAssertEqual(moved.first?.firstLine, 22)
        XCTAssertEqual(moved.first?.lastLine, 24)
    }

    // MARK: Progress

    /// His report: the test bar flew to ~99 % and sat there. Reading is fast
    /// and writing slow, so the meter counts time, not phases.
    func testMeterCountsTimeNotPhases() {
        var meter = WorkMeter(parts: [WorkMeter.Part(promptTokens: 1_500, expectedAnswer: 60, answerCap: 320)],
                              readRate: 150, writeRate: 15, loadSeconds: 0)
        meter.modelLoaded()
        meter.reading(part: 0, done: 1_500)
        // 10 s of reading, 4 s of writing expected: about 71 % once read.
        XCTAssertEqual(meter.fraction, 10.0 / 14.0, accuracy: 0.02)
        var last = meter.fraction
        for written in stride(from: 10, through: 300, by: 10) {
            meter.writing(part: 0, written: written)
            XCTAssertGreaterThanOrEqual(meter.fraction, last - 0.0001)
            XCTAssertLessThan(meter.fraction, 0.996)
            last = meter.fraction
        }
        // A long answer keeps some time left rather than claiming done.
        XCTAssertGreaterThan(meter.secondsLeft, 0)
        meter.finished(part: 0, written: 300)
        XCTAssertEqual(meter.secondsLeft, 0, accuracy: 0.01)
    }

    // MARK: Audio files shorter than their headers

    func testEndOfFileErrorEndsTheReadInsteadOfFailingTheJob() {
        let eof = NSError(domain: NSOSStatusErrorDomain, code: -39)
        XCTAssertTrue(AudioFileEnd.isEnd(eof, position: 10, length: 1_000))
        let other = NSError(domain: NSOSStatusErrorDomain, code: -50)
        XCTAssertFalse(AudioFileEnd.isEnd(other, position: 500, length: 1_000))
        XCTAssertTrue(AudioFileEnd.isEnd(other, position: 990, length: 1_000))
    }
}
