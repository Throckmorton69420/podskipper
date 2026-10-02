import XCTest
@testable import PodSkipper

final class AdFreeCopyTests: XCTestCase {
    func testBracketedInteriorInsertionKeepsExactDAI() async throws {
        let reference = MP3ComparisonFixture.audio(Array(0..<2400))
        let local = MP3ComparisonFixture.audio(Array(0..<1100) + Array(10_000..<10_120) + Array(1100..<2400))
        let (spans, outcome) = try await compare(local, reference)
        XCTAssertEqual(spans.count, 1)
        assertSpan(try XCTUnwrap(spans.first), first: 1100, last: 1220)
        XCTAssertNil(outcome.terminalCandidates)
        XCTAssertEqual(outcome.policyVersion, AdFreeCopy.comparisonPolicyVersion)
        XCTAssertGreaterThan(outcome.requests, 64)
        XCTAssertLessThan(outcome.bytes, reference.count)
    }

    func testPreAndPostRollRemainUnclassifiedWhileMidRollIsConfirmed() async throws {
        let reference = MP3ComparisonFixture.audio(Array(0..<2400))
        let local = MP3ComparisonFixture.audio(Array(20_000..<20_070) + Array(0..<1100)
            + Array(10_000..<10_120) + Array(1100..<2400) + Array(30_000..<30_080))
        let (spans, outcome) = try await compare(local, reference)
        XCTAssertEqual(spans.count, 1)
        assertSpan(try XCTUnwrap(spans.first), first: 1170, last: 1290)
        let terminal = try XCTUnwrap(outcome.terminalCandidates)
        XCTAssertEqual(terminal.count, 2)
        assertSpan(terminal[0], first: 0, last: 70)
        assertSpan(terminal[1], first: 2590, last: 2670)
        XCTAssertTrue(outcome.note.contains("kept for classification"))
    }

    func testShortenedPrefixAndSuffixNeverBecomeConfidentCuts() async throws {
        let local = MP3ComparisonFixture.audio(Array(0..<2400))
        for ids in [Array(0..<1800), Array(600..<2400)] {
            let (spans, outcome) = try await compare(local, MP3ComparisonFixture.audio(ids))
            XCTAssertTrue(spans.isEmpty)
            XCTAssertEqual(outcome.terminalCandidates?.count, 1)
            XCTAssertTrue(outcome.note.contains("shorter edit"))
        }
    }

    func testDifferentEpisodeSparseMatchingAndReorderedAudioAreRejected() async throws {
        let local = MP3ComparisonFixture.audio(Array(0..<2600))
        let references = [
            Array(50_000..<52_400),
            Array(0..<300) + Array(50_000..<51_800) + Array(2300..<2600),
            Array(0..<700) + Array(1400..<2100) + Array(700..<1400) + Array(2100..<2400)
        ]
        for ids in references {
            do {
                _ = try await compare(local, MP3ComparisonFixture.audio(ids))
                XCTFail("An unrelated, sparse, or reordered comparison must not yield cuts")
            } catch let error as AdFreeCopy.ProbeError {
                XCTAssertTrue([.insufficientMatch, .differentEdit].contains(error))
            }
        }
    }

    func testVariableBitrateID3AndRewrittenXingMetadataKeepInteriorAlignment() async throws {
        let refIDs = Array(0..<2400)
        let localIDs = Array(0..<1100) + Array(10_000..<10_120) + Array(1100..<2400)
        let reference = MP3ComparisonFixture.audio(refIDs, variableBitrate: true, tagBytes: 200, xingCount: 2400)
        let local = MP3ComparisonFixture.audio(localIDs, variableBitrate: true, tagBytes: 30, xingCount: 2520)
        let (spans, outcome) = try await compare(local, reference)
        XCTAssertEqual(spans.count, 1)
        // The parser's timeline includes the leading metadata frame in both copies.
        assertSpan(try XCTUnwrap(spans.first), first: 1101, last: 1221)
        XCTAssertNil(outcome.terminalCandidates)
    }

    func testInvalidHTTPRangesAreRejectedWithoutRetries() async throws {
        for mode in [MP3RangeServer.Mode.ignoredRange, .wrongOffset, .shortBody, .notFound, .encoded] {
            let server = MP3RangeServer(body: MP3ComparisonFixture.audio(Array(0..<2400)), mode: mode)
            defer { server.close() }
            var outcome = AdFreeCopy.Outcome()
            do {
                _ = try await AdFreeCopy.probe(local: localFrames(), localBytes: 2520 * 417,
                    reference: server.url, session: server.session, outcome: &outcome)
                XCTFail("Invalid range response was accepted: \(mode)")
            } catch let error as AdFreeCopy.ProbeError {
                XCTAssertEqual(error, .invalidRange)
            }
            XCTAssertEqual(server.requestCount, 1)
            XCTAssertEqual(outcome.requests, 1)
        }
    }

