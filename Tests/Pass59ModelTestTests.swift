import XCTest
@testable import PodSkipper

/// Pass 59 (his 7 Nov questions): the Reader's cuts stay when a model reads;
/// the CPU copy is an engine Compare Models can test; the On Your Episodes
/// table compares each engine with the Reader on the same episodes.
final class Pass59ModelTestTests: XCTestCase {
    override func tearDown() {
        ModelCutCheck.readerAlwaysStands = true
        super.tearDown()
    }

    private func line(_ t: Double, _ text: String, length: Double = 4) -> TimedLine {
        TimedLine(text: text, start: t, end: t + length)
    }

    /// A stretch the Reader cut with middling confidence and nothing in it
    /// that the check reads as selling: before, the model's silence dropped
    /// it; now it stays.
    func testAReaderCutTheModelDidNotMentionStays() {
        let lines = (0..<20).map { line(1_000 + Double($0) * 5, "and the thing about it is that everybody knew") }
        let reader = DetectedSegment(start: 1_010, end: 1_070, kind: .ad, sponsor: "", confidence: 62, evidence: [])
        let now = ModelCutCheck.verify([], lines: lines, readerCuts: [reader], evidence: [], keeps: [], duration: 4_000)
        XCTAssertEqual(now.cuts.count, 1, "\(now.cuts)")
        XCTAssertEqual(now.cuts.first?.start ?? 0, 1_010, accuracy: 0.5)
        ModelCutCheck.readerAlwaysStands = false
        let before = ModelCutCheck.verify([], lines: lines, readerCuts: [reader], evidence: [], keeps: [], duration: 4_000)
        XCTAssertTrue(before.cuts.isEmpty, "before Pass 59 an unsure Reader cut needed the model or selling words")
    }

    func testAJokeAdTheModelMarkedStillVetoesTheReader() {
        let lines = (0..<20).map { line(1_000 + Double($0) * 5, "introducing Pete's back brace, use code OUCH") }
        let reader = DetectedSegment(start: 1_010, end: 1_070, kind: .ad, sponsor: "", confidence: 95, evidence: [])
        let now = ModelCutCheck.verify([], lines: lines, readerCuts: [reader], evidence: [], keeps: [1_000...1_080],
                                       duration: 4_000)
        XCTAssertTrue(now.cuts.isEmpty, "the model's joke-ad call keeps the show: \(now.cuts)")
    }

    func testTheModelStillAddsWhatTheReaderMissed() {
        var lines = (0..<30).map { line(2_000 + Double($0) * 5, "so we were talking about the trip") }
        lines[10] = line(2_050, "this episode is brought to you by Shopify")
        lines[11] = line(2_055, "go to shopify dot com slash pod for a free trial")
        let model = DetectedSegment(start: 2_050, end: 2_060, kind: .ad, sponsor: "Shopify", confidence: 85, evidence: [])
        let reader = DetectedSegment(start: 2_100, end: 2_130, kind: .ad, sponsor: "", confidence: 70, evidence: [])
        let now = ModelCutCheck.verify([model], lines: lines, readerCuts: [reader], evidence: [], keeps: [], duration: 5_000)
        XCTAssertTrue(now.cuts.contains { $0.start <= 2_051 && $0.end >= 2_058 }, "the model's own find: \(now.cuts)")
        XCTAssertTrue(now.cuts.contains { $0.start <= 2_101 && $0.end >= 2_129 }, "the Reader's stays: \(now.cuts)")
    }

    func testTheCPUCopyHasItsOwnEngineID() {
        XCTAssertEqual(ModelBench.cpuEngineID, LocalModelSpec.qwen35_4B.id + "#cpu")
        XCTAssertNotEqual(ModelBench.cpuEngineID, LocalModelSpec.qwen35_4B.id, "its results never mix with the GPU copy's")
    }

    @MainActor
    func testTestingTheCPUCopyWhereItIsntExplainsWhy() {
        let bench = ModelBench.shared
        guard !CPUReading.isDownloaded else { return }
        bench.testCPUCopy(sample: .basic)
        XCTAssertEqual(bench.requestErrorEngine, ModelBench.cpuEngineID)
        XCTAssertNotNil(bench.requestError)
        XCTAssertFalse(bench.isRunning)
        bench.clearRequestError()
    }

    func testOnYourEpisodesComparesEachEngineWithTheReaderOnItsEpisodes() {
        for row in RealEpisodeScores.rows {
            XCTAssertGreaterThan(row.episodes, 0)
            XCTAssertTrue((0...100).contains(row.score), row.name)
            XCTAssertTrue((0...100).contains(row.reader), row.name)
        }
        XCTAssertTrue(RealEpisodeScores.rows.contains { $0.name.contains("CPU") })
    }
}
