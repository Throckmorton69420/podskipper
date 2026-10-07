import Foundation
import Observation
import UIKit
import Darwin

/// The standard tests every ad finder takes (pass 27g, his request: rank
/// the models, keep each one's results, add a harder test, and run Apple
/// Intelligence and the reader through the same tests).
///
/// Two samples. Basic: 40 lines, one obvious host-read ad. Hard: 50 lines
/// with an intro, a tour plug, casual talk about a brand (keep), a joke ad
/// (keep), a host-read ad, a guest's special, another show's promo and the
/// credits. Each answer is scored by how well the lines it would cut match
/// the lines that should be cut (overlap ÷ union, 0–100 %).
enum BenchSample: String, Codable, CaseIterable, Sendable {
    case basic, hard

    var title: String { self == .basic ? "Basic" : "Hard" }
    /// Increment whenever the sample text, timing or expected truth changes.
    var version: Int { 1 }

    var show: String { self == .basic ? LocalJudgeSelfTest.show : "Late Shift" }
    var episode: String { self == .basic ? LocalJudgeSelfTest.title : "Loud Neighbors (with Sam Ortiz)" }
    var notes: String {
        self == .basic ? LocalJudgeSelfTest.notes
            : "Comedian Sam Ortiz joins Nora and Pete. Supported by Brightnest."
    }

    var lines: [TimedLine] {
        let text = self == .basic ? LocalJudgeSelfTest.lines.map(\.text) : Self.hardText
        return text.enumerated().map { TimedLine(text: $1, start: Double($0) * 6, end: Double($0) * 6 + 5.5) }
    }

    /// The lines that should be cut.
    var expectedCut: Set<Int> {
        switch self {
        case .basic: return Set(13...23)
        case .hard: return Set([0] + Array(10...12) + Array(19...24) + Array(33...35) + [42, 43] + Array(47...49))
        }
    }

    private static let hardText = [
        "You're listening to Late Shift with Nora and Pete, a Wavelength Media podcast.",   // 0 intro
        "Hey everybody, welcome back, I'm Nora and Pete is here too.",
        "I went to Costco yesterday and bought forty rolls of paper towels.",
        "Forty. For one person. What's your plan there?",
        "The plan is I never think about paper towels again until 2028.",
        "Did you at least get the hot dog?",
        "Of course I got the hot dog, a dollar fifty, it's the last honest price in America.",
        "That's actually true, Costco is great, I'm not even getting paid to say that.",
        "Nobody's paying us for anything, look at this microphone.",
        "It's held together with tape.",
        "Before we get into it, quick reminder we're on tour this fall.",                    // 10 self promo
        "Denver on the fourth, Austin on the twelfth, tickets at lateshiftlive dot com.",
        "Come say hi, we'll hang out after every show.",
        "Okay so my back has been killing me all week.",
        "You sleep on a couch, that's why.",
        "You know what this show needs? A sponsor for my bad back.",
        "Introducing Pete's Back Brace, now with extra duct tape, use code OUCH for nothing off.",  // 16 joke ad (keep)
        "Please nobody make that, I'm begging you.",
        "Anyway, speaking of backs, let's take a quick break.",
        "Today's episode is supported by Brightnest, the mattress company.",                 // 19 ad
        "I've been sleeping on my Brightnest for three weeks and my back finally stopped hurting.",
        "It ships in a box, and you get a hundred nights to try it at home.",
        "If you don't love it they pick it up for free.",
        "Go to brightnest dot com slash late and get fifteen percent off your mattress.",
        "That's brightnest dot com slash late, fifteen percent off.",
        "Okay, we're back, and we have a guest today.",
        "Our guest is the very funny comedian Sam Ortiz.",
        "Thanks for having me, I love this show, I listen in the car.",
        "You listen to this in the car? On purpose?",
        "On purpose, it keeps me awake on long drives.",
        "So Sam, you grew up in Tucson, right?",
        "Tucson, yeah, it's a hundred and ten degrees and everyone is fine with it.",
        "My dad used to fry eggs on the hood of his truck to prove a point.",
        "And you've got a new special out, right?",                                          // 33 guest plug
        "Yeah, it's called Loud Neighbors, it's streaming on Netflix starting Friday.",
        "Go watch it, I think it's the best thing I've ever done.",
        "What's the story behind the title?",
        "My upstairs neighbor plays the drums at two in the morning.",
        "Just drums? No band?",
        "No band, just him and his anger.",
        "Did you ever complain?",
        "I wrote an hour of comedy about it instead, that's my complaint.",
        "If you like this show, check out Morning Static, another Wavelength Media podcast.",  // 42 network promo
        "New episodes every Tuesday, search Morning Static wherever you listen.",
        "Alright Sam, this was a blast.",
        "Thanks guys, this was fun, I'll come back anytime.",
        "Pete, fix the microphone before next week.",
        "That's the show, thanks to Sam Ortiz for stopping by.",                             // 47 outro
        "Late Shift is produced by Danny Cole, with music by The Fold.",
        "See you next week, everybody.",
    ]

