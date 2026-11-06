import XCTest
import SwiftData
@testable import PodSkipper

/// Pass 58 (his 6 Nov request): a show's own sound kept, but played only when
/// chosen — everywhere, nowhere, or on chosen speakers.
@MainActor
final class Pass58ShowSoundTests: XCTestCase {
    private let shower = SoundOutput(uid: "00:11:22:33:44:55-tacl", name: "Shower Speaker", kind: "BluetoothA2DPOutput")
    private let airpods = SoundOutput(uid: "AA:BB:CC:DD:EE:FF-tacl", name: "AirPods Pro", kind: "BluetoothA2DPOutput")
    private let bose = SoundOutput(uid: "11:22:33:44:55:66-tacl", name: "Bose QC", kind: "BluetoothA2DPOutput")

    /// Kept for the test's length: a show outlives its store otherwise.
    private var container: ModelContainer?

    private func showWithOwnSound() throws -> (Podcast, ModelContainer) {
        let container = try ModelContainer(for: LibraryStore.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let show = Podcast(feedURL: "https://example.com/feed", title: "Show")
        container.mainContext.insert(show)
        var own = SoundProfile.neutral
        own.speed = 1.4
        show.setOwnSound(own)
        self.container = container
        return (show, container)
    }

    func testOwnSoundPlaysEverywhereUntilChosenOtherwise() throws {
        let (show, _) = try showWithOwnSound()
        XCTAssertEqual(show.ownSoundUse, .on, "shows saved before Pass 58 keep playing their own")
        XCTAssertTrue(show.ownSoundPlays(on: [airpods]))
        XCTAssertNil(show.ownSoundUseRaw, "the usual case stores nothing")

        show.chooseOwnSound(false, on: [airpods])
        XCTAssertEqual(show.ownSoundUse, .off)
        XCTAssertFalse(show.ownSoundPlays(on: [shower]))
        XCTAssertTrue(show.hasOwnSound, "choosing All Shows keeps the show's own settings")

        show.chooseOwnSound(true, on: [airpods])
        XCTAssertTrue(show.ownSoundPlays(on: [shower]))
    }

    func testRememberedPerSpeaker() throws {
        let (show, _) = try showWithOwnSound()
        // On the shower speaker with the show's own playing: remember it there.
        show.rememberOwnSoundPerOutput(true, current: [shower])
        XCTAssertEqual(show.ownSoundUse, .outputs)
        XCTAssertTrue(show.ownSoundPlays(on: [shower]))
        XCTAssertFalse(show.ownSoundPlays(on: [airpods]), "any other output plays the default")
        XCTAssertFalse(show.ownSoundPlays(on: [bose]))

        // On AirPods, choosing All Shows changes nothing for the shower speaker.
        show.chooseOwnSound(false, on: [airpods])
        XCTAssertTrue(show.ownSoundPlays(on: [shower]))
        // On Bose, choosing This Show adds Bose only.
        show.chooseOwnSound(true, on: [bose])
        XCTAssertTrue(show.ownSoundPlays(on: [bose]))
        XCTAssertFalse(show.ownSoundPlays(on: [airpods]))
        // Back on the shower speaker, All Shows takes it off the list.
        show.chooseOwnSound(false, on: [shower])
        XCTAssertFalse(show.ownSoundPlays(on: [shower]))
        XCTAssertEqual(show.ownSoundOutputs, [bose])

        // Turned off on Bose (where it plays): plays everywhere again.
        show.rememberOwnSoundPerOutput(false, current: [bose])
        XCTAssertEqual(show.ownSoundUse, .on)
        XCTAssertTrue(show.ownSoundPlays(on: [airpods]))
        XCTAssertNil(show.ownSoundOutputsRaw)
    }

    func testRememberedFromAnOutputWhereTheDefaultPlays() throws {
        let (show, _) = try showWithOwnSound()
        show.chooseOwnSound(false, on: [airpods])
        show.rememberOwnSoundPerOutput(true, current: [airpods])
        XCTAssertEqual(show.ownSoundUse, .outputs)
        XCTAssertTrue(show.ownSoundOutputs.isEmpty, "the default was playing here, so no output plays the show's own yet")
        show.rememberOwnSoundPerOutput(false, current: [airpods])
        XCTAssertEqual(show.ownSoundUse, .off, "and turning it off keeps the default playing")
    }

    func testMatchingWithoutAnIdentifierUsesKindAndName() {
        let a = SoundOutput(uid: "", name: "Kitchen", kind: "AirPlay")
        XCTAssertTrue(a.matches(SoundOutput(uid: "", name: "Kitchen", kind: "AirPlay")))
        XCTAssertFalse(a.matches(SoundOutput(uid: "", name: "Kitchen", kind: "BluetoothA2DPOutput")))
        XCTAssertEqual(SoundOutput(uid: "x", name: "Speaker", kind: "Speaker").displayName, "iPhone Speaker")
    }

    func testUseMyDefaultClearsTheChoiceAndUndoPutsItBack() throws {
        let (show, _) = try showWithOwnSound()
        show.rememberOwnSoundPerOutput(true, current: [shower])
        let saved = show.soundOverrides
        show.useDefaultSound()
        XCTAssertNil(show.ownSoundUseRaw)
        XCTAssertNil(show.ownSoundOutputsRaw)
        show.soundOverrides = saved
        XCTAssertEqual(show.ownSoundUse, .outputs)
        XCTAssertEqual(show.ownSoundOutputs, [shower])
    }

    func testWithoutItsOwnSoundAShowPlaysTheDefault() throws {
        let (show, _) = try showWithOwnSound()
        show.useDefaultSound()
        XCTAssertFalse(show.ownSoundPlays(on: [shower]))
    }

    func testSyncedShowRecordsFromBeforeReadAsAlwaysOn() throws {
        let (show, _) = try showWithOwnSound()
        show.rememberOwnSoundPerOutput(true, current: [shower])
        let value = CloudRecords.ShowValue(show)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        XCTAssertNotNil(object["ownSoundOutputsRaw"])
        object.removeValue(forKey: "ownSoundUseRaw")
        object.removeValue(forKey: "ownSoundOutputsRaw")
        let old = try JSONDecoder().decode(CloudRecords.ShowValue.self, from: JSONSerialization.data(withJSONObject: object))
        old.apply(to: show)
        XCTAssertEqual(show.ownSoundUse, .on)
    }

    func testCurrentOutputsAreNeverEmpty() {
        SoundOutputs.testRoute = nil
        XCTAssertFalse(SoundOutputs.current.isEmpty)
    }
}

/// Pass 58: the cut check's two rules, measured on his test episodes
/// (evidence §9).
final class Pass58CutCheckTests: XCTestCase {
    private func line(_ t: Double, _ text: String, length: Double = 4) -> TimedLine {
        TimedLine(text: text, start: t, end: t + length)
    }

