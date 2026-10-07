import Foundation
import Observation
#if !targetEnvironment(simulator)
import CoreAIKit
import CoreAIKitCore
#endif

/// App-owned presentation data; model-management UI does not depend on the
/// device-only inference runtime or expose package types.
struct CoreAIModelDescriptor: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let repo: String
    let sizeMB: Int?
    let isCompatible: Bool
    var revision: String? = nil
    var variant: String? = nil
    /// The catalog's engine ("pipelined", "static-shape"…), if it names one.
    var engineHint: String? = nil
    /// Why this phone can't run it, in words (pass 30), when it can't.
    var unsupportedReason: String? = nil
    /// Pass 32: which build is used, when it isn't the iPhone one.
    var portableNote: String? = nil

    /// Pass 30: every Core AI model reads the stretches the reader and the
    /// audio flagged (±90 s, plus the first and last 3 minutes), not every
    /// line. In the Mac lab Qwen3 4B, reading all of Bad Friends, called
    /// nearly every stretch of conversation an ad (as it did on his phone:
    /// ~47 of 66 minutes); on flagged stretches it found the real reads.
    /// The models held to ~1,000 tokens on iPhone couldn't read a whole
    /// episode in reasonable time anyway.
    var readsFocused: Bool { true }

    /// Holds only ~1,000 tokens at a time on iPhone.
    var smallContext: Bool {
        CoreAIBundleLimits.isPipelined(engineHint: engineHint, path: variant ?? "")
    }
}

/// Pass 30: which model takes over when the chosen one is deleted.
enum ModelRanking {
    /// Highest score first; unscored after scored, alphabetical among equals.
    static func bestFirst(_ candidates: [(id: String, name: String, score: Double?)]) -> [String] {
        candidates.sorted { a, b in
            switch (a.score, b.score) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }.map(\.id)
    }
}

@available(iOS 27.0, *)
@MainActor
@Observable
final class CoreAIModelLibrary {
    static let shared = CoreAIModelLibrary()

    private(set) var entries: [CoreAIModelDescriptor] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var removingIDs: Set<String> = []
    private(set) var downloadingID: String?
    private(set) var downloadFraction = 0.0
    private(set) var downloadFile = ""
    private var cacheRevision = 0

    #if !targetEnvironment(simulator)
    @ObservationIgnored private var catalogEntries: [String: CatalogEntry] = [:]
    /// Pass 32: the bundle each model is downloaded and loaded from — the
    /// iPhone build, or the portable build where the iPhone one is compiled
    /// for another chip (`portableAlternative`).
    @ObservationIgnored private var bundleIDs: [String: ModelID] = [:]

    private func modelID(for id: String) -> ModelID? { bundleIDs[id] ?? catalogEntries[id]?.modelID }
    #endif
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    private var downloadRunID: UUID?

