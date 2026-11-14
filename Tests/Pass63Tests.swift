import XCTest
@testable import PodSkipper

// Pass 63 (his 10 Nov message and export, build 07da0d7): the Reader on
// Basic and Hard, the samples and their score, whole-sample answers, CPU
// models as a finder, live progress, Core AI's catalog and leftovers.

// MARK: Workstream 2 — the samples and the score

final class Pass63BenchTests: XCTestCase {
    private func cuts(_ parts: [(String, ClosedRange<Int>)]) -> [Int: BenchSample.Category?] {
        var out: [Int: BenchSample.Category?] = [:]
        for (kind, lines) in parts { for line in lines where out[line] == nil { out[line] = BenchSample.Category(kind: kind) } }
        return out
    }

    /// Every break of a sample, named as it is labelled.
    private func exact(_ sample: BenchSample) -> [Int: BenchSample.Category?] {
        var out: [Int: BenchSample.Category?] = [:]
        for region in sample.regions { for line in region.lines { out[line] = region.category } }
        return out
    }

    func testSamplesHaveRealTimingWordsAndPauses() {
        XCTAssertEqual(BenchSample.basic.version, 5)
        let basic = BenchScript.basic, hard = BenchScript.hard
        // Basic: a few minutes, read in one go. Hard: a whole episode, long
        // enough to be read in several parts and for "the first ten
        // minutes" and "the last ten" not to be the same minutes.
        XCTAssertTrue((180...330).contains(basic.duration), "Basic is \(Int(basic.duration)) s")
        XCTAssertGreaterThan(hard.duration, 1_200, "Hard is \(Int(hard.duration)) s")
        XCTAssertGreaterThan(hard.lines.count, 350)
        XCTAssertFalse(BenchSample.basic.usesFocus)
        XCTAssertTrue(BenchSample.hard.usesFocus)
        for script in [basic, hard] {
            // Lines differ in length and pause (they were all six seconds).
            let lengths = Set(script.lines.map { Int(($0.end - $0.start) * 10) })
            XCTAssertGreaterThan(lengths.count, 20)
            XCTAssertFalse(script.silences.isEmpty)
            for (i, line) in script.lines.enumerated() {
                XCTAssertFalse(line.words.isEmpty)
                XCTAssertEqual(line.words.map(\.text).joined(separator: " "), line.text)
                XCTAssertTrue(zip(line.words, line.words.dropFirst()).allSatisfy { $0.end <= $1.start + 0.011 }, "words in order, line \(i)")
                if i > 0 { XCTAssertGreaterThanOrEqual(line.start, script.lines[i - 1].end - 0.011) }
            }
            // Breaks don't overlap each other or the either-way lines.
            let all = script.breaks.flatMap { Array($0.lines) }
            XCTAssertEqual(all.count, Set(all).count)
            XCTAssertTrue(script.either.isDisjoint(with: all))
            XCTAssertTrue(script.traps.allSatisfy { trap in trap.lines.allSatisfy { !all.contains($0) && !script.either.contains($0) } })
        }
        // Basic: pre-roll, intro, one host read, credits, post-roll; no trap (Pass 64).
        XCTAssertEqual(basic.breaks.map(\.kind), ["AD", "INTRO", "AD", "OUTRO", "AD"])
        XCTAssertEqual(basic.traps.count, 0)
        // Hard: every situation of the PodSkipper Test.
        let situations = Set(hard.breaks.flatMap(\.situations) + hard.traps.map(\.situation))
        XCTAssertEqual(situations, Set(PodTestPack.bundled()!.situations))
        let seconds = hard.breaks.map { hard.end($0.lines.upperBound) - hard.start($0.lines.lowerBound) }
        XCTAssertTrue(seconds.contains { $0 < 20 })
        XCTAssertTrue(seconds.contains { $0 > 120 })
        XCTAssertGreaterThanOrEqual(hard.traps.count, 4)
        // A read with the hosts wandering off in the middle: either-way lines between two parts of one read.
        XCTAssertTrue(hard.either.contains { line in hard.breaks.contains { $0.lines.upperBound == line - 1 } && hard.either.contains(line + 3) })
    }

    func testTheScoreHasFourPartsAndNeverCollapsesForOneMistake() {
        for sample in BenchSample.allCases {
            let perfect = sample.checks(cut: exact(sample))
            XCTAssertEqual(perfect.score, 1, accuracy: 1e-9, "every break cut exactly and named right")
            XCTAssertEqual(perfect.showLinesCut, 0)
            XCTAssertEqual(sample.score(cut: []), 0, "nothing cut")
            XCTAssertEqual(sample.score(cut: Set(sample.lines.indices)), 0, accuracy: 0.02, "everything cut: none of the show kept")
            // Either-way lines cost nothing.
            var withEither = exact(sample)
            for line in sample.either { withEither[line] = .some(nil) }
            XCTAssertEqual(sample.checks(cut: withEither).score, perfect.score, accuracy: 0.011)
        }
        let hard = BenchSample.hard
        let quality = hard.report(cuts: hard.script.cuts(hard.expectedCut)).quality
        XCTAssertEqual(quality.adsCut, 1, accuracy: 1e-9)
        XCTAssertEqual(quality.showKept, 1, accuracy: 1e-9)
        XCTAssertEqual(quality.edgesRight, quality.edgesChecked)
        XCTAssertEqual(quality.kindsRight, 0, "these cuts name no kind")
        XCTAssertEqual(quality.score, 0.9, accuracy: 1e-9, "kinds are a tenth of the score")

        // One cut running two lines into the show: a few points, not all of them
        // (it was 0 % for the Reader and Apple Intelligence on his phone).
        let read = hard.script.breaks.first { $0.situations.contains("long read") }!
        var overrun = exact(hard)
        var after = read.lines.upperBound + 1
        while hard.either.contains(after) || hard.expectedCut.contains(after) { after += 1 }
        for line in (read.lines.upperBound + 1)...(after + 1) where overrun[line] == nil { overrun[line] = .ad }
        XCTAssertEqual(hard.checks(cut: overrun).showLinesCut, 2)
        let one = hard.checks(cut: overrun).score
        XCTAssertGreaterThan(one, 0.9)
        XCTAssertLessThan(one, 1)
        // One false cut of the joke ad.
        var joke = exact(hard)
        for line in hard.script.traps.first { $0.name == "the joke ad" }!.lines { joke[line] = .ad }
        let fell = hard.checks(cut: joke)
        XCTAssertGreaterThan(fell.score, 0.85)
        XCTAssertEqual(fell.trapsCut, ["the joke ad"])
        // Losing a tenth of the show costs about twice what hearing a tenth of the ads does.
        let heardATenth = PodTestScore.Quality(skippable: 300, heard: 30, showSeconds: 900, showSecondsCut: 0,
                                               breaks: 1, breaksFound: 1, edgesChecked: 2, edgesRight: 2, kindsChecked: 1, kindsRight: 1)
        let cutATenth = PodTestScore.Quality(skippable: 300, heard: 0, showSeconds: 900, showSecondsCut: 90,
                                             breaks: 1, breaksFound: 1, edgesChecked: 2, edgesRight: 2, kindsChecked: 1, kindsRight: 1)
        XCTAssertEqual(heardATenth.score, 0.9, accuracy: 1e-9)
        XCTAssertEqual(cutATenth.score, 0.81, accuracy: 1e-9)
        // Part of a read left in, and a stretch of the show cut, both show in their own column.
        var missing = exact(hard), cutting = exact(hard)
        for line in read.lines.prefix(12) { missing[line] = nil }
        let showLines = (read.lines.upperBound + 8)...(read.lines.upperBound + 19)
        for line in showLines { cutting[line] = .ad }
        let missed = hard.report(cuts: hard.script.cuts(Set(missing.keys))).quality
        let taken = hard.report(cuts: hard.script.cuts(Set(cutting.keys))).quality
        XCTAssertLessThan(missed.adsCut, 0.9)
        XCTAssertEqual(missed.showKept, 1, accuracy: 1e-9)
        XCTAssertEqual(taken.adsCut, 1, accuracy: 1e-9)
        XCTAssertLessThan(taken.showKept, 0.97)
        XCTAssertGreaterThan(taken.score, 0.7, "a stretch of the show cut is points lost, not all of them")
        // Half of the show gone is a low score, but it says how low.
        var half = exact(hard)
        for line in hard.lines.indices where line % 2 == 0 && half[line] == nil && !hard.either.contains(line) { half[line] = .ad }
        let halved = hard.report(cuts: hard.script.cuts(Set(half.keys))).quality
        XCTAssertEqual(halved.adsCut, 1, accuracy: 1e-9)
        XCTAssertLessThan(halved.showKept, 0.65)
        XCTAssertGreaterThan(halved.score, 0.05)
        XCTAssertLessThan(halved.score, 0.45)
        // A wrong kind for everything costs the kinds' share only.
        var misnamed: [Int: BenchSample.Category?] = [:]
        for line in hard.expectedCut { misnamed[line] = .ad }
        let named = hard.checks(cut: misnamed)
        XCTAssertLessThan(named.kindsRight, named.kindsChecked)
        XCTAssertGreaterThan(named.score, 0.9)
    }

    func testQualityAddsUpAcrossEpisodes() throws {
        let pack = try XCTUnwrap(PodTestPack.bundled())
        let exact = Dictionary(uniqueKeysWithValues: pack.episodes.map { e in
            (e.guid, e.breaks.map { PodTestCut(start: $0.start, end: $0.end, kind: $0.kind == "AD" ? "ad" : $0.kind == "SELF" ? "selfPromo" : $0.kind.lowercased()) })
        })
        let all = try XCTUnwrap(PodTestScore.quality(pack: pack, cuts: exact))
        XCTAssertEqual(all.adsCut, 1, accuracy: 1e-9)
        XCTAssertEqual(all.showKept, 1, accuracy: 1e-6)
        XCTAssertEqual(all.breaksFound, pack.episodes.reduce(0) { $0 + $1.breaks.count })
        XCTAssertEqual(all.kindsRight, all.kindsChecked)
        XCTAssertEqual(all.score, 1, accuracy: 1e-6)
        let none = try XCTUnwrap(PodTestScore.quality(pack: pack, cuts: exact.mapValues { _ in [] }))
        XCTAssertEqual(none.score, 0)
        XCTAssertEqual(none.short, "Ads cut 0% · Show kept 100%")
        XCTAssertNil(PodTestScore.quality(pack: pack, cuts: [:]))
    }

