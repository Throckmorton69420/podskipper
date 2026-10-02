import XCTest
@testable import PodSkipper

@MainActor
final class AdPrintsLibraryTests: XCTestCase {
    private var directory: URL!
    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdPrintsLibraryTests-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        AdPrints.Library.folderOverride = directory
    }
    override func tearDown() {
        AdPrints.Library.folderOverride = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testLegacyPositiveIsQuarantinedWithoutRewritingItsHistoryOrFile() throws {
        let print = recording()
        let entry = legacyEntry()
        try write([entry], print: print)
        let beforeIndex = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        let beforeAudio = try Data(contentsOf: directory.appendingPathComponent(entry.id + ".lm"))
        XCTAssertTrue(AdPrints.Library.matches(in: print, excludingSource: "another-episode").isEmpty)
        let stored = try XCTUnwrap(AdPrints.Library.entries().first)
        XCTAssertTrue(stored.isQuarantined)
        XCTAssertNil(stored.provenance)
        XCTAssertEqual(stored.id, entry.id)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("index.json")), beforeIndex)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(entry.id + ".lm")), beforeAudio)
    }

    func testLegacyNegativeRemainsActiveAndAutomaticPositiveCannotUndoIt() throws {
        let print = recording()
        let entry = legacyEntry(negative: true)
        try write([entry], print: print)
        let matches = AdPrints.Library.matches(in: print)
        XCTAssertEqual(matches.count, 1)
        XCTAssertTrue(try XCTUnwrap(matches.first).negative)
        XCTAssertFalse(AdPrints.Library.add(print, show: "Other", source: "new", kind: "ad",
            provenance: .currentAutomatic, evidencePolicyVersion: AdPrints.Library.currentEvidencePolicyVersion))
        XCTAssertTrue(try XCTUnwrap(AdPrints.Library.entries().first).negative)
        XCTAssertTrue(AdPrints.Library.matches(in: print).allSatisfy(\.negative))
    }

    func testExplicitCorrectionSurvivesFutureOrMissingVersionAndAutomaticRefresh() throws {
        let print = recording()
        XCTAssertTrue(AdPrints.Library.add(print, show: "Show", source: "confirmed", kind: "crossPromo",
            provenance: .userCorrection, evidencePolicyVersion: 999))
        XCTAssertFalse(AdPrints.Library.add(print, show: "Show", source: "automatic", kind: "ad",
            provenance: .currentAutomatic, evidencePolicyVersion: AdPrints.Library.currentEvidencePolicyVersion))
        let entry = try XCTUnwrap(AdPrints.Library.entries().first)
        XCTAssertEqual(entry.provenance, AdPrints.Library.Provenance.userCorrection.rawValue)
        XCTAssertEqual(entry.kind, "crossPromo")
        XCTAssertFalse(entry.isQuarantined)
        XCTAssertEqual(AdPrints.Library.matches(in: print).first?.kind, "crossPromo")
        XCTAssertTrue(AdPrints.Library.matches(in: print, excludingSource: "confirmed").isEmpty)
    }

    func testOnlyCurrentAutomaticPolicyMatchesAndLegacyCanBeRevalidatedInPlace() throws {
        let print = recording()
        let entry = legacyEntry()
        try write([entry], print: print)
        XCTAssertTrue(AdPrints.Library.matches(in: print).isEmpty)
        XCTAssertFalse(AdPrints.Library.add(print, show: "Show", source: "revalidated", kind: "ad",
            provenance: .currentAutomatic, evidencePolicyVersion: AdPrints.Library.currentEvidencePolicyVersion))
        let now = try XCTUnwrap(AdPrints.Library.entries().first)
        XCTAssertEqual(now.id, entry.id)
        XCTAssertEqual(now.added, entry.added)
        XCTAssertFalse(now.isQuarantined)
        XCTAssertEqual(AdPrints.Library.matches(in: print, excludingSource: "other").count, 1)
        XCTAssertTrue(AdPrints.Library.matches(in: print, excludingSource: "revalidated").isEmpty)
        var future = now
        future.evidencePolicyVersion = AdPrints.Library.currentEvidencePolicyVersion + 1
        try write([future], print: print)
        XCTAssertTrue(AdPrints.Library.matches(in: print).isEmpty)
        future.provenance = "unknown-future-provenance"
        try write([future], print: print)
        XCTAssertTrue(AdPrints.Library.matches(in: print).isEmpty)
        XCTAssertEqual(AdPrints.Library.entries().count, 1)
    }

    func testShortConfirmationCannotPromoteWholeLongerLegacyRecording() throws {
        let longer = recording(seconds: 30)
        let entry = legacyEntry(seconds: 30)
        try write([entry], print: longer)
        let shorter = longer.slice(0...12)
        XCTAssertTrue(AdPrints.Library.add(shorter, show: "Show", source: "confirmed-excerpt", kind: "ad",
            provenance: .userCorrection))
        let entries = AdPrints.Library.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(try XCTUnwrap(entries.first(where: { $0.id == entry.id })).isQuarantined)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.id + ".lm").path))
        let matched = try XCTUnwrap(AdPrints.Library.matches(in: longer).first)
        XCTAssertLessThan(matched.end - matched.start, 14)
    }

    func testCorruptIndexIsPreservedAndCannotBeOverwrittenByLearning() throws {
        let invalid = Data("this is not a learned-library index".utf8)
        let url = directory.appendingPathComponent("index.json")
        try invalid.write(to: url)
        XCTAssertTrue(AdPrints.Library.matches(in: recording()).isEmpty)
        XCTAssertFalse(AdPrints.Library.add(recording(), show: "Show", source: "new", kind: "ad",
            provenance: .userCorrection))
        XCTAssertEqual(try Data(contentsOf: url), invalid)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["index.json"])
    }

    func testAutomaticMatchingCapRetainsLegacyHistoryAndExplicitCorrections() throws {
        let print = recording()
        var entries: [AdPrints.Library.Entry] = []
        for index in 0..<(AdPrints.Library.cap + 1) {
            var entry = legacyEntry()
            entry.source = "legacy-\(index)"
            entries.append(entry)
        }
        try write(entries, print: print)
        XCTAssertFalse(AdPrints.Library.add(print, show: "Show", source: "confirmed", kind: "ad", provenance: .userCorrection))
        XCTAssertEqual(AdPrints.Library.entries().count, entries.count)
        for entry in entries {
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.id + ".lm").path))
        }
    }

    func testCachedPositiveNeedsProvenanceWhileExplicitAndNegativeEvidenceSurvive() throws {
        let old = AdPrints.Produced(start: 0, end: 30, acrossEpisodes: true, known: "ad")
        let encoded = try JSONEncoder().encode(old)
        let restored = try JSONDecoder().decode(AdPrints.Produced.self, from: encoded)
        XCTAssertEqual(restored.known, "ad")
        XCTAssertNil(restored.validatedForDetection)
        XCTAssertTrue(restored.acrossEpisodes)
        var current = restored
        current.evidenceProvenance = AdPrints.Library.Provenance.currentAutomatic.rawValue
        current.evidencePolicyVersion = AdPrints.Library.currentEvidencePolicyVersion
        XCTAssertEqual(current.validatedForDetection?.known, "ad")
        current.evidencePolicyVersion = 999
        XCTAssertNil(current.validatedForDetection?.known)
        current.evidenceProvenance = AdPrints.Library.Provenance.userCorrection.rawValue
        XCTAssertEqual(current.validatedForDetection?.known, "ad")
        current.evidenceProvenance = nil; current.evidencePolicyVersion = nil; current.negative = true
        XCTAssertTrue(try XCTUnwrap(current.validatedForDetection).negative)
        XCTAssertNil(current.validatedForDetection?.known)
    }

    func testQuarantinedPositiveCannotBecomeAcrossEpisodeFallbackEvidence() {
        let cached = AdPrints.Produced(start: 10, end: 40, acrossEpisodes: true, known: "ad")
        XCTAssertTrue(AdPrints.detectionEvidence([cached], duration: 100).isEmpty)
        // History remains intact; there is no generic repeat passed into the
        // detector's acrossEpisodes → ad fallback after quarantine.
        XCTAssertEqual(cached.known, "ad")
        XCTAssertTrue(cached.acrossEpisodes)
        let contextual = AdPrints.Produced(start: 10, end: 40, acrossEpisodes: true)
        XCTAssertEqual(AdPrints.detectionEvidence([contextual], duration: 100), [contextual])
    }

    func testDetectionEvidenceRejectsCorruptAndOutOfEpisodeBounds() {
        let valid = AdPrints.Produced(start: 0, end: 100, acrossEpisodes: false, negative: true)
        let invalid = [AdPrints.Produced(start: .nan, end: 20, acrossEpisodes: true),
                       .init(start: 0, end: .infinity, acrossEpisodes: true),
                       .init(start: -.infinity, end: 20, acrossEpisodes: true),
                       .init(start: -1, end: 20, acrossEpisodes: true),
                       .init(start: 40, end: 20, acrossEpisodes: true),
                       .init(start: 20, end: 20, acrossEpisodes: true),
                       .init(start: 20, end: 100.01, acrossEpisodes: true)]
        XCTAssertEqual(AdPrints.detectionEvidence(invalid + [valid], duration: 100), [valid])
        for duration in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertTrue(AdPrints.detectionEvidence([valid], duration: duration).isEmpty)
        }
    }

    private func recording(seconds: Int = 12) -> AdPrints.Landmarks {
        let frames = (0..<(seconds * 30)).map { Int32($0) }
        let hashes = frames.map { UInt32($0) &* 2_654_435_761 &+ 17 }
        return AdPrints.Landmarks(hashes: hashes, frames: frames, seconds: Double(seconds))
    }
    private func legacyEntry(negative: Bool = false, seconds: Double = 12) -> AdPrints.Library.Entry {
        .init(id: UUID().uuidString, show: "Show", source: "original", kind: "ad", negative: negative,
              seconds: seconds, added: Date(timeIntervalSince1970: 100), lastMatched: Date(timeIntervalSince1970: 200))
    }
    private func write(_ entries: [AdPrints.Library.Entry], print: AdPrints.Landmarks) throws {
        // Encoding optional nil fields produces the original legacy shape.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(entries).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        for entry in entries { try print.data().write(to: directory.appendingPathComponent(entry.id + ".lm"), options: .atomic) }
    }
}
