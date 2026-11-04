import XCTest
@testable import PodSkipper

/// Pass 57: the Reader's readers are loaded when a reading needs them and let
/// go when nothing has read for a while.
final class Pass57ReaderCacheTests: XCTestCase {
    func testBackToBackReadingsLoadTheReadersOnce() {
        let cache = ReaderCache()
        var built = 0
        for _ in 0..<5 { _ = cache.readers { built += 1; return [] } }
        XCTAssertEqual(built, 1)
        XCTAssertEqual(cache.loads, 1)
        XCTAssertTrue(cache.isHolding)
    }

    func testIdleReadersAreLetGoAndLoadedAgainWhenNeeded() {
        let cache = ReaderCache()
        _ = cache.readers { [] }
        cache.releaseIfIdle(after: 60, now: Date().addingTimeInterval(30))
        XCTAssertTrue(cache.isHolding, "30 s after a reading they're still held")
        cache.releaseIfIdle(after: 60, now: Date().addingTimeInterval(61))
        XCTAssertFalse(cache.isHolding)
        _ = cache.readers { [] }
        XCTAssertEqual(cache.loads, 2)
    }

    func testAReadingKeepsItsReadersWhileTheCacheLetsGo() throws {
        guard let url = SentenceTagger.weightURLs.first, let reader = SentenceTagger(url: url) else {
            throw XCTSkip("no reader in this build")
        }
        let cache = ReaderCache()
        let readers = cache.readers { [reader] }
        cache.releaseIfIdle(after: 0, now: Date().addingTimeInterval(1))
        XCTAssertFalse(cache.isHolding)
        let sentences = [Sentence(text: "This episode is brought to you by Odeon Coffee.", start: 0, end: 3),
                         Sentence(text: "Anyway, back to the story.", start: 3.2, end: 5)]
        let p = readers[0].probabilities(sentences)
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[0].reduce(0, +), 1, accuracy: 1e-6)
    }

    func testEveryBundledReaderLoadsAndIsItsOwn() {
        let identities = SentenceTagger.identities()
        XCTAssertGreaterThanOrEqual(identities.count, 2, "TaggerWeights.bin and TaggerWeights-2.bin at least")
        XCTAssertEqual(Set(identities).count, identities.count, "no reader is bundled twice")
        XCTAssertEqual(SentenceTagger.ensemble.count, identities.count, "every bundled reader loads")
    }
}
