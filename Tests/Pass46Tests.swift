import XCTest
@testable import PodSkipper

/// Pass 46: his 23 Oct export (3df998e). "Reaching Out" in his library twice
/// (one audio file) cut as half an hour of plugs; a plug run swallowing a
/// paid spot; the kinds of #691's Tulsa King spot; the reader learning from
/// its own finds.
final class Pass46RepeatTests: XCTestCase {
    private func across(_ a: Double, _ b: Double) -> AdPrints.Produced {
        AdPrints.Produced(start: a, end: b, acrossEpisodes: true)
    }

    func testAnEpisodeThatSharesItsProgramGivesNoAcrossEpisodeEvidence() {
        // The hour fingerprinted against its own copy (this Mac, the download
        // of "Reaching Out"): runs of 12–757 s, broken only at pauses.
        let runs = [across(0.3, 299), across(302, 1139), across(1141, 1172), across(1174, 1345),
                    across(1955, 2135), across(2194, 2211), across(3093, 3850)]
        let within = AdPrints.Produced(start: 40, end: 70, acrossEpisodes: false)
        let negative = AdPrints.Produced(start: 600, end: 640, acrossEpisodes: true, negative: true)
        let mine = AdPrints.Produced(start: 3700, end: 3740, acrossEpisodes: true, known: "outro",
                                     evidenceProvenance: AdPrints.Library.Provenance.userCorrection.rawValue)
        let kept = AdPrints.detectionEvidence(runs + [within, negative, mine], duration: 3_886)
        XCTAssertEqual(kept.count, 3)
        XCTAssertTrue(kept.contains(within), "a repeat within the episode still counts")
        XCTAssertTrue(kept.contains { $0.negative }, "his Not an Ad still protects")
        XCTAssertTrue(kept.contains { $0.known == "outro" }, "what he confirmed still counts")
    }

    func testAnOrdinaryEpisodeKeepsItsThemesAndSpots() {
        // A theme, a closing song, three spots from another episode: under
        // ten minutes of an hour.
        let runs = [across(0, 45), across(1800, 1860), across(1862, 1920), across(1925, 1985), across(3500, 3826)]
        XCTAssertEqual(AdPrints.detectionEvidence(runs, duration: 3_900).count, runs.count)
    }

    func testOneRunLongerThanAnyRecordingIsNotOne() {
        let runs = [across(0, 45), across(1200, 1900)]
        let kept = AdPrints.detectionEvidence(runs, duration: 7_200)
        XCTAssertEqual(kept.map(\.start), [0])
    }

    func testNoCutIsLongerThanItsKindCanBe() {
        var log: [String] = []
        let f = { (kind: SegmentKind, a: Double, b: Double) in
            SegmentFinding(kind: kind, start: a, end: b, sponsor: "", confidence: 99, startConfidence: 90,
                           endConfidence: 90, firstSentence: 0, lastSentence: 0)
        }
        // His longest genuine ones: a 463-s break, 460 s of plugs, a 326-s closing song.
        let real = [f(.ad, 1818, 2281), f(.selfPromo, 3440, 3900), f(.outro, 4466, 4792)]
        let runaway = [f(.selfPromo, 0, 1862), f(.selfPromo, 2269, 3711), f(.intro, 0, 400)]
        let out = SegmentDetector.plausible(real + runaway, log: &log)
        XCTAssertEqual(out.map(\.start), real.map(\.start))
        XCTAssertEqual(log.count, 3)
    }
}

final class Pass46PlugTests: XCTestCase {
    private func s(_ text: String, _ a: Double, _ b: Double) -> Sentence { Sentence(text: text, start: a, end: b) }

    /// "Reaching Out" as downloaded on this Mac: Ira's Life Partners plug,
    /// IXL's spot, the content warning, then the show.
    private var opening: [Sentence] {
        [s("Go to thisAmericanlife.org slash life partners, and use the promo code video.", 62, 71),
         s("The promo code is video.", 72, 74),
         s("That link is also in the show notes.", 74, 77),
         s("Okay, here's this week's show.", 77, 81),
         s("This message comes from IXL.", 81, 83),
         s("IXL provides personalized learning for teachers.", 83, 90),
         s("Learn more at ixl.com slash NPR.", 90, 96),
         s("From WBEZ Chicago, it's This American Life.", 106, 109),
         s("I recently heard this podcast that was so exciting to hear.", 110, 119),
         s("And I want to play you some of that show today.", 127, 130),
         s("It's by somebody who I had never heard of before, and the series is called Reaching Out.", 130, 138),
         s("And as you'll hear, he started recording nearly all of his conversations.", 138, 155)]
    }