    /// The Reader, as the app runs it, on both samples (it scored 80 % and
    /// 0 % on the version 3 samples on his phone).
    func testTheReaderScoresOverNinetyOnBoth() async throws {
        for sample in BenchSample.allCases {
            let found = try await ModelBench.readerCuts(sample)
            let report = sample.report(cuts: ModelBench.podCuts(found))
            XCTAssertGreaterThan(report.quality.score, 0.9, "\(sample.title): \(report.line)")
            XCTAssertGreaterThan(report.quality.adsCut, 0.9, sample.title)
            XCTAssertGreaterThan(report.quality.showKept, 0.97, sample.title)
            XCTAssertLessThanOrEqual(report.checks.showLinesCut, 2, sample.title)
            XCTAssertTrue(report.checks.trapsCut.isEmpty, "\(sample.title) cut \(report.checks.trapsCut)")
        }
    }

    /// A model's answer is scored twice: alone, and after PodSkipper's check.
    func testAModelsAnswerIsScoredAloneAndChecked() async throws {
        let sample = BenchSample.basic
        let reader = try await ModelBench.readerCuts(sample)
        let plan = ModelBench.ReadingPlan(lines: sample.lines, readerCuts: reader, only: nil, share: 1)
        // A model that found nothing: 0 alone; with the check the Reader's cuts stand.
        let silent = ModelBench.classificationResult(JudgeReport(parts: [], failedLines: [], stats: JudgeStats(model: "M")),
                                                     engine: "m", name: "M", sample: sample, plan: plan)
        XCTAssertEqual(silent.rawScore, 0)
        XCTAssertGreaterThan(try XCTUnwrap(silent.score), 0.85)
        XCTAssertEqual(silent.rawAndChecked?.hasPrefix("Model alone 0% · with PodSkipper’s check "), true)
        XCTAssertEqual(silent.shareRead, 1)
        XCTAssertNotNil(silent.breakdown)
        // A model that cut a stretch of the show as well as the host read:
        // its own answer loses for it; the check gives the show back.
        let read = sample.regions[2].lines
        let wrong = (read.upperBound + 6)...(read.upperBound + 17)
        func part(_ lines: ClosedRange<Int>, _ label: JudgeLabel) -> JudgedPart {
            JudgedPart(firstLine: lines.lowerBound, lastLine: lines.upperBound, label: label, sponsor: "", funny: false, confidence: 80, why: "")
        }
        let greedy = ModelBench.classificationResult(
            JudgeReport(parts: [part(read, .hostReadAd), part(wrong, .selfPromo)], failedLines: [], stats: JudgeStats(model: "M")),
            engine: "m", name: "M", sample: sample, plan: plan)
        XCTAssertLessThan(try XCTUnwrap(greedy.rawQuality).showKept, 0.9)
        XCTAssertGreaterThan(try XCTUnwrap(greedy.quality).showKept, 0.97)
        XCTAssertGreaterThan(try XCTUnwrap(greedy.score), try XCTUnwrap(greedy.rawScore))
        // An answer that couldn't be read has no score of either kind.
        let failed = ModelBench.classificationResult(JudgeReport(parts: [], failedLines: [0...10], stats: JudgeStats(model: "M")),
                                                     engine: "m", name: "M", sample: sample, plan: plan)
        XCTAssertNil(failed.score)
        XCTAssertNil(failed.rawScore)
    }

    func testEarlierResultsStillLoadAndAreNotRanked() throws {
        let now = BenchResult(engine: "e", name: "E", sample: .hard, date: .now, score: 0.9)
        XCTAssertEqual(now.sampleVersion, 5, "Pass 64: version 5")
        let old = BenchResult(engine: "e", name: "E", sample: .hard, date: .now, score: 0.9, sampleVersion: 3)
        XCTAssertFalse(old.isComparable)
        // A record saved before this pass has none of the new fields.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        for key in ["quality", "rawScore", "rawQuality", "shareRead"] { json.removeValue(forKey: key) }
        let back = try JSONDecoder().decode(BenchResult.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(back.quality)
        XCTAssertNil(back.rawScore)
        XCTAssertEqual(back.score, 0.9)
        // The new fields survive saving.
        var full = now
        full.quality = BenchSample.hard.report(cuts: []).quality
        full.rawScore = 0.4
        full.shareRead = 0.6
        let again = try JSONDecoder().decode(BenchResult.self, from: JSONEncoder().encode(full))
        XCTAssertEqual(again.quality, full.quality)
        XCTAssertEqual(again.rawScore, 0.4)
        XCTAssertEqual(again.shareRead, 0.6)
    }

    /// The scoreboard is worked out from the records, with ads cut and show
    /// kept beside each score and a model's own answer beside the checked one.
    func testScoreboardShowsTheBreakdown() throws {
        let pack = try XCTUnwrap(PodTestPack.bundled())
        let exact = Dictionary(uniqueKeysWithValues: pack.episodes.map { e in
            (e.guid, e.breaks.map { PodTestCut(start: $0.start, end: $0.end, kind: "ad") })
        })
        let run = PodTestRun(runID: UUID(), started: .now, state: .completed, appBuild: "t", device: "t", packVersion: pack.version,
                             engines: [.init(engine: "reader", name: "PodSkipper Reader", kind: .reader,
                                             reads: pack.episodes.map { .init(guid: $0.guid, outcome: .completed, cuts: []) }),
                                       .init(engine: "mlx-x", name: "Model X", kind: .mlx,
                                             reads: pack.episodes.map { .init(guid: $0.guid, outcome: .completed, cuts: exact[$0.guid]!) })])
        XCTAssertTrue(Scoreboard.rows(runs: [], pack: pack, history: []).isEmpty)
        var hard = BenchResult(engine: "mlx-x", name: "Model X", sample: .hard, date: .now, score: 0.81)
        hard.quality = PodTestScore.Quality(skippable: 100, heard: 10, showSeconds: 500, showSecondsCut: 5)
        hard.rawScore = 0.52
        let stale = BenchResult(engine: "cpu-y", name: "CPU Y", sample: .basic, date: .now, score: 1, sampleVersion: 3)
        let rows = Scoreboard.rows(runs: [run], pack: pack, history: [hard, stale])
        XCTAssertEqual(rows.map(\.id), ["reader", "mlx-x"])
        let model = try XCTUnwrap(rows.last)
        XCTAssertEqual(model.test ?? 0, 100, accuracy: 1e-9)
        XCTAssertEqual(model.hard, 0.81)
        XCTAssertEqual(model.hardRaw, 0.52)
        XCTAssertNil(rows.first { $0.id == "cpu-y" }, "an earlier sample's result isn't ranked")
        let lines = model.lines
        XCTAssertEqual(lines.map(\.label), ["Test", "Hard"])
        XCTAssertEqual(lines[0].adsCut, "100%")
        XCTAssertEqual(lines[0].showKept, "100%")
        XCTAssertEqual(lines[0].note?.contains("Reader"), true)
        // Pass 64: the model alone leads (this run kept no model-alone cuts:
        // "–"), then the score after PodSkipper's check.
        XCTAssertEqual(lines[0].alone, "–")
        XCTAssertEqual(lines[0].checked, "100.0")
        XCTAssertEqual(lines[1].alone, "52")
        XCTAssertEqual(lines[1].checked, "81")
        XCTAssertEqual(lines[1].adsCut, "90%")
        XCTAssertEqual(lines[1].showKept, "99%")
        XCTAssertEqual(model.headline, "52")
        // A newer Hard replaces it.
        let newer = BenchResult(engine: "mlx-x", name: "Model X", sample: .hard, date: .now.addingTimeInterval(60), score: 0.86)
        XCTAssertEqual(Scoreboard.rows(runs: [run], pack: pack, history: [hard, newer]).last?.hard, 0.86)
    }
}

// MARK: Workstream 1 — the Reader's detector

final class Pass63DetectorTests: XCTestCase {
    private func sentences(_ texts: [String], gap: Double = 0.3, each: Double = 3) -> [Sentence] {
        var out: [Sentence] = []
        var clock = 0.0
        for text in texts {
            out.append(Sentence(text: text, start: clock, end: clock + each))
            clock += each + gap
        }
        return out
    }

    private func finding(_ kind: SegmentKind, _ first: Int, _ last: Int, in s: [Sentence], confidence: Int = 90) -> SegmentFinding {
        SegmentFinding(kind: kind, start: s[first].start, end: s[last].end, sponsor: "", confidence: confidence,
                       startConfidence: 80, endConfidence: 80, firstSentence: first, lastSentence: last)
    }

    private func tag(_ count: Int, _ rows: [Int: [Double]], default row: [Double] = [0.98, 0.01, 0.01, 0, 0, 0]) -> [[Double]] {
        (0..<count).map { rows[$0] ?? row }
    }

    private let ad: [Double] = [0, 1, 0, 0, 0, 0]

