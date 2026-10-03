import SwiftUI

enum ModelLibraryMode { case mlx, coreAI }

struct LocalModelView: View {
    let mode: ModelLibraryMode
    init(mode: ModelLibraryMode = .mlx) { self.mode = mode }
    @State private var store = ModelStore.shared
    @State private var coreAI = CoreAIModelLibrary.shared

    var body: some View {
        List {
            Text(mode == .coreAI ? AdFinderChoice.coreAI.explanation : AdFinderChoice.model.explanation)
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .contentRow()
            ModelCatalogContent(mode: mode)
            NavigationLink { ModelComparisonView() } label: {
                Label("Compare models", systemImage: "chart.bar.xaxis")
            }.contentRow().accessibilityIdentifier("model.compare")
            SectionHeader("Downloads")
            ModelCellularControl().contentRow()
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle(mode == .coreAI ? "Core AI models" : "MLX models")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .task { coreAI.load(); store.refreshState() }
    }
}

/// The very same model rows appear in the libraries and comparison disclosures.
struct ModelCatalogContent: View {
    let mode: ModelLibraryMode
    @State private var store = ModelStore.shared
    @State private var coreAI = CoreAIModelLibrary.shared
    @State private var bench = ModelBench.shared
    @State private var search = ""
    @State private var deleteID: String?

    var body: some View {
        TextField("Search models", text: $search)
            .font(.body).accessibilityIdentifier("model.\(prefix).search").contentRow()
        if mode == .coreAI {
            if coreAI.loading { ProgressView("Loading models…").contentRow() }
            ForEach(coreAI.entries(matching: search)) { entry in
                row(id: entry.id, benchmarkID: CoreAIQwen3.benchmarkID(for: entry.id), name: entry.name,
                    description: CoreAIModelLibrary.displaySize(entry),
                    downloaded: coreAI.isDownloaded(entry), compatible: entry.isCompatible,
                    selected: coreAI.selectedID == entry.id, downloading: coreAI.downloadingID == entry.id, removing: coreAI.removingIDs.contains(entry.id),
                    select: { coreAI.select(entry) }, download: { coreAI.download(entry) })
            }
            if let error = coreAI.error { downloadMessage(error) }
        } else {
            ForEach(LocalModelSpec.all.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { spec in
                row(id: spec.id, benchmarkID: spec.id, name: spec.name,
                    description: ModelStore.bytes(spec.downloadBytes),
                    downloaded: store.isDownloaded(spec), compatible: true,
                    selected: store.selected == spec,
                    downloading: store.downloadTarget == spec && isMLXDownloading, removing: store.removingIDs.contains(spec.id),
                    select: { store.select(spec) }, download: { store.download(spec) })
            }
            if case .failed(let message) = store.phase { downloadMessage(message) }
            if case .paused(let message) = store.phase { downloadMessage(message) }
            if let note = store.memoryNote { downloadMessage(note) }
            if let error = store.managementError { downloadMessage(error) }
        }
    }

    private var prefix: String { mode == .coreAI ? "coreAI" : "mlx" }
    private var isMLXDownloading: Bool {
        switch store.phase { case .listing, .downloading: return true; default: return false }
    }

    private func downloadMessage(_ message: String) -> some View {
        Text(message).font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).contentRow()
    }

