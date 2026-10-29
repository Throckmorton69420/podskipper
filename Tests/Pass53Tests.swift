import XCTest
@testable import PodSkipper

/// Pass 53: the 1,024-position line on Core AI's sequential engine.
final class Pass53PositionLineTests: XCTestCase {
    func testLongestUnansweredPartIsReadFirst() {
        // Jared Freid, 28 Oct: parts under 1,024 before a 1,616-token part 8.
        let prompts = [900, 880, 950, 700, 990, 860, 940, 1_616, 833, 1_105, 1_108, 255, 938]
        let order = CoreAIPositionLine.readingOrder(promptTokens: prompts)
        XCTAssertEqual(order.first, 7)
        XCTAssertEqual(order.dropFirst().map { $0 }, [0, 1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12])
        // Answered parts don't touch the engine: the longest open one leads.
        let resumed = CoreAIPositionLine.readingOrder(promptTokens: prompts, answered: [7])
        XCTAssertEqual(resumed.first, 10)
        XCTAssertEqual(Set(resumed), Set(prompts.indices))
        XCTAssertEqual(CoreAIPositionLine.readingOrder(promptTokens: [1, 2], answered: [0, 1]), [0, 1])
    }

    func testFreshEngineOnlyForAFirstCrossingOnAUsedEngine() {
        // The four closures: used engine, never past 1,024, now past it.
        XCTAssertTrue(CoreAIPositionLine.needsFreshEngine(widest: 1_003, used: true, promptTokens: 1_616))
        XCTAssertTrue(CoreAIPositionLine.needsFreshEngine(widest: 1_024, used: true, promptTokens: 1_093))
        // What finished: a first part past the line, and parts after one.
        XCTAssertFalse(CoreAIPositionLine.needsFreshEngine(widest: 0, used: false, promptTokens: 1_616))
        XCTAssertFalse(CoreAIPositionLine.needsFreshEngine(widest: 1_739, used: true, promptTokens: 1_270))
        XCTAssertFalse(CoreAIPositionLine.needsFreshEngine(widest: 900, used: true, promptTokens: 1_000))
    }
}

/// Pass 53: the reader's long plug stretches where a model cut pieces of them.
final class Pass53PlugFillTests: XCTestCase {
    private func line(_ start: Double, _ text: String) -> TimedLine {
        TimedLine(text: text, start: start, end: start + 9)
    }

    func testReaderLongPlugIsFilledAroundTheModelsPieces() {
        // Seven minutes of the hosts' plugs; the model cut three pieces.
        var lines: [TimedLine] = []
        for i in 0..<60 {
            let t = 3_000 + Double(i) * 10
            lines.append(line(t, i % 6 == 0 ? "Get tickets at jaredfreid.com for the tour dates" : "and then we went to the show"))
        }
        let reader = DetectedSegment(start: 3_000, end: 3_600, kind: .selfPromo, sponsor: "", confidence: 95,
                                     evidence: ["PodSkipper's reader was sure of it, sentence by sentence"])
        let model = [(3_000.0, 3_100.0), (3_200.0, 3_300.0), (3_420.0, 3_500.0)].map {
            DetectedSegment(start: $0.0, end: $0.1, kind: .selfPromo, sponsor: "", confidence: 80,
                            evidence: ["On-device model: "])
        }
        defer { ModelCutCheck.plugPolicy = 2 }
        ModelCutCheck.plugPolicy = 0
        let before = ModelCutCheck.verify(model, lines: lines, readerCuts: [reader], evidence: [], keeps: [], duration: 4_000)
        ModelCutCheck.plugPolicy = 1
        let after = ModelCutCheck.verify(model, lines: lines, readerCuts: [reader], evidence: [], keeps: [], duration: 4_000)
        func cut(_ o: ModelCutCheck.Outcome) -> Double { o.cuts.reduce(0) { $0 + $1.end - $1.start } }
        XCTAssertLessThan(cut(before), 300)
        XCTAssertGreaterThan(cut(after), 500)
        XCTAssertLessThanOrEqual(after.cuts.map(\.end).max() ?? 0, 3_600)
    }
}

/// Pass 53: the cut check replayed on every labelled episode's model reads
/// (`build/p53/replay-input.json`, made by `build/p53/replay_input.py`),
/// written to `build/p53/replay.json` for `phone_eval.py --cuts`.
final class Pass53ReplayTests: XCTestCase {
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

    func testReplayPlugPolicies() throws {
        guard let data = try? Data(contentsOf: Self.root.appendingPathComponent("build/p53/replay-input.json")) else {
            throw XCTSkip("replay input not on this Mac")
        }
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        var out: [String: [String: [[Any]]]] = [:]
        defer { ModelCutCheck.plugPolicy = 2 }
        for (guid, episode) in root {
            let lines = try JSONDecoder().decode([TimedLine].self,
                                                 from: JSONSerialization.data(withJSONObject: episode["lines"] ?? []))
            let duration = max(episode["duration"] as? Double ?? 0, lines.last?.end ?? 0)
            let current = Self.segments(episode["currentReader"])
            for model in (episode["models"] as? [[String: Any]]) ?? [] {
                let method = model["method"] as? String ?? ""
                let proposed = Self.segments(model["proposed"])
                for (readerName, reader) in [("own", Self.segments(model["reader"])), ("current", current)] {
                    for policy in 0...2 {
                        ModelCutCheck.plugPolicy = policy
                        let checked = ModelCutCheck.verify(proposed, lines: lines, readerCuts: reader, evidence: [], keeps: [],
                                                           duration: duration)
                        out[guid, default: [:]]["\(method) · \(readerName) reader · plugs \(policy)"] =
                            checked.cuts.map { [$0.start, $0.end, $0.kind.rawValue] }
                    }
                }
            }
        }
        let dir = Self.root.appendingPathComponent("build/p53")
        try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]).write(to: dir.appendingPathComponent("replay.json"))
        XCTAssertFalse(out.isEmpty)
    }
}
