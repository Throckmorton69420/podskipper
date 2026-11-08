import Foundation
import Observation
import SwiftData
import UIKit
import os

/// Pass 60 (his 7 Nov request, MODEL-TEST §8): the PodSkipper test on the
/// phone — Compare Models › Run the Test. Every engine reads his test
/// episodes (labelled by hand, never learned from) from the transcripts
/// already on his iPhone, through the app's own path: the Reader, then for a
/// model `ModelFinder.focusRanges` → the model → `ModelFinder.checkedCuts`.
/// Nothing is saved to the episodes; each read is recorded here, scored with
/// `PodTestScore` exactly as the lab's `podtest.py`, and exported with
/// Diagnostics (time spans and kinds only).

enum PodTestEngineKind: String, Codable, Sendable, CaseIterable {
    case reader, mlx, cpu, coreAI, apple
}

/// One run of the test: which engines read which episodes, and what each
/// read cut. Saved after every read, so a closed app resumes where it was.
struct PodTestRun: Codable, Sendable, Identifiable, Equatable {
    enum State: String, Codable, Sendable { case running, completed, stopped, interrupted }

    struct Read: Codable, Sendable, Equatable {
        enum Outcome: String, Codable, Sendable { case pending, reading, completed, failed, skipped }
        var guid: String
        var outcome: Outcome = .pending
        var cuts: [PodTestCut] = []
        var seconds: Double = 0
        var note: String?
        /// Times PodSkipper closed while this read was under way.
        var closures: Int = 0
        var finished: Date?
        /// Model reads: parts asked and the share of the transcript read.
        var parts: Int?
        var share: Double?
        /// His lessons left out because they came from this very episode.
        var lessonsLeftOut: Int?
    }

    struct Engine: Codable, Sendable, Equatable, Identifiable {
        var engine: String
        var name: String
        var kind: PodTestEngineKind
        var modelID: String?
        var modelIdentity: String?
        var reads: [Read]
        var id: String { engine }

        func read(_ guid: String) -> Read? { reads.first { $0.guid == guid } }
        /// Completed reads' cuts, by episode.
        var cuts: [String: [PodTestCut]] {
            Dictionary(reads.filter { $0.outcome == .completed }.map { ($0.guid, $0.cuts) }, uniquingKeysWith: { a, _ in a })
        }
    }

    struct Skip: Codable, Sendable, Equatable {
        var guid: String
        var reason: String
    }

    var runID: UUID
    var started: Date
    var finished: Date?
    var state: State
    var appBuild: String
    var device: String
    var packVersion: Int
    var engines: [Engine]
    var skipped: [Skip] = []
    /// Pass 62: a stopped run he set aside ("Keep Prior Results"): kept in
    /// Earlier Runs, never offered to resume.
    var dismissed: Bool? = nil
    var id: UUID { runID }

    var reads: [Read] { engines.flatMap(\.reads) }
    var doneReads: Int { reads.filter { [.completed, .failed, .skipped].contains($0.outcome) }.count }
    var isUnfinished: Bool {
        state != .completed && dismissed != true && reads.contains { $0.outcome == .pending || $0.outcome == .reading }
    }
    /// Pass 62: reads that finished with cuts (what a results table shows).
    var completedReads: Int { reads.filter { $0.outcome == .completed }.count }
    /// Pass 62: completed reads of any finder but the Reader.
    var completedModelReads: Int {
        engines.filter { $0.kind != .reader }.reduce(0) { $0 + $1.reads.filter { $0.outcome == .completed }.count }
    }
    var reader: Engine? { engines.first { $0.kind == .reader } }

    /// After an earlier launch ended mid-run: the run is interrupted, and a
    /// read under way then counts a closure — after `closuresAllowed` it is
    /// recorded as failed rather than tried again (a model that closes the
    /// app must not do it in a loop).
    func recoveredAfterClosing(closuresAllowed: Int) -> PodTestRun {
        var run = self
        guard run.state == .running else { return run }
        run.state = .interrupted
        for e in run.engines.indices {
            for r in run.engines[e].reads.indices where run.engines[e].reads[r].outcome == .reading {
                run.engines[e].reads[r].closures += 1
                if run.engines[e].reads[r].closures >= closuresAllowed {
                    run.engines[e].reads[r].outcome = .failed
                    run.engines[e].reads[r].note = "PodSkipper closed \(run.engines[e].reads[r].closures) times while reading this episode"
                    run.engines[e].reads[r].finished = .now
                } else {
                    run.engines[e].reads[r].outcome = .pending
                }
            }
        }
        return run
    }

    /// An engine scored beside the Reader on the episodes both completed.
    struct Comparison: Sendable, Equatable {
        var engine: PodTestScore.Summary
        var reader: PodTestScore.Summary
    }

    func comparison(_ engineID: String, pack: PodTestPack) -> Comparison? {
        guard let engine = engines.first(where: { $0.engine == engineID }), let reader else { return nil }
        let both = Set(engine.cuts.keys).intersection(reader.cuts.keys)
        guard !both.isEmpty else { return nil }
        return Comparison(engine: PodTestScore.summary(pack: pack, cuts: engine.cuts, guids: both),
                          reader: PodTestScore.summary(pack: pack, cuts: reader.cuts, guids: both))
    }
}

/// The runs, in a file of their own (Application Support/PodTest).
struct PodTestStore: Sendable {
    let url: URL
    static let keep = 20
    static let standard = PodTestStore(url: URL.applicationSupportDirectory.appending(path: "PodTest/runs.json"))

