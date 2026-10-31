import Foundation
import Observation
#if !targetEnvironment(simulator)
import CoreAI
#endif

/// Pass 36: Core AI's one-time preparation of a model for this iPhone, done
/// as its own visible step instead of hidden inside "Loading".
///
/// Why (his 12–13 Oct phone, build 4075f0e, Diagnostics `…1791860129`):
/// Qwen3 4B sat at "Loading Qwen3 4B · 0 %" for many minutes and Stop did
/// nothing. MetricKit has no crash for those launches; it has three CPU
/// reports (90 s of CPU in about two minutes, all inside Apple's Neural
/// Engine and Core AI compilers) and one disk-write report (4.3 GB, same
/// compiler). That is Core AI preparing (specializing) the downloaded model
/// for this iPhone — work the language engines start inside their load
/// (`PreparedModel.prepare(at:)` in coreai-models). The same model had
/// loaded and answered in about 30 s on 9 Oct, i.e. it had been prepared
/// then; a 36.8 GB "temporary files" removal and re-downloads on 12 Oct
/// meant it had to be prepared again, and each relaunch began again from
/// the start.
///
/// Measured on the Mac (`AIModel.specialize`, Core AI 3600.83): the native
/// preparation **does not stop when its Swift task is cancelled** — it runs
/// to the end and stores its result. So:
/// - Preparation is started here with the same options the engine uses, and
///   stored with the `.persistent` cache policy, so storage pressure doesn't
///   purge it (the default policy may) and the engine's own load is then a
///   cache hit.
/// - Stop during preparation is recorded as *requested*; the caller keeps
///   waiting (and keeps the heavy-work slot) until Core AI returns, then ends
///   as stopped. Nothing claims the work stopped while it is still running.
/// - Whether a model is prepared is read from Core AI's own cache
///   (`AIModelCache.model(for:options:)`, which never starts preparation),
///   and a model's prepared copies are removed with
///   `AIModelCache.deleteEntries(for:)` — by the model they belong to, not by
///   guessing from file names in the temporary folders.
@MainActor
@Observable
final class CoreAIPreparation {
    static let shared = CoreAIPreparation()

    struct Job: Equatable, Sendable {
        var modelID: String
        var name: String
        var started: Date
        /// Stop was asked for; Core AI is still preparing.
        var stopRequestedAt: Date?
    }

    /// The preparation under way, if any (one at a time: heavy work).
    private(set) var current: Job?
    /// Bundle path → prepared for this iPhone, as last read from Core AI.
    private(set) var preparedByBundle: [String: Bool] = [:]

    private static let durationsKey = "coreAI.preparationSeconds"
    private static let inFlightKey = "coreAI.preparing"

    /// How long the last complete preparation of this model took here.
    func lastDuration(_ modelID: String) -> TimeInterval? {
        (UserDefaults.standard.dictionary(forKey: Self.durationsKey) as? [String: Double])?[modelID]
    }

    func requestStop() {
        guard current != nil, current?.stopRequestedAt == nil else { return }
        current?.stopRequestedAt = .now
        BackgroundLog.shared.note("Stop asked for while Core AI prepares \(current?.name ?? "a model"); Core AI can't interrupt that, so it stops when preparation ends")
    }

    /// Reads Core AI's cache for this bundle (off the main actor) and keeps
    /// the answer for the UI. nil when it can't be told (simulator, no asset).
    func refresh(bundle: URL) async -> Bool? {
        let answer = await Task.detached(priority: .utility) { Self.isPrepared(bundle: bundle) }.value
        if let answer { preparedByBundle[bundle.standardizedFileURL.path] = answer }
        return answer
    }

    func knownPrepared(bundle: URL) -> Bool? { preparedByBundle[bundle.standardizedFileURL.path] }

    /// Prepares the bundle's model for this iPhone unless Core AI already has
    /// it. Pass 36 (his 13 Oct phone: Stop sat at "Stopping…" until he closed
    /// the app): Stop ends the caller at once with `CancellationError`. The
    /// native preparation, which can't be interrupted, carries on by itself
    /// and keeps the heavy-work slot (handed over from the caller) until Core
    /// AI returns, so nothing else competes with it; `current` shows it as
    /// finishing after Stop, and its result is kept for the next load.
    func prepare(modelID: String, name: String, bundle: URL,
                 status: @escaping @Sendable (String) -> Void) async throws {
        if await refresh(bundle: bundle) != false { return }
        try await run(modelID: modelID, name: name, bundle: bundle, status: status) {
            do { try await Self.specialize(bundle: bundle); return nil } catch { return (error as NSError).localizedDescription }
        }
    }

