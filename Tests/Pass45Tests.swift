import XCTest
@testable import PodSkipper

/// Pass 45: his 22 Oct export (48b18fe). The cut check replayed with the
/// retrained Reader on every model attempt of the labelled episodes.
final class Pass45ReplayTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private static func segments(_ any: Any?) -> [DetectedSegment] {
        ((any as? [[String: Any]]) ?? []).map { d in
            DetectedSegment(start: d["start"] as? Double ?? 0, end: d["end"] as? Double ?? 0,
                            kind: SegmentKind(rawValue: d["kind"] as? String ?? "") ?? .ad,
                            sponsor: d["sponsor"] as? String ?? "", confidence: d["confidence"] as? Int ?? 0,
                            evidence: (d["evidence"] as? String ?? "").components(separatedBy: " · "),
                            insertedAtDownload: d["insertedAtDownload"] as? Bool ?? false,
                            style: (d["delivery"] as? String).flatMap { $0.isEmpty ? nil
                                : AdDetector.AdStyle(hostRead: $0 == "host", comedyBit: d["comedyBit"] as? Bool ?? false) })
        }
    }

    /// Writes build/p45/replay.json for `phone_eval.py --cuts`: each model
    /// attempt's proposed cuts checked again against the episode's current
    /// (retrained) Reader segments.
    func testReplayCutCheckWithRetrainedReader() throws {
        let url = Self.root.appendingPathComponent("build/phone-1022/results.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("export not on this Mac") }
        let labelDir = Self.root.appendingPathComponent("Tools/DetectionLab/phone-labels")
        let labelled = Set(try FileManager.default.contentsOfDirectory(atPath: labelDir.path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let episodes = try XCTUnwrap(root["episodes"] as? [[String: Any]])
        // Pass 44's held-out fold readers (no audio evidence), where the lab has them.
        let heldOut = (try? Data(contentsOf: Self.root.appendingPathComponent("build/p45/heldout-reader.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var out: [String: [String: [[Any]]]] = [:]
        var notes: [String] = []
        for episode in episodes {
            guard let guid = episode["guid"] as? String, labelled.contains(guid) else { continue }
            let lineData = try JSONSerialization.data(withJSONObject: episode["transcript"] ?? [])
            let lines = try JSONDecoder().decode([TimedLine].self, from: lineData)
            let duration = max(episode["duration"] as? Double ?? 0, lines.last?.end ?? 0)
            let reader = Self.segments(episode["readerSegments"])
            out[guid, default: [:]]["Reader (now)"] = reader.map { [$0.start, $0.end, $0.kind.rawValue] }
            var seen = Set<String>()
            for attempt in ((episode["attempts"] as? [[String: Any]]) ?? []).sorted(by: {
                ($0["date"] as? String ?? "") > ($1["date"] as? String ?? "") }) {
                let method = attempt["method"] as? String ?? ""
                let proposed = Self.segments(attempt["proposedCuts"])
                guard !proposed.isEmpty, !method.hasPrefix("PodSkipper"), method != "Apple Intelligence",
                      seen.insert(method).inserted else { continue }
                let keeps = ((attempt["parts"] as? [[String: Any]]) ?? []).compactMap { p -> ClosedRange<Double>? in
                    guard ["MOCK_AD", "RECURRING_SEGMENT"].contains(p["label"] as? String ?? ""),
                          let a = p["start"] as? Double, let b = p["end"] as? Double, b > a else { return nil }
                    return a...b
                }
                let now = ModelCutCheck.verify(proposed, lines: lines, readerCuts: reader, evidence: [], keeps: keeps,
                                               duration: duration)
                out[guid, default: [:]]["\(method) (replay)"] = now.cuts.map { [$0.start, $0.end, $0.kind.rawValue] }
                if let held = heldOut[guid] {
                    let reader = Self.segments(held)
                    out[guid, default: [:]]["Reader (held out)"] = reader.map { [$0.start, $0.end, $0.kind.rawValue] }
                    let fused = ModelCutCheck.verify(proposed, lines: lines, readerCuts: reader, evidence: [],
                                                     keeps: keeps, duration: duration)
                    out[guid, default: [:]]["\(method) (held out)"] = fused.cuts.map { [$0.start, $0.end, $0.kind.rawValue] }
                }
                if (episode["title"] as? String ?? "").contains("Hamcheck") { notes += now.notes }
                let sorted = now.cuts.sorted { $0.start < $1.start }
                XCTAssertEqual(zip(sorted, sorted.dropFirst()).filter { $0.end > $1.start + 0.5 }.count, 0)
            }
        }
        // The Mac lab's reads (build/p45/<model>/<variant>.cuts.json, raw
        // parts) through the same check, with the held-out Reader where the
        // lab has it, else the episode's own.
        let lab = Self.root.appendingPathComponent("build/p45")
        for model in ["mc", "c3"] {
            let folder = lab.appendingPathComponent(model)
            for file in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where file.hasSuffix(".cuts.json") {
                guard let runs = (try? Data(contentsOf: folder.appendingPathComponent(file)))
                    .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: [String: [[Any]]]] }) else { continue }
                for (guid, sets) in runs where labelled.contains(guid) {
                    guard let episode = episodes.first(where: { $0["guid"] as? String == guid }), let raw = sets.values.first else { continue }
                    let lines = try JSONDecoder().decode([TimedLine].self,
                                                         from: JSONSerialization.data(withJSONObject: episode["transcript"] ?? []))
                    let reader = Self.segments(heldOut[guid] ?? episode["readerSegments"])
                    let proposed = raw.compactMap { c -> DetectedSegment? in
                        guard c.count >= 3, let a = c[0] as? Double, let b = c[1] as? Double,
                              let kind = SegmentKind(rawValue: c[2] as? String ?? "") else { return nil }
                        return DetectedSegment(start: a, end: b, kind: kind, sponsor: "", confidence: 80)
                    }
                    let duration = max(episode["duration"] as? Double ?? 0, lines.last?.end ?? 0)
                    let fused = ModelCutCheck.verify(proposed, lines: lines, readerCuts: reader, evidence: [], keeps: [],
                                                     duration: duration)
                    out[guid, default: [:]]["lab \(model) \(file.dropLast(10)) (fused)"] = fused.cuts.map { [$0.start, $0.end, $0.kind.rawValue] }
                }
            }
        }
        let dir = Self.root.appendingPathComponent("build/p45")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
            .write(to: dir.appendingPathComponent("replay.json"))
        print("PASS45 REPLAY \(out.count) episodes\n" + notes.joined(separator: "\n"))
        XCTAssertFalse(out.isEmpty)
    }
}

/// Pass 45: the cut check lets the retrained Reader's middling ads, sure
/// plugs and repeated spots stand where a model says nothing, and reads a
/// break as one (his 22 Oct #691 Johnny Hamcheck).
final class Pass45CutCheckTests: XCTestCase {
    private func line(_ text: String, _ start: Double, _ end: Double) -> TimedLine {
        TimedLine(text: text, start: start, end: end)
    }

    private func cut(_ start: Double, _ end: Double, _ kind: SegmentKind = .ad, sponsor: String = "",
                     confidence: Int = 80, evidence: [String] = []) -> DetectedSegment {
        DetectedSegment(start: start, end: end, kind: kind, sponsor: sponsor, confidence: confidence, evidence: evidence)
    }

    private let repeatedAudio = SegmentEvidence.repeatedAudio.rawValue

    /// #691's opening: a Paramount+ spot heard again an hour in, Theo's
    /// Netflix plug straight after it, then the guest's introduction.
    private var opening: [TimedLine] {
        [line("The king returns.", 0.4, 2.0),
         line("Sylvester Stallone returns as my boss Dwight Manfredi in Tulsa King.", 2.2, 8.6),
         line("Tulsa King, new season now streaming only on Paramount+.", 40.9, 44.8),
         line("I wanna let you guys know that my new special, I'm doing fine, is out now on Netflix.", 46.4, 51.9),
         line("Um, and thank you all for the support.", 52.3, 54.2),
         line("He's got those 6 inch chains and those 7.5 foot egg rolls.", 55.4, 60.3),
         line("I'm fortunate to sit down with Johnny Hamcheck.", 63.8, 76.9),
         line("This episode is sponsored by BetterHelp.", 3650.5, 3653.4),
         line("Visit BetterHelp.com slash Theo.", 3700, 3705)]
    }

    func testHamcheckKeepsTheRepeatedSpotAndThePlugBesideIt() {
        let model = [cut(3650.5, 3705, sponsor: "BetterHelp")]
        let reader = [cut(0.36, 45.6, confidence: 53, evidence: [repeatedAudio]),
                      cut(46.35, 53.8, .selfPromo, confidence: 52),
                      cut(3603.9, 3649.0, confidence: 88, evidence: [repeatedAudio])]
        let out = ModelCutCheck.verify(model, lines: opening, readerCuts: reader, evidence: [], keeps: [], duration: 8_782)
        let covered = SkipJoin.joined(out.cuts.map { $0.start...$0.end }, maxGap: 1)
        XCTAssertEqual(covered.first?.lowerBound ?? -1, 0.36, accuracy: 0.01)
        XCTAssertEqual(covered.first?.upperBound ?? -1, 53.8, accuracy: 0.01, "spot and plug as one break")
        XCTAssertTrue(out.cuts.contains { $0.start == 3603.9 }, "the spot again an hour in")
        XCTAssertTrue(out.cuts.contains { $0.kind == .selfPromo && $0.start == 46.35 })
        XCTAssertFalse(out.cuts.contains { $0.end > 55 && $0.start < 77 }, "the guest's introduction stays")
    }

    func testAMiddlingPlugAloneInTheConversationIsNotKept() {
        // The same plug with no break beside it: 52 is not sure enough alone.
        let reader = [cut(46.35, 53.8, .selfPromo, confidence: 52)]
        let out = ModelCutCheck.verify([], lines: opening, readerCuts: reader, evidence: [], keeps: [], duration: 8_782)
        XCTAssertTrue(out.cuts.isEmpty)
    }

    func testANeighbourThatDoesNotSellIsNotKept() {
        // Right after a kept spot, but its lines are the show.
        let lines = opening.filter { !$0.text.contains("special") }
        let reader = [cut(0.36, 45.6, confidence: 53, evidence: [repeatedAudio]),
                      cut(46.0, 76.9, .selfPromo, confidence: 60)]
        let out = ModelCutCheck.verify([], lines: lines, readerCuts: reader, evidence: [], keeps: [], duration: 8_782)
        XCTAssertEqual(out.cuts.count, 1)
    }

    func testAJokeAdTheModelNamedStaysTheShow() {
        let reader = [cut(0.36, 45.6, confidence: 53, evidence: [repeatedAudio])]
        let out = ModelCutCheck.verify([], lines: opening, readerCuts: reader, evidence: [], keeps: [0...45.6],
                                       duration: 8_782)
        XCTAssertTrue(out.cuts.isEmpty)
    }

    func testALongRepeatedStretchIsNotASpot() {
        // A rerun's whole segment plays in another episode too (TAL's two
        // copies of "Reaching Out"): repetition alone isn't an ad.
        let lines = (0..<40).map { line("And then she told me about the summer \($0).", Double($0) * 6, Double($0) * 6 + 5) }
        let reader = [cut(0, 216, confidence: 85, evidence: [repeatedAudio])]
        let out = ModelCutCheck.verify([], lines: lines, readerCuts: reader, evidence: [], keeps: [], duration: 3_725)
        XCTAssertTrue(out.cuts.isEmpty)
    }

    func testASurePlugThatSellsStands() {
        let lines = [line("We're going on tour, tickets at theovon.com.", 100, 110),
                     line("Come see us in Tulsa.", 110, 115)]
        let reader = [cut(100, 115, .selfPromo, confidence: 92)]
        let out = ModelCutCheck.verify([], lines: lines, readerCuts: reader, evidence: [], keeps: [], duration: 3_600)
        XCTAssertEqual(out.cuts.count, 1)
    }

    func testAModelPlugNamingASponsorInsideAPaidReadIsAnAd() {
        let lines = [line("We use Shopify for our merch store.", 1950, 1955),
                     line("That's shopify.com slash Theo.", 1995, 2003)]
        let model = [cut(1941.8, 2003.9, .selfPromo, sponsor: "Shopify")]
        let reader = [cut(1854.5, 2003.5, sponsor: "bluechew", confidence: 98)]
        let out = ModelCutCheck.verify(model, lines: lines, readerCuts: reader, evidence: [], keeps: [], duration: 8_782)
        XCTAssertTrue(out.cuts.contains { $0.sponsor == "Shopify" && $0.kind == .ad })
        XCTAssertFalse(out.cuts.contains { $0.kind == .selfPromo })
    }
}

final class Pass45StatusTests: XCTestCase {
    func testTokenCountsAreThinnedButNewKindsOfMessageGoAtOnce() {
        let throttle = StatusThrottle()
        XCTAssertTrue(throttle.admits("Writing classification · 1 tokens"))
        XCTAssertFalse(throttle.admits("Writing classification · 2 tokens"))
        XCTAssertFalse(throttle.admits("Writing classification · 3 tokens"))
        XCTAssertTrue(throttle.admits("Reading part 2 of 11"))
    }
}

@MainActor
final class Pass45StorageTests: XCTestCase {
    private func item(audio: Int64, transcript: Int64) -> StorageView.Item {
        StorageView.Item(id: UUID().uuidString, show: "", title: "", artwork: nil, published: .now, duration: 0,
                         position: 0, played: false, downloaded: nil, audioNames: [], audioBytes: audio,
                         transcriptBytes: transcript)
    }

    func testEachScopeRemovesOnlyWhatItSays() {
        XCTAssertEqual(StorageView.Kind.audio.action, .download)
        XCTAssertEqual(StorageView.Kind.transcripts.action, .transcript)
        XCTAssertNil(StorageView.Kind.all.action, "All asks which")
        let both = item(audio: 250, transcript: 1)
        XCTAssertEqual(both.bytes(.download), 250)
        XCTAssertEqual(both.bytes(.transcript), 1)
        XCTAssertEqual(both.bytes(.both), 251)
        let audioOnly = item(audio: 250, transcript: 0)
        XCTAssertTrue(StorageView.Kind.audio.includes(audioOnly))
        XCTAssertFalse(StorageView.Kind.transcripts.includes(audioOnly))
        XCTAssertFalse(audioOnly.has(.both))
        XCTAssertEqual(StorageView.Action.download.title(2), "Remove Downloads")
    }
}
