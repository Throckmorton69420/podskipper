import XCTest
import AVFoundation
import SwiftData
@testable import PodSkipper

/// Pass 43: his 19 Oct phone — during Find Ads, reads of the episode's file
/// failed with "com.apple.coreaudio.avfaudio error 560164718" ('!con'), every
/// later read failed at once on the same file, the player restarted three
/// times from the same place and paused; another time the Pause button stayed
/// up over 215 s of silence. The real `AudioEngine` in the simulator; the
/// failures are the test hooks standing in for his phone's.
@MainActor
final class Pass43AudioTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func tone(seconds: Double) throws -> AVAudioFile {
        let url = folder.appendingPathComponent("tone-\(seconds).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<Int(frames) {
            let v = Float(0.05 * sin(2 * Double.pi * 440 * Double(i) / 48_000))
            channels[0][i] = v; channels[1][i] = v
        }
        do {
            let out = try AVAudioFile(forWriting: url, settings: format.settings)
            try out.write(from: buffer)
        }
        return try AVAudioFile(forReading: url)
    }

    /// A read fails as on his phone: the file is opened afresh and reading
    /// carries on from the same frame before the queued audio runs out, so
    /// nothing is heard and the clock keeps counting.
    func testFailedReadIsCarriedOverByOpeningTheFileAgain() async throws {
        let engine = AudioEngine(aheadSeconds: 6)
        engine.reopenDelaysForTesting = [0.05, 0.1, 0.2, 0.3]
        defer { engine.stop() }
        engine.adopt(try tone(seconds: 60))
        try engine.play(from: 2)
        try await Task.sleep(for: .milliseconds(400))
        engine.failsReadsForTesting = 2
        try await Task.sleep(for: .milliseconds(2_500))
        XCTAssertEqual(engine.health(), .fine, engine.stateDescription)
        XCTAssertTrue(engine.stateDescription.contains("read failed"), engine.stateDescription)
        XCTAssertTrue(engine.stateDescription.contains("opened again"), engine.stateDescription)
        XCTAssertFalse(engine.readingStopped)
        XCTAssertGreaterThan(engine.currentTime, 4.4)
        // Reading carried on: well ahead of the speaker again.
        let ahead = engine.stateDescription.range(of: #"\(([0-9.]+) s ahead\)"#, options: .regularExpression)
            .map { String(engine.stateDescription[$0]) } ?? ""
        XCTAssertFalse(ahead.isEmpty, engine.stateDescription)
    }

    /// The file can't be opened again either: after the tries, reading stops
    /// for good and the engine says the episode is unreadable — not starved,
    /// which the player would answer by starting again from the same place.
    /// Playing from where it stopped opens the file afresh and works.
    func testFileThatStaysUnreadableIsReportedThenPlaysAfterReopening() async throws {
        let engine = AudioEngine(aheadSeconds: 2)
        engine.reopenDelaysForTesting = [0.05, 0.05, 0.05, 0.05]
        defer { engine.stop() }
        engine.adopt(try tone(seconds: 60))
        try engine.play(from: 5)
        try await Task.sleep(for: .milliseconds(300))
        engine.failsReopensForTesting = 50
        engine.failsReadsForTesting = 1
        var health = engine.health()
        for _ in 0..<60 {
            if case .unreadable = health { break }
            try await Task.sleep(for: .milliseconds(100))
            health = engine.health()
        }
        guard case .unreadable(let heardUntil, let reason) = health else {
            return XCTFail("Expected unreadable, got \(health) · \(engine.stateDescription)")
        }
        XCTAssertTrue(engine.readingStopped)
        XCTAssertTrue(reason.contains("'!con'"), reason)
        XCTAssertGreaterThan(heardUntil, 5.2)
        XCTAssertEqual(engine.currentTime, heardUntil, accuracy: 0.01, "The position stays where sound stopped")
        // Resuming would play nothing new: it asks for a fresh start instead.
        engine.pause()
        XCTAssertThrowsError(try engine.resume())

        engine.failsReopensForTesting = 0
        try engine.play(from: heardUntil)
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertEqual(engine.health(), .fine, engine.stateDescription)
        XCTAssertGreaterThan(engine.currentTime, heardUntil + 0.5)
        XCTAssertFalse(engine.readingStopped)
    }

    /// While the file is being opened afresh after a failure, a short
    /// silence is not mistaken for starvation (which would restart from the
    /// same place and burn the restart budget).
    func testReopeningIsNotStarvation() async throws {
        let engine = AudioEngine(aheadSeconds: 2)
        engine.reopenDelaysForTesting = [1.5, 1.5, 1.5, 1.5]
        defer { engine.stop() }
        engine.adopt(try tone(seconds: 60))
        try engine.play(from: 1)
        engine.failsReadsForTesting = 1
        try await Task.sleep(for: .milliseconds(2_800))
        let health = engine.health()
        if case .starved = health { XCTFail("Reopening counted as starved: \(engine.stateDescription)") }
    }

    func testErrorWordsCarryCoreAudiosCode() {
        let error = NSError(domain: "com.apple.coreaudio.avfaudio", code: 560_164_718)
        XCTAssertTrue(AudioEngine.describe(error).hasSuffix("('!con')"), AudioEngine.describe(error))
        XCTAssertFalse(AudioEngine.describe(NSError(domain: "x", code: -50)).contains("('"))
    }

    /// AirPods leaving begin an interruption iOS never ends; it must not hold
    /// the sound check off after he presses Play again.
    func testRouteDisconnectedInterruptionDoesNotHoldPlaybackChecksOff() {
        XCTAssertFalse(PlayerEngine.interruptionWillEnd(reasonRaw: AVAudioSession.InterruptionReason.routeDisconnected.rawValue))
        XCTAssertTrue(PlayerEngine.interruptionWillEnd(reasonRaw: AVAudioSession.InterruptionReason.default.rawValue))
        XCTAssertTrue(PlayerEngine.interruptionWillEnd(reasonRaw: nil))
    }
}

