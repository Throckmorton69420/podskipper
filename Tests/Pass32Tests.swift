import XCTest
@testable import PodSkipper

/// Pass 32 (his 7 Oct message, build 77b904d Diagnostics and Results).
@MainActor
final class Pass32Tests: XCTestCase {

    // MARK: Editing: an edge dragged into the next cut

    private typealias Plan = CorrectionLedger.OverlapPlan

    /// The end of the first cut dragged part way into the second: the second
    /// is trimmed to start where the first now ends.
    func testPartialOverlapTrimsTheNextCut() {
        let plan = CorrectionLedger.overlapPlan(edited: 100...230, neighbors: [200...300], locked: [false])
        XCTAssertEqual(plan, Plan(edited: 100...230, actions: [.trimStart(0, to: 230)]))
    }

    /// Dragged over the whole second cut: it is taken in.
    func testCoveringTheNextCutTakesItIn() {
        let plan = CorrectionLedger.overlapPlan(edited: 100...320, neighbors: [200...300], locked: [false])
        XCTAssertEqual(plan.actions, [.absorb(0)])
    }

    /// Leaving less than two seconds of it is the same as covering it.
    func testASliverLeftOverIsTakenIn() {
        let plan = CorrectionLedger.overlapPlan(edited: 100...299, neighbors: [200...300], locked: [false])
        XCTAssertEqual(plan.actions, [.absorb(0)])
    }

    /// The start dragged back into the cut before: that one now ends where
    /// this one starts.
    func testOppositeDirectionTrimsThePreviousCut() {
        let plan = CorrectionLedger.overlapPlan(edited: 150...400, neighbors: [100...200], locked: [false])
        XCTAssertEqual(plan.actions, [.trimEnd(0, to: 150)])
    }

    /// A locked cut is a wall.
    func testALockedNeighbourStopsTheEdge() {
        let plan = CorrectionLedger.overlapPlan(edited: 100...260, neighbors: [200...300], locked: [true])
        XCTAssertEqual(plan, Plan(edited: 100...200, actions: []))
    }

    /// Both neighbours at once, of different kinds: each keeps its own
    /// identity and is trimmed (only the trims are planned; kinds are untouched).
    func testBothNeighboursAreTrimmed() {
        let plan = CorrectionLedger.overlapPlan(edited: 90...310, neighbors: [50...100, 300...400], locked: [false, false])
        XCTAssertEqual(plan.actions, [.trimEnd(0, to: 90), .trimStart(1, to: 310)])
    }

    /// A cut that holds this whole one is left alone (nothing sensible to
    /// trim on both sides).
    func testAnEnclosingCutIsLeftAlone() {
        let plan = CorrectionLedger.overlapPlan(edited: 150...160, neighbors: [100...300], locked: [false])
        XCTAssertTrue(plan.actions.isEmpty)
    }

    // MARK: Equalizer range with fixes on

    /// His screenshot: with Reduce Boom and Reduce Muddiness strong, the low
    /// bands stopped well short of +12. Every band now reaches both ends.
    func testEveryBandReachesBothEndsWithStrongFixes() {
        let repairs: [Repair: Double] = [.boom: 12, .mud: 12, .dialogue: 8, .muffled: 8, .harshness: 10]
        for band in 0..<10 {
            for target in [EQMath.gainRange.lowerBound, EQMath.gainRange.upperBound] {
                var preset = EQPreset.flat.gains
                preset[band] = EQMath.baseGain(forTarget: target, band: band, repairs: repairs)
                let heard = EQMath.combinedGains(preset: preset, repairs: repairs)[band]
                XCTAssertEqual(heard, target, accuracy: 0.001, "band \(band) target \(target)")
            }
        }
    }

    /// The band you hear never leaves ±12, whatever the preset part holds.
    func testWhatYouHearStaysInsideTheRange() {
        let heard = EQMath.combinedGains(preset: Array(repeating: 30, count: 10), repairs: [:])
        XCTAssertTrue(heard.allSatisfy { $0 <= EQMath.gainRange.upperBound })
    }

    // MARK: Progress and time left

    private func meter(answer: Int = 60, cap: Int = 320, known: Bool = true) -> WorkMeter {
        WorkMeter(parts: [.init(promptTokens: 2_000, expectedAnswer: answer, answerCap: cap)],
                  readRate: 200, writeRate: 10, loadSeconds: 0, ratesKnown: known)
    }

