import XCTest
@testable import PodSkipper

@MainActor
final class AppleCatalogRequestTests: XCTestCase {
    private enum Failure: Error { case offline }
    private nonisolated static func page(_ id: String, next: String? = nil) -> [String: Any] {
        var page: [String: Any] = ["data": [["id": id, "attributes": ["guid": id, "name": id]]]]
        if let next { page["next"] = next }
        return page
    }
    func testSuccessfulPagesPreserveOrderAndEmptyCatalogueIsValid() async throws {
        var paths: [String] = []
        let items = try await AppleCatalog.checkedEpisodes(showID: 123, fetchPage: { path in
            paths.append(path)
            return Self.page(paths.count == 1 ? "first" : "second", next: paths.count == 1 ? "/next?offset=300" : nil)
        })
        XCTAssertEqual(items.map(\.guid), ["first", "second"])
        XCTAssertEqual(paths.last, "/next?offset=300&limit=300")
        let empty = try await AppleCatalog.checkedEpisodes(showID: 123, fetchPage: { _ in ["data": [] as [[String: Any]]] })
        XCTAssertTrue(empty.isEmpty)
    }
    func testLaterPageFailureDoesNotReturnPartialCatalogue() async throws {
        var requests = 0
        do {
            _ = try await AppleCatalog.checkedEpisodes(showID: 123, fetchPage: { _ in
                requests += 1
                if requests == 2 { throw Failure.offline }
                return Self.page("first", next: "/next?offset=300")
            })
            XCTFail()
        } catch is Failure { }
        XCTAssertEqual(requests, 2)
    }
    func testMalformedDataItemsAndNextLinksFailInsteadOfDroppingData() async throws {
        for page: [String: Any] in [[:], ["data": "wrong"], ["data": [["id": "missing-attributes"]]],
                                    ["data": [] as [[String: Any]], "next": "https://example.invalid/page"]] {
            do { _ = try await AppleCatalog.checkedEpisodes(showID: 123, fetchPage: { _ in page }); XCTFail() }
            catch is AppleCatalog.CatalogError { }
        }
    }
    func testPageLimitAndRepeatedNextLinkRemainIncomplete() async throws {
        do {
            _ = try await AppleCatalog.checkedEpisodes(showID: 123, maxPages: 1,
                fetchPage: { _ in Self.page("first", next: "/next") })
            XCTFail()
        } catch AppleCatalog.CatalogError.incomplete { }
        do {
            _ = try await AppleCatalog.checkedEpisodes(showID: 123,
                fetchPage: { path in Self.page("first", next: path) })
            XCTFail()
        } catch AppleCatalog.CatalogError.incomplete { }
    }
    func testCancellationImmediatelyAfterResponseDoesNotReturnCatalogue() async throws {
        let task = Task.detached {
            try await AppleCatalog.checkedEpisodes(showID: 123, fetchPage: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return Self.page("first")
            })
        }
        do { _ = try await task.value; XCTFail() } catch is CancellationError { }
    }
}
