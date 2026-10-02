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
}

@available(iOS 27.0, *)
@MainActor
@Observable
final class CoreAIModelLibrary {
    static let shared = CoreAIModelLibrary()

    private(set) var entries: [CoreAIModelDescriptor] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var downloadingID: String?
    private(set) var downloadFraction = 0.0
    private(set) var downloadFile = ""
    private var cacheRevision = 0

    #if !targetEnvironment(simulator)
    @ObservationIgnored private var catalogEntries: [String: CatalogEntry] = [:]
    #endif
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    var selectedID: String {
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
                                      isCompatible: $0.modelID != nil)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            #else
            guard let self else { return }
            if DemoData.isEnabled {
                self.entries = [
                    CoreAIModelDescriptor(id: "qwen3-0.6b", name: "Qwen3 0.6B", repo: "Demo catalog", sizeMB: nil, isCompatible: true),
                    CoreAIModelDescriptor(id: "qwen3-4b", name: "Qwen3 4B", repo: "Demo catalog", sizeMB: nil, isCompatible: true)
                ]
            } else {
                self.error = "Core AI models require a physical device."
            }
            #endif
            if !self.entries.contains(where: { $0.id == self.selectedID }), let first = self.entries.first {
                self.selectedID = first.id
            }
            self.loading = false
            self.loadTask = nil
        }
    }

    func isDownloaded(_ entry: CoreAIModelDescriptor) -> Bool {
        _ = cacheRevision
        #if !targetEnvironment(simulator)
        guard let model = catalogEntries[entry.id]?.modelID else { return false }
        return CoreAIKitCore.ModelStore.default.localURL(for: model) != nil
        #else
        return false
        #endif
    }

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
        guard downloadingID == nil else { return }
        downloadingID = entry.id
        downloadFraction = 0
        downloadFile = ""
        error = nil

        Task { [weak self] in
            do {
                _ = try await CoreAIKitCore.ModelStore.default.download(model) { progress in
                    Task { @MainActor [weak self] in
                        self?.downloadFraction = progress.fraction
                        self?.downloadFile = progress.currentFile
                    }
                }
                await MainActor.run {
                    self?.downloadingID = nil
                    self?.downloadFraction = 1
                    self?.downloadFile = ""
                    self?.cacheRevision += 1
                }
            } catch {
                await MainActor.run {
                    self?.downloadingID = nil
                    self?.error = error.localizedDescription
                }
            }
        }
        #else
        error = "Core AI downloads and inference require a physical device."
        #endif
    }

    func delete(_ entry: CoreAIModelDescriptor) {
        guard !HeavyWorkCoordinator.shared.isBusy else { return }
        #if !targetEnvironment(simulator)
        guard let model = catalogEntries[entry.id]?.modelID else { return }
        Task {
            do {
                try await CoreAIKitCore.ModelStore.default.delete(model)
                self.cacheRevision += 1
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
        #endif
    }

    func select(_ entry: CoreAIModelDescriptor) {
        selectedID = entry.id
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
