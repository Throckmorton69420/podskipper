import XCTest
@testable import PodSkipper

final class CoreAIModelDownloadTests: XCTestCase {
    func testCompleteStagingInstallsAtomicallyAndPreservesExistingCache() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.close() }
        try fixture.seedAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.final.path))
        try await fixture.run()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.final.appending(path: "metadata.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))
        XCTAssertEqual(fixture.server.requests, 1, "Complete files must not be fetched again.")
        let preserved = Data("preserve-existing-cache".utf8)
        try preserved.write(to: fixture.final.appending(path: "metadata.json"))
        try fixture.seedAll()
        try await fixture.run()
        XCTAssertEqual(try Data(contentsOf: fixture.final.appending(path: "metadata.json")), preserved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.path))
    }

    func testIncompleteOrDuplicateListingCannotPublishBundle() async throws {
        for listing in [
            #"{"siblings":[{"rfilename":"ios/metadata.json","size":2},{"rfilename":"ios/model.aimodel/weights.bin"}]}"#,
            #"{"siblings":[{"rfilename":"ios/metadata.json","size":2},{"rfilename":"ios/metadata.json","size":2}]}"#,
            #"{"siblings":[{"rfilename":"ios/metadata.json","size":2},{"rfilename":"ios/../escape","size":4}]}"#
        ] {
            let fixture = try DownloadFixture(listing: listing)
            defer { fixture.close() }
            try fixture.seedAll()
            do { try await fixture.run(); XCTFail("An invalid listing must fail") } catch { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.final.path))
        }
    }

    func testInterruptedDownloadKeepsCompletedFilesWithoutPublishingPartialBundle() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.close() }
        try fixture.seed("metadata.json", bytes: Data("{}".utf8))
        do { try await fixture.run(); XCTFail("The missing weight transfer must fail") } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.final.path))
        XCTAssertEqual(try Data(contentsOf: fixture.staging.appending(path: "metadata.json")), Data("{}".utf8))
        // A new downloader after relaunch reuses the completed files and only
        // publishes the directory once every pinned file is present.
        try fixture.seedAll()
        try await fixture.run()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.final.appending(path: "model.aimodel/weights.bin").path))
    }
}

private struct DownloadFixture {
    let root: URL
    let final: URL
    let staging: URL
    let server: ListingServer
    init(listing: String? = nil) throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        final = root.appending(path: "models/test/revision/ios")
        staging = final.deletingLastPathComponent().appending(path: ".podskipper-staging-ios")
        server = ListingServer(listing: listing)
    }
    func seed(_ path: String, bytes: Data) throws {
        let url = staging.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
    }
    func seedAll() throws {
        try seed("metadata.json", bytes: Data("{}".utf8))
        try seed("model.aimodel/weights.bin", bytes: Data([1, 2, 3, 4]))
    }
    func run() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ListingProtocol.self]
        try await CoreAIModelDownload(baseURL: server.base, configuration: config).download(
            repo: "models/test", revision: "revision", variant: "ios", final: final,
            allowCellular: false, progress: { _, _ in })
    }
    func close() { ListingProtocol.remove(server); try? FileManager.default.removeItem(at: root) }
}

private final class ListingServer: @unchecked Sendable {
    let base = URL(string: "https://" + UUID().uuidString.lowercased() + ".models.test")!
    private let lock = NSLock()
    private var count = 0
    private let listing: String
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    init(listing: String? = nil) {
        self.listing = listing ?? #"{"siblings":[{"rfilename":"ios/metadata.json","size":2},{"rfilename":"ios/model.aimodel/weights.bin","size":4}]}"#
        ListingProtocol.register(self)
    }
    func response(_ request: URLRequest) -> Data? {
        lock.lock(); count += 1; lock.unlock()
        guard request.url?.path.contains("/api/models/") == true else { return nil }
        return Data(listing.utf8)
    }
}
private final class ListingProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var servers: [String: ListingServer] = [:]
    static func register(_ server: ListingServer) { lock.lock(); defer { lock.unlock() }; servers[server.base.host!] = server }
    static func remove(_ server: ListingServer) { lock.lock(); defer { lock.unlock() }; servers[server.base.host!] = nil }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".models.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let server = Self.servers[request.url!.host!]; Self.lock.unlock()
        guard let data = server?.response(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