    /// Overlap ÷ union of the cut lines, 0–1 (1 when both are empty).
    func score(cut: Set<Int>) -> Double {
        let union = cut.union(expectedCut)
        guard !union.isEmpty else { return 1 }
        return Double(cut.intersection(expectedCut).count) / Double(union.count)
    }
}

/// One finder's answer to one sample.
struct BenchResult: Codable, Sendable, Equatable, Identifiable {
    var runID: UUID
    var policyVersion: Int
    var sampleVersion: Int
    var engine: String
    var name: String
    var sample: BenchSample
    var date: Date
    var score: Double?
    var readTPS: Double
    var writeTPS: Double
    var seconds: Double
    var peakBytes: Int
    var found: [String]
    var error: String?
    var answerStart: String
    var modelIdentity: String?
    var thermalBefore: Int
    var thermalAfter: Int
    var batteryDelta: Double?
    var freeMemoryBefore: Int
    var freeMemoryAfter: Int

    init(engine: String, name: String, sample: BenchSample, date: Date, score: Double?,
         readTPS: Double = 0, writeTPS: Double = 0, seconds: Double = 0, peakBytes: Int = 0,
         found: [String] = [], error: String? = nil, answerStart: String = "",
         thermalBefore: Int = -1, thermalAfter: Int = -1, batteryDelta: Double? = nil,
         freeMemoryBefore: Int = 0, freeMemoryAfter: Int = 0,
         policyVersion: Int? = nil, sampleVersion: Int? = nil, runID: UUID = UUID(), modelIdentity: String? = nil) {
        self.modelIdentity = modelIdentity
        self.runID = runID; self.policyVersion = policyVersion ?? Self.currentPolicy(for: engine)
        self.sampleVersion = sampleVersion ?? sample.version
        self.engine = engine; self.name = name; self.sample = sample; self.date = date; self.score = score
        self.readTPS = readTPS; self.writeTPS = writeTPS; self.seconds = seconds; self.peakBytes = peakBytes
        self.found = found; self.error = error; self.answerStart = answerStart
        self.thermalBefore = thermalBefore; self.thermalAfter = thermalAfter
        self.batteryDelta = batteryDelta; self.freeMemoryBefore = freeMemoryBefore; self.freeMemoryAfter = freeMemoryAfter
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runID = try c.decodeIfPresent(UUID.self, forKey: .runID) ?? UUID()
        policyVersion = try c.decodeIfPresent(Int.self, forKey: .policyVersion) ?? 0
        sampleVersion = try c.decodeIfPresent(Int.self, forKey: .sampleVersion) ?? 0
        engine = try c.decode(String.self, forKey: .engine)
        name = try c.decode(String.self, forKey: .name)
        sample = try c.decode(BenchSample.self, forKey: .sample)
        date = try c.decode(Date.self, forKey: .date)
        score = try c.decodeIfPresent(Double.self, forKey: .score)
        readTPS = try c.decodeIfPresent(Double.self, forKey: .readTPS) ?? 0
        writeTPS = try c.decodeIfPresent(Double.self, forKey: .writeTPS) ?? 0
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
        peakBytes = try c.decodeIfPresent(Int.self, forKey: .peakBytes) ?? 0
        found = try c.decodeIfPresent([String].self, forKey: .found) ?? []
        error = try c.decodeIfPresent(String.self, forKey: .error)
        modelIdentity = try c.decodeIfPresent(String.self, forKey: .modelIdentity)
        answerStart = try c.decodeIfPresent(String.self, forKey: .answerStart) ?? ""
        thermalBefore = try c.decodeIfPresent(Int.self, forKey: .thermalBefore) ?? -1
        thermalAfter = try c.decodeIfPresent(Int.self, forKey: .thermalAfter) ?? -1
        batteryDelta = try c.decodeIfPresent(Double.self, forKey: .batteryDelta)
        freeMemoryBefore = try c.decodeIfPresent(Int.self, forKey: .freeMemoryBefore) ?? 0
        freeMemoryAfter = try c.decodeIfPresent(Int.self, forKey: .freeMemoryAfter) ?? 0
    }