    private func finding(_ kind: SegmentKind, _ first: Int, _ last: Int, in sentences: [Sentence]) -> SegmentFinding {
        SegmentFinding(kind: kind, start: sentences[first].start, end: sentences[last].end, sponsor: "",
                       confidence: 93, startConfidence: 85, endConfidence: 56, firstSentence: first, lastSentence: last)
    }

    func testAPlugRunStopsBeforeLinesTheReaderIsSureAreTheShow() {
        let sentences = opening
        var log: [String] = []
        let sure = sentences.indices.map { $0 >= 7 }
        let out = SegmentDetector.plugs([finding(.selfPromo, 0, 3, in: sentences)], sentences: sentences,
                                        sureShow: sure, log: &log)
        XCTAssertLessThanOrEqual(out.map(\.end).max() ?? 0, 96, "nothing past the IXL spot")
    }

    func testAPaidSpotInsideAPlugRunStaysAnAd() {
        let sentences = opening
        var log: [String] = []
        let found = [finding(.selfPromo, 0, 3, in: sentences), finding(.ad, 4, 6, in: sentences)]
        let out = SegmentDetector.plugs(found, sentences: sentences, sureShow: sentences.indices.map { $0 >= 7 }, log: &log)
        let ad = out.first { $0.kind == .ad }
        XCTAssertEqual(ad?.start, 81)
        XCTAssertFalse(out.contains { $0.kind == .selfPromo && $0.start < 90 && $0.end > 84 }, "the plug goes round it")
    }

    func testAShortSpotTakesItsHandOffAndAddress() {
        let sentences = opening
        var log: [String] = []
        // The Reader found 83–90 as an ad and the hand-off as part of the plug.
        let found = [finding(.selfPromo, 0, 4, in: sentences), finding(.ad, 5, 5, in: sentences)]
        let out = SegmentDetector.completeShortReads(found, sentences: sentences,
                                                     sureShow: sentences.indices.map { $0 >= 7 }, log: &log)
        let ad = out.first { $0.kind == .ad }
        XCTAssertEqual(ad?.start, 81)
        XCTAssertEqual(ad?.end, 96)
        XCTAssertEqual(out.first { $0.kind == .selfPromo }?.end, 81, "the plug gives up the hand-off")
    }
}

final class Pass46KindTests: XCTestCase {
    private func line(_ text: String, _ a: Double, _ b: Double) -> TimedLine { TimedLine(text: text, start: a, end: b) }
    private func cut(_ a: Double, _ b: Double, _ kind: SegmentKind, sponsor: String = "", confidence: Int = 80) -> DetectedSegment {
        DetectedSegment(start: a, end: b, kind: kind, sponsor: sponsor, confidence: confidence)
    }

    /// #691 as transcribed on his phone.
    private var lines: [TimedLine] {
        [line("The king returns.", 0, 2),
         line("Sylvester Stallone returns as my boss Dwight Manfredi in Tulsa King.", 2, 8),
         line("The Paramount Plus hit series widely considered as one of the best gangster TV shows ever.", 8, 16),
         line("Tulsa King.", 39, 40),
         line("New season now streaming only on Paramount+.", 40, 45),
         line("I wanna let you guys know that my new special, I'm doing fine, is out now on Netflix.", 46, 52),
         line("Um, and thank you all for the support.", 52, 54),
         line("Tulsa King, new season now streaming only on Paramount+.", 3643, 3649)]
    }

    func testTheModelsIntroAndPromoForAStreamingSpotAreAds() {
        let reader = [cut(0, 45, .ad, confidence: 72), cut(3603, 3649, .ad, confidence: 93)]
        var notes: [String] = []
        let out = ModelCutCheck.reconcileKinds([cut(0, 44, .intro), cut(3604, 3648, .crossPromo, sponsor: "Tulsa King")],
                                               readerCuts: reader, lines: lines, notes: &notes)
        XCTAssertEqual(out.map(\.kind), [.ad, .ad])
    }

    func testAnOpeningThemeTheReaderDidNotCallAnAdStaysTheIntro() {
        let theme = [line("From WBEZ Chicago, it's This American Life.", 0, 4)]
        var notes: [String] = []
        let out = ModelCutCheck.reconcileKinds([cut(0, 4, .intro)], readerCuts: [cut(0, 4, .intro, confidence: 90)],
                                               lines: theme, notes: &notes)
        XCTAssertEqual(out.map(\.kind), [.intro])
    }