    func testAReadEndsWhereItLastSells() {
        // "Go for it. Best thing about Tucson?" after an earplug read was an
        // ad at 61–99 % on the Hard sample: five lines of the show cut.
        var texts = ["This episode is sponsored by Hushwell.", "Hushwell makes earplugs you can sleep in.",
                     "I have worn them since the treadmill started.", "Go to hushwell dot com slash shift and use code SHIFT.",
                     "Hushwell. Sleep through it.",
                     "Go for it.", "Best thing about Tucson?", "The whole sky goes pink and orange.", "And the worst thing?"]
        texts += Array(repeating: "We kept talking about the desert for a long while after that.", count: 12)
        let s = sentences(texts)
        var rows: [Int: [Double]] = [:]
        for i in 0...4 { rows[i] = ad }
        rows[5] = [0.01, 0.99, 0, 0, 0, 0]; rows[6] = [0.14, 0.83, 0, 0, 0, 0]
        rows[7] = [0.02, 0.98, 0, 0, 0, 0]; rows[8] = [0.38, 0.61, 0, 0, 0, 0]
        var log: [String] = []
        let out = SegmentDetector.endWhereItSells([finding(.ad, 0, 8, in: s)], sentences: s, tag: tag(s.count, rows), log: &log)
        XCTAssertEqual(out.first?.lastSentence, 4, log.joined(separator: " | "))
        XCTAssertEqual(out.first?.end, s[4].end)

        // A brand spot with no address or code, sure to its last line, stays whole.
        var sure: [Int: [Double]] = [:]
        for i in 0...8 { sure[i] = ad }
        let whole = SegmentDetector.endWhereItSells([finding(.ad, 0, 8, in: s)], sentences: s, tag: tag(s.count, sure), log: &log)
        XCTAssertEqual(whole.first?.lastSentence, 8)

        // Another cut straight after: the lines between two spots belong to the break.
        let next = finding(.ad, 9, 12, in: s)
        let joined = SegmentDetector.endWhereItSells([finding(.ad, 0, 8, in: s), next], sentences: s, tag: tag(s.count, rows), log: &log)
        XCTAssertEqual(joined.first?.lastSentence, 8)

        // Half a minute after the last selling line is another spot or more of the read, not a few carried lines.
        var long = texts
        long.insert(contentsOf: Array(repeating: "And another thing about how well I have been sleeping lately.", count: 10), at: 5)
        let ls = sentences(long)
        var wavering: [Int: [Double]] = [:]
        for i in 0...4 { wavering[i] = ad }
        for i in 5...14 { wavering[i] = [0.3, 0.7, 0, 0, 0, 0] }
        let kept = SegmentDetector.endWhereItSells([finding(.ad, 0, 14, in: ls)], sentences: ls, tag: tag(ls.count, wavering), log: &log)
        XCTAssertEqual(kept.first?.lastSentence, 14)
    }

    func testAPlugEndsWhereItLastPlugs() {
        var texts = ["Tell people where to find you one more time.", "The special is Loud Neighbors, it is on Netflix Friday.",
                     "Phoenix on the ninth, San Diego on the tenth.", "Everything is at samortizcomedy dot com, tickets, dates, the merch.",
                     "Thanks guys, this was fun, I will come back anytime.", "Okay, before we go, I need an update on the couch situation.",
                     "I have decided to pull out the pull-out.", "Wow. Growth."]
        texts += Array(repeating: "We kept talking about the couch for a long while after that.", count: 12)
        let s = sentences(texts)
        var rows: [Int: [Double]] = [:]
        for i in 0...3 { rows[i] = [0, 0, 1, 0, 0, 0] }
        rows[4] = [0.01, 0, 0.99, 0, 0, 0]; rows[5] = [0.04, 0, 0.96, 0, 0, 0]
        rows[6] = [0.12, 0, 0.88, 0, 0, 0]; rows[7] = [0.33, 0, 0.64, 0, 0, 0]
        var log: [String] = []
        let out = SegmentDetector.endWhereItSells([finding(.selfPromo, 0, 7, in: s)], sentences: s, tag: tag(s.count, rows), log: &log)
        XCTAssertEqual(out.first?.lastSentence, 3, log.joined(separator: " | "))
    }

    func testAShortAdThatSaysItIsntOneIsABit() {
        XCTAssertTrue(SegmentDetector.saysItIsNotAnAd("introducing pete's back brace, use code ouch for nothing off"))
        XCTAssertTrue(SegmentDetector.saysItIsNotAnAd("you know what this show needs? a sponsor for my bad back. this show needs a sponsor"))
        XCTAssertTrue(SegmentDetector.saysItIsNotAnAd("costco is great, they're not paying us"))
        XCTAssertFalse(SegmentDetector.saysItIsNotAnAd("go to freshbox dot com slash kitchen and use code kitchen sixty"))
        let s = sentences(["You know what this show needs? A sponsor for my bad back.",
                           "Introducing Pete's Back Brace, now with extra duct tape, use code OUCH for nothing off.",
                           "Pete's Back Brace, because you'll never sleep in a real bed. Side effects include sadness.",
                           "Please nobody make that.",
                           "Today's episode is supported by Brightnest, the mattress company.",
                           "Go to brightnest dot com slash late and you'll get fifteen percent off.",
                           "That's brightnest dot com slash late.", "Thanks to Brightnest for supporting the show."], each: 5)
        var log: [String] = []
        let out = SegmentDetector.settle([finding(.ad, 1, 3, in: s), finding(.ad, 4, 7, in: s)], sentences: s, log: &log)
        XCTAssertEqual(out.map(\.firstSentence), [4], log.joined(separator: " | "))
        // The same answer from a model is left out by the cut check.
        let lines = s.map { TimedLine(text: $0.text, start: $0.start, end: $0.end) }
        let part = JudgedPart(firstLine: 1, lastLine: 2, label: .hostReadAd, sponsor: "Pete's Back Brace", funny: false, confidence: 80, why: "")
        let real = JudgedPart(firstLine: 4, lastLine: 7, label: .hostReadAd, sponsor: "Brightnest", funny: false, confidence: 80, why: "")
        let checked = ModelFinder.checkedCuts(from: [part, real], lines: lines, readerCuts: [], inserted: [], evidence: [], silences: [],
                                              padding: 0, duration: s.last!.end)
        XCTAssertFalse(checked.cuts.contains { $0.start < lines[3].start }, "the joke ad isn't cut")
        XCTAssertTrue(checked.cuts.contains { $0.start >= lines[4].start - 0.01 && $0.end > lines[6].start })
        XCTAssertTrue(checked.notes.contains { $0.contains("says it isn't an ad") })
    }

    func testTheOpeningAndTheCreditsKeepTheirOwnKinds() {
        // "You're listening to Late Shift…" and the two spots after it were one ad.
        let top = sentences(["You're listening to Late Shift with Nora and Pete.", "A Wavelength Media podcast.", "Here we go.",
                             "Tired of overdraft fees? Ridgeline Bank has none.", "Open a checking account in five minutes at ridgeline dot com.",
                             "Ridgeline Bank. Member FDIC.", "This winter, Arcadia Air is flying nonstop to more warm places.",
                             "Book by Friday at arcadia air dot com."])
        var log: [String] = []
        let opened = SegmentDetector.openingApart(finding(.ad, 0, 7, in: top), sentences: top, log: &log)
        XCTAssertEqual(opened.map(\.kind), [.intro, .ad], log.joined(separator: " | "))
        XCTAssertEqual(opened.first?.lastSentence, 2)
        XCTAssertEqual(opened.last?.firstSentence, 3)
        // An ad that doesn't open on an ident stays one.
        XCTAssertEqual(SegmentDetector.openingApart(finding(.ad, 3, 7, in: top), sentences: top, log: &log).count, 1)

        // The credits, the Patreon plug after them and a recorded spot were one "outro".
        var end = sentences(Array(repeating: "We talked about the couch for a long time.", count: 40))
        let base = end.last!.end + 0.3
        let tail = ["Late Shift is produced by Danny Cole, with music by The Fold.", "Our executive producer is Rina Park.",
                    "See you next week, everybody.",
                    "If you want more Late Shift, we do a bonus episode every week on our Patreon.", "Five dollars a month gets you every bonus.",
                    "Need a website? Make one in an afternoon with Pagecraft.", "Go to pagecraft dot com and use code SHIFT for ten percent off."]
        var clock = base
        for (i, text) in tail.enumerated() {
            // A pause where each new thing begins.
            if i == 3 || i == 5 { clock += 1.4 }
            end.append(Sentence(text: text, start: clock, end: clock + 4))
            clock += 4.2
        }
        let first = end.count - tail.count
        let whole = finding(.outro, first, end.count - 1, in: end)
        let split = SegmentDetector.creditsApart(whole, sentences: end, duration: end.last!.end, tag: nil, log: &log)
        XCTAssertEqual(split.map(\.kind), [.outro, .selfPromo, .ad], log.joined(separator: " | "))
        XCTAssertEqual(split[0].lastSentence, first + 2, "the sign-off goes with the credits")
        XCTAssertEqual(split[0].detail, CutDetail.credits.rawValue)
        XCTAssertEqual(split[1].firstSentence, first + 3)
        XCTAssertEqual(split[2].firstSentence, first + 5)
        XCTAssertEqual(split.first?.start, whole.start)
        XCTAssertEqual(split.last?.end, whole.end)
    }

    func testPlugsAreNotJoinedAcrossTalkTheReaderReadsAsTheShow() {
        XCTAssertEqual(SegmentDetector.Tuning().plugGapShow, 0.7)
        let s = sentences(["Tickets are on sale now at lateshiftlive dot com.", "Come say hi, we hang out after every show.",
                           "Okay so my back has been killing me all week.", "You sleep on a couch, that is why.",
                           "It is a couch, Pete. It is not a bed.",
                           "Our merch store has new shirts, go to lateshift dot com slash merch.", "Subscribe to the show wherever you listen."])
        var log: [String] = []
        let pieces = [finding(.selfPromo, 0, 1, in: s), finding(.selfPromo, 5, 6, in: s)]
        // The Reader reads what is between them as the show: two plugs.
        let show = tag(s.count, [0: [0, 0, 1, 0, 0, 0], 1: [0, 0, 1, 0, 0, 0], 5: [0, 0, 1, 0, 0, 0], 6: [0, 0, 1, 0, 0, 0]])
        XCTAssertEqual(SegmentDetector.joinPlugs(pieces, sentences: s, tag: show, log: &log).count, 2)
    }
}

// MARK: Workstream 3 — whole-sample answers, SHOW entries, per-family plans

final class Pass63GuardTests: XCTestCase {
    private func part(_ a: Int, _ b: Int, _ label: JudgeLabel = .paidAd) -> JudgePrompt.RawPart {
        JudgePrompt.RawPart(firstLine: a, lastLine: b, firstWords: "", lastWords: "", label: label,
                            sponsor: "", funny: false, confidence: 80, why: "")
    }