/// Pass 43: his 19 Oct phone — Core AI Qwen3 4B closed PodSkipper 22 times
/// while reading; every job that resumed afterwards kept an earlier result (or the
/// reader's) and called the episode finished, so his chosen model never read
/// it; the reader retrained 20 times in four hours, rolling every one back.
final class Pass43RecoveryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "Pass43RecoveryTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func note(stage: String, episode: String = "guid-1", away: Bool = false) -> CoreAIInFlight.Note {
        CoreAIInFlight.Note(id: "qwen3-4b", name: "Qwen3 4B", episode: episode, stage: stage, away: away, freeMB: 1_200)
    }

    // MARK: Closures

    /// One closure leaves the model one more try of its own; the second
    /// leaves the episode waiting for him. Find Ads Again clears it.
    func testClosuresOnAnEpisodeAreCountedAndForgottenWhenHeAsks() {
        CoreAICrashGuard.remember(note(stage: "part 2 of 5"), defaults: defaults)
        XCTAssertEqual(CoreAICrashGuard.closedLastTime(model: "qwen3-4b", episode: "guid-1", defaults: defaults)?.count, 1)
        XCTAssertLessThanOrEqual(1, CoreAICrashGuard.triesAfterClosing, "after one closure it tries once more")
        CoreAICrashGuard.remember(note(stage: "part 3 of 5"), defaults: defaults)
        let twice = CoreAICrashGuard.closedLastTime(model: "qwen3-4b", episode: "guid-1", defaults: defaults)
        XCTAssertEqual(twice?.count, 2)
        XCTAssertEqual(twice?.stage, "part 3 of 5")
        XCTAssertGreaterThan(twice?.count ?? 0, CoreAICrashGuard.triesAfterClosing, "then it waits for him")
        // Another model's closure starts its own count.
        CoreAICrashGuard.remember(CoreAIInFlight.Note(id: "minicpm5-2b", name: "MiniCPM5 2B", episode: "guid-1", stage: ""),
                                  defaults: defaults)
        XCTAssertEqual(CoreAICrashGuard.closedLastTime(model: "minicpm5-2b", episode: "guid-1", defaults: defaults)?.count, 1)
        CoreAICrashGuard.forget(episode: "guid-1", defaults: defaults)
        XCTAssertNil(CoreAICrashGuard.closedLastTime(model: "minicpm5-2b", episode: "guid-1", defaults: defaults))
    }

    /// Closures under the engine Qwen3 4B used before Pass 43 don't keep it
    /// from the work it is chosen for; new ones count from one.
    func testClosuresBeforeTheEngineChangeDontHoldTheModelBack() throws {
        let old = ["qwen3-4b": CoreAIStability.Record(count: 10, last: .now, stage: "part 2 of 5", duringTest: false)]
        defaults.set(try JSONEncoder().encode(old), forKey: "coreAI.closures")
        XCTAssertFalse(CoreAIStability.avoidForAutomaticWork("qwen3-4b", defaults: defaults))
        XCTAssertNotNil(CoreAIStability.summary(for: "qwen3-4b", defaults: defaults), "the row still tells them")
        CoreAIStability.record(note(stage: "part 1 of 5"), defaults: defaults)
        XCTAssertEqual(CoreAIStability.record(for: "qwen3-4b", defaults: defaults)?.count, 1)
        XCTAssertFalse(CoreAIStability.avoidForAutomaticWork("qwen3-4b", defaults: defaults))
        CoreAIStability.record(note(stage: "part 1 of 5"), defaults: defaults)
        XCTAssertTrue(CoreAIStability.avoidForAutomaticWork("qwen3-4b", defaults: defaults))
    }

    /// The launch after says what happened, not "most likely compiling" for a
    /// closure in the middle of an answer.
    func testTheLaunchNoteSaysWhatHappened() {
        let midAnswer = CoreAIInFlight.launchNote(note(stage: "part 5 of 5 · about 2374 prompt tokens read · writing classification · 1 tokens"))
        XCTAssertFalse(midAnswer.contains("compiling"), midAnswer)
        XCTAssertTrue(midAnswer.contains("one more try"), midAnswer)
        XCTAssertTrue(midAnswer.contains("1200 MB"), midAnswer)
        let loading = CoreAIInFlight.launchNote(note(stage: "loading"))
        XCTAssertTrue(loading.contains("Install Compiled Copy"), loading)
        let away = CoreAIInFlight.launchNote(note(stage: "part 2 of 5", away: true))
        XCTAssertTrue(away.contains("background"), away)
        XCTAssertTrue(away.contains("isn't counted against the model"), away)
        let test = CoreAIInFlight.launchNote(note(stage: "part 1 of 2", episode: ""))
        XCTAssertFalse(test.contains("one more try"), test)
    }

    /// Short of memory: the read stops between parts instead of iOS ending
    /// PodSkipper in one. The simulator's 0 ("not known") isn't short.
    func testCoreAIStopsBetweenPartsWhenMemoryRunsShort() {
        let start = Date.now
        XCTAssertNil(CoreAIMemory.short(since: start, available: 1_500, warned: start.addingTimeInterval(-60)),
                     "a warning before this read started")
        // Pass 44: a warning with plenty left (his phone: one while Qwen3 4B
        // loaded, 6.6 GB free) doesn't stop the read; with little left it does.
        XCTAssertNil(CoreAIMemory.short(since: start, available: 6_600, warned: start.addingTimeInterval(5)))
        XCTAssertNotNil(CoreAIMemory.short(since: start, available: 900, warned: start.addingTimeInterval(5)))
        XCTAssertNotNil(CoreAIMemory.short(since: start, available: 250, warned: .distantPast))
        XCTAssertNil(CoreAIMemory.short(since: start, available: 0, warned: .distantPast))
        XCTAssertTrue(CoreAIAdJudge.JudgeError.lowMemory("x").localizedDescription.contains("again later"))
    }

    // MARK: What an attempt leaves owed

    func testAModelThatCouldntFinishStillOwesTheRead() {
        var run = ModelFinder.Run(finder: "reader")
        XCTAssertEqual(ProcessingPipeline.stillOwed(run), .no, "never started (not downloaded, turned off)")
        run.attempts = 3
        XCTAssertEqual(ProcessingPipeline.stillOwed(run), .automatically)
        run.deferred = true
        XCTAssertEqual(ProcessingPipeline.stillOwed(run), .automatically)
        run.waitsForYou = true
        XCTAssertEqual(ProcessingPipeline.stillOwed(run), .waitsForYou)
    }

    // MARK: Activity

    private func attempt(_ finder: String, method: String, model: String? = nil, kept: String? = nil,
                         waits: Bool? = nil, failure: String? = nil, cuts: [(Double, Double, String)] = []) -> FinderAttempt {
        var run = ModelFinder.Run(finder: finder)
        run.keptEarlier = kept
        run.modelName = model
        run.waitsForYou = waits
        run.failure = failure
        let saved = cuts.map { ModelFinder.StoredCut(start: $0.0, end: $0.1, kind: $0.2, sponsor: "", confidence: 90, delivery: "",
                                                     comedyBit: false, insertedAtDownload: false, evidence: "") }
        return FinderAttempt(date: .now, guid: "g", show: "s", episode: "e", method: method, run: run, seconds: 1,
                             audioSeconds: 60, foreground: true, thermalAtStart: "nominal", thermalAtEnd: "nominal",
                             build: "test", readerCuts: [],
                             // Pass 46: a model votes with what it proposed and
                             // kept; here it proposed exactly what it saved.
                             proposedCuts: run.byModel ? saved : [], parts: [], savedCuts: saved, answerSample: "")
    }

    func testActivityNamesTheEngineAndModelAndWhetherItWasTheChosenOne() {
        XCTAssertNil(ProcessingPipeline.provenance(modelPending: false, attempts: []))
        XCTAssertEqual(ProcessingPipeline.provenance(modelPending: false, attempts: [
            attempt("coreAI", method: "Core AI · Qwen3 4B", model: "Qwen3 4B")]), "Core AI · Qwen3 4B")
        XCTAssertEqual(ProcessingPipeline.provenance(modelPending: true, attempts: [
            attempt("reader", method: "PodSkipper reader", model: "Qwen3 4B", kept: "MLX · Qwen3.5 4B", failure: "closed")]),
            "MLX · Qwen3.5 4B (kept) · Qwen3 4B reads it later")
        XCTAssertEqual(ProcessingPipeline.provenance(modelPending: true, attempts: [
            attempt("reader", method: "PodSkipper reader", model: "Qwen3 4B", waits: true, failure: "closed twice")]),
            "Reader for now · Qwen3 4B waits for you")
        XCTAssertEqual(ProcessingPipeline.provenance(modelPending: false, attempts: [
            attempt("reader", method: "PodSkipper reader", model: "Qwen3 4B", failure: "isn't downloaded")]),
            "Reader · Qwen3 4B not used")
        XCTAssertEqual(ProcessingPipeline.provenance(modelPending: false, attempts: [
            attempt("reader", method: "PodSkipper reader")]), "PodSkipper Reader")
        XCTAssertEqual(ProcessingPipeline.provenance(modelPending: false, attempts: [
            attempt("apple", method: "Apple Intelligence")]), "Apple Intelligence")
    }

    // MARK: The reader learns where models agree

    private let sentences = (0..<200).map { Sentence(text: "s\($0)", start: Double($0) * 10, end: Double($0) * 10 + 9) }
    private typealias Learner = OnDeviceReaderLearner
    private func teacher(_ family: String, _ cuts: [(Double, Double, SegmentKind)]) -> Learner.Teacher {
        Learner.Teacher(family: family, cuts: cuts.map { ($0.0, $0.1, $0.2) }, read: nil)
    }

    func testOneModelAloneTeachesNothing() {
        let qwen = [teacher("qwen", [(400, 460, .ad)]), teacher("qwen", [(400, 470, .ad)])]
        XCTAssertTrue(Learner.agreementLabels(sentences: sentences, teachers: qwen, inserted: []).isEmpty)
        XCTAssertEqual(Learner.family(of: "Core AI · Qwen3 4B"), Learner.family(of: "MLX · Qwen3.5 4B"))
        XCTAssertNotEqual(Learner.family(of: "Core AI · MiniCPM5 2B"), Learner.family(of: "MLX · Qwen3.5 4B"))
    }

    func testTwoFamiliesAgreeingTeachTheirLabelAndTheShowAroundIt() {
        let teachers = [teacher("qwen", [(400, 460, .ad), (1_500, 1_530, .selfPromo)]),
                        teacher("minicpm", [(410, 470, .ad), (1_500, 1_530, .ad)]),
                        teacher("apple", [(1_505, 1_525, .selfPromo)])]
        let labels = Learner.agreementLabels(sentences: sentences, teachers: teachers, inserted: [1_900...1_950])
        XCTAssertEqual(labels[42]?.label, 1, "both cut it as an ad")
        XCTAssertNil(labels[40], "only one family cut it: not taught either way")
        XCTAssertEqual(labels[151]?.label, 2, "two of three say self-promo")
        XCTAssertEqual(labels[192]?.label, 1, "stitched in, as the ad-free download showed")
        for (i, entry) in labels where entry.label == 0 {
            let t = Double(i) * 10 + 4.5
            XCTAssertTrue(t < 370 || (t > 500 && t < 1_470) || t > 1_560, "the show only well clear of every cut: \(t)")
        }
        let promo = labels.values.filter { $0.label != 0 }.reduce(Float(0)) { $0 + $1.weight }
        let show = labels.values.filter { $0.label == 0 }.reduce(Float(0)) { $0 + $1.weight }
        XCTAssertEqual(promo / (promo + show), Learner.promoShare, accuracy: 0.001, "the lab's balance holds")
        // A tie between families teaches nothing.
        let tie = Learner.agreementLabels(sentences: sentences, teachers: [teacher("qwen", [(400, 460, .ad)]),
                                                                          teacher("minicpm", [(400, 460, .intro)])], inserted: [])
        XCTAssertNil(tie[42])
    }

    func testTheReaderTrainsOnlyOnNewEvidence() {
        var status = Learner.Status()
        XCTAssertFalse(Learner.shouldTrain(status: status, gold: 0, silver: 0))
        XCTAssertTrue(Learner.shouldTrain(status: status, gold: 0, silver: 100))
        status.trainedGold = 0; status.trainedSilver = 100; status.rolledBack = true
        XCTAssertFalse(Learner.shouldTrain(status: status, gold: 0, silver: 100), "the same data again")
        XCTAssertFalse(Learner.shouldTrain(status: status, gold: 0, silver: 110), "a little more after a rollback")
        XCTAssertTrue(Learner.shouldTrain(status: status, gold: 0, silver: 125))
        XCTAssertTrue(Learner.shouldTrain(status: status, gold: 4, silver: 100), "a new correction")
        status.rolledBack = false
        XCTAssertTrue(Learner.shouldTrain(status: status, gold: 0, silver: 101))
    }

    func testOtherModelsVoteWithTheirNewestSavedCuts() {
        let log = [attempt("reader", method: "PodSkipper reader", kept: "MLX · Qwen3.5 4B"),
                   attempt("coreAI", method: "Core AI · MiniCPM5 2B", cuts: [(10, 20, "ad")]),
                   attempt("reader", method: "PodSkipper reader", cuts: [(5, 9, "ad")]),
                   attempt("model", method: "MLX · Qwen3.5 4B", cuts: [(30, 40, "selfPromo")]),
                   attempt("coreAI", method: "Core AI · MiniCPM5 2B", cuts: [(50, 60, "ad")])]
        let teachers = ProcessingPipeline.otherTeachers(log)
        XCTAssertEqual(teachers.map(\.family), ["minicpm", "qwen"])
        XCTAssertEqual(teachers.first?.cuts.first?.start, 10, "the newest of each")
        XCTAssertEqual(teachers.last?.cuts.first?.kind, .selfPromo)
    }
}