    func testChangingSizeOrEntityRejectsAllEvidence() async throws {
        for mode in [MP3RangeServer.Mode.changedSize, .changedEntity] {
            let server = MP3RangeServer(body: MP3ComparisonFixture.audio(Array(0..<2400)), mode: mode)
            defer { server.close() }
            var outcome = AdFreeCopy.Outcome()
            do {
                _ = try await AdFreeCopy.probe(local: localFrames(), localBytes: 2520 * 417,
                    reference: server.url, session: server.session, outcome: &outcome)
                XCTFail("Changing reference accepted")
            } catch let error as AdFreeCopy.ProbeError {
                XCTAssertEqual(error, .changedReference)
            }
            XCTAssertEqual(server.requestCount, 2)
            XCTAssertNil(outcome.terminalCandidates)
        }
    }

    func testCancelledTransportDoesNotRetry() async throws {
        let server = MP3RangeServer(body: MP3ComparisonFixture.audio(Array(0..<2400)), mode: .cancelled)
        defer { server.close() }
        var outcome = AdFreeCopy.Outcome()
        do {
            _ = try await AdFreeCopy.probe(local: localFrames(), localBytes: 2520 * 417,
                reference: server.url, session: server.session, outcome: &outcome)
            XCTFail("Cancellation should throw")
        } catch is CancellationError { }
        XCTAssertEqual(server.requestCount, 1)
    }

    func testCancellingInFlightRequestStopsWithoutAnotherRange() async throws {
        let started = expectation(description: "Request in flight")
        let server = MP3RangeServer(body: MP3ComparisonFixture.audio(Array(0..<2400)), mode: .held,
                                    onRequest: { started.fulfill() })
        defer { server.close() }
        let frames = localFrames()
        let task = Task {
            var outcome = AdFreeCopy.Outcome()
            return try await AdFreeCopy.probe(local: frames, localBytes: 2520 * 417,
                reference: server.url, session: server.session, outcome: &outcome)
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request completed") }
        catch is CancellationError { }
        XCTAssertEqual(server.requestCount, 1)
    }

    func testLegacyOutcomesDecodeButUnsafeCachedSpansNeverBecomeCertain() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AdFreeCopy.Outcome())) as? [String: Any])
        object.removeValue(forKey: "policyVersion")
        object.removeValue(forKey: "terminalCandidates")
        object["inserted"] = [["start": 10, "end": 20]]
        let legacy = try JSONDecoder().decode(AdFreeCopy.Outcome.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.policyVersion)
        XCTAssertEqual(legacy.inserted.count, 1)
        XCTAssertTrue(AdFreeCopy.trustedInserted(legacy.inserted, policyVersion: legacy.policyVersion, duration: 100).isEmpty)
        let current = AdFreeCopy.comparisonPolicyVersion
        XCTAssertEqual(AdFreeCopy.trustedInserted(legacy.inserted, policyVersion: current, duration: 100), legacy.inserted)
        for spans in [[InsertedSpan(start: 0, end: 10)], [.init(start: 90, end: 100)],
                      [.init(start: .nan, end: 10)], [.init(start: 5, end: .infinity)],
                      [.init(start: 30, end: 20)], [.init(start: 10, end: 30), .init(start: 20, end: 40)]] {
            XCTAssertTrue(AdFreeCopy.trustedInserted(spans, policyVersion: current, duration: 100).isEmpty)
        }
        XCTAssertNotNil(AdFreeCopy.implausible([.init(start: 0, end: .infinity)], duration: 100))
        XCTAssertNotNil(AdFreeCopy.implausible([.init(start: 0, end: .greatestFiniteMagnitude)],
                                              duration: .greatestFiniteMagnitude))
    }

    private func localFrames() -> AdFreeCopy.Frames {
        MP3ComparisonFixture.audio(Array(0..<1100) + Array(10_000..<10_120) + Array(1100..<2400))
            .withUnsafeBytes { AdFreeCopy.frames(in: $0) }
    }
    private func compare(_ local: Data, _ reference: Data) async throws -> ([InsertedSpan], AdFreeCopy.Outcome) {
        let server = MP3RangeServer(body: reference)
        defer { server.close() }
        var outcome = AdFreeCopy.Outcome()
        let spans = try await AdFreeCopy.probe(local: local.withUnsafeBytes { AdFreeCopy.frames(in: $0) },
            localBytes: local.count, reference: server.url, session: server.session, outcome: &outcome)
        return (spans, outcome)
    }
    private func assertSpan(_ span: InsertedSpan, first: Int, last: Int, file: StaticString = #filePath, line: UInt = #line) {
        let seconds = 1152.0 / 44100
        XCTAssertEqual(span.start, Double(first) * seconds, accuracy: 3 * seconds, file: file, line: line)
        XCTAssertEqual(span.end, Double(last) * seconds, accuracy: 3 * seconds, file: file, line: line)
    }
}

