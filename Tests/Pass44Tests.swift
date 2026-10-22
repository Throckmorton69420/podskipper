import Observation
import XCTest
@testable import PodSkipper

/// Pass 44: what changed under his 20 Oct request — Activity redrawing with
/// every progress step of a Find Ads, and its rows.
@MainActor
final class Pass44Tests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var folder: URL!
    private var file: URL { folder.appending(path: "jobs.json") }
    private let selection = ProcessingEngineSelection(engine: "mlx", modelID: "model-a", modelName: "A")

    override func setUp() {
        super.setUp()
        suite = "Pass44Tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        folder = URL.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    /// Progress inside a step no longer tells the line's readers to redraw
    /// (Activity, the activity bar, every row's Find Ads); a new step, a
    /// change of line or a finish does.
    func testProgressWithinAStepDoesNotRedrawTheLine() throws {
        let store = ProcessingJobStore(file: file, defaults: defaults)
        store.setWaitingOrder(["b", "c"])
        let job = try XCTUnwrap(store.begin("a", title: "A", origin: "user", selection: selection))
        store.progress("a", id: job.id, stage: "transcribing", fraction: 0.1)

        let redrawn = Flag()
        withObservationTracking {
            _ = store.waiting
            _ = store.record("b")
        } onChange: { redrawn.raised = true }
        for step in 2...20 { store.progress("a", id: job.id, stage: "transcribing", fraction: Double(step) / 20) }
        XCTAssertFalse(redrawn.raised, "progress within a step")
        XCTAssertEqual(store.record("a")?.stageFraction, 1, "the record itself still moves")
        XCTAssertEqual(store.waiting, ["b", "c"])

        store.progress("a", id: job.id, stage: "detecting", fraction: 0)
        XCTAssertTrue(redrawn.raised, "a new step")

        let reordered = Flag()
        withObservationTracking { _ = store.waiting } onChange: { reordered.raised = true }
        store.setWaitingOrder(["c", "b"])
        XCTAssertTrue(reordered.raised, "the line reordered")
        XCTAssertEqual(store.waiting, ["c", "b"], "the cached order follows the change")
    }

    private final class Flag: @unchecked Sendable { var raised = false }

    func testActivityLinePlaces() {
        XCTAssertEqual(ActivityView.place(0), "Next in line")
        XCTAssertEqual(ActivityView.place(2), "Number 3 in line")
    }

    /// Core AI: a memory warning while the model loads (his 20 Oct phone,
    /// 6.6 GB free) doesn't stop the read; a real shortage does.
    func testCoreAIWarningDuringLoadDoesNotStopTheRead() {
        let readingBegan = Date.now
        let warnedWhileLoading = readingBegan.addingTimeInterval(-3)
        XCTAssertNil(CoreAIMemory.short(since: readingBegan, available: 6_600, warned: warnedWhileLoading))
        XCTAssertNil(CoreAIMemory.short(since: readingBegan, available: 6_600, warned: readingBegan.addingTimeInterval(9)))
        XCTAssertNotNil(CoreAIMemory.short(since: readingBegan, available: 280, warned: nil))
    }
}

/// Pass 44: each of the four models he tests asked as measured on his
/// labelled episodes.
final class Pass44PromptTests: XCTestCase {
    private let template = "{%- if enable_thinking is defined and enable_thinking is false %}<think>\\n\\n</think>"

    func testEachModelGetsTheRulesMeasuredForIt() {
        let instruct = ModelPromptPlan.plan(id: "ALTICDEV/Qwen3.5-4B-Instruct-MLX-Q6", modelType: "qwen3_5",
                                            template: template, downloadBytes: 0)
        XCTAssertEqual(instruct.profile, .listenerEdges)
        XCTAssertTrue(instruct.summary.contains("edges"), instruct.summary)
        XCTAssertEqual(ModelPromptPlan.plan(id: "mlx-community/Qwen3.5-4B-MLX-4bit", modelType: "qwen3_5",
                                            template: template, downloadBytes: 3_061_129_077).profile, .listener,
                       "the 4-bit did no better with the edge rules")

        let qwen3 = ModelPromptPlan.coreAI(id: "qwen3-4b", name: "Qwen3 4B", template: "enable_thinking", context: 2_047)
        XCTAssertEqual(qwen3.profile, .compactListener)
        XCTAssertEqual(qwen3.answerCap, JudgePrompt.Profile.compact.answerTokens, "same answer room as compact")
        // Pass 45: measured with its own Core AI build on the Mac.
        XCTAssertEqual(ModelPromptPlan.coreAI(id: "minicpm5-2b", name: "MiniCPM5 2B", template: "", context: 2_047).profile, .compactTight)
        XCTAssertEqual(ModelPromptPlan.coreAI(id: "minicpm5-1b", name: "MiniCPM5 1B", template: "", context: 2_047).profile, .compact,
                       "measured on the 2B only")
        XCTAssertEqual(ModelPromptPlan.coreAI(id: "qwen3-0.6b", name: "Qwen3 0.6B", template: "enable_thinking", context: 2_047).profile, .compact,
                       "measured on the 4B only")

        // The rules fit the room they are given.
        let edges = JudgePrompt.Profile.listenerEdges
        XCTAssertTrue(edges.system.hasPrefix(JudgePrompt.listenerRules))
        XCTAssertTrue(edges.system.contains("signing off"))
        XCTAssertNotNil(edges.reminder)
        let compact = JudgePrompt.Profile.compactListener
        XCTAssertEqual(compact.schema, JudgePrompt.Profile.compact.schema)
        XCTAssertLessThan(compact.system.count, JudgePrompt.Profile.compact.system.count * 2,
                          "short enough to leave a 2,047-token model room for a break")
        XCTAssertNotNil(compact.reminder)
    }
}