    private(set) var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: "coreAI.selectedModel") }
    }

    var selectedEntry: CoreAIModelDescriptor? {
        entries.first { $0.id == selectedID }
    }

    func entry(for id: String) -> CoreAIModelDescriptor? {
        entries.first { $0.id == id }
    }

    private init() {
        selectedID = UserDefaults.standard.string(forKey: "coreAI.selectedModel") ?? "qwen3-4b"
    }

    /// Pass 32 (his 7 Oct phone: after Core AI closed the app, every Find
    /// Ads used the reader and said "the selected Core AI model isn't
    /// downloaded yet" — it was downloaded). The catalog was only read when
    /// a model screen opened, so a job started before that saw no models.
    /// Jobs and tests now wait for it (a bounded wait: the built-in catalog
    /// is used when the network is slow).
    func ensureLoaded() async {
        #if !targetEnvironment(simulator)
        if !catalogEntries.isEmpty { return }
        #else
        if !entries.isEmpty || error != nil { return }
        #endif
        load()
        guard let task = loadTask else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: .seconds(20)) }
            await group.next()
            group.cancelAll()
        }
    }

    func load() {
        guard loadTask == nil else { return }
        loading = true
        error = nil
        loadTask = Task { [weak self] in
            #if !targetEnvironment(simulator)
            let live = await ModelCatalog.load()
            let chat = live.available(.chat)
            let builtin = ModelCatalog.builtin.available(.chat)
            let liveIDs = Set(chat.map(\.id))
            let merged = chat + builtin.filter { !liveIDs.contains($0.id) }
            guard let self else { return }
            self.catalogEntries = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
            let machine = Diagnostics.deviceModel
            var portable: [String: ModelID] = [:]
            self.entries = merged.map {
                let path = $0.modelID?.resolvedPath ?? ""
                // Pass 30: a bundle compiled ahead of time for another
                // iPhone's chip can't load here (his 5 Oct phone: Gemma 4
                // E2B and Nemotron 3 Nano, AIModelError 0 every time).
                let chip = CoreAIBundleLimits.aotChip(path)
                let runsHere = CoreAIBundleLimits.runs(chip: chip, machine: machine)
                // Pass 32 (his 7 Oct request): where the iPhone build is
                // compiled for another chip, the same model's portable build
                // — the one Core AI compiles on the device itself, as it
                // does for Qwen3.5, LFM2.5 and the others — is used instead.
                if $0.modelID != nil, !runsHere,
                   let alternative = CoreAIBundleLimits.portableAlternative(iOSPath: path, macPath: $0.variants["macos"]?.path) {
                    portable[$0.id] = $0.modelID(path: alternative)
                    return CoreAIModelDescriptor(id: $0.id, name: $0.name, repo: $0.repo,
                                                 sizeMB: $0.variants["macos"]?.sizeMB ?? $0.variants["ios"]?.sizeMB,
                                                 isCompatible: true, revision: $0.modelID?.revision, variant: alternative,
                                                 engineHint: $0.engine, unsupportedReason: nil,
                                                 portableNote: "The iPhone build is compiled only for the \(CoreAIBundleLimits.phoneName(chip: chip ?? ""))'s chip, so PodSkipper uses the portable build of the same model, which Core AI compiles on this iPhone the first time it loads (slower first start). Not yet tested on an iPhone 16 Pro.")
                }
                let reason: String? = $0.modelID == nil ? "Not published for iPhone"
                    : runsHere ? nil : "Built only for the \(CoreAIBundleLimits.phoneName(chip: chip ?? ""))'s chip"
                return CoreAIModelDescriptor(id: $0.id, name: $0.name, repo: $0.repo,
                                             sizeMB: $0.variants["ios"]?.sizeMB,
                                             isCompatible: $0.modelID != nil && runsHere,
                                             revision: $0.modelID?.revision, variant: $0.modelID?.resolvedPath,
                                             engineHint: $0.engine, unsupportedReason: reason)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.bundleIDs = portable
            #else
            guard let self else { return }
            if DemoData.isEnabled {
                self.entries = [
                    CoreAIModelDescriptor(id: "qwen3-0.6b", name: "Qwen3 0.6B", repo: "Demo catalog", sizeMB: nil, isCompatible: true),
                    CoreAIModelDescriptor(id: "qwen3-4b", name: "Qwen3 4B", repo: "Demo catalog", sizeMB: nil, isCompatible: true)
                ]
                if ProcessInfo.processInfo.arguments.contains("-ModelDownloadDemo") {
                    self.entries.append(CoreAIModelDescriptor(id: "nemotron-3-nano-4b", name: "Nemotron 3 Nano 4B", repo: "Demo catalog", sizeMB: 4_600, isCompatible: true))
                }
            } else {
                self.error = "Core AI models require a physical device."
            }
            #endif
            self.loading = false
            self.loadTask = nil
        }
    }

    func isDownloaded(_ entry: CoreAIModelDescriptor) -> Bool {
        guard !removingIDs.contains(entry.id) else { return false }
        _ = cacheRevision
        #if !targetEnvironment(simulator)
        guard let model = modelID(for: entry.id) else { return false }
        return CoreAIKitCore.ModelStore.default.localURL(for: model) != nil
        #else
        return DemoData.isEnabled && entry.id == "qwen3-0.6b"
        #endif
    }

    var isReady: Bool {
        guard let entry = selectedEntry else { return false }
        return entry.isCompatible && isDownloaded(entry) && ModelBench.shared.isEnabled(CoreAIQwen3.benchmarkID(for: entry.id))
    }

    #if !targetEnvironment(simulator)
    /// Resolve the already-selected catalog entry once; loading must not
    /// silently resolve a changed live catalog or start another download.
    func cachedBundle(for id: String) -> (url: URL, engineHint: String?)? {
        guard let entry = catalogEntries[id], let model = modelID(for: id),
              let url = CoreAIKitCore.ModelStore.default.localURL(for: model) else { return nil }
        return (url, entry.engine)
    }
    #endif

    func downloadedSize(_ entry: CoreAIModelDescriptor) -> Int64 {
        #if !targetEnvironment(simulator)
        guard let model = modelID(for: entry.id),
              let url = CoreAIKitCore.ModelStore.default.localURL(for: model) else { return 0 }
        return FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])?.reduce(Int64(0)) { total, item in
            guard let fileURL = item as? URL,
                  let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { return total }
            return total + Int64(values.fileSize ?? 0)
        } ?? 0
        #else
        return 0
        #endif
    }

    func download(_ entry: CoreAIModelDescriptor) {
        #if !targetEnvironment(simulator)
        guard let model = modelID(for: entry.id) else {
            error = "This model is not published for iOS."
            return
        }
        guard downloadingID == nil, !removingIDs.contains(entry.id) else { return }
        downloadingID = entry.id
        downloadFraction = 0
        downloadFile = ""
        error = nil

        let runID = UUID()
        downloadRunID = runID
        let cellular = ModelStore.shared.allowCellular
        let final = CoreAIKitCore.ModelStore.default.directory
            .appendingPathComponent(model.repo).appendingPathComponent(model.revision)
            .appendingPathComponent(model.resolvedPath)
        downloadTask = Task { [weak self] in
            do {
                try await CoreAIModelDownload().download(repo: model.repo, revision: model.revision,
                    variant: model.resolvedPath, final: final, allowCellular: cellular) { fraction, file in
                    Task { @MainActor [weak self] in
                        guard self?.downloadRunID == runID else { return }
                        self?.downloadFraction = fraction
                        self?.downloadFile = file
                    }
                }
                guard let self, self.downloadRunID == runID else { return }
                self.cacheRevision += 1
                self.finishDownload()
                self.chooseAfterDownload(entry)
            } catch {
                guard let self, self.downloadRunID == runID else { return }
                self.error = error is CancellationError || (error as NSError).code == NSURLErrorCancelled
                    ? "Download stopped. Completed files are kept; tap Download to continue." : error.localizedDescription
                self.finishDownload()
            }
        }
        #else
        if DemoData.isEnabled && ProcessInfo.processInfo.arguments.contains("-ModelDownloadDemo") {
            // UI-only fixture; the HTTP transfer is exercised independently.
            downloadingID = entry.id
            downloadFraction = 0.35
        } else { error = "Core AI downloads and inference require a physical device." }
        #endif
    }

    /// Pass 32 (his 7 Oct request): a model he downloads on purpose becomes
    /// the chosen Core AI model once it is complete — only if this iPhone
    /// can run it and it is switched on. Never an unusable one.
    private func chooseAfterDownload(_ entry: CoreAIModelDescriptor) {
        guard entry.isCompatible, isDownloaded(entry),
              ModelBench.shared.isEnabled(CoreAIQwen3.benchmarkID(for: entry.id)), selectedID != entry.id else { return }
        selectedID = entry.id
        BackgroundLog.shared.note("\(entry.name) finished downloading and is now the chosen Core AI model")
    }

    func cellularRuleChanged() {
        // An in-flight URLSession keeps its original cellular rule. Stop it
        // before another transfer can continue under the new preference.
        if downloadingID != nil { stopDownload() }
    }

    func stopDownload() {
        downloadTask?.cancel()
        #if targetEnvironment(simulator)
        if DemoData.isEnabled { finishDownload() }
        #endif
    }

    private func finishDownload() {
        downloadingID = nil
        downloadTask = nil
        downloadRunID = nil
        downloadFile = ""
    }

    /// Models loaded right now by a job or a test (pass 30). Only these
    /// can't be deleted; any other downloaded model can, whatever else runs.
    /// His 5 Oct phone: every Delete button greyed out while one test ran.
    private(set) var inUse: Set<String> = []
    func markInUse(_ id: String, _ busy: Bool) {
        if busy { inUse.insert(id) } else { inUse.remove(id) }
    }

    /// Whether Delete must wait: the model is loaded, or it is the chosen
    /// one and a job that may load it is under way.
    func deleteWaits(_ entry: CoreAIModelDescriptor) -> Bool {
        inUse.contains(entry.id) || (entry.id == selectedID && HeavyWorkCoordinator.shared.isBusy)
    }

    func delete(_ entry: CoreAIModelDescriptor) {
        #if !targetEnvironment(simulator)
        guard let model = modelID(for: entry.id), !inUse.contains(entry.id) else { return }
        // Only the chosen model can be picked up by a job mid-delete, so only
        // it needs the heavy-work slot.
        var lease: HeavyWorkCoordinator.Lease?
        if entry.id == selectedID {
            guard let acquired = HeavyWorkCoordinator.shared.tryAcquire(owner: "model-delete:" + entry.id) else {
                error = entry.name + " is in use; delete it when the job or test finishes."
                return
            }
            lease = acquired
        }
        removingIDs.insert(entry.id)
        Task {
            defer {
                removingIDs.remove(entry.id)
                cacheRevision += 1
                if let lease { HeavyWorkCoordinator.shared.release(lease) }
            }
            do {
                try await CoreAIKitCore.ModelStore.default.delete(model)
                cacheRevision += 1
                if entry.id == selectedID { selectReplacement(for: entry.id) }
            } catch { self.error = error.localizedDescription }
        }
        #endif
    }

    /// Pass 30 (his request): the chosen model was deleted, so choose the
    /// best-scoring ready model left (alphabetical if none has a score). If
    /// none is left, the selection stays and its tests grey out.
    func selectReplacement(for removed: String) {
        let bench = ModelBench.shared
        let ready = entries.filter {
            $0.id != removed && $0.isCompatible && isDownloaded($0)
                && bench.isEnabled(CoreAIQwen3.benchmarkID(for: $0.id))
        }
        guard let next = ModelRanking.bestFirst(ready.map { ($0.id, $0.name, bench.score(CoreAIQwen3.benchmarkID(for: $0.id))) }).first,
              let entry = ready.first(where: { $0.id == next }) else { return }
        selectedID = entry.id
        BackgroundLog.shared.note("You deleted the chosen Core AI model; \(entry.name) is chosen now")
    }

    @discardableResult
    func select(_ entry: CoreAIModelDescriptor) -> Bool {
        guard entry.isCompatible, isDownloaded(entry),
              ModelBench.shared.isEnabled(CoreAIQwen3.benchmarkID(for: entry.id)),
              !ModelBench.shared.isRunning else { return false }
        selectedID = entry.id
        return true
    }

    func entries(matching query: String) -> [CoreAIModelDescriptor] {
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
                || $0.repo.localizedCaseInsensitiveContains(query)
        }
    }

    static func displaySize(_ entry: CoreAIModelDescriptor) -> String {
        if let mb = entry.sizeMB {
            if mb >= 1000 { return String(format: "%.1f GB", Double(mb) / 1000.0) }
            return "\(mb) MB"
        }
        return "Size varies"
    }
}