    /// The preparation itself, with the native step passed in (tests pass a
    /// slow step that ignores cancellation, as Core AI's does).
    func run(modelID: String, name: String, bundle: URL, status: @escaping @Sendable (String) -> Void,
             work native: @escaping @Sendable () async -> String?) async throws {
        if current != nil { throw PreparationError.busy(name: current?.name ?? name) }
        status("Preparing \(name) for this iPhone")
        let job = Job(modelID: modelID, name: name, started: .now)
        current = job
        Self.writeInFlight(job)
        BackgroundLog.shared.note("Core AI is preparing \(name) for this iPhone (one time; it is kept for later loads)")
        let owningLease = HeavyWorkCoordinator.shared.current
        let work = Task.detached(priority: .userInitiated) { await native() }
        // Pass 56: storage actually free while the compiler writes, every few
        // seconds, into the note a closure leaves for the next launch.
        let disk = Task.detached(priority: .utility) {
            var lowest = Int.max
            while !Task.isCancelled {
                CoreAIInFlight.noteDisk()
                if let mb = CoreAIInFlight.diskMB { lowest = Swift.min(lowest, mb) }
                try? await Task.sleep(for: .seconds(3))
            }
            return lowest
        }
        let gate = Gate()
        // Whoever comes first: Core AI finishing, or Stop.
        Task { @MainActor in
            let failure = await work.value
            disk.cancel()
            let lowest = await disk.value
            if lowest < StorageGuard.lowDiskMB {
                BackgroundLog.shared.note("While Core AI prepared \(name), storage actually free fell to \(lowest) MB")
            }
            self.finish(job: job, bundle: bundle, failure: failure)
            gate.open(.finished(failure))
        }
        let ending = await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            gate.open(.stopped)
        }
        switch ending {
        case .stopped:
            // Hand the slot to the preparation still running; the caller's
            // own release becomes a no-op.
            if current?.started == job.started {
                current?.stopRequestedAt = .now
                if let owningLease { handedLease = HeavyWorkCoordinator.shared.transfer(owningLease, to: "coreai-prepare:" + modelID) }
                BackgroundLog.shared.note("Stopped the test while Core AI prepares \(name). Core AI can't interrupt that; it finishes by itself, keeps PodSkipper's model slot until then, and its result is kept")
            }
            throw CancellationError()
        case .finished(let failure):
            if let failure { throw PreparationError.failed(name: name, detail: failure) }
            if Task.isCancelled { throw CancellationError() }
        }
    }

    /// The slot held for a preparation that outlived its test.
    @ObservationIgnored private var handedLease: HeavyWorkCoordinator.Lease?

    private func finish(job: Job, bundle: URL, failure: String?) {
        let stoppedEarlier = current?.stopRequestedAt != nil
        if current?.started == job.started { current = nil }
        Self.clearInFlight()
        if let lease = handedLease { HeavyWorkCoordinator.shared.release(lease); handedLease = nil }
        let seconds = Date.now.timeIntervalSince(job.started)
        if let failure {
            BackgroundLog.shared.note("Core AI couldn't prepare \(job.name) (\(Self.clock(seconds))): \(failure)")
            preparedByBundle[bundle.standardizedFileURL.path] = false
            return
        }
        var durations = UserDefaults.standard.dictionary(forKey: Self.durationsKey) as? [String: Double] ?? [:]
        durations[job.modelID] = seconds
        UserDefaults.standard.set(durations, forKey: Self.durationsKey)
        preparedByBundle[bundle.standardizedFileURL.path] = true
        BackgroundLog.shared.note("Core AI prepared \(job.name) in \(Self.clock(seconds))" + (stoppedEarlier ? " (after its test was stopped; the prepared model is kept)" : ""))
    }

    /// One-shot hand-off between the native work, Stop, and the caller.
    private final class Gate: @unchecked Sendable {
        enum Ending: Sendable { case finished(String?), stopped }
        private let lock = NSLock()
        private var ending: Ending?
        private var waiter: CheckedContinuation<Ending, Never>?
        func open(_ value: Ending) {
            let resume: CheckedContinuation<Ending, Never>? = lock.withLock {
                guard ending == nil else { return nil }
                ending = value
                defer { waiter = nil }
                return waiter
            }
            resume?.resume(returning: value)
        }
        func wait() async -> Ending {
            await withCheckedContinuation { continuation in
                let ready: Ending? = lock.withLock {
                    if let ending { return ending }
                    waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }

    enum PreparationError: LocalizedError {
        case failed(name: String, detail: String)
        case busy(name: String)
        var errorDescription: String? {
            switch self {
            case .failed(let name, let detail): "Core AI couldn't prepare \(name) for this iPhone: \(detail)"
            case .busy(let name): "Core AI is still finishing preparing \(name); try again when it has finished."
            }
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds.rounded())).formatted(.time(pattern: .minuteSecond))
    }

    // MARK: Launch note: closed while preparing

    struct InFlight: Equatable, Sendable {
        var modelID: String
        var name: String
        var started: Date
        var stopRequested: Bool
    }

    private static let launch = UUID().uuidString

    private static func writeInFlight(_ job: Job) {
        UserDefaults.standard.set(["id": job.modelID, "name": job.name, "launch": launch,
                                   "started": job.started.timeIntervalSince1970], forKey: inFlightKey)
    }

    private static func clearInFlight() { UserDefaults.standard.removeObject(forKey: inFlightKey) }

    /// A preparation an earlier launch didn't finish, taken once. Core AI
    /// doesn't resume a preparation: the next load starts it again.
    static func staleFromEarlierLaunch(defaults: UserDefaults = .standard) -> InFlight? {
        guard let note = defaults.dictionary(forKey: inFlightKey), note["launch"] as? String != launch,
              let id = note["id"] as? String else { return nil }
        defaults.removeObject(forKey: inFlightKey)
        return InFlight(modelID: id, name: note["name"] as? String ?? id,
                        started: Date(timeIntervalSince1970: note["started"] as? Double ?? 0), stopRequested: false)
    }

    // MARK: Core AI

    /// The graph a bundle loads: `metadata.json` → `assets.main`.
    nonisolated static func mainAsset(in bundle: URL) -> URL? {
        CoreAICompiledCopy.mainAsset(in: bundle).map { bundle.appending(path: $0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Every graph in the bundle (the download's own and any compiled copy).
    nonisolated static func assets(in bundle: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["aimodel", "aimodelc"].contains($0.pathExtension) }
            .sorted { $0.path < $1.path }
    }

    /// The chip name Core AI uses for this device ("h17p" on iPhone 16 Pro),
    /// nil where Core AI isn't available (simulator).
    nonisolated static var deviceArchitecture: String? {
        #if !targetEnvironment(simulator)
        if #available(iOS 27, *) { return AIModel.deviceArchitectureName }
        #endif
        return nil
    }

    #if !targetEnvironment(simulator)
    /// The options the language engines prepare with
    /// (`ModelStructure.specializationOptions` in coreai-models): the
    /// Neural Engine for a chunked static-shape graph (it has `extend_*` and
    /// `load_embeddings`), else the GPU expecting frequent reshapes. Must
    /// match exactly, or the engine's load wouldn't find what was prepared.
    nonisolated static func options(for asset: URL) -> SpecializationOptions {
        let names = (try? AIModelAsset(contentsOf: asset).summary(includingStatistics: false))?.functions.map(\.name) ?? []
        if names.contains(where: { $0.hasPrefix("extend") }) && names.contains("load_embeddings") {
            return SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
        }
        var options = SpecializationOptions(preferredComputeUnitKind: .gpu)
        options.expectFrequentReshapes = true
        return options
    }
    #endif

    /// Whether Core AI holds this bundle's graph prepared for this iPhone.
    /// Never starts preparation. nil when it can't be told.
    nonisolated static func isPrepared(bundle: URL) -> Bool? {
        #if !targetEnvironment(simulator)
        guard let asset = mainAsset(in: bundle) else { return nil }
        return ((try? AIModelCache.default.model(for: asset, options: options(for: asset))) ?? nil) != nil
        #else
        return nil
        #endif
    }

    nonisolated private static func specialize(bundle: URL) async throws {
        #if !targetEnvironment(simulator)
        guard let asset = mainAsset(in: bundle) else { return }
        _ = try await AIModel.specialize(contentsOf: asset, options: options(for: asset),
                                         cache: .default, cachePolicy: .persistent)
        #endif
    }

    /// Removes Core AI's prepared copies of every graph in this bundle — only
    /// this bundle's, found by Core AI itself. Call before the files go.
    nonisolated static func removePrepared(bundle: URL) -> [String] {
        removePrepared(assets: assets(in: bundle))
    }

    /// Only these graphs' prepared copies.
    nonisolated static func removePrepared(assets: [URL]) -> [String] {
        #if !targetEnvironment(simulator)
        var failures: [String] = []
        for asset in assets {
            do { try AIModelCache.default.deleteEntries(for: asset) }
            catch { failures.append("Core AI's prepared copy of \(asset.lastPathComponent): \(error.localizedDescription)") }
        }
        return failures
        #else
        return []
        #endif
    }
}