    var id: UUID { runID }
    var lookupKey: String { engine + "/" + sample.rawValue }
    var isComparable: Bool { policyVersion == Self.currentPolicy(for: engine) && sampleVersion == sample.version }

    /// Pass 31: open models are asked differently now (short answer, each
    /// stretch numbered from 0, thinking handled per template), so their
    /// earlier results are marked "earlier policy". Apple Intelligence and
    /// the reader are asked as before.
    static func currentPolicy(for engine: String) -> Int {
        engine == "apple" || engine == "reader" ? 2 : 3
    }
}

/// Every result, kept across launches, and which finders are turned on.
@MainActor
@Observable
final class ModelBench {
    static let shared = ModelBench()

    private(set) var results: [String: BenchResult] = [:]
    private(set) var history: [BenchResult] = []
    private(set) var disabled: Set<String> = []
    /// The finder being tested now, and its current step.
    private(set) var running: String?
    private(set) var runningName: String?
    private(set) var runningSample: BenchSample?
    private(set) var step = ""
    private(set) var stopping = false
    private(set) var waiting = false
    private(set) var startedAt: Date?
    /// 0–1 through the test, as far as the model reports it (pass 29).
    private(set) var fraction: Double = 0
    private(set) var requestError: String?
    @ObservationIgnored private var activeRunID: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?

    private static let resultsKey = "modelBench.results.v1"
    private static let historyKey = "modelBench.history.v2"
    @ObservationIgnored private let defaults: UserDefaults
    private static let disabledKey = "modelBench.disabled.v1"

    init(defaults: UserDefaults = .standard, recoverInterrupted: Bool = true) {
        self.defaults = defaults
        let d = defaults
        if let data = d.data(forKey: Self.resultsKey),
           let saved = try? JSONDecoder().decode([String: BenchResult].self, from: data) {
            results = saved
        }
        disabled = Set(d.stringArray(forKey: Self.disabledKey) ?? [])
        if let data = d.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode([BenchResult].self, from: data) {
            history = saved
            for result in saved.sorted(by: { $0.date < $1.date }) { results[result.lookupKey] = result }
        } else {
            history = Array(results.values)
        }
        importOldSelfTests()
        // Read at launch, so a model that got the app closed shows it at once.
        if recoverInterrupted, let killed = Breadcrumb.staleFromEarlierLaunch() {
            let smaller = Breadcrumb.lowerCap(model: killed.model, below: killed.window)
            BackgroundLog.shared.note("Last time iOS closed PodSkipper while \(LocalModelSpec.named(killed.model).name) was reading (\(killed.window)-token parts). From now on it reads parts of at most \(smaller) tokens.")
            recordClosed(model: killed.model)
        }
        if recoverInterrupted, let stopped = CoreAIInFlight.staleFromEarlierLaunch() {
            let where_ = stopped.episode.isEmpty ? "a test" : "an episode"
            BackgroundLog.shared.note("Last time PodSkipper closed while Core AI \(stopped.name) was reading \(where_)\(stopped.stage.isEmpty ? "" : " (" + stopped.stage + ")") — iOS closed it, or the Core AI runtime itself crashed (an Apple Metal/MPSGraph abort the app can't catch). Check Diagnostics → crash reports.")
            // Pass 32: an episode it closed the app on isn't read by it again
            // until he asks (no crash loop); a test's own result says so.
            CoreAICrashGuard.remember(stopped)
            let engine = CoreAIQwen3.benchmarkID(for: stopped.id)
            for sample in BenchSample.allCases where stopped.episode.isEmpty && result(engine, sample) == nil {
                save(BenchResult(engine: engine, name: "Core AI · " + stopped.name, sample: sample, date: .now, score: nil,
                                 error: "PodSkipper closed while this model was running (iOS, or a Core AI runtime crash)."))
            }
        }
    }

    func result(_ engine: String, _ sample: BenchSample) -> BenchResult? { results[engine + "/" + sample.rawValue] }

    /// 0–1 across the samples it has taken, or nil if never tested.
    func score(_ engine: String) -> Double? {
        let scores = BenchSample.allCases.compactMap { result(engine, $0) }.filter(\.isComparable).compactMap(\.score)
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }

    /// Accuracy is always the primary ordering; speed only breaks equal scores.
    func rank(_ engine: String) -> Double { score(engine) ?? -1 }
    func speed(_ engine: String) -> Double {
        BenchSample.allCases.compactMap { result(engine, $0) }
            .filter(\.isComparable).map(\.readTPS).max() ?? 0
    }

    /// Every result as text, for the Diagnostics file.
    var summary: String {
        let sorted = history.sorted { ($0.name, $0.sample.rawValue) < ($1.name, $1.sample.rawValue) }
        return sorted.map(Self.line).joined(separator: "  ||  ")
    }

    private static func line(_ r: BenchResult) -> String {
        let score: String = r.score.map { "\(Int(($0 * 100).rounded()))%" } ?? "✕ \(r.error ?? "")"
        let found: String = r.found.isEmpty ? "nothing" : r.found.joined(separator: ", ")
        let began: String = r.answerStart.isEmpty ? ""
            : " · began: " + String(r.answerStart.replacingOccurrences(of: "\n", with: " ").prefix(160))
        let speed = "\(Int(r.readTPS.rounded())) tok/s · \(Int(r.seconds.rounded())) s"
        var device = ""
        if r.thermalBefore >= 0 || r.thermalAfter >= 0 { device += " · thermal \(r.thermalBefore)→\(r.thermalAfter)" }
        if let delta = r.batteryDelta { device += String(format: " · battery %.1f%%", delta * 100) }
        return "\(r.name) [\(r.engine)] · run \(r.runID.uuidString) · \(r.sample.title) · policy \(r.policyVersion) · \(score) · \(speed) · found: \(found)\(began)\(device)"
    }

    func clearRequestError() { requestError = nil }

    func isEnabled(_ engine: String) -> Bool { !disabled.contains(engine) }

    func setEnabled(_ engine: String, _ on: Bool) {
        if on { disabled.remove(engine) } else { disabled.insert(engine) }
        defaults.set(Array(disabled), forKey: Self.disabledKey)
    }

    func latestSummary(_ engine: String) -> String? {
        let results = BenchSample.allCases.compactMap { sample -> String? in
            guard let result = result(engine, sample) else { return nil }
            return sample.title + ": " + (result.score.map { "\(Int(($0 * 100).rounded()))% match" } ?? "Failed")
                + (result.isComparable ? "" : " · earlier policy")
        }
        return results.isEmpty ? nil : results.joined(separator: " · ")
    }

    var isRunning: Bool { running != nil }

    // MARK: Running

    /// Both samples with the selected downloaded model.
    func testSelectedModel(sample: BenchSample) {
        let spec = ModelStore.shared.selected
        guard ModelStore.shared.isReady, isEnabled(spec.id) else {
            requestError = "Download the selected MLX model before testing it."
            return
        }
        testModel(spec, sample: sample)
    }

    /// Pass 32 (his 7 Oct request): Basic or Hard on any downloaded,
    /// switched-on MLX model, from its own row — it doesn't have to be the
    /// chosen one.
    func testModel(_ spec: LocalModelSpec, sample: BenchSample) {
        guard ModelStore.shared.isDownloaded(spec), isEnabled(spec.id) else {
            requestError = "Download " + spec.name + " and switch it on before testing it."
            return
        }
        start(engine: spec.id, name: spec.name, sample: sample, modelIdentity: spec.id + " @ " + spec.revision) { sample in
            let report = try await LocalJudge.shared.judgeReport(
                lines: sample.lines, show: sample.show, title: sample.episode, notes: sample.notes,
                evidence: [], only: nil, model: spec, progress: self.progressHandler(),
                status: self.statusHandler(engine: spec.id), requireCompleteAnswer: true)
            try Task.checkCancellation()
            return Self.classificationResult(report, engine: spec.id, name: spec.name, sample: sample)
        }
    }

    @available(iOS 27.0, *)
    func testCoreAI(sample: BenchSample) {
        guard let selected = CoreAIModelLibrary.shared.selectedEntry else {
            requestError = "Choose a Core AI model before testing it."
            return
        }
        guard CoreAIModelLibrary.shared.isReady else {
            requestError = "Download " + selected.name + " before testing it."
            return
        }
        testCoreAI(selected, sample: sample)
    }

