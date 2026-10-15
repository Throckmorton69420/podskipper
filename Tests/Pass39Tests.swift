import XCTest
@testable import PodSkipper

/// Pass 39: the reader fills what the model's cuts leave out instead of
/// replacing them (his 15 Oct three-episode comparison).
final class Pass39Tests: XCTestCase {

    private func line(_ text: String, _ start: Double, _ end: Double) -> TimedLine {
        TimedLine(text: text, start: start, end: end)
    }

    private func cut(_ start: Double, _ end: Double, _ kind: SegmentKind = .ad, sponsor: String = "",
                     confidence: Int = 80) -> DetectedSegment {
        DetectedSegment(start: start, end: end, kind: kind, sponsor: sponsor, confidence: confidence)
    }

    /// We Might Be Drunk: Rocket Money, Hims and Underdog back to back
    /// inside one sure reader stretch that starts a little early and runs
    /// ten seconds into the show.
    private var breakLines: [TimedLine] {
        [line("God, what is this?", 2150, 2155),
         line("Thanks to Rocket Money for sponsoring the show.", 2155, 2157),
         line("Join at rocketmoney.com slash drunk.", 2205, 2218),
         line("Hey folks, Hims, the best nights happen in the moment.", 2220, 2225),
         line("Visit hims.com slash drunk, restrictions apply.", 2284, 2294),
         line("Hey, hey, folks, here we are.", 2297, 2300),
         line("I got to tell you about Underdog.", 2301, 2303),
         line("Download Underdog to play, terms apply.", 2367, 2375),
         line("Hey! What's shaking? Good to see you, mate.", 2376, 2385)]
    }