    /// The answers his 10 Nov export holds, on the samples they were given for.
    func testNoFamilyMayMarkMostOfAStretchAsOnePart() {
        let basic = BenchSample.basic.lines, hard = BenchSample.hard.lines
        let whole = 0..<basic.count, long = 0..<hard.count
        for spec in LocalModelSpec.all + [.lfm25_1_2B_cpu, .lfm3_1_7B_cpu] {
            let plan = ModelPromptPlan.plan(for: spec, folder: nil)
            let share = try? XCTUnwrap(plan.maxCutShare, "\(spec.name) has no limit")
            XCTAssertLessThanOrEqual(share ?? 1, 0.5, spec.name)
            for label in [JudgeLabel.intro, .paidAd, .credits, .hostReadAd, .outro, .selfPromo] {
                // "lines 0–92: INTRO", "0–163: PAID_AD" (Llama 3.2, LFM2.5 2.6B, MiniCPM5 1B, Gemma 3, Gemma 4 E2B…)
                XCTAssertTrue(JudgePrompt.shifted([part(0, basic.count - 1, label)], window: whole, lines: basic, maxShare: plan.maxCutShare).isEmpty)
                XCTAssertTrue(JudgePrompt.shifted([part(0, hard.count - 1, label)], window: long, lines: hard, maxShare: plan.maxCutShare).isEmpty)
                // "INTRO 5–81" (Phi-4 mini), "HOST_READ_AD 34–92" (Gemma 3): most of the sample without touching both ends.
                XCTAssertTrue(JudgePrompt.shifted([part(5, basic.count - 8, label)], window: whole, lines: basic, maxShare: plan.maxCutShare).isEmpty,
                              "\(spec.name) \(label.rawValue)")
                XCTAssertTrue(JudgePrompt.shifted([part(1, hard.count / 2 + 30, label)], window: long, lines: hard, maxShare: plan.maxCutShare).isEmpty)
            }
            // A real read inside the stretch is kept.
            let read = BenchSample.hard.script.breaks.first { $0.situations.contains("long read") }!.lines
            XCTAssertEqual(JudgePrompt.shifted([part(read.lowerBound, read.upperBound, .hostReadAd)], window: long, lines: hard,
                                               maxShare: plan.maxCutShare).count, 1, spec.name)
        }
    }

    func testAnAnswerThatLabelsLineAfterLineIsDroppedWhole() {
        let hard = BenchSample.hard.lines
        // Qwen3.5 2B (CPU): every two or three lines its own HOST_READ_AD, most of the sample.
        var tiling: [JudgePrompt.RawPart] = []
        var line = 40
        while line < hard.count - 3 { tiling.append(part(line, line + 2, .hostReadAd)); line += 3 }
        XCTAssertTrue(JudgePrompt.shifted(tiling, window: 0..<hard.count, lines: hard).isEmpty)
        // A joke marked to be kept is not a cut, and survives.
        let kept = JudgePrompt.shifted(tiling + [part(10, 12, .mockAd)], window: 0..<hard.count, lines: hard)
        XCTAssertEqual(kept.map(\.label), [.mockAd])
        // Eight real, separate parts are far under the limit.
        let real = BenchSample.hard.script.breaks.prefix(8).map { part($0.lines.lowerBound, $0.lines.upperBound, .paidAd) }
        XCTAssertEqual(JudgePrompt.shifted(Array(real), window: 0..<hard.count, lines: hard).count, 8)
    }

    func testPartsThatContradictEachOtherAreDropped() {
        let hard = BenchSample.hard.lines
        // LFM2.5 1.2B (CPU): "NETWORK_PROMO 28–63, SELF_PROMO 29–63, INTRO 33–60, OUTRO 35–60".
        let answer = [part(28, 63, .networkPromo), part(29, 63, .selfPromo), part(33, 60, .intro), part(35, 60, .outro), part(200, 204, .paidAd)]
        let kept = JudgePrompt.shifted(answer, window: 0..<hard.count, lines: hard)
        XCTAssertEqual(kept.map(\.firstLine), [200])
        // A short promo inside a break marked whole is not a contradiction.
        let nested = JudgePrompt.shifted([part(215, 225, .paidAd), part(219, 221, .networkPromo)], window: 0..<hard.count, lines: hard)
        XCTAssertEqual(nested.count, 2)
    }

    func testAPartLongerThanItsKindCanBeIsDropped() {
        XCTAssertEqual(JudgePrompt.longestPart(.intro), 150)
        let lines = (0..<400).map { TimedLine(text: "line \($0)", start: Double($0) * 6, end: Double($0) * 6 + 5.5) }
        // A 3-minute "intro" in a 40-minute stretch is under half of it, but no intro is that long.
        XCTAssertTrue(JudgePrompt.shifted([part(0, 30, .intro)], window: 0..<400, lines: lines).isEmpty)
        XCTAssertEqual(JudgePrompt.shifted([part(0, 5, .intro)], window: 0..<400, lines: lines).count, 1)
        XCTAssertEqual(JudgePrompt.shifted([part(100, 160, .hostReadAd)], window: 0..<400, lines: lines).count, 1, "a six-minute read")
        XCTAssertTrue(JudgePrompt.shifted([part(100, 200, .hostReadAd)], window: 0..<400, lines: lines).isEmpty, "ten minutes isn't one read")
        // A joke marked to be kept for ten minutes would stop the Reader's real cuts under it.
        XCTAssertTrue(JudgePrompt.shifted([part(100, 200, .mockAd)], window: 0..<400, lines: lines).isEmpty)
    }

