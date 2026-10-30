import XCTest
import BackgroundTasks
@testable import PodSkipper

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

/// Pass 53: iCloud presence and the background-scheduling message.
final class Pass53CloudAndBackgroundTests: XCTestCase {
    func testOtherDevicesAreReadFromTheirOwnKeys() {
        let all: [String: Any] = [
            "device.me": ["kind": "iPhone", "at": 100.0],
            "device.ipad": ["kind": "iPad", "build": "abc", "system": "27.0", "at": 200.0],
            "device.old": ["kind": "iPhone", "at": 50.0],
            "listening.v2": Data(),
        ]
        let others = CloudSync.otherDevices(in: all, me: "me")
        XCTAssertEqual(others.map(\.kind), ["iPad", "iPhone"])
        XCTAssertEqual(others.first?.build, "abc")
        XCTAssertTrue(CloudSync.otherDevices(in: ["device.me": ["at": 1.0]], me: "me").isEmpty)
    }

    @MainActor func testUnavailableNamesASettingOnlyWhenOneIsOff() {
        let error = BGTaskScheduler.Error(.unavailable)
        // The simulator says so itself; the device wording is checked by reading it.
        XCTAssertFalse(BackgroundWork.describe(error, refreshOn: true, lowPower: false).contains("is off"))
    }
}