    /// An answer running long no longer pins the bar near the end with a
    /// second or two "left".
    func testALongAnswerDoesNotPinTheBar() {
        var m = meter()
        m.modelLoaded()
        m.writing(part: 0, written: 200)
        XCTAssertLessThan(m.fraction, 0.9)
        XCTAssertGreaterThan(m.secondsLeft, 5)
        XCTAssertFalse(m.confident)
        // The worst case: the rest of the cap at the writing speed.
        XCTAssertEqual(m.worstSecondsLeft, 12, accuracy: 0.01)
    }

    func testFinishedIsTheOnlyHundredPercent() {
        var m = meter()
        m.reading(part: 0, done: 2_000)
        m.writing(part: 0, written: 59)
        XCTAssertLessThanOrEqual(m.fraction, 0.97)
        m.finished(part: 0, written: 59)
        XCTAssertEqual(m.fraction, 1)
    }

    /// An untested model's speed is measured as it goes.
    func testSpeedIsMeasuredLive() {
        var m = meter(known: false)
        XCTAssertFalse(m.confident)
        let t0 = Date()
        m.reading(part: 0, done: 0, now: t0)
        m.reading(part: 0, done: 900, now: t0.addingTimeInterval(3))
        XCTAssertEqual(m.readRate, 300, accuracy: 0.01)
        XCTAssertTrue(m.confident)
    }

    /// Core AI's reading count comes from the clock: it can't teach a speed.
    func testClockEstimatesDoNotTeachASpeed() {
        var m = meter(known: false)
        let t0 = Date()
        m.reading(part: 0, done: 0, now: t0, measured: false)
        m.reading(part: 0, done: 900, now: t0.addingTimeInterval(3), measured: false)
        XCTAssertEqual(m.readRate, 200)
        XCTAssertFalse(m.confident)
    }

    // MARK: Core AI crashes and results

    func testACrashOnAnEpisodeIsRememberedUntilHeAsksAgain() {
        let defaults = UserDefaults(suiteName: "Pass32Tests.crash")!
        defaults.removePersistentDomain(forName: "Pass32Tests.crash")
        let note = CoreAIInFlight.Note(id: "qwen3-4b", name: "Qwen3 4B", episode: "guid-1", stage: "part 2 of 7")
        CoreAICrashGuard.remember(note, defaults: defaults)
        XCTAssertEqual(CoreAICrashGuard.closedLastTime(model: "qwen3-4b", episode: "guid-1", defaults: defaults)?.stage, "part 2 of 7")
        XCTAssertNil(CoreAICrashGuard.closedLastTime(model: "qwen3-4b", episode: "guid-2", defaults: defaults))
        XCTAssertNil(CoreAICrashGuard.closedLastTime(model: "minicpm5-1b", episode: "guid-1", defaults: defaults))
        CoreAICrashGuard.forget(episode: "guid-1", defaults: defaults)
        XCTAssertNil(CoreAICrashGuard.closedLastTime(model: "qwen3-4b", episode: "guid-1", defaults: defaults))
        // A crash during a test isn't an episode's.
        CoreAICrashGuard.remember(CoreAIInFlight.Note(id: "x", name: "X", episode: "", stage: ""), defaults: defaults)
        XCTAssertNil(CoreAICrashGuard.closedLastTime(model: "x", episode: "", defaults: defaults))
    }

    private func attempt(_ finder: String, kept: String? = nil, model: String? = nil) -> FinderAttempt {
        var run = ModelFinder.Run(finder: finder)
        run.keptEarlier = kept
        run.modelName = model
        return FinderAttempt(date: .now, guid: "g", show: "s", episode: "e", method: finder, run: run, seconds: 1,
                             audioSeconds: 60, foreground: true, thermalAtStart: "nominal", thermalAtEnd: "nominal",
                             build: "test", readerCuts: [], proposedCuts: [], parts: [], savedCuts: [], answerSample: "")
    }

    /// His LoS #954 evening: Qwen3.5 4B (MLX) found the ads, then Core AI
    /// crashed and the reader ran. The MLX result is the one to keep.
    func testTheLastGoodResultIsTheModelsNotTheFallbacks() {
        let log = [attempt("reader", kept: "MLX · Qwen3.5 4B"), attempt("model", model: "Qwen3.5 4B"), attempt("reader")]
        XCTAssertEqual(ProcessingPipeline.lastGoodAttempt(in: log)?.run.finder, "model")
        XCTAssertEqual(ProcessingPipeline.lastGoodAttempt(in: [attempt("apple"), attempt("model")])?.run.finder, "apple")
        // When the reader's answer is what's there, there is nothing to keep.
        XCTAssertNil(ProcessingPipeline.lastGoodAttempt(in: [attempt("reader"), attempt("model")]))
        XCTAssertNil(ProcessingPipeline.lastGoodAttempt(in: []))
    }

