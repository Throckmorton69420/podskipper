import SwiftUI

/// Settings → Storage → Models and Caches (Pass 33): what the models take,
/// measured from the files, and the copies nothing uses any more.
struct ModelStorageView: View {
    @State private var report: ModelStorage.Report?
    @State private var measuring = false
    @State private var confirm: Confirm?
    @State private var message: String?

    enum Confirm: Identifiable {
        case leftovers, compiled
        var id: Self { self }
    }

    var body: some View {
        List {
            if let report {
                Section {
                    LabeledContent("Downloaded models", value: bytes(report.modelBytes))
                    if report.compiledBytes > 0 {
                        LabeledContent("Compiled models", value: bytes(report.compiledBytes))
                    }
                    if report.temporaryBytes > 1_000_000 {
                        LabeledContent("Temporary files", value: bytes(report.temporaryBytes))
                    }
                    if let free = report.freeBytes {
                        LabeledContent("Free on this iPhone", value: bytes(free))
                    }
                } footer: {
                    Text("Measured from the files just now. iPhone Storage in Settings can take a few minutes to catch up after something is removed.")
                }

                Section("Models") {
                    let mlx = ModelStore.shared
                    ForEach(LocalModelSpec.all.filter { (report.mlx[$0.id] ?? 0) > 0 }, id: \.id) { spec in
                        LabeledContent(spec.name, value: bytes(report.mlx[spec.id] ?? 0))
                    }
                    let library = CoreAIModelLibrary.shared
                    ForEach(library.entries.filter { library.isDownloaded($0) }, id: \.id) { entry in
                        LabeledContent("Core AI · " + entry.name, value: bytes(library.downloadedSize(entry)))
                    }
                    if report.modelBytes == 0, mlx.readyIDs.isEmpty {
                        Text("No models are downloaded.").foregroundStyle(.secondary)
                    }
                }

                if report.reclaimableBytes > 0 {
                    Section {
                        if report.coreAIStrayBytes > 0 {
                            LabeledContent("Older Core AI copies", value: bytes(report.coreAIStrayBytes))
                        }
                        if report.mlxStrayBytes > 0 {
                            LabeledContent("Models no longer offered", value: bytes(report.mlxStrayBytes))
                        }
                        if report.partialBytes > 0 {
                            LabeledContent("Downloads that stopped part way", value: bytes(report.partialBytes))
                        }
                        Button("Remove Unused Copies", role: .destructive) { confirm = .leftovers }
                            .accessibilityIdentifier("modelStorage.removeLeftovers")
                    } header: {
                        Text("Not used by any model")
                    } footer: {
                        Text("Copies nothing in PodSkipper loads: an older version of a model, or a download that stopped. Your episodes, transcripts and corrections are not affected.")
                    }
                }

                if report.compiledBytes > 0 {
                    Section {
                        Button("Clear Compiled Models", role: .destructive) { confirm = .compiled }
                            .accessibilityIdentifier("modelStorage.clearCompiled")
                    } footer: {
                        Text("Core AI prepares each model for this iPhone the first time it loads and keeps the result. Clearing it frees the space; the next load of each Core AI model takes longer and warms the phone while it is prepared again.")
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let message {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Models and Caches")
        .navigationBarTitleDisplayMode(.inline)
        .task { await measure() }
        .refreshable { await measure() }
        .confirmationDialog(confirm == .compiled ? "Clear compiled models?" : "Remove unused copies?",
                            isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { which in
            Button(which == .compiled ? "Clear \(bytes(report?.compiledBytes ?? 0))" : "Remove \(bytes(report?.reclaimableBytes ?? 0))",
                   role: .destructive) {
                Task { await perform(which) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityIdentifier("modelStorage.list")
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private func measure() async {
        guard !measuring else { return }
        measuring = true
        defer { measuring = false }
        let ids = Set(LocalModelSpec.all.map(\.id))
        let paths = CoreAIModelLibrary.shared.currentBundlePaths
        let active = CoreAIModelLibrary.shared.downloadingID != nil || {
            if case .downloading = ModelStore.shared.phase { return true }
            return false
        }()
        report = await Task.detached(priority: .userInitiated) {
            ModelStorage.measure(mlxIDs: ids, coreAIPaths: paths, downloadActive: active)
        }.value
    }

    private func perform(_ which: Confirm) async {
        guard let report else { return }
        let before = report.reclaimableBytes + report.compiledBytes
        let failures: [String] = await Task.detached(priority: .userInitiated) {
            switch which {
            case .leftovers:
                return ModelStorage.remove(report.coreAIStray + report.mlxStray + report.partial)
            case .compiled:
                do { try ModelStorage.clearCompiledCache(); return [] } catch { return [error.localizedDescription] }
            }
        }.value
        await measure()
        let after = (self.report?.reclaimableBytes ?? 0) + (self.report?.compiledBytes ?? 0)
        message = failures.isEmpty
            ? "Freed \(bytes(max(0, before - after)))."
            : "Some files couldn’t be removed: " + failures.joined(separator: "; ")
        BackgroundLog.shared.note("Models and Caches: " + (message ?? ""))
    }
}