    func testShowIsNeverOfferedOrCounted() {
        // Nemotron 3 Nano 4B: "SHOW 0–163"; Granite 4.0 H 1B: "SHOW 1–1, SHOW 2–2, SHOW 3–3, SHOW 4–4".
        for profile in [JudgePrompt.Profile.lean, .listener, .listenerEdges, .compact, .compactListener, .compactTight, .leanReasoned, .candidate, .guided] {
            XCTAssertFalse(profile.schema.contains("SHOW"), profile.rawValue)
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(profile.schema.utf8)), profile.rawValue)
        }
        for profile in [JudgePrompt.Profile.lean, .listener, .listenerEdges, .compact, .compactListener, .compactTight, .leanReasoned] {
            XCTAssertTrue(profile.system.contains("never list the show itself"), profile.rawValue)
        }
        XCTAssertTrue(JudgePrompt.Profile.candidate.system.contains("Never list the show."))
        // A free answer that still writes it is read, and the entry dropped.
        let answer = #"{"parts":[{"first_line":1,"last_line":1,"label":"SHOW","sponsor":"","funny":false},{"first_line":5,"last_line":9,"label":"PAID_AD","sponsor":"X","funny":false}]}"#
        let parsed = try? XCTUnwrap(JudgePrompt.parseComplete(answer))
        XCTAssertEqual(parsed?.count, 2)
        XCTAssertEqual(JudgePrompt.shifted(parsed ?? [], window: 100..<160).map(\.firstLine), [105])
    }

    func testEachFamilyIsAskedItsOwnWay() {
        // LFM3 1.7B: told how to go through the lines; Qwen3.5 4B: the listener's rules.
        let lfm3 = ModelPromptPlan.plan(for: .lfm3_1_7B_cpu, folder: nil)
        XCTAssertEqual(lfm3.family, "LFM3")
        XCTAssertEqual(lfm3.profile, .guided)
        XCTAssertEqual(lfm3.maxWindowTokens, 2_400)
        XCTAssertEqual(lfm3.repetitionPenalty, 1.1)
        XCTAssertTrue(JudgePrompt.Profile.guided.system.contains("last_line is larger than first_line"))
        XCTAssertFalse(JudgePrompt.Profile.guided.system.contains(#"{"parts":[]}"#), "the empty answer isn't quoted to small models")
        XCTAssertNotNil(JudgePrompt.Profile.guided.reminder)
        XCTAssertEqual(ModelPromptPlan.plan(for: .lfm25_1_2B_cpu, folder: nil).family, "LFM2.5")
        let qwen = ModelPromptPlan.plan(for: .qwen35_4B, folder: nil)
        XCTAssertEqual(qwen.profile, .listener)
        XCTAssertTrue(qwen.profile.system.contains("for nothing off"), "a joke ad's tells are spelled out")
        // On the CPU a part is never longer than the family is shown, and the answer is held to the form.
        XCTAssertEqual(CPUJudge.windowTokens(lfm3), 2_400)
        XCTAssertEqual(CPUJudge.windowTokens(qwen), 3_000)
        XCTAssertEqual(CPUJudge.windowTokens(ModelPromptPlan.plan(for: .lfm25_1_2B_cpu, folder: nil)), 2_000)
        let grammar = try? XCTUnwrap(CPUJudge.grammar(lfm3))
        XCTAssertEqual(grammar?.contains("{0,7}"), true, "at most eight parts")
        XCTAssertEqual(grammar?.contains("SHOW"), false)
        for label in ["PAID_AD", "HOST_READ_AD", "NETWORK_PROMO", "SELF_PROMO", "GUEST_PLUG", "INTRO", "OUTRO", "CREDITS", "MOCK_AD"] {
            XCTAssertEqual(grammar?.contains("\\\"\(label)\\\""), true, label)
        }
        XCTAssertEqual(CPUJudge.grammar(ModelPromptPlan.coreAI(id: "qwen3-4b", name: "Qwen3 4B", template: "", context: 2_047))?.contains("{0,3}"), true)
        // The CPU catalog: LFM3 1.7B, pinned.
        let model = CPUReading.lfm3_1_7B_q4
        XCTAssertTrue(CPUReading.catalog.contains(model))
        XCTAssertEqual(model.file, "LFM3-1.7B-QAD-Q4_0.gguf")
        XCTAssertEqual(model.bytes, 1_049_615_680)
        XCTAssertEqual(model.sha256, "43a7d09a0e9cba91b63eb7052488b9564569bddfd65754d2e426465e572a7452")
        let prompt = model.chatPrompt(system: "R", header: "H", rest: "L")
        XCTAssertEqual(prompt.head + prompt.tail, "<|startoftext|><|im_start|>system\nR<|im_end|>\n<|im_start|>user\nHL<|im_end|>\n<|im_start|>assistant\n<think></think>")
    }

    func testAShortOpenerNextToABreakPassesTheCutCheck() {
        // The Basic sample: a model's five-second "From Copperline Audio, this is Kitchen Table" after the pre-roll.
        let sample = BenchSample.basic
        let lines = sample.lines
        func part(_ lines: ClosedRange<Int>, _ label: JudgeLabel) -> JudgedPart {
            JudgedPart(firstLine: lines.lowerBound, lastLine: lines.upperBound, label: label, sponsor: "", funny: false, confidence: 80, why: "")
        }
        let preRoll = sample.regions[0].lines, intro = sample.regions[1].lines
        let checked = ModelFinder.checkedCuts(from: [part(preRoll, .paidAd), part(intro, .intro)], lines: lines, readerCuts: [],
                                              inserted: [], evidence: [], silences: sample.silences, padding: 0.4, duration: sample.duration)
        XCTAssertTrue(checked.cuts.contains { $0.kind == .intro }, checked.notes.joined(separator: " | "))
        // The same few seconds in the middle of the show are still too short to cut.
        let quiet = lines.indices.first { i in
            i > intro.upperBound + 8 && lines[i].end - lines[i].start < 5
                && sample.regions.allSatisfy { i < $0.lines.lowerBound - 4 || i > $0.lines.upperBound + 4 }
        }!
        let middle = quiet...quiet
        let alone = ModelFinder.checkedCuts(from: [part(middle, .intro)], lines: lines, readerCuts: [], inserted: [], evidence: [],
                                            silences: sample.silences, padding: 0.4, duration: sample.duration)
        XCTAssertFalse(alone.cuts.contains { $0.kind == .intro })
    }
}

// MARK: Workstream 4 — CPU models as a finder, and who reads when

final class Pass63RoutingTests: XCTestCase {
    private func facts(_ choice: AdFinderChoice, cpuReady: Bool = true, background: Bool = true, gpu: Bool = false) -> FinderRouting.Facts {
        FinderRouting.Facts(choice: choice, mlx: "Qwen3.5 4B", coreAI: "Qwen3 4B", cpu: "Qwen3.5 4B (CPU)",
                            cpuReady: cpuReady, backgroundCPU: background, backgroundGPU: gpu)
    }

    func testFiveChoicesInOrder() {
        XCTAssertEqual(AdFinderChoice.ordered, [.reader, .apple, .model, .coreAI, .cpu])
        XCTAssertEqual(Set(AdFinderChoice.ordered), Set(AdFinderChoice.allCases))
        XCTAssertEqual(AdFinderChoice.cpu.title, "CPU models (processor)")
        XCTAssertEqual(AdFinderChoice(rawValue: "cpu"), .cpu)
        XCTAssertEqual(AdFinderChoice(rawValue: "model"), .model, "saved choices keep their meaning")
    }

    func testWhoReadsOnScreenAndOff() {
        // PodSkipper Reader: nothing else reads.
        var plan = FinderRouting.plan(facts(.reader))
        XCTAssertEqual(plan.onScreen, .reader)
        XCTAssertEqual(plan.offScreen, .reader)
        XCTAssertNil(plan.again)
        // Apple Intelligence: the CPU model first off screen, Apple Intelligence again when he's back.
        plan = FinderRouting.plan(facts(.apple))
        XCTAssertEqual(plan.onScreen, .apple)
        XCTAssertEqual(plan.offScreen, .cpu("Qwen3.5 4B (CPU)"))
        XCTAssertEqual(plan.again, .apple)
        plan = FinderRouting.plan(facts(.apple, background: false))
        XCTAssertEqual(plan.offScreen, .reader)
        XCTAssertEqual(plan.again, .apple)
        // MLX and Core AI: the CPU model off screen, or wait with the Reader's cuts.
        for (choice, chosen) in [(AdFinderChoice.model, FinderRouting.Engine.mlx("Qwen3.5 4B")), (.coreAI, .coreAI("Qwen3 4B"))] {
            plan = FinderRouting.plan(facts(choice))
            XCTAssertEqual(plan.onScreen, chosen)
            XCTAssertEqual(plan.offScreen, .cpu("Qwen3.5 4B (CPU)"))
            XCTAssertNil(plan.again, "the CPU model's read is kept")
            plan = FinderRouting.plan(facts(choice, background: false))
            XCTAssertEqual(plan.offScreen, .reader)
            XCTAssertEqual(plan.again, chosen)
            plan = FinderRouting.plan(facts(choice, cpuReady: false))
            XCTAssertEqual(plan.offScreen, .reader, "not downloaded: nothing to fall back to")
            XCTAssertEqual(plan.again, chosen)
            plan = FinderRouting.plan(facts(choice, gpu: true))
            XCTAssertEqual(plan.offScreen, chosen, "with Background GPU Access it reads off screen itself")
        }
        // CPU models: on screen and off, whatever the background switch says.
        for background in [true, false] {
            plan = FinderRouting.plan(facts(.cpu, background: background))
            XCTAssertEqual(plan.onScreen, .cpu("Qwen3.5 4B (CPU)"))
            XCTAssertEqual(plan.offScreen, .cpu("Qwen3.5 4B (CPU)"))
        }
        plan = FinderRouting.plan(facts(.cpu, cpuReady: false))
        XCTAssertEqual(plan.onScreen, .reader)
        XCTAssertTrue(plan.summary.contains("isn’t downloaded yet"))
    }

    func testTheSummaryNamesBothFinders() {
        for choice in AdFinderChoice.ordered {
            for background in [true, false] {
                let plan = FinderRouting.plan(facts(choice, background: background))
                XCTAssertTrue(plan.summary.contains(plan.onScreen.name), "\(choice) \(background): \(plan.summary)")
                XCTAssertTrue(plan.summary.contains(plan.offScreen.name), "\(choice) \(background): \(plan.summary)")
                XCTAssertTrue(plan.summary.hasSuffix("."))
                XCTAssertEqual(plan.summary.filter { $0 == "." }.count - plan.summary.components(separatedBy: "3.5").count + 1, 1,
                               "one sentence: \(plan.summary)")
            }
        }
        XCTAssertEqual(FinderRouting.plan(facts(.model)).summary,
                       "On screen Qwen3.5 4B finds the ads; locked or in the background Qwen3.5 4B (CPU) reads instead, and its result is kept.")
    }

    func testUseItOnScreenTooBecomesTheFifthChoice() throws {
        let name = "pass63-routing-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // On, with an MLX model chosen: the CPU model was reading everything.
        defaults.set(true, forKey: "cpuReading.primary")
        defaults.set(AdFinderChoice.model.rawValue, forKey: "adFinder")
        FinderRouting.migratePrimarySwitch(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "adFinder"), AdFinderChoice.cpu.rawValue)
        XCTAssertNil(defaults.object(forKey: "cpuReading.primary"))
        // Once only: choosing MLX again afterwards stays.
        defaults.set(AdFinderChoice.model.rawValue, forKey: "adFinder")
        FinderRouting.migratePrimarySwitch(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "adFinder"), AdFinderChoice.model.rawValue)
        // On with Apple Intelligence or the Reader chosen it did nothing, and still does nothing.
        for choice in [AdFinderChoice.apple, .reader] {
            defaults.set(true, forKey: "cpuReading.primary")
            defaults.set(choice.rawValue, forKey: "adFinder")
            FinderRouting.migratePrimarySwitch(defaults: defaults)
            XCTAssertEqual(defaults.string(forKey: "adFinder"), choice.rawValue)
        }
        // Off: nothing changes.
        defaults.set(false, forKey: "cpuReading.primary")
        defaults.set(AdFinderChoice.coreAI.rawValue, forKey: "adFinder")
        FinderRouting.migratePrimarySwitch(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "adFinder"), AdFinderChoice.coreAI.rawValue)
    }

    func testTheChosenFinderFollowsTheSetting() {
        let before = UserDefaults.standard.string(forKey: "adFinder")
        defer { UserDefaults.standard.set(before, forKey: "adFinder") }
        UserDefaults.standard.set(AdFinderChoice.cpu.rawValue, forKey: "adFinder")
        XCTAssertTrue(CPUReading.isChosenFinder)
        UserDefaults.standard.set(AdFinderChoice.model.rawValue, forKey: "adFinder")
        XCTAssertFalse(CPUReading.isChosenFinder)
    }

    /// A CPU model's results stay under its engine id whether or not its file is on the phone.
    @MainActor
    func testACPUModelsResultsOutliveItsDownload() throws {
        let name = "pass63-bench-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let bench = ModelBench(defaults: defaults, recoverInterrupted: false)
        let model = CPUReading.lfm3_1_7B_q4
        XCTAssertFalse(model.isDownloaded, "never downloaded in a test run")
        bench.save(BenchResult(engine: model.engineID, name: model.name, sample: .basic, date: .now, score: 0.94))
        XCTAssertEqual(bench.runs(model.engineID).count, 1)
        XCTAssertEqual(bench.result(model.engineID, .basic)?.score, 0.94)
        // A new launch reads them back.
        let again = ModelBench(defaults: defaults, recoverInterrupted: false)
        XCTAssertEqual(again.runs(model.engineID).count, 1)
        XCTAssertEqual(again.lastScored(model.engineID, .basic)?.score, 0.94)
        // Every catalog model has a row, downloaded or not.
        XCTAssertEqual(CPUReading.catalog.count, 5)
        XCTAssertTrue(CPUReading.catalog.allSatisfy { !$0.engineID.isEmpty && !$0.summary.isEmpty })
    }
}

