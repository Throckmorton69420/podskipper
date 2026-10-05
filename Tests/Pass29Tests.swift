import XCTest
import SwiftData
@testable import PodSkipper

/// Pass 29 (his 5 Oct phone): heat pacing that never waits forever, Restart
/// that starts the job once, a line that Find Ads can always rejoin, and the
/// sound model's new fixes and chart change tracking.
@MainActor
final class Pass29Tests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var container: ModelContainer!
    private var store: ProcessingJobStore!
    private var resources: HeavyWorkCoordinator!

    override func setUpWithError() throws {
        suite = "Pass29Tests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        folder = URL.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        store = ProcessingJobStore(file: folder.appending(path: "jobs.json"), defaults: defaults)
        resources = HeavyWorkCoordinator()
    }

    override func tearDown() {
        ThermalPacing.stateOverride = nil
        ThermalPacing.criticalLimit = 5 * 60
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
        container = nil
        super.tearDown()
    }

    private func episode(_ guid: String) -> Episode {
        let episode = Episode(guid: guid, title: guid, episodeDescription: "", audioURL: "https://example.invalid/audio.mp3",
                              publishedAt: .now, duration: 60)
        container.mainContext.insert(episode)
        return episode
    }

    private func pipeline(_ worker: @escaping ProcessingPipeline.Worker) -> ProcessingPipeline {
        let pipeline = ProcessingPipeline(jobs: store, resources: resources, worker: worker)
        pipeline.configure(context: container.mainContext, settings: AppSettings())
        return pipeline
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    // MARK: Heat

    func testWarmPhoneRestsBetweenPartsAndCarriesOn() async throws {
        ThermalPacing.stateOverride = .serious
        var slept = 0
        try await ThermalPacing.beforePart(status: { _ in }, sleep: { _ in slept += 1 })
        XCTAssertEqual(slept, 20, "a 20 s rest, one second at a time, then the read carries on")
    }

    func testCoolPhoneDoesNotWait() async throws {
        ThermalPacing.stateOverride = .fair
        var slept = 0
        try await ThermalPacing.beforePart(status: { _ in }, sleep: { _ in slept += 1 })
        XCTAssertEqual(slept, 0)
    }

    func testTooHotGivesUpInsteadOfWaitingForever() async throws {
        ThermalPacing.stateOverride = .critical
        ThermalPacing.criticalLimit = 0
        do {
            try await ThermalPacing.beforePart(status: { _ in }, sleep: { _ in try await Task.sleep(for: .milliseconds(1)) })
            XCTFail("must not wait forever")
        } catch is ThermalPacing.TooHot {
        }
    }

    // MARK: The line

    func testRestartRunsTheJobOnceMore() async throws {
        let a = episode("a")
        var starts = 0
        let pipeline = pipeline { _, _ in
            starts += 1
            if starts == 1 { try await Task.sleep(for: .seconds(30)) }
        }
        pipeline.processNow([a])
        try await waitUntil { starts == 1 && pipeline.isRunning }
        pipeline.stalledSince = .now
        await pipeline.restart(a)
        try await waitUntil { store.record("a")?.status == .completed }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(starts, 2, "Restart starts the episode exactly once more")
        XCTAssertTrue(pipeline.waitingQueue.isEmpty)
        try await waitUntil { !resources.isBusy }
    }

    func testFindAdsWorksAgainAfterTakingAWaitingEpisodeOutOfLine() async throws {
        let b = episode("b")
        var started: [String] = []
        let pipeline = pipeline { episode, _ in started.append(episode.guid) }
        // Something else holds the shared slot, so "b" waits for it.
        let held = try XCTUnwrap(resources.tryAcquire(owner: "maintenance:x"))
        pipeline.processNow([b])
        try await waitUntil { resources.waitingOwners.contains("episode:b") }
        pipeline.cancelWaiting("b")
        try await waitUntil { resources.waitingOwners.isEmpty }
        resources.release(held)
        await pipeline.processNow(b)
        XCTAssertEqual(started, ["b"])
        XCTAssertEqual(store.record("b")?.status, .completed)
    }

    // MARK: Sound

    func testNewFixesWorkWhereTheirNamesSay() {
        func peak(_ repair: Repair) -> (hz: Double, db: Double) {
            let plan = EQMath.plan(SoundSettings(base: EQPreset.flat.gains, repairs: [repair: repair.defaultStrength], normalizationDB: 0))
            var best = (hz: 1_000.0, db: 0.0)
            for step in 0...80 {
                let hz = 50 * pow(16_000 / 50, Double(step) / 80)
                let db = EQMath.toneResponseDB(at: hz, plan: plan)
                if abs(db) > abs(best.db) { best = (hz, db) }
            }
            return best
        }
        let nasal = peak(.nasal)
        XCTAssertLessThan(nasal.db, -2)
        XCTAssertTrue((600...1_600).contains(nasal.hz), "nasal cut centred near 1 kHz, was \(nasal.hz)")
        let muffled = peak(.muffled)
        XCTAssertGreaterThan(muffled.db, 1.5)
        XCTAssertGreaterThan(muffled.hz, 5_000)
        XCTAssertEqual(Repair.nasal.zone.name, "Body")
        XCTAssertEqual(Repair.muffled.zone.name, "Air")
    }

    func testFixesStillMoveTheEqualizerSliders() {
        var state = SoundState()
        state.setRepair(.mud, on: true)
        // Equalizer off: the sliders show the fixes on a flat base.
        let off = EQMath.combinedGains(preset: state.baseGains, repairs: state.enabledRepairs)
        XCTAssertLessThan(off[3], -3, "250 Hz band pulled down by Reduce Muddiness")
        // Equalizer on with a preset: preset plus the fix.
        state.equalizerOn = true
        state.choosePreset(named: EQPreset.speech.name)
        let on = EQMath.combinedGains(preset: state.baseGains, repairs: state.enabledRepairs)
        XCTAssertEqual(on[3], EQPreset.speech.gains[3] + off[3], accuracy: 0.01)
    }

    func testChartKnowsWhatJustChanged() {
        let before = SoundSettings(base: EQPreset.flat.gains, repairs: [.mud: 5], normalizationDB: 0)
        var after = before
        after.repairs[.mud] = 7
        XCTAssertEqual(EQCurvePanel.changed(from: before, to: after), .fix(.mud))
        after = before
        after.repairs[.sibilance] = 6
        XCTAssertEqual(EQCurvePanel.changed(from: before, to: after), .fix(.sibilance))
        after = before
        after.base = EQPreset.speech.gains
        XCTAssertEqual(EQCurvePanel.changed(from: before, to: after), .preset)
        after = before
        after.normalizationDB = 2
        XCTAssertNil(EQCurvePanel.changed(from: before, to: after), "loudness is not a tone change")
    }

    func testZonesCoverTheWholeAxisInOrder() {
        let zones = SoundZone.all
        XCTAssertEqual(zones.first?.low, 20)
        XCTAssertEqual(zones.last?.high, 20_000)
        for (a, b) in zip(zones, zones.dropFirst()) { XCTAssertEqual(a.high, b.low) }
        XCTAssertEqual(SoundZone.containing(300).name, "Mud")
        XCTAssertEqual(SoundZone.containing(7_000).name, "Sibilance")
    }
}