/// Pass 43: Qwen3.5 4B asked as the Mac lab measured best (`Profile.listener`).
final class Pass43PromptTests: XCTestCase {
    func testQwen35FourBIsAskedWithTheListenersRulesAndReminder() {
        let template = "{%- if enable_thinking is defined and enable_thinking is false %}<think>\\n\\n</think>"
        let big = ModelPromptPlan.plan(id: "mlx-community/Qwen3.5-4B-MLX-4bit", modelType: "qwen3_5",
                                       template: template, downloadBytes: 3_061_129_077)
        XCTAssertEqual(big.profile, .listener)
        XCTAssertTrue(big.summary.contains("repeated after each stretch"), big.summary)
        // Measured on the 4B only: the smaller ones, and other families, as before.
        for id in ["mlx-community/Qwen3.5-2B-MLX-4bit", "mlx-community/Qwen3.5-0.8B-MLX-4bit"] {
            XCTAssertEqual(ModelPromptPlan.plan(id: id, modelType: "qwen3_5", template: template, downloadBytes: 0).profile, .lean, id)
        }
        XCTAssertEqual(ModelPromptPlan.coreAI(id: "qwen3-4b", name: "Qwen3 4B", template: "enable_thinking", context: 4_096).profile, .lean)
        // Pass 44: the listener's short rules at that size (Pass44Tests).
        XCTAssertEqual(ModelPromptPlan.coreAI(id: "qwen3-4b", name: "Qwen3 4B", template: "enable_thinking", context: 2_047).profile, .compactListener,
                       "on the sequential engine, held under 2,048 tokens")

        let system = JudgePrompt.Profile.listener.system
        XCTAssertTrue(system.contains("GUEST_PLUG"))
        XCTAssertTrue(system.contains("«I»"), "the app's audio marks are explained")
        XCTAssertFalse(system.contains("\"properties\""), "the answer is described in words, not a schema")
        XCTAssertEqual(JudgePrompt.Profile.listener.schema, JudgePrompt.Profile.lean.schema)
        XCTAssertEqual(LocalJudge.heldAnswerCap(big), LocalJudge.heldAnswerCap(
            ModelPromptPlan.plan(id: "mlx-community/Qwen3-4B-4bit", modelType: "qwen3", template: template, downloadBytes: 0)))
        XCTAssertNil(JudgePrompt.Profile.lean.reminder)

        let lines = (0..<40).map { TimedLine(text: "line \($0)", start: Double($0) * 5, end: Double($0) * 5 + 4) }
        let user = JudgePrompt.userLocal(show: "Show", title: "Title", notes: "", lines: lines, window: 10..<20, spans: [],
                                         reminder: JudgePrompt.Profile.listener.reminder)
        XCTAssertTrue(user.hasSuffix(JudgePrompt.listenerReminder), "the task said again after the lines")
        XCTAssertTrue(user.contains("9 line 19\n\n"))
        XCTAssertEqual(JudgePrompt.userLocal(show: "Show", title: "Title", notes: "", lines: lines, window: 10..<20, spans: []),
                       JudgePrompt.userHeader(show: "Show", title: "Title", notes: "")
                        + JudgePrompt.stretch(lines: lines, window: 10..<20, spans: []), "other profiles as before")
        // A saved answer asked the old way isn't reused for the new one.
        var lean = big
        lean.profile = .lean
        XCTAssertNotEqual(big.identity, lean.identity)
    }
}