/// Complete deterministic MPEG headers and distinct payloads. The payload need
/// not decode to sound: these tests exercise frame alignment rather than DSP.
private enum MP3ComparisonFixture {
    static func audio(_ ids: [Int], variableBitrate: Bool = false, tagBytes: Int = 0, xingCount: Int? = nil) -> Data {
        var data = Data()
        if tagBytes > 0 {
            data.append(contentsOf: [0x49, 0x44, 0x33, 3, 0, 0,
                UInt8((tagBytes >> 21) & 127), UInt8((tagBytes >> 14) & 127),
                UInt8((tagBytes >> 7) & 127), UInt8(tagBytes & 127)])
            data.append(Data(repeating: 0, count: tagBytes))
        }
        if let xingCount {
            var frame = [UInt8](repeating: 0, count: 417)
            frame.replaceSubrange(0..<4, with: [0xFF, 0xFB, 0x90, 0])
            frame.replaceSubrange(36..<40, with: [0x58, 0x69, 0x6E, 0x67])
            frame[45] = UInt8(xingCount & 255)
            frame[46] = UInt8((xingCount >> 8) & 255)
            data.append(contentsOf: frame)
        }
        for id in ids {
            let large = variableBitrate && id % 2 == 1
            let length = large ? 522 : 417
            var frame = [UInt8](repeating: 0, count: length)
            frame.replaceSubrange(0..<4, with: [0xFF, 0xFB, large ? 0xA0 : 0x90, 0])
            var random = UInt64(id + 1) &* 0x9e3779b97f4a7c15
            for i in 4..<length {
                random ^= random >> 12; random ^= random << 25; random ^= random >> 27
                frame[i] = UInt8(truncatingIfNeeded: random &* 0x2545F4914F6CDD1D)
            }
            data.append(contentsOf: frame)
        }
        return data
    }
}

/// Every test has an independent URL/session/body. No live network is involved.
private final class MP3RangeServer: @unchecked Sendable {
    enum Mode { case normal, ignoredRange, wrongOffset, shortBody, notFound, encoded, changedSize, changedEntity, cancelled, held }
    let body: Data
    let mode: Mode
    let url = URL(string: "https://adfree.test/" + UUID().uuidString)!
    let session: URLSession
    let onRequest: (() -> Void)?
    private let lock = NSLock()
    private var count = 0
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    init(body: Data, mode: Mode = .normal, onRequest: (() -> Void)? = nil) {
        self.body = body; self.mode = mode; self.onRequest = onRequest
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MP3RangeProtocol.self]
        session = URLSession(configuration: config)
        MP3RangeProtocol.register(self)
    }
    func close() { session.invalidateAndCancel(); MP3RangeProtocol.remove(self) }
    func response(to request: URLRequest) -> (HTTPURLResponse, Data)? {
        lock.lock(); count += 1; let number = count; lock.unlock()
        onRequest?()
        if mode == .held { return nil }
        let bounds = request.value(forHTTPHeaderField: "Range")!.dropFirst(6).split(separator: "-").map { Int($0)! }
        let lower = bounds[0], upper = bounds[1]
        var data = Data(body[lower...upper])
        var headers = ["Content-Range": "bytes \(lower)-\(upper)/\(body.count)", "ETag": "stable"]
        var status = 206
        switch mode {
        case .ignoredRange: status = 200; data = body
        case .wrongOffset: headers["Content-Range"] = "bytes \(lower + 1)-\(upper + 1)/\(body.count)"
        case .shortBody: data.removeLast()
        case .notFound: status = 404
        case .encoded: headers["Content-Encoding"] = "gzip"
        case .changedSize: if number > 1 { headers["Content-Range"] = "bytes \(lower)-\(upper)/\(body.count + 1)" }
        case .changedEntity: if number > 1 { headers["ETag"] = "changed" }
        default: break
        }
        return (HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, data)
    }
}
private final class MP3RangeProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var servers: [URL: MP3RangeServer] = [:]
    static func register(_ server: MP3RangeServer) { lock.lock(); defer { lock.unlock() }; servers[server.url] = server }
    static func remove(_ server: MP3RangeServer) { lock.lock(); defer { lock.unlock() }; servers[server.url] = nil }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "adfree.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let server = Self.servers[request.url!]; Self.lock.unlock()
        guard let server else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return }
        if server.mode == .cancelled { _ = server.response(to: request); client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return }
        guard let (response, data) = server.response(to: request) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
