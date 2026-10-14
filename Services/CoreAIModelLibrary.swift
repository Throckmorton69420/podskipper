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
    /// Pass 37: Gemma 4's word tables, where it has them (see `load`).
    @ObservationIgnored private var gemmaTables: [String: ModelID] = [:]
    #endif
    /// Decoder 2,121 MB + the two word-table files 2,350 MB.
    nonisolated static let gemmaDownloadMB = 4_471
    /// The two table files and where they go inside the decoder's folder.
    nonisolated static let gemmaTableFiles: Set<String> = ["embed_per_layer.i8", "embed_per_layer.scale.f32"]
    nonisolated static let gemmaTablesFolder = "ple-tables"

    /// Pass 37: whether a downloaded bundle folder holds Gemma's tables.
    nonisolated static func tablesComplete(in bundle: URL) -> Bool {
        let folder = bundle.appending(path: gemmaTablesFolder)
        return gemmaTableFiles.allSatisfy { ((try? folder.appending(path: $0).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }
    }
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    private var downloadRunID: UUID?

    /// Pass 36: chat models whose iPhone build is a Neural Engine
    /// (static-shape) graph with no compiled copy published for most chips.
    /// Their model cards: "iOS static bundles must be AOT-compiled before
    /// device use" (published for h18p only).
    nonisolated static let neuralEngineOnlyOnIPhone: Set<String> = ["qwen3-4b", "qwen3-0.6b"]

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
                // Pass 36 (his 9 and 12 Oct phone: "GPU buffer allocation
                // failed: per-token input 'ple_table' (9,620,726,743,040
                // bytes)", every load, both samples): Gemma 4 is two bundles —
                // the decoder and its per-layer word tables, which CoreAIKit
                // feeds through its own Gemma loader (`GemmaModelID`). Loaded
                // alone through the general engine, the tables input has no
                // size. Its iPhone decoder is also built only for the iPhone
                // 17 Pro, and its portable one "crashes the on-device GPU
                // specializer" (CoreAIKit). No supported way to run it here.
                // Pass 36 (his 13 Oct phone, after the compiled copy): Qwen3's
                // iPhone builds run on the Neural Engine, and Core AI compiles
                // that on the device before first use — measured on the Mac
                // for Qwen3 0.6B: 33 min from the download, 4.5 min from a copy
                // compiled ahead of time on the Mac (still not none); on his
                // phone the h17p copy of Qwen3 4B hadn't finished after 16 min
                // and Qwen3 0.6B's first run took 12 min. The same
                // model's GPU build (the publisher's `macos` bundle, same
                // revision) prepares in about 11 s on the Mac, like the GPU
                // builds his phone already runs (LFM2.5, Granite, MiniCPM5).
                if Self.neuralEngineOnlyOnIPhone.contains($0.id), $0.modelID != nil,
                   let gpu = $0.variants["macos"]?.path, !CoreAIBundleLimits.hasPublishedBuild(for: machine, iOSPath: path) {
                    portable[$0.id] = $0.modelID(path: gpu)
                    return CoreAIModelDescriptor(id: $0.id, name: $0.name, repo: $0.repo,
                                                 sizeMB: $0.variants["macos"]?.sizeMB ?? $0.variants["ios"]?.sizeMB,
                                                 isCompatible: true, revision: $0.modelID?.revision, variant: gpu,
                                                 engineHint: $0.engine, unsupportedReason: nil,
                                                 portableNote: "Uses the GPU build of the same model. Its iPhone build runs on the Neural Engine, which Core AI first compiles on the phone for a very long time (Qwen3 0.6B took 12 minutes on this iPhone; Qwen3 4B didn't finish in 16).")
                }
                // Pass 37 (his request: make Gemma work rather than mark it
                // unusable). Gemma 4 E2B is now loaded as CoreAIKit loads it:
                // the decoder with its two word tables bound beside it
                // (`CoreAIGemmaTables`), downloaded into the decoder's folder
                // (`ple-tables/`, only the two files the decoder reads). On
                // an iPhone 17 Pro its compiled iPhone build is used; on
                // other iPhones the portable build of the same QAT decoder,
                // which Core AI compiles on the phone the first time (the
                // publisher saw that compile fail on early iOS 27 betas;
                // untested on iOS 27.0.1) — or a copy compiled on a Mac for
                // this iPhone's chip, installed in Models and Caches.
                if let gemma = GemmaModelID.byCatalogID[$0.id], $0.modelID != nil {
                    let compiledHere = CoreAIBundleLimits.hasPublishedBuild(for: machine, iOSPath: path)
                    let decoder = compiledHere ? path : ($0.variants["macos"]?.path ?? path)
                    portable[$0.id] = $0.modelID(path: decoder)
                    gemmaTables[$0.id] = gemma.pinned($0.revision).tables
                    return CoreAIModelDescriptor(id: $0.id, name: $0.name, repo: $0.repo,
                                                 sizeMB: Self.gemmaDownloadMB, isCompatible: true,
                                                 revision: $0.modelID?.revision, variant: decoder,
                                                 engineHint: $0.engine, unsupportedReason: nil,
                                                 portableNote: compiledHere ? nil
                                                    : "Gemma loads with its word tables beside it. Its iPhone build is compiled only for the iPhone 17 Pro, so PodSkipper uses the portable build of the same model, which Core AI compiles on this iPhone the first time it loads. If that fails, a copy compiled on a Mac for this iPhone can be installed under the model in Models and Caches.")
                }
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
            self.gemmaTables = self.gemmaTables.filter { portable[$0.key] != nil }
            // Pass 36: a chosen model this version can't run (Gemma 4 E2B was
            // chosen automatically after its download) gives way to the best
            // ready one, so Find Ads doesn't keep failing on it.
            if let chosen = self.selectedEntry, !chosen.isCompatible {
                self.selectReplacement(for: chosen.id, reason: "\(chosen.name) can't run on this iPhone")
            }
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
        guard let model = modelID(for: entry.id),
              let url = CoreAIKitCore.ModelStore.default.localURL(for: model) else { return false }
        return gemmaTables[entry.id] == nil || Self.tablesComplete(in: url)
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

    /// Pass 37: Gemma's word tables for this model, when it needs them and
    /// they're complete; nil for every other model.
    func tablesFolder(for id: String) -> URL?? {
        guard gemmaTables[id] != nil else { return .some(nil) }
        guard let url = cachedBundle(for: id)?.url, Self.tablesComplete(in: url) else { return nil }
        return .some(url.appending(path: Self.gemmaTablesFolder))
    }
    #endif

    /// Pass 36: whether Core AI holds this downloaded model prepared for this
    /// iPhone, as last read (nil = not read yet, or can't be told).
    func prepared(_ entry: CoreAIModelDescriptor) -> Bool? {
        #if !targetEnvironment(simulator)
        guard let url = cachedBundle(for: entry.id)?.url else { return nil }
        return CoreAIPreparation.shared.knownPrepared(bundle: url)
        #else
        return nil
        #endif
    }

    /// Reads it from Core AI for every downloaded model (cheap: it never
    /// starts preparation).
    func refreshPrepared() async {
        #if !targetEnvironment(simulator)
        for entry in entries where entry.isCompatible && isDownloaded(entry) {
            if let url = cachedBundle(for: entry.id)?.url { _ = await CoreAIPreparation.shared.refresh(bundle: url) }
        }
        #endif
    }

    /// Pass 33: where each downloaded model the app would load sits under
    /// CoreAIKit's store (`repo/revision/path`), so Storage can tell the
    /// copies in use from ones nothing points at.
    var currentBundlePaths: Set<String> {
        #if !targetEnvironment(simulator)
        let root = CoreAIKitCore.ModelStore.default.directory.standardizedFileURL.path
        return Set(entries.compactMap { entry -> String? in
            guard let url = cachedBundle(for: entry.id)?.url.standardizedFileURL.path,
                  url.hasPrefix(root + "/") else { return nil }
            return String(url.dropFirst(root.count + 1))
        })
        #else
        return []
        #endif
    }

    /// Pass 35: the bundle path each catalog model loads, by catalog id, and
    /// each catalog model's repository, so the storage inventory can name
    /// every copy on disk (in use, another version of a listed model, or a
    /// model not in the list) instead of filing it as unused.
    var storagePathsByID: [String: String] {
        #if !targetEnvironment(simulator)
        let root = CoreAIKitCore.ModelStore.default.directory.standardizedFileURL.path
        return Dictionary(uniqueKeysWithValues: entries.compactMap { entry -> (String, String)? in
            guard let url = cachedBundle(for: entry.id)?.url.standardizedFileURL.path,
                  url.hasPrefix(root + "/") else { return nil }
            return (entry.id, String(url.dropFirst(root.count + 1)))
        })
        #else
        return [:]
        #endif
    }

    var repositoriesByID: [String: String] {
        Dictionary(entries.map { ($0.id, $0.repo) }, uniquingKeysWith: { a, _ in a })
    }

    func entry(id: String) -> CoreAIModelDescriptor? { entries.first { $0.id == id } }

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
        // Pass 35: room for the download and, for a model Core AI compiles
        // on the phone, its compiled copy, with a margin for the library.
        let room = StorageGuard.check(writing: Int64(entry.sizeMB ?? 2_500) * 2_000_000)
        if case .insufficient = room {
            error = StorageGuard.message(for: room, doing: "download and prepare " + entry.name)
            return
        }
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
        let tables = gemmaTables[entry.id]
        // Pass 37: Gemma downloads in two parts — the decoder, then its word
        // tables into the decoder's folder; the bar covers both by size.
        let decoderShare = tables == nil ? 1.0 : 2_121.0 / Double(Self.gemmaDownloadMB)
        let decoderPresent = CoreAIKitCore.ModelStore.default.localURL(for: model) != nil
        downloadTask = Task { [weak self] in
            do {
                if !decoderPresent {
                    try await CoreAIModelDownload().download(repo: model.repo, revision: model.revision,
                        variant: model.resolvedPath, final: final, allowCellular: cellular) { fraction, file in
                        Task { @MainActor [weak self] in
                            guard self?.downloadRunID == runID else { return }
                            self?.downloadFraction = fraction * decoderShare
                            self?.downloadFile = file
                        }
                    }
                }
                if let tables, !Self.tablesComplete(in: final) {
                    try await CoreAIModelDownload().download(repo: tables.repo, revision: tables.revision,
                        variant: tables.resolvedPath, final: final.appending(path: Self.gemmaTablesFolder),
                        allowCellular: cellular, only: Self.gemmaTableFiles) { fraction, file in
                        Task { @MainActor [weak self] in
                            guard self?.downloadRunID == runID else { return }
                            self?.downloadFraction = decoderShare + fraction * (1 - decoderShare)
                            self?.downloadFile = file
                        }
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

    /// Pass 36: what one deletion did, item by item, for the screen and the
    /// cleanup log. Nothing is said to be removed until it has been.
    struct DeletionReport: Sendable, Equatable {
        var deleted: [String] = []
        /// Kept on purpose, with the reason.
        var retained: [String] = []
        var failures: [String] = []
        /// Bytes measured before removal of what was actually removed.
        var freed: Int64 = 0
    }

    /// Deletes exactly the copy of this model that PodSkipper loads: its
    /// bundle (with any compiled copy installed in it), Core AI's prepared
    /// copy of it, and its own stopped download. Pass 36 (his request): other
    /// revisions or builds of the same model in the same repository are kept
    /// — Pass 33 removed the whole repository folder — and listed as kept, so
    /// each can be deleted on its own in Models and Caches.
    /// Returns the task doing it, so the caller can wait for the real result.
    @discardableResult
    func delete(_ entry: CoreAIModelDescriptor) -> Task<DeletionReport, Never>? {
        #if !targetEnvironment(simulator)
        guard let model = modelID(for: entry.id) else { return nil }
        guard !inUse.contains(entry.id), CoreAIPreparation.shared.current?.modelID != entry.id else {
            error = entry.name + " is in use; delete it when the job or test finishes."
            return nil
        }
        // Only the chosen model can be picked up by a job mid-delete, so only
        // it needs the heavy-work slot.
        var lease: HeavyWorkCoordinator.Lease?
        if entry.id == selectedID {
            guard let acquired = HeavyWorkCoordinator.shared.tryAcquire(owner: "model-delete:" + entry.id) else {
                error = entry.name + " is in use; delete it when the job or test finishes."
                return nil
            }
            lease = acquired
        }
        removingIDs.insert(entry.id)
        let bundle = CoreAIKitCore.ModelStore.default.localURL(for: model)
        let root = CoreAIKitCore.ModelStore.default.directory
        let final = root.appendingPathComponent(model.repo).appendingPathComponent(model.revision)
            .appendingPathComponent(model.resolvedPath)
        let staging = final.deletingLastPathComponent().appendingPathComponent(".podskipper-staging-" + final.lastPathComponent)
        let name = entry.name
        return Task {
            defer {
                removingIDs.remove(entry.id)
                cacheRevision += 1
                if let lease { HeavyWorkCoordinator.shared.release(lease) }
            }
            var report = await Task.detached(priority: .userInitiated) { () -> DeletionReport in
                var report = DeletionReport()
                let freeBefore = ModelStorage.freeBytes()
                var items: [CleanupLog.Item] = []
                if let bundle {
                    let bytes = ModelStorage.size(of: bundle)
                    // Core AI's prepared copy first: it is found by the graph's path.
                    let prepared = CoreAIPreparation.removePrepared(bundle: bundle)
                    report.failures += prepared
                    items.append(CleanupLog.Item(name: "Prepared copy of \(name)", area: "Core AI cache", kind: "prepared model",
                                                 evidence: "Core AI's cache entries for this bundle's graphs", bytes: 0,
                                                 result: prepared.isEmpty ? "removed" : "failed: " + prepared.joined(separator: "; ")))
                    let removed = ModelStorage.removeModelFiles([bundle])
                    if let failure = removed.failures.first {
                        report.failures.append(failure)
                        items.append(CleanupLog.Item(name: bundle.lastPathComponent, area: "Core AI models", kind: "model",
                                                     evidence: "The bundle PodSkipper loads for \(name)", bytes: bytes, result: "failed: " + failure))
                    } else {
                        report.freed += bytes
                        report.deleted.append("\(name) (\(ModelStorage.relativePath(of: bundle, under: root)))")
                        items.append(CleanupLog.Item(name: bundle.lastPathComponent, area: "Core AI models", kind: "model",
                                                     evidence: "The bundle PodSkipper loads for \(name)", bytes: bytes, result: "removed"))
                    }
                }
                if FileManager.default.fileExists(atPath: staging.path) {
                    let bytes = ModelStorage.size(of: staging)
                    let removed = ModelStorage.removeModelFiles([staging])
                    if removed.failures.isEmpty { report.freed += bytes; report.deleted.append("Stopped download of \(name)") }
                    report.failures += removed.failures
                    items.append(CleanupLog.Item(name: staging.lastPathComponent, area: "Core AI models", kind: "stopped download",
                                                 evidence: "PodSkipper's own download folder for this build", bytes: bytes,
                                                 result: removed.failures.first.map { "failed: " + $0 } ?? "removed"))
                }
                // Other copies under the same repository are kept, named.
                let repoFolder = root.appendingPathComponent(model.repo)
                for other in ModelStorage.coreAIBundles(under: repoFolder) {
                    let relative = ModelStorage.relativePath(of: other, under: root)
                    report.retained.append("\(relative): another version or build you kept; delete it on its own if you don't need it")
                    items.append(CleanupLog.Item(name: relative, area: "Core AI models", kind: "model", evidence: "Same repository, different revision or build",
                                                 bytes: ModelStorage.size(of: other), result: "kept: not the copy being deleted"))
                }
                CleanupLog.record(CleanupLog.Operation(date: .now, context: "Delete \(name)", items: items,
                                                       freeBefore: freeBefore, freeAfter: ModelStorage.freeBytes()))
                return report
            }.value
            cacheRevision += 1
            if report.failures.isEmpty, entry.id == selectedID { selectReplacement(for: entry.id) }
            if !report.failures.isEmpty { error = report.failures.joined(separator: "; ") }
            report.retained.sort()
            return report
        }
        #else
        return nil
        #endif
    }

    /// Pass 30 (his request): the chosen model was deleted, so choose the
    /// best-scoring ready model left (alphabetical if none has a score). If
    /// none is left, the selection stays and its tests grey out.
    func selectReplacement(for removed: String, reason: String = "You deleted the chosen Core AI model") {
        let bench = ModelBench.shared
        let ready = entries.filter {
            $0.id != removed && $0.isCompatible && isDownloaded($0)
                && bench.isEnabled(CoreAIQwen3.benchmarkID(for: $0.id))
        }
        guard let next = ModelRanking.bestFirst(ready.map { ($0.id, $0.name, bench.score(CoreAIQwen3.benchmarkID(for: $0.id))) }).first,
              let entry = ready.first(where: { $0.id == next }) else { return }
        selectedID = entry.id
        BackgroundLog.shared.note("\(reason); \(entry.name) is chosen now")
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