    func testThreeSponsorsInsideOneReaderStretchStaySeparate() {
        let model = [cut(2155, 2218.8, sponsor: "rocketmoney"),
                     cut(2220.5, 2294.9, sponsor: "hims"),
                     cut(2300, 2375.7, .crossPromo, sponsor: "underdog")]
        let reader = cut(2150, 2385.6, sponsor: "rocketmoney", confidence: 98)
        let out = ModelCutCheck.verify(model, lines: breakLines, readerCuts: [reader], evidence: [], keeps: [],
                                       duration: 5_147)
        XCTAssertEqual(out.cuts.map(\.sponsor), ["rocketmoney", "hims", "underdog"])
        XCTAssertEqual(out.cuts.map(\.kind), [.ad, .ad, .crossPromo])
        // Holes between reads go to the next read; nothing overlaps.
        XCTAssertEqual(out.cuts[1].start, 2218.8, accuracy: 0.01)
        XCTAssertEqual(out.cuts[2].start, 2294.9, accuracy: 0.01)
        for (a, b) in zip(out.cuts, out.cuts.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start + 0.01) }
        // The reader's early start is the lead-in; its overrun into the show is not added.
        XCTAssertEqual(out.cuts[0].start, 2150, accuracy: 0.01)
        XCTAssertEqual(out.cuts[2].end, 2375.7, accuracy: 0.01)
        XCTAssertFalse(out.notes.contains { $0.hasPrefix("kept the reader's") })
    }

    func testTheReaderStretchStandsWhereTheModelMostlySaidNothing() {
        let model = [cut(2155, 2190, sponsor: "rocketmoney")]
        let reader = cut(2150, 2385.6, sponsor: "rocketmoney", confidence: 98)
        let out = ModelCutCheck.verify(model, lines: breakLines, readerCuts: [reader], evidence: [], keeps: [],
                                       duration: 5_147)
        let covered = SkipJoin.joined(out.cuts.map { $0.start...$0.end }, maxGap: 0.01)
        XCTAssertEqual(covered.count, 1)
        XCTAssertEqual(covered[0].lowerBound, 2150, accuracy: 0.01)
        XCTAssertEqual(covered[0].upperBound, 2385.6, accuracy: 0.01)
        XCTAssertTrue(out.cuts.contains { $0.start == 2155 && $0.sponsor == "rocketmoney" }, "the model's own read keeps its edges")
        for (a, b) in zip(out.cuts, out.cuts.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start + 0.01) }
    }

    func testAJokeAdTheModelNamedIsNotFilledIn() {
        let model = [cut(2155, 2218.8, sponsor: "rocketmoney"), cut(2300, 2375.7, sponsor: "underdog")]
        let reader = cut(2150, 2385.6, sponsor: "rocketmoney", confidence: 98)
        let out = ModelCutCheck.verify(model, lines: breakLines, readerCuts: [reader], evidence: [],
                                       keeps: [2225...2290], duration: 5_147)
        XCTAssertFalse(out.cuts.contains { $0.start < 2290 && $0.end > 2225 })
    }

    func testOneReadAnsweredInPiecesIsCheckedAsOne() {
        let lines = [line("Learn more at cosentix.com.", 7700, 7705), line("Ask about Cosentix.", 7706, 7711)]
        let model = [cut(7700.5, 7705.5, sponsor: "Cosentix"), cut(7706.9, 7711.5, sponsor: "Cosentix")]
        let out = ModelCutCheck.verify(model, lines: lines, readerCuts: [], evidence: [], keeps: [], duration: 7_740)
        XCTAssertEqual(out.cuts.count, 1)
        XCTAssertEqual(out.cuts[0].start, 7700.5, accuracy: 0.01)
        XCTAssertEqual(out.cuts[0].end, 7711.5, accuracy: 0.01)
    }

    func testCrossKindOverlapSplitsTheOuterCut() {
        let out = ModelCutCheck.separate([cut(0, 100), cut(40, 60, .crossPromo)])
        XCTAssertEqual(out.map(\.start), [0, 40, 60])
        XCTAssertEqual(out.map(\.end), [40, 60, 100])
    }

    func testPlugRoundCueForDates() {
        XCTAssertTrue(ModelFinder.plugRound("Just plug some dates, Mark."))
        XCTAssertTrue(ModelFinder.plugRound("Plug your dates."))
        XCTAssertFalse(ModelFinder.plugRound("He dated a plumber."))
    }

    // MARK: Prompt prefix and cooling

    func testSharedPrefixIsWholeChunksAndLeavesEachPartItsOwnTokens() {
        let rules = Array(0..<600)
        let a = rules + [900, 901, 902], b = rules + [950, 951]
        // Whole 256-token chunks only, so parts are chunked as whole prompts are.
        XCTAssertEqual(PromptPrefixCache.sharedPrefix([a, b])?.count, 512)
        XCTAssertEqual(PromptPrefixCache.sharedPrefix([Array(0..<512), Array(0..<512) + [1]])?.count, 256,
                       "a part that is only the prefix keeps one token of its own")
        XCTAssertNil(PromptPrefixCache.sharedPrefix([a]), "one part has nothing to share")
        XCTAssertNil(PromptPrefixCache.sharedPrefix([Array(0..<100) + [5], Array(0..<100) + [6]]), "too short to be worth it")
    }

    func testCoolingWaitIsReportedWithItsClockAndEnds() async throws {
        ThermalPacing.stateOverride = .serious
        defer { ThermalPacing.stateOverride = nil }
        var seen: [String] = []
        try await ThermalPacing.beforePart(status: { _ in }, sleep: { _ in
            seen.append(ThermalPacing.waitLine() ?? "none")
            if seen.count >= 2 { ThermalPacing.stateOverride = .nominal }
        })
        XCTAssertTrue(seen.first?.hasPrefix("Waiting for iPhone to cool · 0:00 so far · carries on in") == true, seen.first ?? "")
        XCTAssertNil(ThermalPacing.wait, "no wait once the part may start")
        XCTAssertNil(ThermalPacing.waitLine())
    }

    func testTooHotSaysItCarriesOnWhenItCools() async throws {
        ThermalPacing.stateOverride = .critical
        defer { ThermalPacing.stateOverride = nil }
        var seen: [String] = []
        try await ThermalPacing.beforePart(status: { _ in }, sleep: { _ in
            seen.append(ThermalPacing.waitLine() ?? "none")
            ThermalPacing.stateOverride = .nominal
        })
        XCTAssertTrue(seen.first?.hasPrefix("Paused: iPhone is too hot") == true, seen.first ?? "")
        XCTAssertTrue(seen.first?.hasSuffix("carries on when it cools") == true)
    }

    // MARK: Video from Apple's episode page

    func testApplePageVideoIsReadFromItsListOfFiles() {
        let html = #"<script>{"mediaEnclosures":[{"streamUrl":"https://host.example/ep.mp3","priceType":"STDQ","mediaKinds":["audio"]},{"streamUrl":"https://video.host.example/main.m3u8?isSgai=true&a=1","priceType":"STDQ","mediaKinds":["video"],"tokenRequirements":null},{"streamUrl":"https://play.itunes.apple.com/hls/playlist.m3u8?a=1","priceType":"PSUB","mediaKinds":["audio"]}],"currentMediaEnclosure":{}}</script>"#
        let page = VideoSourceResolver.parsePage(html)
        XCTAssertEqual(page.enclosures.count, 3)
        let candidates = VideoSourceResolver.videoCandidates(page)
        XCTAssertEqual(candidates.map(\.url.host), ["video.host.example"])
        XCTAssertFalse(page.subscriberVideoOnly)
    }

    func testSubscriberOnlyVideoIsSaidSo() {
        let html = #"{"mediaEnclosures":[{"streamUrl":"https://play.itunes.apple.com/v.m3u8","priceType":"PSUB","mediaKinds":["video"]}]}"#
        let page = VideoSourceResolver.parsePage(html)
        XCTAssertTrue(VideoSourceResolver.videoCandidates(page).isEmpty)
        XCTAssertTrue(page.subscriberVideoOnly)
    }

    func testMasterPlaylistIsMeasuredOnAVariantWithAPicture() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=130716,CODECS="mp4a.40.2"
        /audio.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1340122,RESOLUTION=640x360,CODECS="avc1.640029,mp4a.40.2"
        /360p.m3u8?x=1
        """
        let url = VideoSourceResolver.videoVariant(in: master, base: URL(string: "https://cdn.example/a/main.m3u8")!)
        XCTAssertEqual(url?.absoluteString, "https://cdn.example/360p.m3u8?x=1")
        XCTAssertTrue(VideoSourceResolver.encrypted("#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://x\"\n"))
        XCTAssertFalse(VideoSourceResolver.encrypted("#EXTM3U\n#EXTINF:6,\nseg.mp4\n"))
        XCTAssertEqual(VideoSourceResolver.streamLength("#EXTINF:6.0,\na\n#EXTINF:4.5,\nb\n"), 10.5)
    }

    func testANewEpisodeIsLookedAtAgainWithinHoursEvenWithAYouTubeMatch() {
        let now = Date()
        XCTAssertEqual(VideoSourceResolver.recheckAfter(published: now.addingTimeInterval(-86_400), found: false, now: now), 3 * 3_600)
        XCTAssertEqual(VideoSourceResolver.recheckAfter(published: now.addingTimeInterval(-30 * 86_400), found: false, now: now), 86_400)
        XCTAssertEqual(VideoSourceResolver.recheckAfter(published: now, found: true, now: now), 7 * 86_400)
    }

    // MARK: His exported episodes (Mac only, skipped when the file isn't there)

    /// Replays the cut check on each model attempt in his 15 Oct Results
    /// export against the stretches labelled by hand from the transcripts,
    /// and fails if the new check hears more ad or cuts more of the show
    /// than the saved results did on any of the three episodes.
    func testExportReplayOnHisThreeEpisodes() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/phone-1015/PodSkipper-results-1792032802.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("export not on this Mac") }
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let episodes = try XCTUnwrap(root["episodes"] as? [[String: Any]])
        let truth: [String: (cut: [ClosedRange<Double>], neutral: [ClosedRange<Double>])] = [
            "Two Mark Normands, One Sam Morril, no cups": ([2155...2375.5, 4879...5048],
                                                            [2150...2155, 2421...2452, 4858...4879, 5098...5148]),
            "#202 - Grace Kuhlenschmidt": ([0...44.5, 1665...1786.5, 3894...3912, 3946...4110, 5805...5864, 7651...7737.7],
                                           [44.5...59, 3940...3946, 4110...4112, 7635...7651]),
            "#690 - Josh Brolin": ([0...14.5, 15...53, 1768...1945.5, 3534...3700, 5895...5927], [53...54, 5890...5895])]
        func segments(_ any: Any?) -> [DetectedSegment] {
            ((any as? [[String: Any]]) ?? []).map { d in
                DetectedSegment(start: d["start"] as? Double ?? 0, end: d["end"] as? Double ?? 0,
                                kind: SegmentKind(rawValue: d["kind"] as? String ?? "") ?? .ad,
                                sponsor: d["sponsor"] as? String ?? "", confidence: d["confidence"] as? Int ?? 0,
                                evidence: [d["evidence"] as? String ?? ""],
                                insertedAtDownload: d["insertedAtDownload"] as? Bool ?? false)
            }
        }
        func score(_ cuts: [DetectedSegment], _ t: (cut: [ClosedRange<Double>], neutral: [ClosedRange<Double>]))
            -> (heard: Double, showCut: Double, overlaps: Int) {
            let u = SkipJoin.joined(cuts.map { $0.start...$0.end }, maxGap: 0)
            func inter(_ a: ClosedRange<Double>, _ b: ClosedRange<Double>) -> Double {
                max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
            }
            let total = t.cut.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
            let covered = u.reduce(0) { s, r in s + t.cut.reduce(0) { $0 + inter(r, $1) } }
            let neutral = u.reduce(0) { s, r in s + t.neutral.reduce(0) { $0 + inter(r, $1) } }
            let length = u.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
            let sorted = cuts.sorted { $0.start < $1.start }
            let overlaps = zip(sorted, sorted.dropFirst()).filter { $0.end > $1.start + 0.5 }.count
            return (total - covered, length - covered - neutral, overlaps)
        }
        var report: [String] = []
        for episode in episodes {
            guard let title = episode["title"] as? String, let t = truth[title] else { continue }
            let lineData = try JSONSerialization.data(withJSONObject: episode["transcript"] ?? [])
            let lines = try JSONDecoder().decode([TimedLine].self, from: lineData)
            let duration = max(episode["duration"] as? Double ?? 0, lines.last?.end ?? 0)
            for attempt in (episode["attempts"] as? [[String: Any]]) ?? [] {
                let proposed = segments(attempt["proposedCuts"])
                guard !proposed.isEmpty else { continue }
                let reader = segments(attempt["readerCuts"])
                let keeps = ((attempt["parts"] as? [[String: Any]]) ?? []).compactMap { p -> ClosedRange<Double>? in
                    guard ["MOCK_AD", "RECURRING_SEGMENT"].contains(p["label"] as? String ?? ""),
                          let a = p["start"] as? Double, let b = p["end"] as? Double, b > a else { return nil }
                    return a...b
                }
                let now = ModelCutCheck.verify(proposed, lines: lines, readerCuts: reader, evidence: [], keeps: keeps,
                                               duration: duration)
                let before = score(segments(attempt["savedCuts"]), t)
                let after = score(now.cuts, t)
                report.append(String(format: "%@ · %@: heard %.0f → %.0f s, show cut %.0f → %.0f s, overlaps %d → %d, cuts %d",
                                     title, attempt["method"] as? String ?? "", before.heard, after.heard,
                                     before.showCut, after.showCut, before.overlaps, after.overlaps, now.cuts.count))
                XCTAssertLessThanOrEqual(after.heard, before.heard + 1, title)
                XCTAssertLessThanOrEqual(after.showCut, before.showCut + 1, title)
                XCTAssertEqual(after.overlaps, 0, title)
            }
        }
        print("PASS39 REPLAY\n" + report.joined(separator: "\n"))
        XCTAssertFalse(report.isEmpty)
    }
}
