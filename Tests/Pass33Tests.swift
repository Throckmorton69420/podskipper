import XCTest
@testable import PodSkipper

/// Pass 33 (his 9 Oct phone report on build 3ba90ff, Diagnostics and Results).
@MainActor
final class Pass33Tests: XCTestCase {

    // MARK: Model storage
    // Pass 35: the storage tests moved to Pass35Tests. Pass 33's compared
    // flat MLX folder names with "owner/repo" ids, the bug that filed every
    // MLX model under "Models no longer offered".

    // MARK: Progress while cooling (his 9 Oct phone)

    /// A cooling wait is recorded as waiting, for exactly as long as it lasts.
    func testCoolingIsRecordedAsWaiting() async throws {
        ThermalPacing.stateOverride = .serious
        defer { ThermalPacing.stateOverride = nil }
        let before = ThermalPacing.cooledSeconds()
        var sawWaiting = false
        try await ThermalPacing.beforePart(status: { _ in }, sleep: { _ in
            if ThermalPacing.coolingSince != nil { sawWaiting = true }
            try await Task.sleep(for: .milliseconds(20))
        })
        XCTAssertTrue(sawWaiting, "the wait says it is a wait while it lasts")
        XCTAssertNil(ThermalPacing.coolingSince, "and stops saying so when it ends")
        XCTAssertGreaterThan(ThermalPacing.cooledSeconds() - before, 0.2)
    }

    /// Nominal heat: nothing is recorded as waiting.
    func testNoWaitWhenCool() async throws {
        ThermalPacing.stateOverride = .nominal
        defer { ThermalPacing.stateOverride = nil }
        let before = ThermalPacing.cooledSeconds()
        try await ThermalPacing.beforePart(status: { _ in }, sleep: { _ in XCTFail("no rest when cool") })
        XCTAssertEqual(ThermalPacing.cooledSeconds(), before, accuracy: 0.001)
    }

    /// The bar is the work the model reported, never the clock: with no
    /// report yet it stays at 0 however long the test has been going.
    func testTheBarNeverFillsFromTheClock() {
        let bench = ModelBench(defaults: UserDefaults(suiteName: "pass33-\(UUID())")!, recoverInterrupted: false)
        XCTAssertEqual(bench.shownFraction(now: .now.addingTimeInterval(600)), 0)
    }

    /// Time left counts down only with work: a wait to cool since the last
    /// reading isn't subtracted from it.
    func testTimeLeftHoldsWhileCooling() async throws {
        let monitor = LocalJudgeMonitor.shared
        monitor.started()
        monitor.metered(0.4, secondsLeft: 100)
        ThermalPacing.stateOverride = .serious
        defer { ThermalPacing.stateOverride = nil; monitor.finished(nil, error: nil) }
        try await ThermalPacing.beforePart(status: { _ in }, sleep: { _ in try await Task.sleep(for: .milliseconds(30)) })
        // About 0.6 s passed, all of it waiting.
        XCTAssertLessThan(monitor.workSinceReading(now: .now), 0.15)
    }

    // MARK: MLX answers (his 9 Oct phone samples)