    func testAPromoForAPodcastStaysAPromo() {
        let promo = [line("Listen to Morbid wherever you get your podcasts.", 10, 15),
                     line("New episodes every Monday, now streaming on Wondery+.", 15, 20)]
        var notes: [String] = []
        let asPromo = ModelCutCheck.reconcileKinds([cut(10, 20, .crossPromo)], readerCuts: [cut(10, 20, .ad)],
                                                   lines: promo, notes: &notes)
        XCTAssertEqual(asPromo.map(\.kind), [.crossPromo])
        let asAd = ModelCutCheck.reconcileKinds([cut(10, 20, .ad)], readerCuts: [cut(10, 20, .crossPromo)],
                                                lines: promo, notes: &notes)
        XCTAssertEqual(asAd.map(\.kind), [.crossPromo])
    }

    func testTheHostsOwnPlugAfterTheSpotIsHisPlug() {
        var notes: [String] = []
        let out = ModelCutCheck.reconcileKinds([cut(0, 54, .ad, confidence: 72)], readerCuts: [], lines: lines, notes: &notes)
        XCTAssertEqual(out.map(\.kind), [.ad, .selfPromo])
        XCTAssertEqual(out.first?.end, 45, "the ad ends with its last line")
        XCTAssertEqual(out.last?.start, 46)
        XCTAssertEqual(out.last?.end, 54)
    }

    func testAnAdNamingItsSponsorWithOurIsStillTheAd() {
        let shopify = [line("We use Shopify for our merch store.", 1950, 1955),
                       line("That's shopify.com slash Theo.", 1995, 2003)]
        var notes: [String] = []
        let out = ModelCutCheck.reconcileKinds([cut(1941, 2004, .ad, sponsor: "Shopify")], readerCuts: [],
                                               lines: shopify, notes: &notes)
        XCTAssertEqual(out.map(\.kind), [.ad])
    }
}

final class Pass46LearnerTests: XCTestCase {
    private func sentences(_ count: Int) -> [Sentence] {
        (0..<count).map { Sentence(text: "line \($0)", start: Double($0) * 10, end: Double($0) * 10 + 9) }
    }

    func testAModelsOwnFindIsWhatItProposedAndTheCheckKept() {
        // Proposed 30–60; the check kept 20–60 (the Reader's lead-in) and
        // added 100–150 from the Reader alone.
        let mine = OnDeviceReaderLearner.independent(proposed: [(30, 60, .ad)],
                                                     kept: [(20, 60, .ad), (100, 150, .ad)])
        XCTAssertEqual(mine.count, 1)
        XCTAssertEqual(mine.first?.start, 30)
        XCTAssertEqual(mine.first?.end, 60)
    }

    func testTwoSavesThatOnlyKeptTheReadersStretchTeachNothing() {
        // #691: the Tulsa King spot was Reader-only in both saves.
        let s = sentences(60)
        let qwen = OnDeviceReaderLearner.Teacher(
            family: "qwen", cuts: OnDeviceReaderLearner.independent(proposed: [(300, 360, .ad)], kept: [(0, 45, .ad), (300, 360, .ad)]),
            read: nil)
        let minicpm = OnDeviceReaderLearner.Teacher(
            family: "minicpm", cuts: OnDeviceReaderLearner.independent(proposed: [], kept: [(0, 45, .ad)]), read: nil)
        let labels = OnDeviceReaderLearner.agreementLabels(sentences: s, teachers: [qwen, minicpm], inserted: [],
                                                           claimed: [0...45, 300...360])
        XCTAssertTrue((0...4).allSatisfy { labels[$0] == nil }, "the spot only the Reader found is taught neither way")
        XCTAssertTrue((30...35).allSatisfy { labels[$0] == nil }, "one family alone teaches nothing")
    }

    func testOneFamilyIsOneVote() {
        let s = sentences(20)
        let a = OnDeviceReaderLearner.Teacher(family: "qwen", cuts: [(0, 50, .intro)], read: nil)
        let b = OnDeviceReaderLearner.Teacher(family: "qwen", cuts: [(0, 50, .intro)], read: nil)
        let c = OnDeviceReaderLearner.Teacher(family: "minicpm", cuts: [(0, 50, .ad)], read: nil)
        let labels = OnDeviceReaderLearner.agreementLabels(sentences: s, teachers: [a, b, c], inserted: [])
        XCTAssertNil(labels[2], "qwen twice and minicpm once is one against one: no majority")
        let d = OnDeviceReaderLearner.Teacher(family: "minicpm", cuts: [(0, 50, .intro)], read: nil)
        XCTAssertEqual(OnDeviceReaderLearner.agreementLabels(sentences: s, teachers: [a, d], inserted: [])[2]?.label, 4)
    }

