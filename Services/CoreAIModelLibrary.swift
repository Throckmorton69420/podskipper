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
            self.entries = merged.map {
                CoreAIModelDescriptor(id: $0.id, name: $0.name, repo: $0.repo,
                                      sizeMB: $0.variants["ios"]?.sizeMB,
                                      isCompatible: $0.modelID != nil, revision: $0.modelID?.revision, variant: $0.modelID?.resolvedPath)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
        guard let model = catalogEntries[entry.id]?.modelID else { return false }
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
        guard let entry = catalogEntries[id], let model = entry.modelID,
              let url = CoreAIKitCore.ModelStore.default.localURL(for: model) else { return nil }
        return (url, entry.engine)
    }
    #endif

    func downloadedSize(_ entry: CoreAIModelDescriptor) -> Int64 {
        #if !targetEnvironment(simulator)
        guard let model = catalogEntries[entry.id]?.modelID,
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
        guard let model = catalogEntries[entry.id]?.modelID else {
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

    func delete(_ entry: CoreAIModelDescriptor) {
        #if !targetEnvironment(simulator)
        guard let model = catalogEntries[entry.id]?.modelID,
              let lease = HeavyWorkCoordinator.shared.tryAcquire(owner: "model-delete:" + entry.id) else { return }
        removingIDs.insert(entry.id)
        Task {
            defer {
                removingIDs.remove(entry.id)
                cacheRevision += 1
                HeavyWorkCoordinator.shared.release(lease)
            }
            do { try await CoreAIKitCore.ModelStore.default.delete(model) }
            catch { self.error = error.localizedDescription }
        }
        #endif
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