// MARK: Workstream 5 — progress from the work itself

final class Pass63ProgressTests: XCTestCase {
    private final class Values: @unchecked Sendable {
        private let lock = NSLock()
        private var fractions: [Double] = [], lines: [String] = []
        func add(_ value: Double) { lock.withLock { fractions.append(value) } }
        func say(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [Double] { lock.withLock { fractions } }
        var said: [String] { lock.withLock { lines } }
    }

    /// A one-part read (Basic or Hard on a CPU model) as the engine reports
    /// it: every 256-token batch, then every token. The bar sat at 0 % until
    /// the whole part was done.
    func testACPUReadMovesTheBarWithEveryBatchAndToken() {
        let prompt = 2_900, answer = 180
        let meter = WorkMeterBox(WorkMeter(parts: [.init(promptTokens: prompt, expectedAnswer: 80, answerCap: 640)],
                                           readRate: 20, writeRate: 4, loadSeconds: 0, ratesKnown: false))
        let values = Values()
        let reporter = CPUJudge.Reporter(meter: meter, parts: 1, progress: { values.add($0) }, status: { values.say($0) })
        let clock = CPUJudge.StepClock()
        var now = Date(timeIntervalSince1970: 1_000)
        reporter.change { $0.modelLoaded() }
        reporter.read(part: 0, before: 0, done: 0, of: prompt, paced: false, clock: clock, now: now)
        XCTAssertEqual(values.all.last, 0)
        XCTAssertFalse(meter.snapshot.speedMeasured, "nothing measured yet: the time left isn't said")
        var done = 0
        while done < prompt {
            let step = min(256, prompt - done)
            done += step
            now += Double(step) / 21   // 21 tokens a second, as on his phone
            reporter.read(part: 0, before: 0, done: done, of: prompt, paced: false, clock: clock, now: now)
        }
        let afterReading = values.all.last ?? 0
        XCTAssertGreaterThan(afterReading, 0.3)
        XCTAssertLessThan(afterReading, 0.97)
        XCTAssertTrue(meter.snapshot.speedMeasured)
        XCTAssertEqual(meter.snapshot.readRate, 21, accuracy: 0.5, "this run's own speed")
        for token in 1...answer {
            now += 0.3
            reporter.wrote(part: 0, tokens: token, paced: false, clock: clock, now: now)
        }
        XCTAssertEqual(meter.snapshot.writeRate, 1 / 0.3, accuracy: 0.2)
        reporter.change { $0.finished(part: 0, written: answer) }
        let all = values.all
        XCTAssertEqual(all.last, 1)
        XCTAssertTrue(zip(all, all.dropFirst()).allSatisfy { $0 <= $1 }, "never backwards")
        // Many steps on the way, not one jump.
        XCTAssertGreaterThan(Set(all.map { Int($0 * 100) }).count, 15)
        XCTAssertTrue(all.contains { $0 > 0.02 && $0 < 0.2 })
        XCTAssertTrue(all.contains { $0 > 0.5 && $0 < 0.9 })
        // What it says while it works.
        XCTAssertTrue(values.said.contains { $0.hasPrefix("Reading the sample on the CPU · part 1 of 1 · ") && $0.contains("% · 21 tokens a second") },
                      values.said.prefix(4).joined(separator: " | "))
        XCTAssertTrue(values.said.contains { $0.hasPrefix("Writing its answer · part 1 of 1 · ") && $0.contains("tokens · 3.3 a second") })
        XCTAssertEqual(CPUJudge.Reporter.readingLine(part: 1, parts: 3, share: 42, speed: 20.6, paced: true),
                       "Reading the sample on the CPU, paced · part 2 of 3 · 42% · 21 tokens a second")
        XCTAssertEqual(CPUJudge.Reporter.writingLine(part: 0, parts: 1, tokens: 1, speed: 0, paced: false),
                       "Writing its answer · part 1 of 1 · 1 token")
    }

    /// The time left comes from this run's own speed, never an earlier run's.
    func testTimeLeftWaitsForThisRunsOwnSpeed() {
        var meter = WorkMeter(parts: [.init(promptTokens: 2_000, expectedAnswer: 100, answerCap: 320)],
                              readRate: 200, writeRate: 20, loadSeconds: 0, ratesKnown: true)
        XCTAssertFalse(meter.speedMeasured, "an earlier run's rates are known, but nothing is measured")
        XCTAssertFalse(meter.confident)
        let start = Date(timeIntervalSince1970: 0)
        meter.reading(part: 0, done: 0, now: start)
        XCTAssertEqual(meter.fraction, 0)
        // A hot phone today: 40 tokens a second, a fifth of the earlier run's.
        meter.reading(part: 0, done: 400, now: start.addingTimeInterval(10))
        XCTAssertTrue(meter.speedMeasured)
        XCTAssertEqual(meter.readRate, 40, accuracy: 0.01)
        XCTAssertEqual(meter.writeRate, 4, accuracy: 0.01, "writing is taken to be as much slower than reading as before")
        XCTAssertEqual(meter.secondsLeft, 1_600.0 / 40 + 100.0 / 4, accuracy: 0.5)
        // Once it writes, its own writing speed.
        meter.writing(part: 0, written: 0, now: start.addingTimeInterval(50))
        meter.writing(part: 0, written: 16, now: start.addingTimeInterval(52))
        XCTAssertTrue(meter.liveWrite)
        XCTAssertEqual(meter.writeRate, 8, accuracy: 0.01)
        let box = WorkMeterBox(WorkMeter(parts: [.init(promptTokens: 100, expectedAnswer: 10, answerCap: 20)],
                                         readRate: 50, writeRate: 9, loadSeconds: 0, ratesKnown: true))
        XCTAssertFalse(box.updateReading { _ in }.speedKnown, "Measuring speed… until this run has measured")
    }

    /// Core AI says nothing while it reads a prompt: nothing is added to the
    /// bar until the read is really done (it was the clock's guess at an
    /// earlier run's speed, which ran to 72–80 % and froze).
    func testCoreAIsBarWaitsForTheReadToFinish() {
        var meter = WorkMeter(parts: [.init(promptTokens: 1_930, expectedAnswer: 60, answerCap: 170),
                                      .init(promptTokens: 1_500, expectedAnswer: 60, answerCap: 170)],
                              readRate: 50, writeRate: 9, loadSeconds: 0, ratesKnown: true)
        meter.modelLoaded()
        XCTAssertEqual(meter.fraction, 0)
        // 80 seconds into a read expected to take 39: still nothing on the bar.
        XCTAssertEqual(meter.fraction, 0)
        meter.readFinished(part: 0, seconds: 96.5)
        XCTAssertTrue(meter.speedMeasured)
        XCTAssertEqual(meter.readRate, 20, accuracy: 0.01)
        XCTAssertGreaterThan(meter.fraction, 0.3)
        XCTAssertLessThan(meter.fraction, 0.6)
        // A model that reads in steps says how far it is.
        XCTAssertEqual(CoreAIReadSteps.tokensRead(CoreAIReadSteps.message(read: 512, of: 1_930)), 512)
        XCTAssertNil(CoreAIReadSteps.tokensRead("Reading sample · 1930 input tokens"))
        XCTAssertNil(CoreAIReadSteps.tokensRead("Writing classification · 37 tokens"))
    }

    func testStepClockMeasuresSinceThePartBegan() {
        let clock = CPUJudge.StepClock()
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(clock.reading(0, now: start), 0)
        XCTAssertEqual(clock.reading(256, now: start.addingTimeInterval(4)) ?? 0, 64, accuracy: 0.01)
        XCTAssertTrue(clock.shouldSay(now: start))
        XCTAssertFalse(clock.shouldSay(now: start.addingTimeInterval(0.2)))
        XCTAssertTrue(clock.shouldSay(now: start.addingTimeInterval(0.6)))
    }

    /// The stand-in read the simulator shows: the same reporter, start to finish.
    func testTheStandInReadReportsLikeARealOne() async throws {
        let values = Values()
        try await CPUJudge.demoRead(progress: { values.add($0) }, status: { values.say($0) })
        let all = values.all
        XCTAssertEqual(all.first, 0)
        XCTAssertEqual(all.last, 1)
        XCTAssertTrue(zip(all, all.dropFirst()).allSatisfy { $0 <= $1 })
        XCTAssertGreaterThan(Set(all.map { Int($0 * 100) }).count, 15)
        XCTAssertTrue(values.said.contains { $0.hasPrefix("Reading the sample on the CPU · part 2 of 2") })
        XCTAssertTrue(values.said.contains { $0.hasPrefix("Writing its answer · part 1 of 2") })
    }
}

// MARK: Workstream 1 — learning starts at once

final class Pass63LearnerTests: XCTestCase {
    func testActivityIsSaidPlainly() {
        XCTAssertNil(OnDeviceReaderLearner.Activity.idle.line)
        XCTAssertEqual(OnDeviceReaderLearner.Activity.starting.line, "Starting to learn…")
        XCTAssertEqual(OnDeviceReaderLearner.Activity.training(reader: 2, of: 2).line, "Learning: reader 2 of 2…")
        XCTAssertEqual(OnDeviceReaderLearner.Activity.gathering("Loud Neighbors").line, "Reading “Loud Neighbors”…")
        XCTAssertEqual(OnDeviceReaderLearner.correctionPause, .seconds(2), "seconds after a correction, not twenty")
        XCTAssertEqual(OnDeviceReaderLearner.trainingPause, .seconds(2), "and not thirty more before it trains")
    }