    func testNothingAnyoneMarkedIsTaughtAsTheShow() {
        let s = sentences(60)
        let a = OnDeviceReaderLearner.Teacher(family: "qwen", cuts: [(300, 360, .ad)], read: nil)
        let b = OnDeviceReaderLearner.Teacher(family: "minicpm", cuts: [(300, 360, .ad)], read: nil)
        let free = OnDeviceReaderLearner.agreementLabels(sentences: s, teachers: [a, b], inserted: [])
        XCTAssertEqual(free[1]?.label, 0)
        let claimed = OnDeviceReaderLearner.agreementLabels(sentences: s, teachers: [a, b], inserted: [], claimed: [0...45])
        XCTAssertNil(claimed[1], "the Reader's stretch is not the show just because models missed it")
        XCTAssertEqual(claimed[32]?.label, 1)
    }

    func testOtherTeachersVoteWithTheirOwnFinds() {
        func stored(_ a: Double, _ b: Double) -> ModelFinder.StoredCut {
            ModelFinder.StoredCut(start: a, end: b, kind: "ad", sponsor: "", confidence: 80, delivery: "",
                                  comedyBit: false, insertedAtDownload: false, evidence: "")
        }
        let reader = stored(0, 45), own = stored(300, 360)
        var run = ModelFinder.Run(finder: "coreAI")
        run.modelName = "MiniCPM5 2B"
        let attempt = FinderAttempt(date: .now, guid: "g", show: "", episode: "", method: "Core AI · MiniCPM5 2B", run: run,
                                    seconds: 1, audioSeconds: 1, foreground: true, thermalAtStart: "", thermalAtEnd: "",
                                    build: "", readerCuts: [reader], proposedCuts: [own], parts: [],
                                    savedCuts: [reader, own], answerSample: "")
        let teachers = ProcessingPipeline.otherTeachers([attempt])
        XCTAssertEqual(teachers.first?.cuts.map(\.start), [300])
        XCTAssertEqual(ProcessingPipeline.claimedStretches([attempt]).count, 3)
    }
}

/// Pass 46: his 23 Oct export (3df998e). Every model attempt on a labelled
/// episode checked again with the episode's Reader, with and without
/// `ModelCutCheck.reconcileKinds`, into build/p46/replay.json for
/// `phone_eval.py --cuts`. Skips without the export.
final class Pass46ReplayTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private static func segments(_ any: Any?) -> [DetectedSegment] {
        ((any as? [[String: Any]]) ?? []).map { d in
            DetectedSegment(start: d["start"] as? Double ?? 0, end: d["end"] as? Double ?? 0,
                            kind: SegmentKind(rawValue: d["kind"] as? String ?? "") ?? .ad,
                            sponsor: d["sponsor"] as? String ?? "", confidence: d["confidence"] as? Int ?? 0,
                            evidence: (d["evidence"] as? String ?? "").components(separatedBy: " · "),
                            insertedAtDownload: d["insertedAtDownload"] as? Bool ?? false)
        }
    }

    func testReplayKinds() throws {
        guard let data = try? Data(contentsOf: Self.root.appendingPathComponent("build/phone-1023/results.json")) else {
            throw XCTSkip("export not on this Mac")
        }
        let labelled = Set(try FileManager.default.contentsOfDirectory(
            atPath: Self.root.appendingPathComponent("Tools/DetectionLab/phone-labels").path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var out: [String: [String: [[Any]]]] = [:]
        defer { ModelCutCheck.reconcilesKinds = true }
        for episode in try XCTUnwrap(root["episodes"] as? [[String: Any]]) {
            guard let guid = episode["guid"] as? String, labelled.contains(guid) else { continue }
            let lines = try JSONDecoder().decode([TimedLine].self,
                                                 from: JSONSerialization.data(withJSONObject: episode["transcript"] ?? []))
            let duration = max(episode["duration"] as? Double ?? 0, lines.last?.end ?? 0)
            var seen = Set<String>()
            for attempt in ((episode["attempts"] as? [[String: Any]]) ?? []).sorted(by: {
                ($0["date"] as? String ?? "") > ($1["date"] as? String ?? "") }) {
                let method = attempt["method"] as? String ?? ""
                let proposed = Self.segments(attempt["proposedCuts"])
                guard !proposed.isEmpty, !method.hasPrefix("PodSkipper"), method != "Apple Intelligence",
                      seen.insert(method).inserted else { continue }
                // The Reader as that attempt had it.
                let reader = Self.segments(attempt["readerCuts"])
                for (name, on) in [("kinds", true), ("before", false)] {
                    ModelCutCheck.reconcilesKinds = on
                    let checked = ModelCutCheck.verify(proposed, lines: lines, readerCuts: reader, evidence: [], keeps: [],
                                                       duration: duration)
                    out[guid, default: [:]]["\(method) (\(name))"] = checked.cuts.map { [$0.start, $0.end, $0.kind.rawValue] }
                }
            }
        }
        let dir = Self.root.appendingPathComponent("build/p46")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]).write(to: dir.appendingPathComponent("replay.json"))
        XCTAssertFalse(out.isEmpty)
    }
}
