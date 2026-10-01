import Foundation
import Observation
import CoreAIKit
import CoreAIKitCore

@available(iOS 27.0, *)
@MainActor
@Observable
final class CoreAIModelLibrary {
    static let shared = CoreAIModelLibrary()

    private(set) var entries: [CatalogEntry] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var downloadingID: String?
    private(set) var downloadFraction = 0.0
    private(set) var downloadFile = ""

    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private var storedSelection: String {
        get { UserDefaults.standard.string(forKey: "coreAI.selectedModel") ?? "qwen3-4b" }
        set { UserDefaults.standard.set(newValue, forKey: "coreAI.selectedModel") }
    }

    var selectedID: String {
        get { storedSelection }
        set { storedSelection = newValue }
    }

    var selectedEntry: CatalogEntry? {
        entries.first { $0.id == selectedID }
    }

    private init() {}

    func load() {
        guard loadTask == nil else { return }
        loading = true
        error = nil
        loadTask = Task { [weak self] in
            let live = await ModelCatalog.load()
            let chat = live.available(.chat)
            let builtin = ModelCatalog.builtin.available(.chat)
            let liveIDs = Set(chat.map(\.id))
            let merged = chat + builtin.filter { !liveIDs.contains($0.id) }
            guard let self else { return }
            self.entries = merged.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            if !self.entries.contains(where: { $0.id == self.selectedID }), let first = self.entries.first {
                self.storedSelection = first.id
            }
            self.loading = false
            self.loadTask = nil
        }
    }

    func isDownloaded(_ entry: CatalogEntry) -> Bool {
        guard let model = entry.modelID else { return false }
        return CoreAIKitCore.ModelStore.default.localURL(for: model) != nil
    }

    func downloadedSize(_ entry: CatalogEntry) -> Int64 {
        guard let model = entry.modelID,
              let url = ModelStore.default.localURL(for: model) else { return 0 }
        return CoreAIKitCore.ModelStore.directorySize(url)
    }

    func download(_ entry: CatalogEntry) {
        guard let model = entry.modelID else {
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
                _ = try await ModelStore.default.download(model) { progress in
                    Task { @MainActor [weak self] in
                        self?.downloadFraction = progress.fraction
                        self?.downloadFile = progress.currentFile
                    }
                }
                await MainActor.run {
                    self?.downloadingID = nil
                    self?.downloadFraction = 1
                    self?.downloadFile = ""
                }
            } catch {
                await MainActor.run {
                    self?.downloadingID = nil
                    self?.error = error.localizedDescription
                }
            }
        }
    }

    func delete(_ entry: CatalogEntry) {
        guard let model = entry.modelID else { return }
        Task {
            do {
                try await ModelStore.default.delete(model)
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }

    func select(_ entry: CatalogEntry) {
        selectedID = entry.id
    }

    func entries(matching query: String) -> [CatalogEntry] {
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
                || $0.repo.localizedCaseInsensitiveContains(query)
        }
    }

    static func displaySize(_ entry: CatalogEntry) -> String {
        if let mb = entry.variants["ios"]?.sizeMB {
            if mb >= 1000 { return String(format: "%.1f GB", Double(mb) / 1000.0) }
            return "\(mb) MB"
        }
        return "Size varies"
    }
}
