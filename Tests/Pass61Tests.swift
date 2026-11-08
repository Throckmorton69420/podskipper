import XCTest
@testable import PodSkipper

/// Pass 61: his 7 Nov exports crashed on every build. An iOS report's call
/// stack is nested one level per frame; a deep one ran JSONSerialization's
/// recursive writer out of stack inside `Diagnostics.exportFile`.
final class Pass61DiagnosticsExportTests: XCTestCase {
    private var written: [URL] = []

    override func tearDown() {
        for url in written { try? FileManager.default.removeItem(at: url) }
        written = []
        super.tearDown()
    }

    /// A crash report whose one call stack is `frames` frames deep, shaped as MetricKit saves it.
    private func report(frames: Int) -> Data {
        var s = #"{"crashDiagnostics":[{"callStackTree":{"callStacks":[{"threadAttributed":true,"callStackRootFrames":["#
        s += String(repeating: #"{"address":4096,"binaryName":"PodSkipper","subFrames":["#, count: frames)
        s += #"{"address":4096,"binaryName":"PodSkipper"}"#
        s += String(repeating: "]}", count: frames)
        s += "]}]}}]}"
        return Data(s.utf8)
    }

    private func save(_ data: Data, at seconds: Int) throws {
        try FileManager.default.createDirectory(at: Diagnostics.folder, withIntermediateDirectories: true)
        let url = Diagnostics.folder.appending(path: "diagnostic-\(seconds).json")
        try data.write(to: url)
        written.append(url)
    }

    func testDeepReportExportsWithoutCrashing() async throws {
        let deep = report(frames: 30_000)
        XCTAssertEqual(RawJSON.depth(deep), 60_008)
        try save(deep, at: Int(Date.now.timeIntervalSince1970) - 60)
        let url = try await Diagnostics.exportFile(scope: Diagnostics.Scope(parts: [.crashes]))
        written.append(url)
        let out = try Data(contentsOf: url)
        XCTAssertNotNil(out.range(of: deep), "the report goes in exactly as saved")
        XCTAssertEqual(RawJSON.depth(out), 60_008 + 3, "root → metricKit array → entry → report")
        XCTAssertNil(out.range(of: Data("pk-metrickit-".utf8)))
    }

    func testShallowReportReadsAsBefore() async throws {
        let shallow = report(frames: 3)
        try save(shallow, at: Int(Date.now.timeIntervalSince1970) - 120)
        let url = try await Diagnostics.exportFile(scope: Diagnostics.Scope(parts: [.crashes]))
        written.append(url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let reports = try XCTUnwrap(root["metricKit"] as? [[String: Any]])
        let mine = try XCTUnwrap(reports.first { ($0["file"] as? String) == written[0].lastPathComponent })
        XCTAssertEqual(mine["kind"] as? String, "diagnostic")
        let expected = try JSONSerialization.jsonObject(with: shallow) as? NSDictionary
        XCTAssertEqual(mine["report"] as? NSDictionary, expected)
    }

    func testNoReportsGivesAnEmptyList() {
        let out = RawJSON.splice(Data(#"{"a" : "tok","b" : 1}"#.utf8), token: "tok", with: [])
        XCTAssertEqual(String(decoding: out, as: UTF8.self), #"{"a" : [],"b" : 1}"#)
    }

    func testDepthScanner() {
        XCTAssertEqual(RawJSON.depth(Data(#"{"a":"[{\"x"}"#.utf8)), 1, "brackets and quotes inside strings don't count")
        XCTAssertNil(RawJSON.depth(Data(#"{"a":[1}"#.utf8).dropLast()))
        XCTAssertNil(RawJSON.depth(Data(#"{"a":"open}"#.utf8)))
        XCTAssertFalse(RawJSON.isObject(Data("[1]".utf8)))
        XCTAssertTrue(RawJSON.isObject(Data(" \n{\"a\":1}".utf8)))
        XCTAssertFalse(RawJSON.isObject(Data("{\"a\":1".utf8)))
    }
}