    private struct File: Codable { var version = 1; var runs: [PodTestRun] }

    func load() -> [PodTestRun] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder.podTest.decode(File.self, from: data))?.runs ?? []
    }

    func save(_ runs: [PodTestRun]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.iso.encode(File(runs: Array(runs.suffix(Self.keep)))).write(to: url, options: .atomic)
    }
}

extension JSONDecoder {
    static let podTest: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// What one episode gives every engine: the same inputs a Find Ads job
/// builds (`ProcessingPipeline.detectAndSave`), from what is stored.
struct PodTestInputs {
    var guid: String
    var segments: [TranscriptSegment]
    var lines: [TimedLine]
    var silences: [ClosedRange<Double>]
    var inserted: [InsertedSpan]
    var produced: [AdPrints.Produced]
    var knownSponsors: [String]
    var showLessons: [DetectionCorrection]
    var globalLessons: [DetectionCorrection]
    var lessonsLeftOut: Int
    var show: String
    var title: String
    var notes: String
    var showNotes: String
    var episodeDuration: Double
    var minimumConfidence: Int
    var padding: Double

    var duration: Double { episodeDuration > 0 ? episodeDuration : (lines.last?.end ?? 0) }
    var evidence: [EvidenceSpan] { ModelFinder.evidence(inserted: inserted, produced: produced) }
}

@MainActor
@Observable
final class PodTestRunner {
    static let shared = PodTestRunner()

    /// The phone's copy must be within this of the length labelled (an ad
    /// server's new ads make a different file whose times don't line up).
    nonisolated static let durationTolerance = 3.0
    nonisolated static let closuresAllowed = 2
    static let awakeReason = "podskipper test"
    private static let leftOutKey = "podTest.leftOutKinds.v1"
    /// Pass 62: each finder's switch, by engine id (any downloaded model).
    private static let choicesKey = "podTest.engineChoices.v2"

    @ObservationIgnored let pack: PodTestPack?
    @ObservationIgnored private let store: PodTestStore
    @ObservationIgnored private let defaults: UserDefaults

    private(set) var runs: [PodTestRun]
    private(set) var isRunning = false
    private(set) var stopping = false
    private(set) var pausedOffScreen = false
    private(set) var waiting = false
    private(set) var activeEngine: String?
    private(set) var activeEngineName: String?
    private(set) var activeEpisode = 0
    private(set) var episodeCount = 0
    private(set) var step = ""
    private(set) var fraction = 0.0
    private(set) var startedAt: Date?
    private(set) var leftOutKinds: Set<PodTestEngineKind>
    /// Pass 62: on/off per engine id; an engine not here follows `defaultOn`.
    private(set) var engineChoices: [String: Bool]
    var requestError: String?
    private(set) var saveError: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var readerCache: [String: [DetectedSegment]] = [:]
    @ObservationIgnored private var readToken = UUID()

    init(store: PodTestStore = .standard, pack: PodTestPack? = .bundled(), defaults: UserDefaults = .standard) {
        // Screenshot runs keep their runs out of the simulator's own file.
        self.store = DemoData.isEnabled
            ? PodTestStore(url: FileManager.default.temporaryDirectory.appending(path: "podtest-demo-\(UUID().uuidString).json"))
            : store
        self.pack = pack
        self.defaults = defaults
        leftOutKinds = Set((defaults.stringArray(forKey: Self.leftOutKey) ?? []).compactMap(PodTestEngineKind.init(rawValue:)))
        engineChoices = (defaults.dictionary(forKey: Self.choicesKey) as? [String: Bool]) ?? [:]
        let loaded = self.store.load()
        runs = loaded.map { $0.recoveredAfterClosing(closuresAllowed: Self.closuresAllowed) }
        if runs != loaded { persist() }
        if DemoData.isEnabled, ProcessInfo.processInfo.arguments.contains("-PodTestDemo"), let pack {
            runs = [Self.demoRun(pack)]
            // Pass 62: and a run stopped before it read anything.
            if ProcessInfo.processInfo.arguments.contains("-PodTestDemoStopped"), var stopped = runs.first {
                stopped.runID = UUID()
                stopped.started = .now
                stopped.finished = .now
                stopped.state = .stopped
                for e in stopped.engines.indices {
                    for r in stopped.engines[e].reads.indices { stopped.engines[e].reads[r] = .init(guid: stopped.engines[e].reads[r].guid) }
                }
                runs.append(stopped)
            }
        }
    }

