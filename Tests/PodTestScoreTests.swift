import XCTest
@testable import PodSkipper

/// Pass 60: the phone's PodSkipper test scores exactly as the lab's
/// `Tools/ReaderData/podtest.py`. `Tests/Fixtures/PodTestParity.json` is
/// written by `podtest.py parity …`: the shipped pack, cut sets (the lab's
/// Reader, MLX, CPU and a Core AI read of the test episodes, plus nothing
/// cut, everything cut and every break cut exactly) and what Python scored.
final class PodTestScoreTests: XCTestCase {
    struct Fixture: Decodable {
        struct Expected: Decodable {
            struct Row: Decodable {
                var heard: Double
                var noticed: Int
                var show: Double
                var jumps: Int
                var base: Double
                var breaks: Int
                var caught: Int
                var skippable: Double
                var cost: Double
                var audio: Double
                var sit: [String: Int]
                var sitN: [String: Int]
            }
            var everyday: Double
            var challenge: Double
            var rates: [String: Double]
            var episodes: [String: Row]
        }
        var pack: PodTestPack
        var sets: [String: [String: [[CutField]]]]
        var expected: [String: Expected]
    }

    /// A cut as Python writes it: [start, end, kind].
    enum CutField: Decodable {
        case number(Double), text(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { self = .number(d) } else { self = .text(try c.decode(String.self)) }
        }
    }

    static func cuts(_ raw: [[CutField]]) -> [PodTestCut] {
        raw.compactMap { fields in
            guard fields.count >= 3, case .number(let a) = fields[0], case .number(let b) = fields[1],
                  case .text(let kind) = fields[2] else { return nil }
            return PodTestCut(start: a, end: b, kind: kind)
        }
    }

