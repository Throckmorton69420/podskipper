import XCTest
@testable import PodSkipper

/// Pass 54: Core AI's sequential engine reads in narrow steps, and a fresh
/// engine is made from measured memory, not from a token line.
final class Pass54CoreAIMemoryTests: XCTestCase {
    func testPrefillWidthPerRoute() {
        // The sequential engine: 256-token steps (Mac lab: footprint ≤ 1.28 GB
        // against 2.7 GB in Core AI's own 512/1,024-token steps).
        XCTAssertEqual(CoreAIPrefill.width(route: .sequential, decodeOnly: false, pipelinedHint: false), 256)
        XCTAssertEqual(CoreAIPrefill.width(route: .sequential, decodeOnly: false, pipelinedHint: true), 256)
        // One token per step where the graph takes one, as before.
        XCTAssertEqual(CoreAIPrefill.width(route: .sequential, decodeOnly: true, pipelinedHint: false), 1)
        XCTAssertEqual(CoreAIPrefill.width(route: .pipelinedPrimed, decodeOnly: false, pipelinedHint: true), 1)
        // Core AI's own choice elsewhere.
        XCTAssertNil(CoreAIPrefill.width(route: .pipelinedPrimed, decodeOnly: false, pipelinedHint: false))
        XCTAssertNil(CoreAIPrefill.width(route: .runtimeGrammar, decodeOnly: false, pipelinedHint: false))
        XCTAssertNil(CoreAIPrefill.width(route: .staticShape, decodeOnly: false, pipelinedHint: false))
    }

    func testFreshEngineOnlyAfterMeasuredGrowth() {
        // The Mac lab's 1,024-wide read: settled at ~1.0 GB, a later part
        // peaked at 2.4 GB — a fresh engine before the next part.
        XCTAssertTrue(CoreAIFootprint.needsFreshEngine(settled: 1_000, now: 2_359))
        // The 256-wide read: peaks within ~0.3 GB of where it settled.
        XCTAssertFalse(CoreAIFootprint.needsFreshEngine(settled: 984, now: 1_163))
        // Nothing to compare yet (first part) or nothing measured.
        XCTAssertFalse(CoreAIFootprint.needsFreshEngine(settled: nil, now: 5_000))
        XCTAssertFalse(CoreAIFootprint.needsFreshEngine(settled: 1_000, now: 0))
        XCTAssertFalse(CoreAIFootprint.needsFreshEngine(settled: 0, now: 3_000))
    }

    func testFootprintIsMeasured() {
        XCTAssertGreaterThan(CoreAIFootprint.megabytes(), 0)
    }

    func testCrashNoteSaysTheFootprintAtTheLastStep() {
        let note = CoreAIInFlight.Note(id: "qwen3-4b", name: "Qwen3 4B", episode: "guid-1",
                                       stage: "part 4 of 6 · about 1679 prompt tokens read · writing classification · 7 tokens",
                                       freeMB: 5_273, footprintMB: 1_420, graphicsMB: 2_610)
        let text = CoreAIInFlight.launchNote(note)
        XCTAssertTrue(text.contains("writing classification · 7 tokens"))
        XCTAssertTrue(text.contains("PodSkipper was using 1420 MB (graphics 2610 MB) at the last step noted"))
        XCTAssertTrue(text.contains("about 5273 MB more"))
    }
}

/// Pass 54: Basic/Hard checked kind by kind, re-scoring answers his phone
/// stored.
final class Pass54BenchChecksTests: XCTestCase {
    private func cuts(_ parts: [(String, ClosedRange<Int>)]) -> [Int: BenchSample.Category?] {
        var out: [Int: BenchSample.Category?] = [:]
        for (kind, lines) in parts { for line in lines where out[line] == nil { out[line] = BenchSample.Category(kind: kind) } }
        return out
    }

    // Pass 62: the three tests that re-scored his phone's answers on the
    // version 2 samples' lines are replaced by Pass62BenchTests (version 3:
    // new samples, the PodSkipper Test's score).