    /// Screenshot runs only (`-PodTestDemo`): a finished run with made-up
    /// cuts on the real test episodes, so the results can be looked at in
    /// the simulator (where no model runs and the episodes aren't in the
    /// library). Never saved.
    static func demoRun(_ pack: PodTestPack) -> PodTestRun {
        func reads(_ cuts: (Int, PodTestPack.Episode) -> [PodTestCut]?) -> [PodTestRun.Read] {
            pack.episodes.enumerated().map { i, e in
                guard let c = cuts(i, e) else {
                    return PodTestRun.Read(guid: e.guid, outcome: .failed, note: "3 of 7 parts couldn’t be read: answer cut short")
                }
                return PodTestRun.Read(guid: e.guid, outcome: .completed, cuts: c, seconds: Double(40 + 13 * i),
                                       finished: .now, parts: 4 + i % 3, share: 0.3 + 0.04 * Double(i % 5))
            }
        }
        let exact = { (e: PodTestPack.Episode) in e.breaks.map { PodTestCut(start: $0.start, end: $0.end, kind: $0.kind.lowercased()) } }
        let reader = reads { i, e in Array(exact(e).enumerated().filter { $0.offset % 5 != i % 5 }.map(\.element)) }
            .map { read -> PodTestRun.Read in var r = read; r.parts = nil; r.share = nil; return r }
        let model = reads { i, e in
            i == 6 ? nil : exact(e).map { PodTestCut(start: $0.start + 1, end: $0.end + (i.isMultiple(of: 3) ? 7 : 1), kind: $0.kind) }
        }
        let apple = reads { i, e in Array(exact(e).enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)) }
        var run = PodTestRun(runID: UUID(), started: .now.addingTimeInterval(-5_400), finished: .now, state: .completed,
                             appBuild: BuildInfo.commit, device: Diagnostics.deviceModel, packVersion: pack.version,
                             engines: [
                                .init(engine: "reader", name: "PodSkipper Reader", kind: .reader, modelIdentity: "Reader \(AdDetector.version)", reads: reader),
                                .init(engine: "demo-mlx", name: "Qwen3.5 4B", kind: .mlx, modelIdentity: "demo @ demo revision", reads: model),
                                .init(engine: "apple", name: "Apple Intelligence", kind: .apple, reads: apple),
                             ])
        run.skipped = []
        return run
    }

    var latest: PodTestRun? { runs.last }
    var unfinished: PodTestRun? { isRunning ? nil : runs.last.flatMap { $0.isUnfinished ? $0 : nil } }
    var totalReads: Int { runs.last?.reads.count ?? 0 }
    var doneReads: Int { runs.last?.doneReads ?? 0 }

    /// Pass 62 (his 8 Nov run: a run he stopped at 0 reads hid the finished
    /// one): the run whose scores the results table shows — the newest
    /// finished run that read something, else the run with the most
    /// completed reads (the newest of equals). A run stopped before it read
    /// anything never takes the table.
    var resultsRun: PodTestRun? { Self.resultsRun(in: runs) }

    nonisolated static func resultsRun(in runs: [PodTestRun]) -> PodTestRun? {
        if let finished = runs.last(where: { $0.state == .completed && $0.completedReads > 0 }) {
            // A later unfinished run that has read more models replaces it.
            if let later = runs.last(where: { $0.started > finished.started && $0.state != .completed
                                              && $0.completedModelReads > finished.completedModelReads }) {
                return later
            }
            return finished
        }
        return runs.filter { $0.completedReads > 0 }
            .max { $0.completedReads != $1.completedReads ? $0.completedReads < $1.completedReads : $0.started < $1.started }
    }

    /// Pass 62: "Keep Prior Results" — the stopped run is set aside: one
    /// that read nothing is removed, one that read something is kept under
    /// Earlier Runs; the controls go back to Run the Test and the finished
    /// run's results stay.
    func dismissUnfinished() {
        guard !isRunning, let run = unfinished else { return }
        if run.completedReads == 0 {
            runs.removeAll { $0.runID == run.runID }
        } else {
            update(run.runID) { $0.dismissed = true }
        }
        requestError = nil
        persist()
        BackgroundLog.shared.note("PodSkipper test: the stopped run (\(run.doneReads) of \(run.reads.count) reads) was set aside")
    }

    func setIncluded(_ kind: PodTestEngineKind, _ on: Bool) {
        guard kind != .reader else { return }
        if on { leftOutKinds.remove(kind) } else { leftOutKinds.insert(kind) }
        defaults.set(leftOutKinds.map(\.rawValue).sorted(), forKey: Self.leftOutKey)
    }

    /// Pass 62: whether a finder reads in the next run.
    func isIncluded(_ plan: Plan) -> Bool {
        guard plan.kind != .reader else { return true }
        return engineChoices[plan.engine] ?? (plan.chosen && !leftOutKinds.contains(plan.kind))
    }

    func setIncluded(_ plan: Plan, _ on: Bool) {
        guard plan.kind != .reader else { return }
        engineChoices[plan.engine] = on
        defaults.set(engineChoices, forKey: Self.choicesKey)
    }

    // MARK: Engines

    struct Plan: Identifiable, Equatable {
        var engine: String
        var name: String
        var kind: PodTestEngineKind
        var modelID: String?
        var identity: String?
        /// Why it can't read now, said plainly; nil when it can.
        var unavailable: String?
        /// Pass 62: the model chosen for Find Ads (or the CPU model chosen
        /// for the background): on unless he switches it off. Other
        /// downloaded models are offered off.
        var chosen = true
        var id: String { engine }
    }