/// Pass 43: a job told to wait until he's back no longer holds up the line.
@MainActor
final class Pass43LineTests: XCTestCase {
    func testAWaitingJobDoesntHoldUpTheOnesBehindIt() async throws {
        let suite = "Pass43LineTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let folder = URL.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = ProcessingJobStore(file: folder.appending(path: "jobs.json"), defaults: defaults)
        func episode(_ guid: String) -> Episode {
            let episode = Episode(guid: guid, title: guid, episodeDescription: "", audioURL: "https://example.invalid/a.mp3",
                                  publishedAt: .now, duration: 60)
            container.mainContext.insert(episode)
            return episode
        }
        let a = episode("a"), b = episode("b")
        var started: [String] = []
        let pipeline = ProcessingPipeline(jobs: store, resources: HeavyWorkCoordinator()) { episode, _ in
            started.append(episode.guid)
        }
        pipeline.configure(context: container.mainContext, settings: AppSettings())
        pipeline.processNow([a, b])
        store.deferRetry("a", until: .distantFuture)
        let deadline = ContinuousClock.now + .seconds(5)
        while store.record("b")?.status != .completed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.record("b")?.status, .completed, "b went ahead")
        XCTAssertEqual(started, ["b"])
        XCTAssertEqual(pipeline.headOfLine, nil)
        XCTAssertTrue(pipeline.isWaiting("a"), "a is still in the line, waiting")
        await pipeline.processNow(a)
        XCTAssertEqual(started, ["b", "a"])
        XCTAssertEqual(store.record("a")?.status, .completed)
    }
}