    private func row(id: String, benchmarkID: String, name: String, description: String,
                     downloaded: Bool, compatible: Bool, selected: Bool, downloading: Bool, removing: Bool,
                     select: @escaping () -> Bool, download: @escaping () -> Void) -> some View {
        let enabled = bench.isEnabled(benchmarkID)
        let usable = downloaded && compatible && enabled
        return VStack(alignment: .leading, spacing: 10) {
            Button { if select() { Feel.selection.play() } } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: selected && usable ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected && usable ? Theme.accentHot : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.body.weight(.semibold))
                        Text(description + " · " + (compatible ? (downloaded ? (enabled ? "Ready" : "Turned off") : "Not downloaded") : "Unavailable on iOS"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }.fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
            }
            .buttonStyle(.plain).disabled(!usable || bench.isRunning)
            .accessibilityIdentifier("model.\(prefix).select." + id)
            HStack(spacing: 12) {
                Button {
                    if downloading { mode == .coreAI ? coreAI.stopDownload() : store.pause() }
                    else if downloaded { deleteID = id }
                    else { download() }
                } label: {
                    SharedActionLabel(removing ? "Removing…" : downloading ? "Stop Download" : downloaded ? "Delete" : "Download",
                                      symbol: downloading ? "stop.fill" : downloaded ? "trash" : "arrow.down")
                }
                .buttonStyle(.glass)
                .tint(downloaded ? .red : Theme.accentHot)
                .disabled(removing || !compatible || (downloaded && HeavyWorkCoordinator.shared.isBusy)
                          || (!downloaded && !downloading && anotherDownload(id)))
                .accessibilityIdentifier("model.\(prefix).download." + id)
                Toggle("Enable " + name, isOn: Binding(
                    get: { bench.isEnabled(benchmarkID) }, set: { bench.setEnabled(benchmarkID, $0) }))
                    .labelsHidden().tint(Theme.accentHot).disabled(bench.isRunning)
                    .accessibilityLabel("Enable " + name)
                    .accessibilityIdentifier("model.\(prefix).enabled." + id)
            }
            if downloading {
                if mode == .coreAI {
                    ProgressView(value: coreAI.downloadFraction)
                    Text("Downloading \(Int(coreAI.downloadFraction * 100))% · " + coreAI.downloadFile).font(.subheadline)
                } else if case .downloading(let done, let total, _) = store.phase {
                    ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                    Text(ModelStore.bytes(done) + " of " + ModelStore.bytes(total)).font(.subheadline)
                } else { ProgressView("Starting download…") }
            }
            if let summary = bench.latestSummary(benchmarkID) {
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentRow(top: 12, bottom: 12)
        .confirmationDialog("Delete " + name + "?", isPresented: Binding(
            get: { deleteID == id }, set: { if !$0 { deleteID = nil } }), titleVisibility: .visible) {
                Button("Delete Download", role: .destructive) {
                    if mode == .coreAI, let entry = coreAI.entry(for: id) { coreAI.delete(entry) }
                    else if let spec = LocalModelSpec.all.first(where: { $0.id == id }) { store.delete(spec) }
                    deleteID = nil
                }
            } message: { Text("Downloaded files are removed. Test history is kept.") }
    }

    private func anotherDownload(_ id: String) -> Bool {
        if mode == .coreAI { return coreAI.downloadingID != nil && coreAI.downloadingID != id }
        return isMLXDownloading && store.downloadTarget.id != id
    }
}

struct ModelCellularControl: View {
    @State private var store = ModelStore.shared
    var body: some View {
        @Bindable var store = store
        Toggle("Allow cellular downloads", isOn: $store.allowCellular)
            .tint(Theme.accentHot).accessibilityIdentifier("model.allowCellular")
    }
}

struct LocalModelSettingsLabel: View {
    @State private var store = ModelStore.shared
    var body: some View {
        ModelLibrarySettingsLabel(title: "MLX model library", detail: store.isReady
            ? store.selected.name + " · Ready" : "Choose and download")
    }
}

struct ModelLibrarySettingsLabel: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.body)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension JudgeLabel {
    /// Plain words for the screen.
    var plainName: String {
        switch self {
        case .paidAd:           return "Ad"
        case .hostReadAd:       return "Host-read ad"
        case .networkPromo:     return "Other show's promo"
        case .selfPromo:        return "Self-promotion"
        case .guestPlug:        return "Guest's plug"
        case .intro:            return "Intro"
        case .outro:            return "Outro"
        case .credits:          return "Credits"
        case .recurringSegment: return "Regular segment (kept)"
        case .mockAd:           return "Joke ad (kept)"
        }
    }
}