    /// The engines, in the order they read: the Reader first (every model
    /// starts from its cuts), then MLX models, CPU models, Core AI models and
    /// Apple Intelligence. Pass 62 (his 8 Nov request): every downloaded
    /// model of each kind, not only the chosen one, so Qwen3.5 4B and its
    /// Instruct 6-bit (and their CPU copies) read in the same run.
    func plans() -> [Plan] {
        let bench = ModelBench.shared
        var out: [Plan] = []
        out.append(Plan(engine: "reader", name: "PodSkipper Reader", kind: .reader, identity: "Reader \(AdDetector.version)",
                        unavailable: SentenceTagger.isBundled ? nil : "The bundled Reader is missing."))
        let store = ModelStore.shared
        let selected = store.selected
        var mlx = LocalModelSpec.all.filter { $0.id == selected.id || store.isDownloaded($0) }
        mlx.sort { ($0.id == selected.id ? 0 : 1, LocalModelSpec.all.firstIndex(of: $0) ?? 0) < ($1.id == selected.id ? 0 : 1, LocalModelSpec.all.firstIndex(of: $1) ?? 0) }
        for spec in mlx {
            var why: String?
            #if targetEnvironment(simulator)
            why = "MLX models run on iPhone only."
            #else
            if !store.isDownloaded(spec) { why = "Download it to include it." }
            else if !bench.isEnabled(spec.id) { why = "Switched off in Compare Models." }
            #endif
            out.append(Plan(engine: spec.id, name: spec.name, kind: .mlx, modelID: spec.id,
                            identity: spec.id + " @ " + spec.revision, unavailable: why, chosen: spec.id == selected.id))
        }
        let cpuChosen = CPUReading.selected
        for model in CPUReading.catalog where model == cpuChosen || model.isDownloaded {
            var why: String?
            if !CPUReading.engineIncluded { why = "CPU models run on iPhone only." }
            else if !model.isDownloaded { why = "Download it under MLX models › Reading in the Background." }
            out.append(Plan(engine: model.engineID, name: model.name, kind: .cpu, modelID: model.id,
                            identity: model.identity, unavailable: why, chosen: model == cpuChosen))
        }
        let library = CoreAIModelLibrary.shared
        let chosenEntry = library.selectedEntry
        var coreAI = library.entries.filter { $0.id == chosenEntry?.id || ($0.isCompatible && library.isDownloaded($0)) }
        coreAI.sort { ($0.id == chosenEntry?.id ? 0 : 1, $0.name) < ($1.id == chosenEntry?.id ? 0 : 1, $1.name) }
        if coreAI.isEmpty {
            out.append(Plan(engine: "coreAI", name: "Core AI", kind: .coreAI, unavailable: "Choose a Core AI model to include it."))
        }
        for entry in coreAI {
            var why: String?
            #if targetEnvironment(simulator)
            why = "Core AI models run on iPhone only."
            #else
            if !entry.isCompatible { why = entry.unsupportedReason ?? "This iPhone can't run it." }
            else if !library.isDownloaded(entry) { why = "Download it to include it." }
            else if !bench.isEnabled(CoreAIQwen3.benchmarkID(for: entry.id)) { why = "Switched off in Compare Models." }
            #endif
            out.append(Plan(engine: CoreAIQwen3.benchmarkID(for: entry.id), name: "Core AI · " + entry.name, kind: .coreAI,
                            modelID: entry.id,
                            identity: entry.repo + " @ " + (entry.revision ?? "unknown revision") + " / " + (entry.variant ?? "unknown variant"),
                            unavailable: why, chosen: entry.id == chosenEntry?.id))
        }
        out.append(Plan(engine: "apple", name: "Apple Intelligence", kind: .apple,
                        identity: "Apple Intelligence · iOS " + UIDevice.current.systemVersion,
                        unavailable: AdDetector.availability()))
        return out
    }

    // MARK: Running

    func start(context: ModelContext, settings: AppSettings) {
        guard !isRunning else { return }
        requestError = nil
        guard let pack else { requestError = "This build has no test episodes."; return }
        guard !ModelBench.shared.isRunning else {
            requestError = "A model test is running. Let it finish or stop it first."
            return
        }
        let engines = plans().filter { $0.unavailable == nil && isIncluded($0) }
        let run = PodTestRun(runID: UUID(), started: .now, state: .running, appBuild: BuildInfo.commit,
                             device: Diagnostics.deviceModel, packVersion: pack.version,
                             engines: engines.map { plan in
                                 PodTestRun.Engine(engine: plan.engine, name: plan.name, kind: plan.kind, modelID: plan.modelID,
                                                   modelIdentity: plan.identity,
                                                   reads: pack.episodes.map { PodTestRun.Read(guid: $0.guid) })
                             })
        runs.append(run)
        persist()
        BackgroundLog.shared.note("PodSkipper test started: \(engines.map(\.name).joined(separator: ", ")) on \(pack.episodes.count) test episodes")
        launch(run.runID, context: context, settings: settings)
    }

    func resume(context: ModelContext, settings: AppSettings) {
        guard !isRunning, let run = unfinished else { return }
        requestError = nil
        guard !ModelBench.shared.isRunning else {
            requestError = "A model test is running. Let it finish or stop it first."
            return
        }
        update(run.runID) { $0.state = .running; $0.finished = nil }
        persist()
        BackgroundLog.shared.note("PodSkipper test resumed: \(run.doneReads) of \(run.reads.count) reads done")
        launch(run.runID, context: context, settings: settings)
    }

    func stop() {
        guard isRunning, !stopping else { return }
        stopping = true
        step = "Stopping…"
        task?.cancel()
    }

