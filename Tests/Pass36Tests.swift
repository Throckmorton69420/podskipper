import XCTest
@testable import PodSkipper

/// Pass 36 (his 12–13 Oct phone on 4075f0e): model-test attempts, Stop during
/// work that can't be interrupted, and storage identification/cleanup records.
/// Everything destructive runs on a throwaway folder.
@MainActor
final class Pass36Tests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var root: URL!

    override func setUpWithError() throws {
        suite = "Pass36Tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pass36-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Stop during work that can't be interrupted

    /// Like Core AI's preparation (measured: `AIModel.specialize` runs to the
    /// end after its task is cancelled), the work keeps going after Stop. The
    /// test must say Stop was requested, keep the heavy-work slot until the
    /// work really ends, publish no result from it, and record the stop.
    func testStopDuringUninterruptibleWorkWaitsForItAndRecordsTheStop() async throws {
        let bench = ModelBench(defaults: defaults, recoverInterrupted: false)
        let finished = Flag()
        bench.start(engine: "slow", name: "Slow model", sample: .hard, modelIdentity: "repo @ rev") { sample in
            let native = Task.detached { () -> Bool in
                // Ignores cancellation, as the native step does.
                let end = Date().addingTimeInterval(0.6)
                while Date() < end { usleep(10_000) }
                finished.set()
                return true
            }
            _ = await native.value
            return BenchResult(engine: "slow", name: "Slow model", sample: sample, date: .now, score: 1)
        }
        try await waitUntil { bench.startedAt != nil }
        bench.stop()
        XCTAssertTrue(bench.stopping, "the request is acknowledged at once")
        XCTAssertNotNil(bench.stopRequestedAt)
        XCTAssertTrue(bench.isRunning, "not called stopped while the work still runs")
        XCTAssertTrue(HeavyWorkCoordinator.shared.isBusy, "the slot stays taken while the work runs")
        XCTAssertFalse(finished.value)
        try await waitUntil(seconds: 5) { !bench.isRunning }
        XCTAssertTrue(finished.value, "it ended only after the work had")
        XCTAssertFalse(HeavyWorkCoordinator.shared.isBusy)
        XCTAssertEqual(bench.history.count, 1)
        let record = try XCTUnwrap(bench.history.first)
        XCTAssertEqual(record.resolvedOutcome, .stopped)
        XCTAssertNil(record.score, "a late answer after Stop is not published as a result")
        XCTAssertEqual(record.modelIdentity, "repo @ rev")
        XCTAssertEqual(record.appBuild, BuildInfo.commit)
        XCTAssertNotNil(record.stage)
    }

    /// His 13 Oct phone: Stop during Core AI's preparation sat at
    /// "Stopping…" until he closed the app. Now the caller ends at once, the
    /// preparation (which can't be interrupted) keeps the heavy-work slot by
    /// itself until it really ends, and then frees it.
    func testStopDuringPreparationReturnsAtOnceAndTheSlotIsHeldUntilTheWorkEnds() async throws {
        let coordinator = HeavyWorkCoordinator.shared
        let preparation = CoreAIPreparation.shared
        let finished = Flag()
        let lease = try XCTUnwrap(coordinator.tryAcquire(owner: "benchmark:test"))
        let caller = Task { @MainActor in
            try await preparation.run(modelID: "slow-model", name: "Slow Model", bundle: self.root, status: { _ in }) {
                let end = Date().addingTimeInterval(0.8)
                while Date() < end { usleep(10_000) }   // ignores cancellation
                finished.set()
                return nil
            }
        }
        try await waitUntil { preparation.current != nil }
        let asked = Date()
        caller.cancel()
        do { try await caller.value; XCTFail("a stopped preparation ends its caller") } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(asked), 0.4, "Stop returns at once")
        XCTAssertFalse(finished.value)
        XCTAssertNotNil(preparation.current?.stopRequestedAt, "shown as still preparing after Stop")
        coordinator.release(lease)   // the test's own release: the slot stays with the preparation
        XCTAssertEqual(coordinator.current?.owner, "coreai-prepare:slow-model")
        try await waitUntil(seconds: 5) { !coordinator.isBusy }
        XCTAssertTrue(finished.value, "the slot was freed only after the work ended")
        XCTAssertNil(preparation.current)
        XCTAssertNotNil(preparation.lastDuration("slow-model"))
    }

    // MARK: Every attempt is its own record

    /// An attempt PodSkipper closed during is recorded at the next launch even
    /// though the model already has a result (it used to be added only when
    /// there was none), and the earlier score stays for ranking.
    func testInterruptedAttemptIsRecordedBesideEarlierSuccess() throws {
        let bench = ModelBench(defaults: defaults, recoverInterrupted: false)
        let engine = CoreAIQwen3.benchmarkID(for: "qwen3-4b")
        bench.save(BenchResult(engine: engine, name: "Core AI · Qwen3 4B", sample: .hard, date: .now.addingTimeInterval(-86_400),
                               score: 0.39, outcome: .completed))
        let runID = UUID()
        var attempt = BenchAttempt(runID: runID, engine: engine, name: "Core AI · Qwen3 4B", sample: .hard,
                                   modelIdentity: "mlboydaisuke/qwen3-4b @ e40878f / ios", started: .now,
                                   stage: "Preparing the model for this iPhone · Preparing Qwen3 4B for this iPhone")
        attempt.launch = "an earlier launch"
        attempt.build = "4075f0e"
        attempt.write(defaults: defaults)

        let relaunched = ModelBench(defaults: defaults, recoverInterrupted: true)
        XCTAssertEqual(relaunched.history.count, 2)
        let latest = try XCTUnwrap(relaunched.result(engine, .hard))
        XCTAssertEqual(latest.runID, runID, "the record is the attempt itself")
        XCTAssertEqual(latest.resolvedOutcome, .interrupted)
        XCTAssertEqual(latest.appBuild, "4075f0e")
        XCTAssertTrue(latest.stage?.contains("Preparing") == true)
        XCTAssertEqual(relaunched.lastScored(engine, .hard)?.score, 0.39, "the earlier valid score is kept")
        XCTAssertEqual(relaunched.score(engine), 0.39)
        // Taken once.
        XCTAssertEqual(ModelBench(defaults: defaults, recoverInterrupted: true).history.count, 2)
    }

    func testRecordsBeforePass36GetAnOutcome() throws {
        let failed = BenchResult(engine: "e", name: "e", sample: .basic, date: .now, score: nil,
                                 error: "Loading Gemma 4 E2B: Couldn't load Gemma 4 E2B: GPU buffer allocation failed")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(failed)) as? [String: Any])
        legacy.removeValue(forKey: "outcome"); legacy.removeValue(forKey: "appBuild")
        let decoded = try JSONDecoder().decode(BenchResult.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.outcome)
        XCTAssertEqual(decoded.resolvedOutcome, .loadFailed)
        XCTAssertEqual(BenchResult(engine: "e", name: "e", sample: .basic, date: .now, score: nil,
                                   error: "The model reached its 320-token answer limit before returning a complete classification.").resolvedOutcome,
                       .invalidOutput)
        XCTAssertEqual(BenchResult(engine: "e", name: "e", sample: .basic, date: .now, score: 0.5).resolvedOutcome, .completed)
    }

    // MARK: Storage identification and records

    private var locations: ModelStorage.Locations {
        ModelStorage.Locations(mlxRoot: root.appending(path: "Models"), coreAIRoot: root.appending(path: "CoreAIKit/Models"),
                               caches: root.appending(path: "Caches"), temporary: root.appending(path: "tmp"))
    }

    private func file(_ path: String, bytes: Int = 4096, old: Bool = true) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        guard old else { return }
        var item = url
        while item.pathComponents.count > root.pathComponents.count + 1 {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: item.path)
            item = item.deletingLastPathComponent()
        }
    }

    /// Core AI's own store is never "leftovers", compiler-named files aren't
    /// removed in bulk, and every item says how it was identified.
    func testCoreAIStoreAndCompilerFilesAreNotTidiedAndSayWhy() throws {
        try file("Caches/coreai-cache/sync/26A434/abc.lock", bytes: 10)
        try file("Caches/coreai-cache/tmp/work.bin", bytes: 50_000)
        try file("tmp/com.apple.MetalPerformanceShadersGraph/x", bytes: 30_000)
        try file("tmp/CFNetworkDownload_1.tmp", bytes: 20_000)
        try file("tmp/mystery", bytes: 1_000)
        let report = ModelStorage.measure(.init(), at: locations)
        let byName = Dictionary(uniqueKeysWithValues: report.scratch.map { ($0.name, $0) })
        XCTAssertEqual(byName["coreai-cache"]?.kind, .coreAIStore)
        XCTAssertEqual(byName["com.apple.MetalPerformanceShadersGraph"]?.kind, .modelCompileScratch)
        XCTAssertEqual(Set(report.tidyEntries.map(\.name)), ["CFNetworkDownload_1.tmp"])
        XCTAssertTrue(report.scratch.allSatisfy { !$0.evidence.isEmpty })
        XCTAssertEqual(byName["mystery"]?.kind.need, "Unknown whether still needed")
        // While heavy work runs, Core AI's store is in use whatever its age.
        let busy = ModelStorage.measure(.init(workActive: true), at: locations)
        XCTAssertEqual(busy.scratch.first { $0.name == "coreai-cache" }?.inUse, true)
    }

    /// Each removal is recorded item by item: name, kind, evidence, bytes
    /// and what happened, with free space before and after.
    func testCleanupIsRecordedItemByItem() throws {
        try file("tmp/CFNetworkDownload_2.tmp", bytes: 20_000)
        try file("tmp/Clips/new.m4a", bytes: 1_000, old: false)
        let log = root.appending(path: "cleanup-log.json")
        let report = ModelStorage.measure(.init(), at: locations)
        let result = ModelStorage.removeScratch(report.scratch, at: locations, context: "Tidy Up", log: log)
        XCTAssertEqual(result.failures.count, 1, "the clip just written is kept")
        let operation = try XCTUnwrap(CleanupLog.load(from: log).first)
        XCTAssertEqual(operation.context, "Tidy Up")
        let items = Dictionary(uniqueKeysWithValues: operation.items.map { ($0.name, $0) })
        XCTAssertEqual(items["CFNetworkDownload_2.tmp"]?.result, "removed")
        XCTAssertGreaterThan(items["CFNetworkDownload_2.tmp"]?.bytes ?? 0, 0)
        XCTAssertEqual(items["Clips"]?.result, "kept: in use")
        XCTAssertFalse(items["CFNetworkDownload_2.tmp"]?.evidence.isEmpty ?? true)
    }

    /// Deleting one Core AI copy keeps the others in its repository: the
    /// deletion lists them as kept rather than removing the whole repository.
    func testOtherCoreAIVersionsInTheRepositoryAreFoundSeparately() throws {
        let models = root.appending(path: "CoreAIKit/Models")
        try file("CoreAIKit/Models/owner/repo/rev1/ios/a.bundle/metadata.json")
        try file("CoreAIKit/Models/owner/repo/rev2/ios/b.bundle/metadata.json")
        try file("CoreAIKit/Models/owner/repo/rev2/ios/b.bundle/main.aimodel/main.mlirb")
        try file("CoreAIKit/Models/owner/repo/rev2/ios/.podskipper-staging-c.bundle/metadata.json")
        let bundles = ModelStorage.coreAIBundles(under: models.appending(path: "owner/repo"))
        XCTAssertEqual(bundles.map { ModelStorage.relativePath(of: $0, under: models) },
                       ["owner/repo/rev1/ios/a.bundle", "owner/repo/rev2/ios/b.bundle"])
    }

    // MARK: Compiled copy matched to the exact download

    /// A copy compiled from another revision of the model is refused; one
    /// compiled from exactly the downloaded graph installs and says so.
    /// Chips are compared with Core AI's own name for this device.
    func testCompiledCopyMustComeFromTheDownloadedGraphAndChip() async throws {
        let bundle = root.appending(path: "CoreAIKit/Models/m/qwen3-4b/rev/ios")
        let graph = bundle.appending(path: "qwen3_4b_static.aimodel")
        try FileManager.default.createDirectory(at: graph, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["assets": ["main": "qwen3_4b_static.aimodel"]])
            .write(to: bundle.appending(path: "metadata.json"))
        try Data([1, 2, 3]).write(to: graph.appending(path: "main.mlirb"))
        let downloadedHash = Data(repeating: 0xAB, count: 32)
        try downloadedHash.write(to: graph.appending(path: "main.hash"))

        func compiled(_ name: String, sourceHash: String) throws -> URL {
            let folder = root.appending(path: "Import/\(UUID().uuidString)/\(name)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["sourceHash": sourceHash, "producer": "coreai-build-3600.83.1"])
                .write(to: folder.appending(path: "metadata.json"))
            try Data(repeating: 2, count: 1_000).write(to: folder.appending(path: "main-h17p.mlirb"))
            return folder
        }
        let other = try compiled("qwen3_4b_static.h17p.aimodelc", sourceHash: String(repeating: "CD", count: 32))
        XCTAssertThrowsError(try CoreAICompiledCopy.install(from: other, into: bundle, machine: "iPhone17,1", free: 50_000_000_000)) {
            XCTAssertEqual($0 as? CoreAICompiledCopy.Failure, .wrongSource)
        }
        let right = try compiled("qwen3_4b_static.h17p.aimodelc", sourceHash: String(repeating: "ab", count: 32))
        XCTAssertThrowsError(try CoreAICompiledCopy.validate(right, for: bundle, machine: "iPhone17,1", architecture: "h18p")) {
            XCTAssertEqual($0 as? CoreAICompiledCopy.Failure, .wrongChip("h17p"), "Core AI's own chip name decides")
        }
        // Pass 36: the Files route (checks small files first, then brings the
        // rest down from iCloud — local files pass straight through).
        let seen = Flag()
        try await CoreAICompiledCopy.installFromFiles(right, into: bundle, machine: "iPhone17,1") { done, total in
            if done == total && total > 0 { seen.set() }
        }
        XCTAssertTrue(seen.value, "progress reports the whole copy present")
        XCTAssertEqual(CoreAICompiledCopy.matchesDownload(in: bundle), true)
        XCTAssertEqual(CoreAIPreparation.mainAsset(in: bundle)?.lastPathComponent, "qwen3_4b_static.h17p.aimodelc")
        XCTAssertEqual(CoreAIPreparation.assets(in: bundle).map(\.lastPathComponent),
                       ["qwen3_4b_static.aimodel", "qwen3_4b_static.h17p.aimodelc"])
    }

    // MARK: Helpers

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        func set() { lock.withLock { on = true } }
        var value: Bool { lock.withLock { on } }
    }

    private func waitUntil(seconds: Double = 3, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }
}