    static func fixture() throws -> Fixture {
        let url = Bundle(for: PodTestScoreTests.self).url(forResource: "PodTestParity", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/PodTestParity.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testSwiftScoresMatchPython() throws {
        let fixture = try Self.fixture()
        let pack = fixture.pack
        XCTAssertEqual(fixture.sets.count, 7)
        for (name, set) in fixture.sets {
            let expected = try XCTUnwrap(fixture.expected[name], name)
            var cuts: [String: [PodTestCut]] = [:]
            for (guid, raw) in set { cuts[guid] = Self.cuts(raw) }
            XCTAssertEqual(cuts.values.reduce(0) { $0 + $1.count }, set.values.reduce(0) { $0 + $1.count }, name)
            for (guid, row) in expected.episodes {
                let e = try XCTUnwrap(pack.episode(guid))
                let mine = PodTestScore.episode(e, cuts: cuts[guid] ?? [], constants: pack.constants)
                let what = name + " " + guid
                XCTAssertEqual(mine.heard, row.heard, accuracy: 1e-9, what)
                XCTAssertEqual(mine.noticed, row.noticed, what)
                XCTAssertEqual(mine.show, row.show, accuracy: 1e-9, what)
                XCTAssertEqual(mine.jumps, row.jumps, what)
                XCTAssertEqual(mine.base, row.base, accuracy: 1e-9, what)
                XCTAssertEqual(mine.breaks, row.breaks, what)
                XCTAssertEqual(mine.caught, row.caught, what)
                XCTAssertEqual(mine.skippable, row.skippable, accuracy: 1e-9, what)
                XCTAssertEqual(mine.cost, row.cost, accuracy: 1e-9, what)
                XCTAssertEqual(mine.audio, row.audio, accuracy: 1e-9, what)
                XCTAssertEqual(mine.sit, row.sit, what)
                XCTAssertEqual(mine.sitN, row.sitN, what)
            }
            let summary = PodTestScore.summary(pack: pack, cuts: cuts)
            XCTAssertEqual(summary.episodes, expected.episodes.count, name)
            XCTAssertEqual(try XCTUnwrap(summary.everyday, name), expected.everyday, accuracy: 1e-9, name)
            XCTAssertEqual(try XCTUnwrap(summary.challenge, name), expected.challenge, accuracy: 1e-9, name)
            XCTAssertEqual(Set(summary.rates.keys), Set(expected.rates.keys), name)
            for (situation, rate) in expected.rates {
                XCTAssertEqual(summary.rates[situation] ?? -1, rate, accuracy: 1e-12, name + " " + situation)
            }
        }
        // The numbers MODEL-TEST §5 reports for the test episodes.
        XCTAssertEqual(fixture.expected["reader"]?.everyday ?? 0, 92.4, accuracy: 0.05)
        XCTAssertEqual(fixture.expected["every break exactly"]?.everyday ?? 0, 100, accuracy: 1e-9)
    }

    /// The app ships the same episodes the fixture was scored on.
    func testShippedPackIsTheFixturePack() throws {
        let shipped = try XCTUnwrap(PodTestPack.bundled(), "Resources/Detection/PodTest.json missing from the app")
        XCTAssertEqual(shipped, try Self.fixture().pack)
        XCTAssertEqual(shipped.episodes.count, 11)
        XCTAssertEqual(Set(shipped.episodes.map(\.show)).count, 7)
        XCTAssertEqual(shipped.situations.count, 14)
        // Time spans only: nothing in the pack is longer than a situation name.
        let data = try Data(contentsOf: try XCTUnwrap(Bundle.main.url(forResource: "PodTest", withExtension: "json")))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("\"text\""))
        XCTAssertFalse(text.contains("\"transcript\""))
    }

    func testSkipsAnotherVersionOfTheEpisode() {
        XCTAssertNil(PodTestRunner.skipReason(labelled: 2118, phone: 2120.9, inLibrary: true, hasTranscript: true))
        XCTAssertNil(PodTestRunner.skipReason(labelled: 2118, phone: 2115, inLibrary: true, hasTranscript: true))
        XCTAssertEqual(PodTestRunner.skipReason(labelled: 2118, phone: 2121.5, inLibrary: true, hasTranscript: true),
                       "A different version of the episode (4 s longer than the one checked by hand)")
        XCTAssertEqual(PodTestRunner.skipReason(labelled: 2118, phone: 2060, inLibrary: true, hasTranscript: true),
                       "A different version of the episode (58 s shorter than the one checked by hand)")
        XCTAssertEqual(PodTestRunner.skipReason(labelled: 2118, phone: 0, inLibrary: false, hasTranscript: false),
                       "Not in your library")
        XCTAssertEqual(PodTestRunner.skipReason(labelled: 2118, phone: 2118, inLibrary: true, hasTranscript: false),
                       "No transcript on this iPhone")
    }

    func testLessonsFromTheEpisodeItselfAreLeftOut() {
        let transcript = "And now a word from our sponsor. Quince has the softest sweaters, go to quince dot com slash show. Back to the show."
        let own = DetectionCorrection(excerpt: "Quince has the softest sweaters, go to Quince dot com slash show", kind: .ad)
        let other = DetectionCorrection(excerpt: "BetterHelp is online therapy that fits your schedule", kind: .ad)
        let tiny = DetectionCorrection(excerpt: "the show", kind: nil, boundary: "outsideEnd")
        let (kept, leftOut) = PodTestRunner.withoutOwnLessons([own, other, tiny], transcript: transcript)
        XCTAssertEqual(leftOut, 1)
        XCTAssertEqual(kept, [other, tiny])
    }

    func testRunResumesAfterClosingAndGivesUpAfterTwo() {
        var run = PodTestRun(runID: UUID(), started: .now, state: .running, appBuild: "test", device: "test", packVersion: 1,
                             engines: [.init(engine: "reader", name: "Reader", kind: .reader,
                                             reads: [.init(guid: "a", outcome: .completed), .init(guid: "b", outcome: .reading),
                                                     .init(guid: "c")])])
        run = run.recoveredAfterClosing(closuresAllowed: 2)
        XCTAssertEqual(run.state, .interrupted)
        XCTAssertEqual(run.engines[0].reads.map(\.outcome), [.completed, .pending, .pending])
        XCTAssertEqual(run.engines[0].reads[1].closures, 1)
        XCTAssertTrue(run.isUnfinished)
        XCTAssertEqual(run.doneReads, 1)
        // Closed again on the same read: recorded as failed, not tried a third time.
        run.state = .running
        run.engines[0].reads[1].outcome = .reading
        run = run.recoveredAfterClosing(closuresAllowed: 2)
        XCTAssertEqual(run.engines[0].reads[1].outcome, .failed)
        XCTAssertEqual(run.engines[0].reads[1].note, "PodSkipper closed 2 times while reading this episode")
        // A finished run is left as it is.
        var done = run
        done.state = .completed
        XCTAssertEqual(done.recoveredAfterClosing(closuresAllowed: 2), done)
    }

    /// A model is compared with the Reader only on episodes both read.
    func testComparisonIsPaired() throws {
        let pack = try Self.fixture().pack
        let exact = Dictionary(uniqueKeysWithValues: pack.episodes.map { e in
            (e.guid, e.breaks.map { PodTestCut(start: $0.start, end: $0.end, kind: $0.kind.lowercased()) })
        })
        let first = pack.episodes[0].guid
        let reader = PodTestRun.Engine(engine: "reader", name: "Reader", kind: .reader,
                                       reads: pack.episodes.map { .init(guid: $0.guid, outcome: .completed, cuts: []) })
        let model = PodTestRun.Engine(engine: "m", name: "Model", kind: .mlx,
                                      reads: pack.episodes.map { e in
                                          e.guid == first ? .init(guid: e.guid, outcome: .completed, cuts: exact[e.guid]!)
                                              : .init(guid: e.guid, outcome: .failed)
                                      })
        let run = PodTestRun(runID: UUID(), started: .now, state: .completed, appBuild: "t", device: "t", packVersion: 1,
                             engines: [reader, model])
        let comparison = try XCTUnwrap(run.comparison("m", pack: pack))
        XCTAssertEqual(comparison.engine.episodes, 1)
        XCTAssertEqual(comparison.reader.episodes, 1)
        XCTAssertEqual(comparison.engine.everyday ?? 0, 100, accuracy: 1e-9)
        XCTAssertLessThan(comparison.reader.everyday ?? 100, 10)
    }

    func testStoreKeepsRunsAcrossLaunches() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "podtest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PodTestStore(url: dir.appending(path: "runs.json"))
        XCTAssertEqual(store.load(), [])
        let run = PodTestRun(runID: UUID(), started: Date(timeIntervalSince1970: 1_794_000_000), state: .stopped,
                             appBuild: "abc", device: "iPhone17,1", packVersion: 1,
                             engines: [.init(engine: "reader", name: "Reader", kind: .reader, modelIdentity: "Reader 58",
                                             reads: [.init(guid: "g", outcome: .completed,
                                                           cuts: [PodTestCut(start: 1.5, end: 30.25, kind: "ad")], seconds: 2)])],
                             skipped: [.init(guid: "h", reason: "Not in your library")])
        try store.save([run])
        XCTAssertEqual(store.load(), [run])
        // Exported as the Mac reads it (`podtest.py --phone`).
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder.iso.encode(run)) as? [String: Any])
        let engines = try XCTUnwrap(json["engines"] as? [[String: Any]])
        let reads = try XCTUnwrap(engines.first?["reads"] as? [[String: Any]])
        XCTAssertEqual(reads.first?["outcome"] as? String, "completed")
        XCTAssertEqual((reads.first?["cuts"] as? [[String: Any]])?.first?["kind"] as? String, "ad")
        XCTAssertNotNil(json["runID"] as? String)
        XCTAssertNotNil(json["started"] as? String)
    }

    /// Mac only, asked for (`podtest-reader` in `build/lab-tests.txt`; about
    /// 30 min in the unoptimised simulator build): the runner's Reader path on
    /// the test episodes' transcripts — `build/p60/reader-lab.json`,
    /// git-ignored, from `build/p60/reader_lab_inputs.py` — with the lab's
    /// inputs (transcript only, padding 0.4) gives the lab's Reader cuts and
    /// score.
    @MainActor
    func testReaderPathMatchesLab() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let asked = (try? String(contentsOf: root.appending(path: "build/lab-tests.txt"), encoding: .utf8)) ?? ""
        guard asked.contains("podtest-reader") else { throw XCTSkip("Lab check not asked for (build/lab-tests.txt)") }
        let url = root.appending(path: "build/p60/reader-lab.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("No lab transcripts at \(url.path)") }
        let transcripts = try JSONDecoder().decode([String: [TimedLine]].self, from: data)
        let fixture = try Self.fixture()
        var cuts: [String: [PodTestCut]] = [:]
        for (guid, timed) in transcripts {
            let x = PodTestInputs(
                guid: guid,
                segments: timed.map { TranscriptSegment(text: $0.text, start: $0.start, end: $0.end, words: $0.words ?? []) },
                lines: timed.map { TimedLine(text: $0.text, start: $0.start, end: $0.end) },
                silences: [], inserted: [], produced: [], knownSponsors: [], showLessons: [], globalLessons: [],
                lessonsLeftOut: 0, show: "", title: "", notes: "", showNotes: "", episodeDuration: 0,
                minimumConfidence: 60, padding: 0.4)
            cuts[guid] = try await PodTestRunner.detect(x, apple: false, cache: nil, progress: nil).map(PodTestRunner.cut)
        }
        let lab = try XCTUnwrap(fixture.sets["reader"])
        for (guid, raw) in lab {
            let mine = cuts[guid] ?? []
            let theirs = Self.cuts(raw)
            XCTAssertEqual(mine.count, theirs.count, guid)
            for (a, b) in zip(mine, theirs) {
                XCTAssertEqual(a.start, b.start, accuracy: 1e-6, guid)
                XCTAssertEqual(a.end, b.end, accuracy: 1e-6, guid)
                XCTAssertEqual(a.kind, b.kind, guid)
            }
        }
        let score = PodTestScore.summary(pack: fixture.pack, cuts: cuts)
        XCTAssertEqual(score.everyday ?? 0, fixture.expected["reader"]?.everyday ?? -1, accuracy: 1e-6)
        print("PODTEST-LAB Reader on \(score.episodes) test episodes: Everyday \(score.everyday ?? .nan), Challenge \(score.challenge ?? .nan)")
    }
}