    override func tearDown() {
        ModelCutCheck.readerEdges = true
        ModelCutCheck.brandNeedsCue = true
        super.tearDown()
    }

    /// Whiskey Ginger 51:02: the hosts joking about a CPAP; the model called
    /// it an ad "for ResMed".
    private func banter(withOffer: Bool) -> [TimedLine] {
        var lines = (0..<12).map { line(3_060 + Double($0) * 5, $0 % 3 == 0 ? "Resmed 11, is this the compact one?" : "they're pretty chunky, put Porsche on the bag") }
        if withOffer { lines[6] = line(3_090, "Go to resmed.com slash whiskey for twenty percent off") }
        return lines
    }

    func testTheModelsOwnSponsorNameAloneDoesNotProveAnAd() {
        let model = DetectedSegment(start: 3_060, end: 3_120, kind: .ad, sponsor: "ResMed", confidence: 80, evidence: [])
        let now = ModelCutCheck.verify([model], lines: banter(withOffer: false), readerCuts: [], evidence: [], keeps: [],
                                       duration: 5_000)
        XCTAssertTrue(now.cuts.isEmpty, "banter naming a brand is the show: \(now.cuts)")
        ModelCutCheck.brandNeedsCue = false
        let before = ModelCutCheck.verify([model], lines: banter(withOffer: false), readerCuts: [], evidence: [], keeps: [],
                                          duration: 5_000)
        XCTAssertFalse(before.cuts.isEmpty, "before Pass 58 the name alone kept it")
    }

    func testTheNameStillCountsBesideAnOffer() {
        let model = DetectedSegment(start: 3_060, end: 3_120, kind: .ad, sponsor: "ResMed", confidence: 80, evidence: [])
        let now = ModelCutCheck.verify([model], lines: banter(withOffer: true), readerCuts: [], evidence: [], keeps: [],
                                       duration: 5_000)
        let kept = now.cuts.reduce(0) { $0 + $1.end - $1.start }
        XCTAssertGreaterThan(kept, 50, "a read with an offer keeps the brand's lines around it")
    }

    func testTheReadersConfidentOutroStandsWhereTheModelSaidNothing() {
        let lines = (0..<30).map { line(4_800 + Double($0) * 5, "thanks for listening, see you next week") }
        let outro = DetectedSegment(start: 4_906, end: 4_944, kind: .outro, sponsor: "", confidence: 93, evidence: [])
        let ad = DetectedSegment(start: 1_860, end: 1_950, kind: .ad, sponsor: "Shopify", confidence: 80, evidence: [])
        let now = ModelCutCheck.verify([ad], lines: lines, readerCuts: [outro], evidence: [], keeps: [], duration: 4_950)
        XCTAssertTrue(now.cuts.contains { $0.kind == .outro && $0.start >= 4_900 }, "\(now.cuts)")
        ModelCutCheck.readerEdges = false
        let before = ModelCutCheck.verify([ad], lines: lines, readerCuts: [outro], evidence: [], keeps: [], duration: 4_950)
        XCTAssertFalse(before.cuts.contains { $0.kind == .outro })
    }

    func testOnlyAtTheEdgesAndOnlyWhenSure() {
        let lines = (0..<30).map { line(2_000 + Double($0) * 5, "and that's the end of that segment") }
        let middle = DetectedSegment(start: 2_000, end: 2_060, kind: .outro, sponsor: "", confidence: 95, evidence: [])
        let unsure = DetectedSegment(start: 4_900, end: 4_940, kind: .outro, sponsor: "", confidence: 58, evidence: [])
        let now = ModelCutCheck.verify([], lines: lines, readerCuts: [middle, unsure], evidence: [], keeps: [], duration: 4_950)
        XCTAssertTrue(now.cuts.isEmpty, "an outro mid-episode, or one the Reader isn't sure of, isn't kept: \(now.cuts)")
    }

    func testAJokeTheModelMarkedStaysTheShow() {
        let lines = (0..<10).map { line(10 + Double($0) * 5, "welcome back to the show everybody") }
        let intro = DetectedSegment(start: 10, end: 60, kind: .intro, sponsor: "", confidence: 95, evidence: [])
        let now = ModelCutCheck.verify([], lines: lines, readerCuts: [intro], evidence: [], keeps: [10...60], duration: 3_000)
        XCTAssertTrue(now.cuts.isEmpty)
    }
}