    /// Pass 32: Basic or Hard on any downloaded, usable Core AI model, from
    /// its own row.
    @available(iOS 27.0, *)
    func testCoreAI(_ selected: CoreAIModelDescriptor, sample: BenchSample) {
        let library = CoreAIModelLibrary.shared
        guard selected.isCompatible, library.isDownloaded(selected),
              isEnabled(CoreAIQwen3.benchmarkID(for: selected.id)) else {
            requestError = "Download " + selected.name + " and switch it on before testing it."
            return
        }
        let engine = CoreAIQwen3.benchmarkID(for: selected.id)
        let name = "Core AI · " + selected.name
        start(engine: engine, name: name, sample: sample, modelIdentity: selected.repo + " @ " + (selected.revision ?? "Unknown revision") + " / " + (selected.variant ?? "Unknown variant")) { sample in
            let report = try await CoreAIAdJudge.shared.judgeReport(
                lines: sample.lines, show: sample.show, title: sample.episode,
                notes: sample.notes, evidence: [], corrections: "", modelID: selected.id,
                progress: self.progressHandler(), status: self.statusHandler(engine: engine), requireCompleteAnswer: true, expectedModel: selected)
            try Task.checkCancellation()
            return Self.classificationResult(report, engine: engine, name: name, sample: sample)
        }
    }

    private func progressHandler() -> @Sendable (Double) -> Void {
        let runID = activeRunID
        return { [weak self] value in
            Task { @MainActor in
                guard let self, self.activeRunID == runID, !self.stopping else { return }
                self.fraction = max(self.fraction, min(1, value))
            }
        }
    }

    /// How long this test took last time it finished, for "about N left".
    var expectedSeconds: Double? {
        guard let engine = running, let sample = runningSample,
              let last = result(engine, sample), last.error == nil, last.seconds > 1 else { return nil }
        return last.seconds
    }

    /// Seconds left: from the model's own progress once it is under way,
    /// else from how long the last run took.
    func secondsLeft(now: Date) -> Double? {
        guard let startedAt else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        // Pass 31: the work meter's own count (tokens left to read and
        // write at this model's measured speeds), ticking down between its
        // updates.
        if let (left, at) = LocalJudgeMonitor.shared.meterReading {
            return max(0, left - now.timeIntervalSince(at))
        }
        if fraction > 0.1 { return max(0, elapsed / fraction - elapsed) }
        if let expected = expectedSeconds { return max(0, expected - elapsed) }
        return nil
    }

    /// Pass 32 (his 7 Oct phone: the time left still wasn't right): said as
    /// honestly as the numbers allow. Until this model's speed on this phone
    /// is known, it says it is measuring; while an answer runs longer than
    /// usual, it gives the most it could take (every answer to its cap) as
    /// well as the likely time.
    func timeLeftText(now: Date) -> String? {
        let monitor = LocalJudgeMonitor.shared
        guard let left = secondsLeft(now: now) else { return nil }
        func clock(_ s: Double) -> String { Duration.seconds(max(1, s.rounded())).formatted(.time(pattern: .minuteSecond)) }
        if monitor.meterReading != nil {
            let worst = monitor.worstSecondsLeft.map { max(0, $0 - now.timeIntervalSince(monitor.secondsLeftAt ?? now)) }
            if !monitor.speedKnown { return "Measuring this model's speed on your iPhone…" }
            if let worst, !monitor.estimateConfident || worst > left * 1.5, worst - left >= 20 {
                return "About " + clock(left) + " left · up to " + clock(worst) + " if it writes its longest answer"
            }
        }
        return left >= 1 ? "About " + clock(left) + " left" : "Finishing"
    }

    /// 0–1 for the bar: the model's progress, or time against the last run.
    func shownFraction(now: Date) -> Double? {
        if fraction > 0 { return fraction }
        guard let startedAt, let expected = expectedSeconds else { return nil }
        return min(0.95, now.timeIntervalSince(startedAt) / expected)
    }

    private func statusHandler(engine: String) -> @Sendable (String) -> Void {
        let runID = activeRunID
        return { [weak self] message in
            Task { @MainActor in
                guard let self, self.activeRunID == runID, self.running == engine, !self.stopping else { return }
                self.step = message
            }
        }
    }