    func testShortLoopsAreCaught() {
        XCTAssertTrue(AnswerLoop.isLooping(#"{"parts": [{"first_line": 0, "last_line": 49, "label": "/&/&/&/&/&/&/&/&/&/&/&/&/&/&"#))
        XCTAssertTrue(AnswerLoop.isLooping(#""sponsorship", "commercial", "commercial", "commercial", "commercial", "commercial", "commercial", "commercial", "#))
    }

    func testIndentedJSONIsNotALoop() {
        let ministral = "```json\n{\n  \"parts\": [\n    {\n      \"first_line\": 0,\n      \"last_line\": 1,\n      \"label\": \"INTRO\",\n            "
        XCTAssertFalse(AnswerLoop.isLooping(ministral))
        XCTAssertFalse(AnswerLoop.isLooping(#"{"parts":[{"first_line":14,"last_line":23,"label":"HOST_READ_AD","sponsor":"Harborline Coffee","funny":false}]}"#))
    }

    func testLabelsAreReadWhateverTheirCase() {
        XCTAssertEqual(JudgePrompt.label(named: "Paid_AD"), .paidAd)
        XCTAssertEqual(JudgePrompt.label(named: "host read ad"), .hostReadAd)
        XCTAssertEqual(JudgePrompt.label(named: "show"), JudgeLabel(rawValue: "SHOW"))
        // Pass 38 (his request: common aliases): "SPONSOR" can only be an ad
        // and both ad labels make the same cut; ambiguous or unknown names are
        // still not guessed.
        XCTAssertEqual(JudgePrompt.label(named: "SPONSOR"), .paidAd)
        XCTAssertNil(JudgePrompt.label(named: "PROMO"), "ambiguous: not guessed")
        XCTAssertNil(JudgePrompt.label(named: "BANANA"), "an unknown label is still not guessed")
    }

    /// Ministral 3 3B's Basic answer on his phone: complete, fenced, with
    /// lower-case labels — rejected as "incomplete or invalid" before.
    func testFencedLowercaseAnswerIsComplete() {
        let answer = "```json\n{\n  \"parts\": [\n    {\n      \"first_line\": 0,\n      \"last_line\": 33,\n      \"label\": \"show\",\n      \"sponsor\": \"\"\n    },\n    {\n      \"first_line\": 13,\n      \"last_line\": 23,\n      \"label\": \"HOST_READ_AD\",\n      \"sponsor\": \"Harborline Coffee\",\n      \"funny\": true\n    }\n  ]\n}\n```"
        XCTAssertEqual(JudgePrompt.parseComplete(answer)?.count, 2)
    }

    /// Phi-4 mini's Hard answer: the list alone, numbers as strings.
    func testABareListIsAnAnswer() {
        let answer = "```json\n[{\"first_line\": \"0\", \"last_line\": \"49\", \"label\": \"INTRO\"}]\n```"
        XCTAssertEqual(JudgePrompt.parseComplete(answer)?.first?.lastLine, 49)
        XCTAssertEqual(JudgePrompt.parse(#"{"parts":[{"first_line":1,"last_line":2,"label":"PAID_AD"}]}"#)?.count, 1)
    }

    // MARK: Speed and Audio: per show, and Reset (A04)

    private func show() -> Podcast { Podcast(feedURL: "https://example.com/\(UUID())", title: "Show") }

    /// A show follows the default until it has its own; then it keeps its
    /// own copy whatever the default does; "Use My Default" gives it back.
    func testShowInheritsThenKeepsItsOwnThenReverts() {
        let settings = AppSettings()
        let saved = settings.profile
        defer { settings.profile = saved }
        let podcast = show()
        var base = settings.profile
        base.speed = 1.3; base.smartSpeed = false
        settings.profile = base
        XCTAssertEqual(settings.profile(for: podcast).speed, 1.3, "inherits")
        XCTAssertFalse(podcast.hasOwnSound)

        var own = settings.profile(for: podcast)
        own.speed = 1.8; own.smartSpeed = true; own.evenOut = true; own.evenOutStrength = 0.75
        podcast.setOwnSound(own)
        XCTAssertTrue(podcast.hasOwnSound)
        base.speed = 1.1
        settings.profile = base
        XCTAssertEqual(settings.profile(for: podcast).speed, 1.8, "its own copy, not the default")
        XCTAssertTrue(settings.smartSpeed(for: podcast).on, "the player reads the show's Smart Speed")
        let plan = settings.sound(for: podcast, normalizationGain: nil)
        XCTAssertTrue(plan.levelling)
        XCTAssertEqual(plan.levellingStrength, 0.75)
        XCTAssertFalse(settings.sound(for: nil, normalizationGain: nil).levelling, "the default stays off")

        podcast.useDefaultSound()
        XCTAssertFalse(podcast.hasOwnSound)
        XCTAssertEqual(settings.profile(for: podcast).speed, 1.1)
    }

    /// Reset puts back exactly what a fresh install starts with, leaves
    /// shows alone, and can be undone.
    func testResetRestoresFreshDefaultsAndUndoes() {
        let settings = AppSettings()
        let saved = (settings.profile, settings.monoDownmix)
        defer { settings.profile = saved.0; settings.monoDownmix = saved.1 }
        let podcast = show()
        var own = settings.profile(for: podcast); own.speed = 2.0
        podcast.setOwnSound(own)

        var changed = settings.profile
        changed.speed = 1.6; changed.smartSpeed = true; changed.normalize = false
        changed.sound.equalizerOn = true; changed.sound.setRepair(.boom, on: true)
        settings.profile = changed
        settings.monoDownmix = true

        let undo = SoundResetUndo(settings: settings, shows: [])
        settings.resetSoundToDefaults()
        assertNeutral(settings)
        XCTAssertEqual(settings.profile(for: podcast).speed, 2.0, "a show keeps its own settings")

        undo.restore(settings: settings)
        XCTAssertEqual(settings.profile.speed, 1.6)
        XCTAssertTrue(settings.profile.sound.isOn(.boom))
        XCTAssertTrue(settings.monoDownmix)
    }

    /// His intended baseline (9 Oct): 1×; Smart Speed, Volume Normalization,
    /// Even Out Volume, equalizer, Mono and every sound fix off; EQ flat.
    private func assertNeutral(_ settings: AppSettings, file: StaticString = #filePath, line: UInt = #line) {
        let p = settings.profile
        XCTAssertEqual(p.speed, 1.0, file: file, line: line)
        XCTAssertFalse(p.smartSpeed, "Smart Speed", file: file, line: line)
        XCTAssertFalse(p.normalize, "Volume Normalization", file: file, line: line)
        XCTAssertFalse(p.evenOut, "Even Out Volume", file: file, line: line)
        XCTAssertFalse(settings.monoDownmix, "Mono", file: file, line: line)
        XCTAssertFalse(p.sound.equalizerOn, "Equalizer", file: file, line: line)
        XCTAssertEqual(p.sound.preset, EQPreset.flat.name, file: file, line: line)
        XCTAssertEqual(p.sound.gains, EQPreset.flat.gains, file: file, line: line)
        for repair in Repair.allCases {
            XCTAssertFalse(settings.isOn(repair), "\(repair.title) should be off", file: file, line: line)
        }
        XCTAssertTrue(p.sound.enabled.isEmpty, file: file, line: line)
        XCTAssertFalse(settings.rumbleFilterEnabled, file: file, line: line)
        XCTAssertFalse(settings.voiceBoostEnabled, file: file, line: line)
    }

    /// A fresh install (nothing saved) reads the neutral baseline, and the
    /// one-time step stores nothing for it.
    func testFreshInstallIsNeutral() throws {
        let name = "fresh-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        SoundSettingsMigration.keepPreviousDefaults(d, domain: name)
        let stored = d.persistentDomain(forName: name) ?? [:]
        XCTAssertNil(stored["normalize"])
        XCTAssertNil(stored["rumble"])
        XCTAssertEqual(stored[SoundSettingsMigration.neutralDefaultsKey] as? Int, 1)
        // The registered defaults (what a fresh install reads, and what Reset
        // puts back) are the neutral baseline.
        let settings = AppSettings()
        let saved = (settings.profile, settings.monoDownmix)
        defer { settings.profile = saved.0; settings.monoDownmix = saved.1 }
        settings.resetSoundToDefaults()
        assertNeutral(settings)
        assertNeutral(AppSettings())
    }

    /// An update keeps what an existing install was hearing: switches left
    /// at the old defaults (on) are stored as on; anything he set stays.
    func testUpdateKeepsWhatAnExistingInstallHeard() throws {
        let name = "existing-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        d.set(2, forKey: SoundSettingsMigration.versionKey)
        d.set(false, forKey: "rumble")
        SoundSettingsMigration.keepPreviousDefaults(d, domain: name)
        var stored = d.persistentDomain(forName: name) ?? [:]
        XCTAssertEqual(stored["normalize"] as? Bool, true, "was on by default, stays on")
        XCTAssertEqual(stored["rumble"] as? Bool, false, "his own choice is untouched")
        // Runs once: a later Reset (which removes the keys) isn't undone.
        d.removeObject(forKey: "normalize")
        SoundSettingsMigration.keepPreviousDefaults(d, domain: name)
        stored = d.persistentDomain(forName: name) ?? [:]
        XCTAssertNil(stored["normalize"])
    }

    /// Undoing a show's reset puts back exactly the fields it had, even a
    /// show that only had a speed of its own.
    func testUndoRestoresAPartialShow() {
        let settings = AppSettings()
        let podcast = show()
        podcast.playbackSpeedOverride = 1.4
        let undo = SoundResetUndo(settings: settings, shows: [podcast])
        podcast.useDefaultSound()
        XCTAssertNil(podcast.playbackSpeedOverride)
        undo.restore(settings: settings)
        XCTAssertEqual(podcast.playbackSpeedOverride, 1.4)
        XCTAssertNil(podcast.customSoundData, "nothing it didn't have is added")
    }

    /// Sounds saved before Pass 33 (without Even Out) still read.
    func testOlderSavedShowSoundsStillDecode() throws {
        var before = SoundState(); before.equalizerOn = true
        let data = try JSONEncoder().encode(before)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("evenOut"), "a show without it stores nothing new")
        let state = try JSONDecoder().decode(SoundState.self, from: data)
        XCTAssertNil(state.evenOut)
        XCTAssertTrue(state.equalizerOn)
    }
}