    func testChecksSurviveSavingAndOldResultsStillLoad() throws {
        var result = BenchResult(engine: "apple", name: "Apple Intelligence", sample: .hard, date: .now, score: 0.5)
        result.checks = BenchSample.hard.checks(cut: cuts([("ad", 19...24)]))
        let data = try JSONEncoder().encode(result)
        let back = try JSONDecoder().decode(BenchResult.self, from: data)
        XCTAssertEqual(back.checks, result.checks)
        // A version 1 record has no checks and isn't ranked with version 2.
        var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        old.removeValue(forKey: "checks")
        old["sampleVersion"] = 1
        let earlier = try JSONDecoder().decode(BenchResult.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(earlier.checks)
        XCTAssertFalse(earlier.isComparable)
    }
}

/// Pass 54: syncing through his Cloudflare storage when the two devices'
/// copies name different iCloud stores.
final class Pass54RelaySyncTests: XCTestCase {
    /// The bucket, in memory.
    actor Bucket: RelayTransport {
        var files: [String: Data] = [:]
        func put(_ data: Data, name: String) async throws { files[name] = data }
        func get(name: String) async throws -> Data? { files[name] }
        func names() async throws -> [String] { Array(files.keys) }
        func tamper(_ name: String) { files[name] = Data("not sealed".utf8) }
    }

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000)
        func tick(_ s: Double = 1) { now += s }
    }

    private func pair() -> (Bucket, SyncRelaySetup, Clock, RelayStore, RelayStore) {
        let bucket = Bucket(), setup = SyncRelaySetup.new(credentials: nil), clock = Clock()
        let phone = RelayStore(transport: bucket, key: setup.sealKey, deviceID: "phone", file: nil, clock: { clock.now })
        let pad = RelayStore(transport: bucket, key: setup.sealKey, deviceID: "pad", file: nil, clock: { clock.now })
        return (bucket, setup, clock, phone, pad)
    }

    func testWhatOneDeviceWritesReachesTheOther() async throws {
        let (_, _, clock, phone, pad) = pair()
        phone.set([["feed": "https://a/feed", "title": "A"]], forKey: "shows.v1")
        phone.setData(Data("positions".utf8), forKey: "listening.v2")
        try await phone.send(kind: "iPhone")
        clock.tick()
        let changed = try await pad.receive()
        XCTAssertEqual(changed, ["shows.v1", "listening.v2"])
        XCTAssertEqual((pad.array(forKey: "shows.v1") as? [[String: String]])?.first?["title"], "A")
        XCTAssertEqual(pad.data(forKey: "listening.v2"), Data("positions".utf8))
        XCTAssertEqual(pad.devices["phone"]?.kind, "iPhone")
    }

    func testTheNewestWriteOfEachKeyWinsAndOlderOnesDont() async throws {
        let (_, _, clock, phone, pad) = pair()
        phone.set("old", forKey: "k")
        try await phone.send(kind: "iPhone")
        clock.tick()
        pad.set("new", forKey: "k")          // later, on the iPad
        try await pad.send(kind: "iPad")
        clock.tick()
        try await phone.receive()
        XCTAssertEqual(phone.object(forKey: "k") as? String, "new")
        // The phone's older value doesn't come back on the iPad.
        try await phone.send(kind: "iPhone")
        let back = try await pad.receive()
        XCTAssertTrue(back.isEmpty)
        XCTAssertEqual(pad.object(forKey: "k") as? String, "new")
        // A removal is a write too.
        clock.tick()
        phone.set(nil, forKey: "k")
        try await phone.send(kind: "iPhone")
        try await pad.receive()
        XCTAssertNil(pad.object(forKey: "k"))
        XCTAssertNil(pad.dictionaryRepresentation["k"])
    }

    func testOnlyTheSameSetupCanReadIt() async throws {
        let (bucket, _, _, phone, _) = pair()
        phone.set("secret", forKey: "k")
        try await phone.send(kind: "iPhone")
        let stranger = RelayStore(transport: bucket, key: SyncRelaySetup.new(credentials: nil).sealKey,
                                  deviceID: "other", file: nil)
        do {
            try await stranger.receive()
            XCTFail("a file sealed with another secret was read")
        } catch {}
        XCTAssertNil(stranger.object(forKey: "k"))
        // What's stored isn't readable as text.
        let sealed = try await bucket.get(name: "phone.sealed")
        XCTAssertNil(String(data: sealed ?? Data(), encoding: .utf8)?.range(of: "secret"))
    }

    func testSetupTextRoundTripsAndNamesAPrivateFolder() {
        let credentials = R2Uploader.Credentials(accountID: "acct", accessKeyID: "key", secretAccessKey: "s3cr3t",
                                                 bucket: "pods", publicBaseURL: "https://pods.example")
        let setup = SyncRelaySetup.new(credentials: credentials)
        let back = SyncRelaySetup(text: setup.text)
        XCTAssertEqual(back, setup)
        XCTAssertEqual(back?.folder, setup.folder)
        XCTAssertTrue(setup.folder.hasPrefix("sync/") && setup.folder.count == 5 + 32 + 1)
        XCTAssertNotEqual(SyncRelaySetup.new(credentials: nil).folder, setup.folder)
        XCTAssertNil(SyncRelaySetup(text: "hello"))
        XCTAssertNil(SyncRelaySetup(text: SyncRelaySetup.prefix + "AAAA"))
        XCTAssertNotNil(SyncRelaySetup(text: "  " + setup.text + "\n"))
    }

    func testCloudRecordsMergeThroughTheRelay() async throws {
        // The records layer (settings, bookmarks, corrections, found ads)
        // reads and writes the relay exactly as it does iCloud's store.
        let (_, _, clock, phone, pad) = pair()
        let stamped = ["e1": CloudRecords.Stamped(at: clock.now, value: "12.5")]
        phone.setData(try JSONEncoder().encode(stamped), forKey: "records.cuts")
        try await phone.send(kind: "iPhone")
        try await pad.receive()
        let read = try JSONDecoder().decode([String: CloudRecords.Stamped<String>].self,
                                            from: XCTUnwrap(pad.data(forKey: "records.cuts")))
        XCTAssertEqual(read["e1"]?.value, "12.5")
    }

    func testTheStoreSurvivesARelaunch() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "relay-\(UUID().uuidString)/store.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let setup = SyncRelaySetup.new(credentials: nil)
        let first = RelayStore(transport: Bucket(), key: setup.sealKey, deviceID: "phone", file: file)
        first.set(["a": 1.5], forKey: "unfollowed.v2")
        let again = RelayStore(transport: Bucket(), key: setup.sealKey, deviceID: "phone", file: file)
        XCTAssertEqual(again.dictionary(forKey: "unfollowed.v2") as? [String: Double], ["a": 1.5])
    }
}