    static func classificationResult(_ report: JudgeReport, engine: String, name: String, sample: BenchSample) -> BenchResult {
        let stats = report.stats
        let cut = Set(report.parts.filter { $0.isCut && !$0.funny }.flatMap { $0.firstLine...$0.lastLine })
        return BenchResult(engine: engine, name: name, sample: sample, date: .now,
                           score: report.failedLines.isEmpty ? sample.score(cut: cut) : nil,
                           readTPS: stats.readTokensPerSecond, writeTPS: stats.writeTokensPerSecond,
                           seconds: stats.loadSeconds + stats.promptSeconds + stats.generateSeconds,
                           peakBytes: stats.peakMemoryBytes,
                           found: report.parts.map { "\($0.label.rawValue) \($0.firstLine)–\($0.lastLine)" },
                           error: report.failedLines.isEmpty ? nil : (stats.failureDetails ?? BenchError.unreadableAnswer.localizedDescription),
                           answerStart: stats.answerSample)
    }

    func testDetector(apple: Bool, sample: BenchSample) {
        let engine = apple ? "apple" : "reader"
        let name = apple ? "Apple Intelligence" : "PodSkipper reader"
        start(engine: engine, name: name, sample: sample) { sample in
            if apple, let why = AdDetector.availability() { throw BenchError.unavailable(why) }
            let lines = sample.lines
            let segments = lines.map { TranscriptSegment(text: $0.text, start: $0.start, end: $0.end, words: []) }
            let started = Date.now
            let previousTuning = SegmentDetector.tuning
            SegmentDetector.tuning.ownReader = !apple
            defer { SegmentDetector.tuning = previousTuning }
            let result = try await AdDetector().detectSentences(
                segments: segments, showTitle: sample.show, episodeTitle: sample.episode,
                showNotes: sample.notes, audioDuration: lines.last?.end ?? 0)
            try Task.checkCancellation()
            var cut = Set<Int>()
            for segment in result.segments {
                for (i, line) in lines.enumerated() where (line.start + line.end) / 2 >= segment.start
                    && (line.start + line.end) / 2 <= segment.end { cut.insert(i) }
            }
            let found = result.segments.map { segment -> String in
                let inside = lines.indices.filter { (lines[$0].start + lines[$0].end) / 2 >= segment.start
                    && (lines[$0].start + lines[$0].end) / 2 <= segment.end }
                return "\(segment.kind.rawValue) \(inside.first ?? 0)–\(inside.last ?? 0)"
            }
            return BenchResult(engine: engine, name: name, sample: sample, date: .now,
                               score: sample.score(cut: cut), seconds: Date.now.timeIntervalSince(started),
                               found: found)
        }
    }

    func stop() {
        guard running != nil else { return }
        stopping = true
        step = "Stopping…"
        task?.cancel()
        Feel.warning.play()
    }

    func start(engine: String, name: String, sample: BenchSample, modelIdentity: String? = nil,
                       run: @escaping @MainActor (BenchSample) async throws -> BenchResult) {
        guard running == nil else {
            requestError = "A test is already running. Stop it before starting another."
            return
        }
        requestError = nil
        activeRunID = UUID()
        running = engine
        runningName = name
        runningSample = sample
        stopping = false
        fraction = 0
        waiting = HeavyWorkCoordinator.shared.isBusy
        // Say what it waits for (his 5 Oct phone: "waiting for other
        // processing" with nothing visibly running).
        let owner = HeavyWorkCoordinator.shared.current?.owner ?? ""
        step = !waiting ? "Starting test"
            : owner.hasPrefix("episode:") ? "Waiting for Find Ads on an episode to finish. Pause it in Activity to test now."
            : owner.hasPrefix("benchmark:") ? "Waiting for the previous test to stop"
            : "Waiting for background work to finish (getting episodes ready)"
        task = Task { @MainActor in
            var lease: HeavyWorkCoordinator.Lease?
            defer {
                activeRunID = nil
                running = nil
                runningName = nil
                runningSample = nil
                step = ""
                stopping = false
                waiting = false
                startedAt = nil
                fraction = 0
                task = nil
                if let lease { HeavyWorkCoordinator.shared.release(lease) }
            }
            var before: BenchDeviceSnapshot?
            do {
                lease = try await HeavyWorkCoordinator.shared.acquire(owner: "benchmark:" + engine, priority: .user)
                try Task.checkCancellation()
                waiting = false
                startedAt = .now
                step = "Reading sample"
                before = BenchDeviceSnapshot.capture()
                var result = try await run(sample)
                result.modelIdentity = modelIdentity
                try Task.checkCancellation()
                let after = BenchDeviceSnapshot.capture()
                result.thermalBefore = before?.thermal ?? -1
                result.thermalAfter = after.thermal
                result.freeMemoryBefore = before?.freeMemory ?? 0
                result.freeMemoryAfter = after.freeMemory
                if let a = before?.battery, let b = after.battery { result.batteryDelta = b - a }
                result.seconds = startedAt.map { Date.now.timeIntervalSince($0) } ?? result.seconds
                save(result)
                Feel.confirm.play()
            } catch is CancellationError {
                // Deliberately quiet: Stop is an expected user action.
            } catch {
                if !Task.isCancelled {
                    let after = BenchDeviceSnapshot.capture()
                    save(BenchResult(engine: engine, name: name, sample: sample, date: .now, score: nil,
                                     seconds: startedAt.map { Date.now.timeIntervalSince($0) } ?? 0,
                                     error: step + ": " + error.localizedDescription,
                                     thermalBefore: before?.thermal ?? -1, thermalAfter: after.thermal,
                                     freeMemoryBefore: before?.freeMemory ?? 0, freeMemoryAfter: after.freeMemory, modelIdentity: modelIdentity))
                }
            }


        }
    }