    /// His 10 Nov export: rolled back on 6 Nov by the old trainer, never tried again.
    func testARolledBackHeadIsDueAtLaunch() {
        var status = OnDeviceReaderLearner.Status()
        status.trainedAt = Date(timeIntervalSince1970: 1_793_900_000)
        status.rolledBack = true
        status.trainedGold = 2_273
        status.trainedSilver = 400
        status.trainer = nil
        XCTAssertTrue(OnDeviceReaderLearner.needsNewTrainer(status))
        XCTAssertTrue(OnDeviceReaderLearner.shouldTrain(status: status, gold: 2_273, silver: 400), "the same data, the new trainer")
        status.trainer = OnDeviceReaderLearner.trainerVersion
        XCTAssertFalse(OnDeviceReaderLearner.shouldTrain(status: status, gold: 2_273, silver: 400))
        XCTAssertTrue(OnDeviceReaderLearner.shouldTrain(status: status, gold: 2_300, silver: 400), "a new correction")
    }

    /// A learner of its own, in a folder of its own: a correction on one
    /// episode is learned from and put to use, without touching what the
    /// app's own learner keeps.
    func testACorrectionIsLearnedAtOnceAndKept() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pass63-learner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let appHeads = LearnedReaderHeads.current?.heads.count
        let learner = OnDeviceReaderLearner(folder: folder, applies: false)
        var status = await learner.trainNow()
        XCTAssertFalse(status.inUse)
        XCTAssertTrue(status.lastDecision.hasPrefix("Nothing to learn from yet"))

        // He locks the host read of the Basic sample as an ad and marks a stretch of talk Not an Ad.
        let sample = BenchSample.basic
        let lines = sample.lines
        let read = sample.regions[2].lines
        func delta(_ action: String, _ range: ClosedRange<Int>, _ kind: String) -> CorrectionDelta {
            CorrectionDelta(date: .now, action: action, start: lines[range.lowerBound].start, end: lines[range.upperBound].end,
                            kind: kind, contains: [kind], predictions: [],
                            grade: CutGrade(recall: 1, precision: 1, labelAgreement: 1, fragments: 1, score: 100),
                            finder: "test", absorbed: 0, key: "\(range.lowerBound)-\(range.upperBound)")
        }
        let request = OnDeviceReaderLearner.GoldRequest(
            episode: "pass63-basic", show: sample.show, title: sample.episode, transcriptOnDisk: false,
            inlineTranscript: try JSONEncoder().encode(lines),
            deltas: [delta("lock", read, "ad"), delta("lock", sample.regions[0].lines, "ad")],
            current: [.init(start: lines[read.lowerBound].start, end: lines[read.upperBound].end, kind: "ad"),
                      .init(start: lines[0].start, end: lines[sample.regions[0].lines.upperBound].end, kind: "ad")])
        await learner.noteCorrections(request, after: .milliseconds(10))
        // Gathered and trained within seconds, with nothing else asked of it.
        var waited = 0.0
        repeat {
            try await Task.sleep(for: .milliseconds(500))
            waited += 0.5
            status = await learner.currentStatus()
        } while status.trainedAt == nil && waited < 240
        let trained = try XCTUnwrap(status.trainedAt, "no training within four minutes of a correction")
        XCTAssertLessThan(Date.now.timeIntervalSince(trained), 300)
        XCTAssertGreaterThan(status.goldExamples, 20)
        XCTAssertEqual(status.trainer, OnDeviceReaderLearner.trainerVersion)
        XCTAssertEqual(status.evidence?.first?.teacher, "your corrections")
        XCTAssertTrue(status.inUse, status.lastDecision)
        XCTAssertTrue(status.lastDecision.hasPrefix("Kept the new reader head"), status.lastDecision)
        XCTAssertEqual(status.rolledBack, false)
        let kept = await learner.keptHeads
        XCTAssertEqual(kept?.count, SentenceTagger.identities().count)
        // Update Learned Reader trains again on the same data and keeps a head.
        let again = await learner.trainNow()
        XCTAssertTrue(again.inUse, again.lastDecision)
        // The app's own learned heads are as they were.
        XCTAssertEqual(LearnedReaderHeads.current?.heads.count, appHeads)
        let idle = await learner.activity
        XCTAssertEqual(idle, .idle)
    }

    func testLearnedHeadsReadBackFromTheirFile() {
        let head = ReaderHead(inputs: 3, mid: 2, outputs: 2, midWeight: [1, 2, 3, 4, 5, 6], midBias: [0.5, -0.5],
                              outWeight: [1, 0, 0, 1], outBias: [0.1, 0.2])
        let data = OnDeviceReaderLearner.encodeHeads([("abc", head)])
        let back = LearnedReaderHeads.decode(data)
        XCTAssertEqual(back?.count, 1)
        XCTAssertEqual(back?.first?.base, "abc")
        XCTAssertEqual(back?.first?.head, head)
        XCTAssertNil(LearnedReaderHeads.decode(Data("nope".utf8)))
    }
}

// MARK: Workstream 6 — Core AI's catalog and what a failed preparation leaves

final class Pass63CoreAITests: XCTestCase {
    private typealias Build = CoreAICompatibility.Build
    /// An iPhone 16 Pro: 7.47 GB, the increased memory limit his builds carry.
    private let budget = CoreAICompatibility.weightBudgetMB(physicalMB: 7_470, increasedLimit: true)

    func testEachRequestedModelIsResolvedForThisIPhone() {
        XCTAssertEqual(budget, 5_674)
        // LFM3 1.7B: its iPhone build is for one chip (the catalog's "architectures"), so the portable build.
        let lfm3 = CoreAICompatibility.resolve(ios: Build(path: "ios", sizeMB: 2_164, architectures: ["h19p"]),
                                               mac: Build(path: "gpu-pipelined/lfm3_1_7b_decode_int8hu_block32_sym_pf64", sizeMB: 2_720),
                                               machine: "iPhone17,1", weightBudgetMB: budget)
        XCTAssertTrue(lfm3.compatible)
        XCTAssertTrue(lfm3.usesMacBuild)
        XCTAssertEqual(lfm3.path, "gpu-pipelined/lfm3_1_7b_decode_int8hu_block32_sym_pf64")
        XCTAssertEqual(lfm3.note?.contains("iPhone 18 Pro"), true)
        // On the phone it was compiled for, the iPhone build.
        let made = CoreAICompatibility.resolve(ios: Build(path: "ios", sizeMB: 2_164, architectures: ["h19p"]),
                                               mac: Build(path: "gpu-pipelined/x", sizeMB: 2_720), machine: "iPhone19,1", weightBudgetMB: budget)
        XCTAssertEqual(made.path, "ios")
        XCTAssertFalse(made.usesMacBuild)
        // Qwen3.5 2B: the same build on both, runs as it is.
        let qwen2 = CoreAICompatibility.resolve(ios: Build(path: "gpu-pipelined/qwen3_5_2b_decode_int8hu_block32_sym", sizeMB: 3_047),
                                                mac: Build(path: "gpu-pipelined/qwen3_5_2b_decode_int8hu_block32_sym", sizeMB: 3_047),
                                                machine: "iPhone17,1", weightBudgetMB: budget)
        XCTAssertTrue(qwen2.compatible)
        XCTAssertNil(qwen2.note)
        // Nanbeige4.2 3B: runs, and he is told its 4.9 GB are close to the limit.
        let nanbeige = CoreAICompatibility.resolve(ios: Build(path: "gpu-pipelined/nanbeige4_2_3b_decode_int8hu_block32_sym_s1", sizeMB: 4_931),
                                                   mac: nil, machine: "iPhone17,1", weightBudgetMB: budget)
        XCTAssertTrue(nanbeige.compatible)
        XCTAssertEqual(nanbeige.note?.contains("4.9 GB"), true)
        // Mistral 7B v0.3: published for the Mac only; that GPU build is used (as Qwen3 4B's is).
        let mistral = CoreAICompatibility.resolve(ios: nil, mac: Build(path: "macos", sizeMB: 4_078), machine: "iPhone17,1", weightBudgetMB: budget)
        XCTAssertTrue(mistral.compatible)
        XCTAssertTrue(mistral.usesMacBuild)
        XCTAssertEqual(mistral.note?.hasPrefix("Published for the Mac only."), true)
        // Qwen3.5 4B, GPT-OSS 20B, Muse Glimmer 30B: more than iOS lets PodSkipper hold.
        for extra in CoreAIExtraModels.list where ["qwen3.5-4b", "gpt-oss-20b", "muse-glimmer-30b"].contains(extra.id) {
            let resolved = CoreAICompatibility.resolve(ios: extra.ios, mac: extra.mac, machine: "iPhone17,1", weightBudgetMB: budget)
            XCTAssertFalse(resolved.compatible, extra.name)
            XCTAssertNil(resolved.path)
            XCTAssertEqual(resolved.reason?.hasPrefix("Too large for this iPhone: "), true, extra.name)
        }
        // …though a 12 GB iPhone could hold Qwen3.5 4B.
        let bigger = CoreAICompatibility.weightBudgetMB(physicalMB: 11_400, increasedLimit: true)
        XCTAssertTrue(CoreAICompatibility.resolve(ios: nil, mac: CoreAIExtraModels.list[0].mac, machine: "iPhone18,1", weightBudgetMB: bigger).compatible)
        // Qwen2.5 1.5B Instruct: an iPhone build of its own.
        let qwen25 = CoreAIExtraModels.list.first { $0.id == "qwen2.5-1.5b-instruct" }!
        XCTAssertTrue(CoreAICompatibility.resolve(ios: qwen25.ios, mac: qwen25.mac, machine: "iPhone17,1", weightBudgetMB: budget).compatible)
        // Nemotron: its iPhone build names another chip in its path; the portable one is used.
        let nemotron = CoreAICompatibility.resolve(ios: Build(path: "ios-h18p/nemotron_3_nano_4b_decode_int8hu", sizeMB: 4_629),
                                                   mac: Build(path: "gpu-pipelined/nemotron_3_nano_4b_decode_int8hu", sizeMB: 4_626),
                                                   machine: "iPhone17,1", weightBudgetMB: budget)
        XCTAssertEqual(nemotron.path, "gpu-pipelined/nemotron_3_nano_4b_decode_int8hu")
        // Built for another chip with no portable build: said so.
        let stuck = CoreAICompatibility.resolve(ios: Build(path: "ios-h18p/x", sizeMB: 900), mac: Build(path: "macos", sizeMB: 900),
                                                machine: "iPhone17,1", weightBudgetMB: budget)
        XCTAssertFalse(stuck.compatible)
        XCTAssertEqual(stuck.reason, "Built only for the iPhone 17 Pro’s chip")
        // Nothing published anywhere.
        XCTAssertEqual(CoreAICompatibility.resolve(ios: nil, mac: nil, machine: "iPhone17,1", weightBudgetMB: budget).reason, "Not published for iPhone")
    }