    private func launch(_ runID: UUID, context: ModelContext, settings: AppSettings) {
        isRunning = true
        stopping = false
        startedAt = .now
        fraction = 0
        readerCache = [:]
        let pipeline = ProcessingPipeline.shared
        let pausedPreparation = pipeline.isRunning && pipeline.currentOrigin == .automatic
        if pausedPreparation { pipeline.cancelBackgroundWork() }
        waiting = HeavyWorkCoordinator.shared.isBusy
        step = waiting ? "Waiting for other work to finish" : "Starting"
        ScreenAwake.hold(Self.awakeReason)
        task = Task { @MainActor in
            var lease: HeavyWorkCoordinator.Lease?
            var ending = PodTestRun.State.completed
            do {
                lease = try await HeavyWorkCoordinator.shared.acquire(owner: "benchmark:podtest", priority: .user)
                waiting = false
                try await work(runID, context: context, settings: settings)
            } catch {
                ending = stopping || error is CancellationError || Task.isCancelled ? .stopped : .interrupted
                if !(error is CancellationError) { requestError = error.localizedDescription }
            }
            update(runID) { run in
                run.state = ending
                run.finished = .now
                for e in run.engines.indices {
                    for r in run.engines[e].reads.indices where run.engines[e].reads[r].outcome == .reading {
                        run.engines[e].reads[r].outcome = .pending
                    }
                }
            }
            persist()
            if let run = runs.first(where: { $0.runID == runID }) {
                BackgroundLog.shared.note("PodSkipper test \(ending == .completed ? "finished" : ending.rawValue): \(run.doneReads) of \(run.reads.count) reads")
            }
            if ending == .completed { Feel.confirm.play() }
            if let lease { HeavyWorkCoordinator.shared.release(lease) }
            ScreenAwake.release(Self.awakeReason)
            isRunning = false
            stopping = false
            pausedOffScreen = false
            waiting = false
            activeEngine = nil
            activeEngineName = nil
            activeEpisode = 0
            step = ""
            fraction = 0
            startedAt = nil
            readerCache = [:]
            task = nil
            if pausedPreparation { PrepareAhead.shared.refresh() }
        }
    }

    /// Why an episode can't be read on this iPhone, or nil.
    nonisolated static func skipReason(labelled: Double, phone: Double, inLibrary: Bool, hasTranscript: Bool) -> String? {
        guard inLibrary else { return "Not in your library" }
        guard hasTranscript else { return "No transcript on this iPhone" }
        let difference = phone - labelled
        guard abs(difference) <= durationTolerance else {
            return "A different version of the episode (\(Int(abs(difference).rounded())) s \(difference > 0 ? "longer" : "shorter") than the one checked by hand)"
        }
        return nil
    }