    func testHybridModelAnswersAreReadWhenTheListCloses() {
        XCTAssertFalse(CoreAIAnswerText.listClosed(#"{"parts":[{"label":"PAID_AD","first_line":3"#))
        XCTAssertTrue(CoreAIAnswerText.listClosed(#"{"parts":[{"label":"PAID_AD","first_line":3,"last_line":9}]}"#))
        XCTAssertTrue(CoreAIAnswerText.listClosed(#"{"parts":[]}"#))
        XCTAssertFalse(CoreAIAnswerText.listClosed(#"{"parts":[{"sponsor":"a ] b }"#))
        struct Fake: Error, CustomStringConvertible { var description: String }
        XCTAssertTrue(CoreAIAnswerText.isMissingStateView(Fake(description: #"CoreAIError(kind: Missing value, message: "Missing state view for convState.")"#)))
    }

    // MARK: Core AI builds for another iPhone's chip

    func testPortableBuildIsUsedWhenTheIPhoneBuildIsForAnotherChip() {
        XCTAssertEqual(CoreAIBundleLimits.portableAlternative(iOSPath: "ios-h18p/nemotron_3_nano_4b_decode_int8hu",
                                                              macPath: "gpu-pipelined/nemotron_3_nano_4b_decode_int8hu"),
                       "gpu-pipelined/nemotron_3_nano_4b_decode_int8hu")
        XCTAssertEqual(CoreAIBundleLimits.portableAlternative(iOSPath: "gpu-pipelined-b2/gemma4_e2b_qat_decode_int4lin_tbl_aotc_h18p",
                                                              macPath: "gpu-pipelined-b2/gemma4_e2b_qat_decode_int4lin_tbl"),
                       "gpu-pipelined-b2/gemma4_e2b_qat_decode_int4lin_tbl")
        // An iPhone build that isn't chip-specific needs nothing else.
        XCTAssertNil(CoreAIBundleLimits.portableAlternative(iOSPath: "ios", macPath: "macos"))
        // A Mac build that isn't the device-compiled format isn't offered.
        XCTAssertNil(CoreAIBundleLimits.portableAlternative(iOSPath: "ios-h18p/x", macPath: "macos"))
    }

    // MARK: The reader's proven openers and closers stay with a model's cuts

    /// Bad Friends 7 Oct: both MLX runs lost the show's produced intro and
    /// outro (the same recording plays in every episode), which the reader
    /// had. A repeat is exact evidence, so it stays when the model is silent.
    func testAProvenIntroIsKeptWhenTheModelSaysNothingAboutIt() {
        var intro = DetectedSegment(start: 129, end: 141, kind: .intro, sponsor: "", confidence: 85)
        intro.evidence = [SegmentEvidence.repeatedAudio.rawValue]
        var plug = DetectedSegment(start: 1_836, end: 1_848, kind: .selfPromo, sponsor: "", confidence: 100)
        plug.evidence = ["two readings agreed"]
        let lines = [TimedLine(text: "You two are bad friends", start: 129, end: 141)]
        let outcome = ModelCutCheck.verify([], lines: lines, readerCuts: [intro, plug], evidence: [], keeps: [], duration: 4_448)
        XCTAssertEqual(outcome.cuts.map(\.kind), [.intro])
    }

    // MARK: A part that labels the whole stretch is not a located ad

    private func part(_ first: Int, _ last: Int, _ label: JudgeLabel = .hostReadAd) -> JudgePrompt.RawPart {
        JudgePrompt.RawPart(firstLine: first, lastLine: last, firstWords: "", lastWords: "",
                            label: label, sponsor: "", funny: false, confidence: 80, why: "")
    }

    func testAWholeStretchAnswerIsDropped() {
        let kept = JudgePrompt.shifted([part(0, 79), part(30, 44)], window: 100..<180)
        XCTAssertEqual(kept.map(\.firstLine), [130])
    }

    func testALongRealAdInsideTheStretchIsKept() {
        // 70 of 80 lines, but with conversation on both sides.
        XCTAssertFalse(JudgePrompt.isContainer(part(5, 74), windowCount: 80))
        // Short samples (the Basic test) are never judged this way.
        XCTAssertFalse(JudgePrompt.isContainer(part(0, 20), windowCount: 21))
        XCTAssertFalse(JudgePrompt.isContainer(part(0, 79, .show), windowCount: 80))
    }
}
