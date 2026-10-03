import XCTest
@testable import PodSkipper

@MainActor
final class DiscoverLookupTests: XCTestCase {
    nonisolated private func response(_ url: URL, ids: [Int], status: Int = 200) throws -> (Data, URLResponse) {
        let rows = ids.map { ["collectionId": $0, "collectionName": "Show \($0)",
                            "feedUrl": "https://example.invalid/\($0).xml"] as [String: Any] }
        return (try JSONSerialization.data(withJSONObject: ["results": rows]),
            try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }

    nonisolated private func ids(in url: URL) throws -> [Int] {
        let value = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "id" })?.value)
        return value.split(separator: ",").compactMap { Int($0) }
    }

    func testBatchedResultsKeepRequestedRankingWithoutDuplicateRequestsOrRows() async throws {
        let wanted = Array(1...27)
        var batches = [[Int]]()
        let result = try await DiscoverService.lookup(ids: wanted + [1, 27, 1]) { [self] url in
            let ids = try ids(in: url)
            batches.append(ids)
            return try response(url, ids: ids.reversed() + [ids[0]])
        }
        XCTAssertEqual(batches.map(\.count), [25, 2])
        XCTAssertEqual(batches.flatMap { $0 }, wanted)
        XCTAssertEqual(result.map(\.id), wanted)
    }

    func testEmptyRequestAndSuccessfulEmptyResponseAreGenuineEmptyResults() async throws {
        var requests = 0
        let empty = try await DiscoverService.lookup(ids: []) { _ in
            requests += 1; throw URLError(.badURL)
        }
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(requests, 0)
        let absent = try await DiscoverService.lookup(ids: [1]) { [self] url in
            requests += 1
            return try response(url, ids: [])
        }
        XCTAssertTrue(absent.isEmpty)
        XCTAssertEqual(requests, 1)
    }

    func testTransportFailureIsNotConvertedIntoEmptyResultsOrFollowedByAnotherChunk() async {
        var requests = 0
        do {
            _ = try await DiscoverService.lookup(ids: Array(1...51)) { _ in
                requests += 1; throw URLError(.notConnectedToInternet)
            }
            XCTFail("Transport failure must reach the caller")
        } catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(requests, 1)
    }

    func testFailedSecondChunkDoesNotReturnAnIncompleteSuccess() async {
        var requests = 0
        do {
            _ = try await DiscoverService.lookup(ids: Array(1...51)) { [self] url in
                requests += 1
                if requests == 2 { throw URLError(.timedOut) }
                return try response(url, ids: ids(in: url))
            }
            XCTFail("Partial directory data must not be reported as complete")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(requests, 2)
    }

    func testHTTPFailureIsRejectedEvenWithDecodableResults() async {
        for status in [401, 429, 503] {
            do {
                _ = try await DiscoverService.lookup(ids: [1]) { [self] url in try response(url, ids: [1], status: status) }
                XCTFail("HTTP failure must reach retry UI")
            } catch DiscoverService.DiscoverError.httpStatus(let code) { XCTAssertEqual(code, status) }
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testMalformedResponseThrowsWhileUnavailableRowsRemainLegitimateEmpty() async throws {
        for body in ["not JSON", "{}", "{\"results\":{}}"] {
            do {
                _ = try await DiscoverService.lookup(ids: [1]) { [self] url in
                    let (_, http) = try response(url, ids: [])
                    return (Data(body.utf8), http)
                }
                XCTFail("Malformed response must not become an empty success")
            } catch is DecodingError { } catch { XCTFail("Unexpected error: \(error)") }
        }
        let unavailable = try await DiscoverService.lookup(ids: [1]) { [self] url in
            let (_, http) = try response(url, ids: [])
            return (Data("{\"results\":[{\"collectionId\":1},{\"feedUrl\":\"\"}]}".utf8), http)
        }
        XCTAssertTrue(unavailable.isEmpty)
    }

    func testNonHTTPResponseAndInvalidIDsDoNotBecomeSuccessfulDirectoryData() async {
        do {
            _ = try await DiscoverService.lookup(ids: [1]) { url in
                (Data("{\"results\":[]}".utf8), URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
            }
            XCTFail("Lookup requires an HTTP response")
        } catch DiscoverService.DiscoverError.unexpectedResponse { } catch { XCTFail("Unexpected error: \(error)") }
        for ids in [[0], [-1], [1, 0]] {
            do {
                _ = try await DiscoverService.lookup(ids: ids) { _ in XCTFail("Invalid ID must not be sent"); throw URLError(.badURL) }
                XCTFail("Invalid IDs must be reported")
            } catch DiscoverService.DiscoverError.badRequest { } catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testCancellationAfterResponseStopsBeforeAnotherChunkOrPublishingResults() async {
        let started = expectation(description: "Lookup request started")
        var finish: CheckedContinuation<Void, Never>?
        var requests = 0
        let task = Task { @MainActor [self] in
            try await DiscoverService.lookup(ids: Array(1...26)) { [self] url in
                requests += 1
                await withCheckedContinuation { finish = $0; started.fulfill() }
                return try response(url, ids: ids(in: url))
            }
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        finish?.resume()
        do { _ = try await task.value; XCTFail("A late response must not become success") }
        catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(requests, 1)
    }

    func testLookupFailureKeepsCatalogSnapshotAndRetryReplacesIt() async {
        let loader = CatalogLoader<PodcastSearchResult>()
        await loader.load { [self] in
            try await DiscoverService.lookup(ids: [1]) { [self] url in try response(url, ids: [1]) }
        }
        await loader.load {
            try await DiscoverService.lookup(ids: [2]) { _ in throw URLError(.notConnectedToInternet) }
        }
        XCTAssertEqual(loader.items.map(\.id), [1])
        XCTAssertNotNil(loader.failure)
        await loader.load { [self] in
            try await DiscoverService.lookup(ids: [2]) { [self] url in try response(url, ids: [2]) }
        }
        XCTAssertEqual(loader.items.map(\.id), [2])
        XCTAssertNil(loader.failure)
        XCTAssertEqual(loader.state, .loaded)
    }

    func testShowChartUsesSameCheckedTransportForChartAndRankedLookup() async throws {
        var paths = [String]()
        let shows = try await DiscoverService.topShows(genre: 1303, limit: 2) { [self] url in
            paths.append(url.path)
            if url.path == "/lookup" { return try response(url, ids: [1, 2]) }
            let (_, http) = try response(url, ids: [])
            let body = "{\"feed\":{\"entry\":[{\"id\":{\"attributes\":{\"im:id\":\"2\"}}},{\"id\":{\"attributes\":{\"im:id\":\"1\"}}}]}}"
            return (Data(body.utf8), http)
        }
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(paths.last, "/lookup")
        XCTAssertEqual(shows.map(\.id), [2, 1])
    }

    func testShowAndEpisodeChartsAndSearchRejectHTTPFailureEvenWithEmptyShapedJSON() async {
        let request: DiscoverService.Request = { [self] url in
            let (_, http) = try response(url, ids: [], status: 503)
            return (Data("{\"feed\":{\"entry\":[],\"results\":[]},\"results\":[]}".utf8), http)
        }
        let actions: [() async throws -> Void] = [
            { _ = try await DiscoverService.topShows(request: request) },
            { _ = try await DiscoverService.topEpisodes(request: request) },
            { _ = try await DiscoverService.searchEpisodes("episode", request: request) }
        ]
        for action in actions {
            do { try await action(); XCTFail("A server failure must not become empty results") }
            catch DiscoverService.DiscoverError.httpStatus(let code) { XCTAssertEqual(code, 503) }
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testAllEntryPointsAcceptGenuineEmptyAndBlankSearchDoesNotSendRequest() async throws {
        var requests = 0
        let request: DiscoverService.Request = { [self] url in
            requests += 1
            let (_, http) = try response(url, ids: [])
            return (Data("{\"feed\":{\"entry\":[],\"results\":[]},\"results\":[]}".utf8), http)
        }
        let shows = try await DiscoverService.topShows(request: request)
        let episodes = try await DiscoverService.topEpisodes(request: request)
        let found = try await DiscoverService.searchEpisodes("episode", request: request)
        let blank = try await DiscoverService.searchEpisodes("   \n", request: request)
        XCTAssertTrue(shows.isEmpty && episodes.isEmpty && found.isEmpty && blank.isEmpty)
        XCTAssertEqual(requests, 3)
    }
}