    private func work(_ runID: UUID, context: ModelContext, settings: AppSettings) async throws {
        guard let pack, runs.contains(where: { $0.runID == runID }) else { return }
        let guids = pack.episodes.map(\.guid)
        let found = (try? context.fetch(FetchDescriptor<Episode>(predicate: #Predicate { guids.contains($0.guid) }))) ?? []
        var library: [String: Episode] = [:]
        for episode in found where library[episode.guid] == nil { library[episode.guid] = episode }
        var skips: [PodTestRun.Skip] = []
        var eligible: [String: Episode] = [:]
        for labelled in pack.episodes {
            let episode = library[labelled.guid]
            var phone = episode?.duration ?? 0
            if let episode, phone <= 0, episode.hasTranscript { phone = await episode.loadTranscript().last?.end ?? 0 }
            if let why = Self.skipReason(labelled: labelled.duration, phone: phone, inLibrary: episode != nil,
                                         hasTranscript: episode?.hasTranscript ?? false) {
                skips.append(.init(guid: labelled.guid, reason: why))
            } else {
                eligible[labelled.guid] = episode
            }
        }
        update(runID) { run in
            run.skipped = skips
            for e in run.engines.indices {
                for r in run.engines[e].reads.indices {
                    let read = run.engines[e].reads[r]
                    if let skip = skips.first(where: { $0.guid == read.guid }), read.outcome != .completed {
                        run.engines[e].reads[r].outcome = .skipped
                        run.engines[e].reads[r].note = skip.reason
                    } else if eligible[read.guid] != nil, read.outcome == .skipped {
                        // Read now, though an earlier start couldn't.
                        run.engines[e].reads[r].outcome = .pending
                        run.engines[e].reads[r].note = nil
                    }
                }
            }
        }
        persist()
        let order = guids.filter { eligible[$0] != nil }
        episodeCount = order.count
        guard let engines = runs.first(where: { $0.runID == runID })?.engines else { return }
        for engine in engines {
            try Task.checkCancellation()
            activeEngine = engine.engine
            activeEngineName = engine.name
            if let why = unavailableNow(engine) {
                update(runID) { run in
                    guard let e = run.engines.firstIndex(where: { $0.engine == engine.engine }) else { return }
                    for r in run.engines[e].reads.indices where run.engines[e].reads[r].outcome == .pending {
                        run.engines[e].reads[r].outcome = .skipped
                        run.engines[e].reads[r].note = why
                    }
                }
                persist()
                continue
            }
            var index = 0
            while index < order.count {
                let guid = order[index]
                guard let episode = eligible[guid],
                      let read = runs.first(where: { $0.runID == runID })?.engines.first(where: { $0.engine == engine.engine })?.read(guid),
                      read.outcome == .pending else { index += 1; continue }
                try Task.checkCancellation()
                try await waitForScreen()
                activeEpisode = index + 1
                fraction = 0
                step = "Reading " + episode.title
                setRead(runID, engine.engine, guid) { $0.outcome = .reading }
                persist()
                let started = Date.now
                do {
                    let result = try await readOne(engine, episode: episode, settings: settings, runID: runID)
                    setRead(runID, engine.engine, guid) {
                        $0.outcome = .completed
                        $0.cuts = result.cuts
                        $0.seconds = Date.now.timeIntervalSince(started)
                        $0.parts = result.parts
                        $0.share = result.share
                        $0.lessonsLeftOut = result.lessonsLeftOut
                        $0.note = result.note
                        $0.finished = .now
                    }
                    index += 1
                } catch ReadStop.offScreen {
                    // Asked again once PodSkipper is back on screen.
                    setRead(runID, engine.engine, guid) { $0.outcome = .pending }
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        setRead(runID, engine.engine, guid) { $0.outcome = .pending }
                        persist()
                        throw CancellationError()
                    }
                    setRead(runID, engine.engine, guid) {
                        $0.outcome = .failed
                        $0.note = error.localizedDescription
                        $0.seconds = Date.now.timeIntervalSince(started)
                        $0.finished = .now
                    }
                    index += 1
                }
                persist()
            }
            await Self.releaseEngine(engine.kind, name: engine.name)
        }
    }

    /// Pass 62 (his 7 Nov run: iOS closed the app once between models):
    /// each engine's memory is let go before the next one loads. The MLX,
    /// CPU and Core AI readers already free their model when a read ends;
    /// MLX's GPU buffer cache is handed back here too, and the next engine
    /// waits (up to 3 s) for iOS to report the memory free again.
    static func releaseEngine(_ kind: PodTestEngineKind, name: String) async {
        let before = os_proc_available_memory()
        if kind == .mlx { MLXMemory.release() }
        var after = os_proc_available_memory()
        for _ in 0..<10 where after < before {
            try? await Task.sleep(for: .milliseconds(300))
            after = os_proc_available_memory()
        }
        if kind != .reader {
            BackgroundLog.shared.note("PodSkipper test: \(name) done; memory free for the next \(ByteCountFormatter.string(fromByteCount: Int64(after), countStyle: .memory))")
        }
    }

    enum ReadStop: Error, LocalizedError {
        case offScreen
        case unavailable(String)
        case incomplete(String)
        var errorDescription: String? {
            switch self {
            case .offScreen: "PodSkipper left the screen"
            case .unavailable(let why): why
            case .incomplete(let why): why
            }
        }
    }

    struct ReadResult {
        var cuts: [PodTestCut]
        var parts: Int?
        var share: Double?
        var lessonsLeftOut: Int?
        var note: String?
    }

    /// Whether an engine planned at the start can still read (a resumed
    /// run, after a model was removed or switched off).
    private func unavailableNow(_ engine: PodTestRun.Engine) -> String? {
        switch engine.kind {
        case .reader: return SentenceTagger.isBundled ? nil : "The bundled Reader is missing."
        case .apple: return AdDetector.availability()
        case .cpu:
            let model = CPUReading.model(id: engine.modelID) ?? CPUReading.model(engineID: engine.engine)
            return CPUReading.engineIncluded && model?.isDownloaded == true ? nil : "\(engine.name) isn't downloaded any more."
        case .mlx:
            guard let spec = LocalModelSpec.all.first(where: { $0.id == engine.modelID }),
                  ModelStore.shared.isDownloaded(spec) else { return "\(engine.name) isn't downloaded any more." }
            return nil
        case .coreAI:
            guard let id = engine.modelID, let entry = CoreAIModelLibrary.shared.entry(for: id),
                  entry.isCompatible, CoreAIModelLibrary.shared.isDownloaded(entry) else {
                return "\(engine.name) isn't downloaded any more."
            }
            return nil
        }
    }

    private func waitForScreen() async throws {
        while UIApplication.shared.applicationState != .active {
            pausedOffScreen = true
            step = "Paused: open PodSkipper to carry on"
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) { break }
            try Task.checkCancellation()
        }
        pausedOffScreen = false
    }

    // MARK: One read

    private func readOne(_ engine: PodTestRun.Engine, episode: Episode, settings: AppSettings,
                         runID: UUID) async throws -> ReadResult {
        let x = try await Self.inputs(for: episode, settings: settings)
        let token = UUID()
        readToken = token
        let progress = ProgressThrottle { [weak self] value in
            guard let self, self.readToken == token else { return }
            self.fraction = max(self.fraction, min(1, value))
        }
        let statuses = StatusThrottle()
        let status: @Sendable (String) -> Void = { [weak self] message in
            guard statuses.admits(message) else { return }
            Task { @MainActor in
                guard let self, self.readToken == token, !self.stopping else { return }
                self.step = message
            }
        }
        let checkpoint = DetectionCheckpoint(guid: "podtest-\(runID.uuidString)-\(engine.engine)-\(episode.guid)")
        do {
            var result: ReadResult
            switch engine.kind {
            case .reader:
                let cuts = try await readerCuts(x, progress: { progress.report($0) })
                result = ReadResult(cuts: cuts.map(Self.cut))
            case .apple:
                if let why = AdDetector.availability() { throw ReadStop.unavailable(why) }
                JobHeartbeat.shared.startJob()
                do {
                    let cuts = try await Self.detect(x, apple: true, cache: checkpoint.cache, progress: { progress.report($0) })
                    let unanswered = JobHeartbeat.shared.unansweredSummary
                    result = ReadResult(cuts: cuts.map(Self.cut),
                                        note: unanswered.count > 0 ? "\(unanswered.count) questions unanswered (\(unanswered.reasons))" : nil)
                } catch {
                    // iOS holds Apple's model back off screen on battery.
                    if !(error is CancellationError), UIApplication.shared.applicationState != .active { throw ReadStop.offScreen }
                    throw error
                }
            case .mlx, .cpu, .coreAI:
                let readerAds = try await readerCuts(x, progress: nil)
                result = try await modelRead(engine, x, readerAds: readerAds, checkpoint: checkpoint,
                                             progress: { progress.report($0) }, status: status)
            }
            result.lessonsLeftOut = x.lessonsLeftOut
            checkpoint.discard()
            return result
        } catch {
            checkpoint.save()
            throw error
        }
    }

    /// The Reader's cuts for an episode, read once per run and launch (the
    /// models start from them).
    private func readerCuts(_ x: PodTestInputs, progress: (@Sendable (Double) -> Void)?) async throws -> [DetectedSegment] {
        if let cached = readerCache[x.guid] {
            progress?(1)
            return cached
        }
        let cuts = try await Self.detect(x, apple: false, cache: nil, progress: progress)
        readerCache[x.guid] = cuts
        return cuts
    }

    /// The detector as a Find Ads job runs it: the Reader, or Apple
    /// Intelligence asking about each stretch (`SegmentDetector.tuning`).
    static func detect(_ x: PodTestInputs, apple: Bool, cache: AdDetector.ReplyCache?,
                       progress: (@Sendable (Double) -> Void)?) async throws -> [DetectedSegment] {
        let previousTuning = SegmentDetector.tuning
        let previousCache = AdDetector.replyCache
        SegmentDetector.tuning.ownReader = !apple
        if apple { AdDetector.replyCache = cache }
        defer {
            SegmentDetector.tuning = previousTuning
            if apple { AdDetector.replyCache = previousCache }
        }
        let detection = try await AdDetector().detectSentences(
            segments: x.segments, silences: x.silences, knownSponsors: x.knownSponsors,
            corrections: x.showLessons, globalCorrections: x.globalLessons,
            showTitle: x.show, episodeTitle: x.title, showNotes: x.showNotes,
            audioDuration: x.episodeDuration, minimumConfidence: x.minimumConfidence, padding: x.padding,
            hints: [], inserted: x.inserted.map { $0.start...$0.end }, produced: x.produced, progress: progress)
        try Task.checkCancellation()
        return detection.segments
    }

    /// A model's read as `ProcessingPipeline.readWithModel` /
    /// `readOffScreenOnCPU` / `readWithCoreAI` do it, up to
    /// `ModelFinder.attempts` tries, then the app's cut check.
    private func modelRead(_ engine: PodTestRun.Engine, _ x: PodTestInputs, readerAds: [DetectedSegment],
                           checkpoint: DetectionCheckpoint, progress: @escaping @Sendable (Double) -> Void,
                           status: @escaping @Sendable (String) -> Void) async throws -> ReadResult {
        let evidence = x.evidence
        let lessons = ModelFinder.correctionsBlock(x.showLessons)
        var only: [Range<Int>]? = ModelFinder.focusRanges(lines: x.lines, readerCuts: readerAds, duration: x.duration,
                                                          evidence: evidence, hints: [])
        var lastError: Error?
        for attempt in 1...ModelFinder.attempts {
            try Task.checkCancellation()
            if UIApplication.shared.applicationState != .active { throw ReadStop.offScreen }
            if attempt > 1 {
                step = "Trying again (\(attempt) of \(ModelFinder.attempts))"
                try await Task.sleep(for: ModelFinder.retryWait)
            }
            do {
                let report: JudgeReport
                switch engine.kind {
                case .mlx:
                    guard let spec = LocalModelSpec.all.first(where: { $0.id == engine.modelID }) else {
                        throw ReadStop.unavailable("\(engine.name) is no longer in the library.")
                    }
                    report = try await LocalJudge.shared.judgeReport(
                        lines: x.lines, show: x.show, title: x.title, notes: x.notes, evidence: evidence, only: only,
                        corrections: lessons, model: spec, progress: progress, status: status, checkpoint: checkpoint)
                case .cpu:
                    guard let model = CPUReading.model(id: engine.modelID) ?? CPUReading.model(engineID: engine.engine) else {
                        throw ReadStop.unavailable("\(engine.name) is no longer in the list.")
                    }
                    report = try await CPUJudge.shared.judgeReport(
                        lines: x.lines, show: x.show, title: x.title, notes: x.notes, evidence: evidence, only: only,
                        corrections: lessons, model: model,
                        budget: {
                            await MainActor.run {
                                let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
                                return CPUBudget(mode: !hot && UIApplication.shared.applicationState == .active ? .full : .paced)
                            }
                        },
                        progress: progress, status: status, checkpoint: checkpoint)
                case .coreAI:
                    await CoreAIModelLibrary.shared.ensureLoaded()
                    guard let id = engine.modelID, let entry = CoreAIModelLibrary.shared.entry(for: id) else {
                        throw ReadStop.unavailable("\(engine.name) isn't in the Core AI catalog.")
                    }
                    // Core AI models read the flagged stretches only, as in Find Ads.
                    only = entry.readsFocused
                        ? ModelFinder.fastRanges(lines: x.lines, readerCuts: readerAds, duration: x.duration,
                                                 evidence: evidence, hints: [])
                        : nil
                    report = try await CoreAIAdJudge.shared.judgeReport(
                        lines: x.lines, show: x.show, title: x.title, notes: x.notes, evidence: evidence,
                        corrections: lessons, modelID: entry.id, only: only, progress: progress, status: status,
                        episodeGUID: "podtest:" + x.guid, checkpoint: checkpoint)
                case .reader, .apple:
                    throw ReadStop.unavailable("Not a model.")
                }
                if !report.failedLines.isEmpty {
                    let why = "\(report.failedLines.count) of \(report.stats.windows) parts couldn't be read: \(report.stats.failureDetails ?? "no readable answer")"
                    if engine.kind == .coreAI, report.parts.isEmpty, report.failedLines.count >= report.stats.windows {
                        throw ReadStop.incomplete(why)
                    }
                    lastError = ReadStop.incomplete(why)
                    continue
                }
                let checked = ModelFinder.checkedCuts(from: report.parts, lines: x.lines, readerCuts: readerAds,
                                                      inserted: x.inserted, evidence: evidence, silences: x.silences,
                                                      padding: x.padding, duration: x.duration,
                                                      corrections: x.showLessons + x.globalLessons)
                return ReadResult(cuts: checked.cuts.map(Self.cut), parts: report.stats.windows,
                                  share: only.map { ModelFinder.share($0, of: x.lines) } ?? 1)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if case LocalJudge.JudgeError.needsForeground = error { throw ReadStop.offScreen }
                if case CoreAIAdJudge.JudgeError.needsForeground = error { throw ReadStop.offScreen }
                if case ReadStop.incomplete = error { throw error }
                if case ReadStop.unavailable = error { throw error }
                lastError = error
            }
        }
        throw lastError ?? ReadStop.incomplete("No answer")
    }

    nonisolated static func cut(_ s: DetectedSegment) -> PodTestCut {
        PodTestCut(start: s.start, end: s.end, kind: s.kind.rawValue)
    }

    /// The same inputs a Find Ads job gives the engines (stored transcript,
    /// silences, the ad-free comparison and repeated recordings, his show's
    /// lessons, Settings' confidence and padding), less SponsorBlock's hints
    /// (fetched from the internet: a test reads the same input every time)
    /// and his lessons taken from this very episode (they would tell the
    /// engine the answer).
    static func inputs(for episode: Episode, settings: AppSettings) async throws -> PodTestInputs {
        let timed = await episode.loadTranscript()
        guard timed.count >= 10 else { throw ReadStop.unavailable("No transcript on this iPhone") }
        let segments = timed.map { TranscriptSegment(text: $0.text, start: $0.start, end: $0.end, words: $0.words ?? []) }
        let lines = timed.map { TimedLine(text: $0.text, start: $0.start, end: $0.end) }
        let evidenceDuration = episode.audioFileLength > 0 ? episode.audioFileLength : episode.duration
        let showLessons = episode.podcast?.corrections ?? []
        let globalLessons = GlobalCorrections.all
        let filtered = await Task.detached(priority: .userInitiated) {
            let text = lines.map(\.text).joined(separator: " ")
            let show = Self.withoutOwnLessons(showLessons, transcript: text)
            let global = Self.withoutOwnLessons(globalLessons, transcript: text)
            return (show: show.kept, global: global.kept, leftOut: show.leftOut + global.leftOut)
        }.value
        return PodTestInputs(
            guid: episode.guid, segments: segments, lines: lines, silences: episode.silenceRanges,
            inserted: episode.insertedSpans,
            produced: AdPrints.detectionEvidence(episode.producedSpans, duration: evidenceDuration),
            knownSponsors: episode.podcast?.knownSponsors ?? [], showLessons: filtered.show,
            globalLessons: filtered.global, lessonsLeftOut: filtered.leftOut,
            show: episode.podcast?.title ?? "", title: episode.title, notes: episode.plainDescription,
            showNotes: episode.episodeDescription, episodeDuration: episode.duration,
            minimumConfidence: settings.minimumConfidence, padding: settings.boundaryPadding)
    }

    /// His lessons (passages he marked, edges he dragged) whose words occur
    /// in this episode came from it, most likely: left out, so a test
    /// episode he corrected doesn't hand the engine its own answer.
    nonisolated static func withoutOwnLessons(_ lessons: [DetectionCorrection], transcript: String) -> (kept: [DetectionCorrection], leftOut: Int) {
        func flat(_ s: String) -> String {
            String(s.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
                .split(separator: " ").joined(separator: " ")
        }
        let text = flat(transcript)
        var kept: [DetectionCorrection] = []
        var leftOut = 0
        for lesson in lessons {
            let words = flat(lesson.excerpt)
            let key = String(words.prefix(80))
            if key.count >= 16, text.contains(key) {
                leftOut += 1
            } else {
                kept.append(lesson)
            }
        }
        return (kept, leftOut)
    }

    // MARK: Records

    private func update(_ runID: UUID, _ change: (inout PodTestRun) -> Void) {
        guard let i = runs.firstIndex(where: { $0.runID == runID }) else { return }
        change(&runs[i])
    }

    private func setRead(_ runID: UUID, _ engine: String, _ guid: String, _ change: (inout PodTestRun.Read) -> Void) {
        update(runID) { run in
            guard let e = run.engines.firstIndex(where: { $0.engine == engine }),
                  let r = run.engines[e].reads.firstIndex(where: { $0.guid == guid }) else { return }
            change(&run.engines[e].reads[r])
        }
    }

    private func persist() {
        do {
            try store.save(runs)
            saveError = nil
        } catch {
            saveError = "Couldn't save the test's results: " + error.localizedDescription
        }
    }

    /// For Diagnostics: the runs in the chosen period.
    func exportRuns(from: Date?, to: Date?) -> [PodTestRun] {
        runs.filter { run in (from.map { run.started >= $0 } ?? true) && (to.map { run.started <= $0 } ?? true) }
    }
}