    /// iOS closed the app while this model was reading (from the breadcrumb).
    func recordClosed(model id: String) {
        let name = LocalModelSpec.named(id).name
        for sample in BenchSample.allCases where result(id, sample) == nil {
            save(BenchResult(engine: id, name: name, sample: sample, date: .now, score: nil,
                             error: "iOS closed the app during this test. Diagnostics are needed to determine why."))
        }
    }

    func save(_ result: BenchResult) {
        results[result.lookupKey] = result
        history.append(result)
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: Self.historyKey) }
        if let data = try? JSONEncoder().encode(results) {
            defaults.set(data, forKey: Self.resultsKey)
        }
    }

    /// His 30 Sep self-tests (one text line per model) become Basic results.
    private func importOldSelfTests() {
        guard let all = defaults.dictionary(forKey: "localJudge.selfTests") as? [String: String] else { return }
        for (name, line) in all {
            guard let spec = LocalModelSpec.all.first(where: { $0.name == name }),
                  result(spec.id, .basic) == nil else { continue }
            if line.contains("failed:") {
                let why = line.components(separatedBy: "failed: ").last ?? "failed"
                save(BenchResult(engine: spec.id, name: name, sample: .basic, date: .distantPast, score: nil, error: why, policyVersion: 0))
                continue
            }
            let tps = Double(Self.capture(line, #"read (\d+) tok/s"#) ?? "") ?? 0
            let wtps = Double(Self.capture(line, #"wrote ([\d.]+) tok/s"#) ?? "") ?? 0
            let foundText = Self.capture(line, #"found: (.*?)( · answer began:|$)"#) ?? "nothing"
            var cut = Set<Int>(), found: [String] = []
            if foundText != "nothing" {
                for piece in foundText.components(separatedBy: ", ") {
                    let bits = piece.split(separator: " ")
                    guard bits.count == 2, let label = JudgeLabel(rawValue: String(bits[0])) else { continue }
                    let range = bits[1].split(separator: "–").compactMap { Int($0) }
                    guard range.count == 2, range[0] <= range[1] else { continue }
                    found.append(piece)
                    if label.segmentKind != nil { cut.formUnion(range[0]...range[1]) }
                }
            }
            save(BenchResult(engine: spec.id, name: name, sample: .basic, date: .distantPast,
                             score: BenchSample.basic.score(cut: cut), readTPS: tps, writeTPS: wtps, found: found, policyVersion: 0))
        }
    }

    private static func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
enum BenchError: LocalizedError {
    case unavailable(String)
    case jobRunning
    case unreadableAnswer
    var errorDescription: String? {
        switch self {
        case .unavailable(let why): return "Apple Intelligence isn't available: \(why)"
        case .jobRunning: return "An episode is being processed; run this test when it's done."
        case .unreadableAnswer: return "The model did not return a complete, readable classification."
        }
    }
}

private struct BenchDeviceSnapshot {
    let thermal: Int
    let battery: Double?
    let freeMemory: Int

    static func capture() -> BenchDeviceSnapshot {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        let battery = device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil
        return BenchDeviceSnapshot(thermal: thermal, battery: battery,
                                   freeMemory: Int(os_proc_available_memory()))
    }
}
