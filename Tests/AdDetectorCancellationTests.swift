import XCTest
@testable import PodSkipper

@MainActor
final class AdDetectorCancellationTests: XCTestCase {
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0, writes = 0, responses = 0
        var cache: AdDetector.ReplyCache {
            (get: { [self] _ in lock.withLock { reads += 1 }; return "cached" },
             set: { [self] _, _ in lock.withLock { writes += 1 } })
        }
        var misses: AdDetector.ReplyCache {
            (get: { [self] _ in lock.withLock { reads += 1 }; return nil },
             set: { [self] _, _ in lock.withLock { writes += 1 } })
        }
        func response() { lock.withLock { responses += 1 } }
        var counts: [Int] { lock.withLock { [reads, writes, responses] } }
    }

    override func setUp() {
        super.setUp()
        AdDetector.simulateRefusal = false
        AdDetector.inBackground = false
    }

    func testRequestIdentitySeparatesTokenBudgetPolicyDetectorAndRuntime() {
        func key(_ tokens: Int = 60, _ detector: Int = 1, _ policy: Int = 2, _ runtime: String = "test-runtime") -> String {
            AdDetector.responseCacheKey("prompt", instructions: "instructions", maxTokens: tokens,
                detectorVersion: detector, policyVersion: policy, runtimeIdentity: runtime)
        }
        XCTAssertEqual(key(), key())
        XCTAssertEqual(Set([key(), key(61), key(60, 2), key(60, 1, 3), key(60, 1, 2, "other-runtime")]).count, 5)
        let first = AdDetector.responseCacheKey("c", instructions: "ab", maxTokens: 60, runtimeIdentity: "runtime")
        let second = AdDetector.responseCacheKey("bc", instructions: "a", maxTokens: 60, runtimeIdentity: "runtime")
        XCTAssertNotEqual(first, second)
    }

    func testAlreadyCancelledRequestDoesNotReadCacheOrStartInference() async {
        let probe = Probe()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var log: [String] = []
            return await AdDetector.ask("prompt", instructions: "instructions", log: &log, label: "test",
                maxTokens: 60, cacheSnapshot: probe.cache, respond: { _, _, _ in probe.response(); return "fresh" })
        }
        let answer = await task.value
        XCTAssertNil(answer); XCTAssertEqual(probe.counts, [0, 0, 0])
    }

    func testCancellationImmediatelyAfterResponseDoesNotCommitOrReturnIt() async {
        let probe = Probe()
        let task = Task {
            var log: [String] = []
            return await AdDetector.ask("prompt", instructions: "instructions", log: &log, label: "test",
                maxTokens: 60, cacheSnapshot: probe.misses, respond: { _, _, _ in
                    probe.response(); withUnsafeCurrentTask { $0?.cancel() }; return "late response"
                })
        }
        let answer = await task.value
        XCTAssertNil(answer); XCTAssertEqual(probe.counts, [1, 0, 1])
    }

    func testCancelledBatchDoesNotLaunchRemainingPromptsOrWriteLateResults() async {
        let probe = Probe()
        let task = Task {
            var log: [String] = []
            return await AdDetector.askAll((0..<30).map { "prompt-\($0)" }, instructions: "instructions", label: "test",
                maxTokens: 60, width: 1, log: &log, progress: { _ in withUnsafeCurrentTask { $0?.cancel() } },
                cacheSnapshot: probe.misses, respond: { prompt, _, _ in probe.response(); return prompt })
        }
        let answers = await task.value
        XCTAssertEqual(answers.count, 30)
        XCTAssertEqual(answers.compactMap { $0 }, ["prompt-0"])
        XCTAssertEqual(probe.counts, [1, 1, 1])
    }

    func testBatchKeepsRequestOrderAndUsesItsFrozenCache() async {
        let probe = Probe()
        var log: [String] = []
        let answers = await AdDetector.askAll(["first", "second", "third"], instructions: "instructions", label: "test",
            maxTokens: 60, width: 2, log: &log, cacheSnapshot: probe.misses, respond: { prompt, _, _ in
                probe.response()
                if prompt == "first" { try await Task.sleep(for: .milliseconds(10)) }
                return prompt
            })
        XCTAssertEqual(answers.compactMap { $0 }, ["first", "second", "third"])
        XCTAssertEqual(probe.counts, [3, 3, 3])
    }
}