    func testTheCatalogsChipListIsRead() throws {
        let json = #"{"version":3,"models":[{"id":"lfm3-1.7b","name":"LFM3 1.7B","repo":"r","kind":"chat","variants":{"macos":{"path":"gpu-pipelined/a","sizeMB":2720},"ios":{"path":"ios","engine":"static-shape","sizeMB":2164,"architectures":["h19p"]}}},{"id":"x","variants":{"ios":{"path":"int8"}}}]}"#
        let details = try JSONDecoder().decode(CoreAICatalogDetails.self, from: Data(json.utf8))
        XCTAssertEqual(details.variant("lfm3-1.7b", "ios")?.architectures, ["h19p"])
        XCTAssertEqual(details.variant("lfm3-1.7b", "ios")?.engine, "static-shape")
        XCTAssertNil(details.variant("x", "ios")?.architectures)
        XCTAssertNil(details.variant("missing", "ios"))
        XCTAssertEqual(CoreAICompatibility.foreignChip(.init(path: "ios", sizeMB: 1, architectures: ["h19p"]), machine: "iPhone17,1"), "h19p")
        XCTAssertNil(CoreAICompatibility.foreignChip(.init(path: "ios", sizeMB: 1, architectures: ["h17p", "h19p"]), machine: "iPhone17,1"))
        XCTAssertNil(CoreAICompatibility.foreignChip(.init(path: "gpu-pipelined/a", sizeMB: 1), machine: "iPhone17,1"))
    }

    func testExtraModelsArePinnedAndTheUnpublishedOnesNamed() {
        XCTAssertEqual(Set(CoreAIExtraModels.list.map(\.id)), ["qwen3.5-4b", "qwen2.5-1.5b-instruct", "gpt-oss-20b", "muse-glimmer-30b"])
        for model in CoreAIExtraModels.list {
            XCTAssertEqual(model.revision.count, 40, model.name)
            XCTAssertEqual(model.repo.split(separator: "/").count, 2)
            XCTAssertNotNil(model.mac ?? model.ios)
        }
        XCTAssertEqual(CoreAIExtraModels.notPublished, ["Mixtral", "Qwen3.5 4B Instruct"])
        XCTAssertTrue(CoreAIExtraModels.notPublishedNote.contains("Mixtral or Qwen3.5 4B Instruct"))
    }

    /// Core AI's 12–25-line stretches: "lines 0–13: HOST_READ_AD" for a 14-line stretch.
    func testAShortStretchRestatedWholeIsNoCut() {
        func part(_ a: Int, _ b: Int) -> JudgePrompt.RawPart {
            JudgePrompt.RawPart(firstLine: a, lastLine: b, firstWords: "", lastWords: "", label: .hostReadAd,
                                sponsor: "", funny: false, confidence: 80, why: "")
        }
        // Granite 4.0-H 1B on Basic, Youtu-LLM 2B ("0–15" of 16).
        XCTAssertTrue(JudgePrompt.shifted([part(0, 13)], window: 79..<93).isEmpty)
        XCTAssertTrue(JudgePrompt.shifted([part(0, 15)], window: 77..<93).isEmpty)
        // Qwen3 4B's located read in the same kind of stretch is kept, on the episode's own line numbers.
        XCTAssertEqual(JudgePrompt.shifted([part(21, 25)], window: 67..<93).map(\.firstLine), [88])
        XCTAssertEqual(JudgePrompt.shifted([part(0, 10)], window: 79..<93).map(\.lastLine), [89])
    }

    func testLeftoverWorkFoldersAreRecognisedAndRemoved() throws {
        // His 10 Nov phone: tmp/NSIRD_PodSkipper_0eS9di, 3.6 GB, "No rule recognises this name".
        XCTAssertEqual(ModelStorage.classify(name: "NSIRD_PodSkipper_0eS9di", area: "tmp"), .leftoverWork)
        XCTAssertEqual(ModelStorage.classify(name: "NSIRD_PodSkipper_0eS9di", area: "Caches"), .unknown)
        XCTAssertTrue(ModelStorage.ScratchEntry.Kind.leftoverWork.safeByKind)
        XCTAssertEqual(StorageGuard.preparationBytes(modelBytes: 1_702_000_000), 3_744_400_000)

        let root = FileManager.default.temporaryDirectory.appending(path: "pass63-storage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = ModelStorage.Locations(mlxRoot: root.appending(path: "mlx"), coreAIRoot: root.appending(path: "coreai"),
                                               caches: root.appending(path: "Caches"), temporary: root.appending(path: "tmp"))
        for folder in [locations.mlxRoot, locations.coreAIRoot, locations.caches, locations.temporary] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        func make(_ name: String, written: Date) throws -> URL {
            let folder = locations.temporary.appending(path: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: "model.part")
            try Data(count: 4_096).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: file.path)
            try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: folder.path)
            return folder
        }
        let launch = Date()
        let old = try make("NSIRD_PodSkipper_old111", written: launch.addingTimeInterval(-3_600))
        let fresh = try make("NSIRD_PodSkipper_new222", written: launch.addingTimeInterval(30))
        let other = try make("somebody-elses-folder", written: launch.addingTimeInterval(-3_600))
        let log = root.appending(path: "cleanups.json")
        // At launch: what an earlier launch left goes; what is being written now stays; nothing else is touched.
        let freed = ModelStorage.removeLeftoverWork(at: locations, before: launch, context: "test", log: log)
        XCTAssertGreaterThan(freed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        let logged = CleanupLog.load(from: log)
        XCTAssertEqual(logged.first?.items.first?.name, "NSIRD_PodSkipper_old111")
        XCTAssertEqual(logged.first?.items.first?.kind, "Leftover work folders")
        // After a preparation that failed: only what it wrote since it began.
        let earlier = try make("NSIRD_PodSkipper_before", written: launch.addingTimeInterval(-600))
        let removed = ModelStorage.removeLeftoverWork(at: locations, before: launch.addingTimeInterval(60), since: launch,
                                                      context: "test", log: log)
        XCTAssertGreaterThan(removed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: earlier.path))
        // Nothing left to do: nothing logged.
        XCTAssertEqual(ModelStorage.removeLeftoverWork(at: locations, before: launch.addingTimeInterval(-7_200), context: "test", log: log), 0)
        XCTAssertEqual(CleanupLog.load(from: log).count, 2)
    }
}

// MARK: Lab check, asked for — learning from his own corrections

final class Pass63LabTests: XCTestCase {
    private struct Corrected: Decodable {
        struct Cut: Decodable { var start: Double; var end: Double; var kind: String }
        var episode: String
        var show: String
        var title: String
        var transcript: [TimedLine]
        var corrections: [CorrectionDelta]
        var current: [Cut]
    }

    /// Mac only, asked for (`learner` in `build/lab-tests.txt`; several
    /// minutes in the unoptimised simulator build): the corrections of his
    /// 10 Nov Results export (`build/p63/gold-requests.json`, git-ignored,
    /// from `Tools/ReaderData/gold_requests.py`) through a learner of its own, as
    /// the app's gathers and trains. The trust step keeps a head; it is
    /// written to `build/p63/UserTaggerHead.bin`, for `LAB_HEADS`
    /// (lab-segments) to judge on episodes it never saw.
    func testLearningFromHisCorrectionsKeepsAHead() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let asked = (try? String(contentsOf: root.appending(path: "build/lab-tests.txt"), encoding: .utf8)) ?? ""
        guard asked.contains("learner") else { throw XCTSkip("Lab check not asked for (build/lab-tests.txt)") }
        let url = root.appending(path: "build/p63/gold-requests.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("No corrections at \(url.path)") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let episodes = try decoder.decode([Corrected].self, from: data)
        let folder = FileManager.default.temporaryDirectory.appending(path: "pass63-lab-learner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let learner = OnDeviceReaderLearner(folder: folder, applies: false)
        let requests = try episodes.map { e in
            OnDeviceReaderLearner.GoldRequest(
                episode: e.episode, show: e.show, title: e.title, transcriptOnDisk: false,
                inlineTranscript: try JSONEncoder().encode(e.transcript), deltas: e.corrections,
                current: e.current.map { .init(start: $0.start, end: $0.end, kind: $0.kind) })
        }
        let started = Date()
        await learner.rebuild(gold: requests, silver: [])
        let gathered = Date().timeIntervalSince(started)
        let status = await learner.trainNow()
        print("LEARNER-LAB \(episodes.count) episodes, \(episodes.reduce(0) { $0 + $1.corrections.count }) corrections · gold \(status.goldExamples) · gathered in \(Int(gathered)) s, trained in \(Int(Date().timeIntervalSince(started) - gathered)) s · in use \(status.inUse) · \(status.lastDecision)")
        for item in status.evidence ?? [] { print("LEARNER-LAB   \(item.title.prefix(50)): \(ReaderLearningView.counts(item.sentences))") }
        XCTAssertGreaterThan(status.goldExamples, 1_000)
        XCTAssertEqual(status.trainer, OnDeviceReaderLearner.trainerVersion)
        XCTAssertTrue(status.inUse, status.lastDecision)
        XCTAssertEqual(status.rolledBack, false)
        let kept = await learner.keptHeads
        let heads = try XCTUnwrap(kept)
        XCTAssertEqual(heads.count, SentenceTagger.identities().count)
        try OnDeviceReaderLearner.encodeHeads(heads).write(to: root.appending(path: "build/p63/UserTaggerHead.bin"))
    }
}
