import SwiftUI
import UniformTypeIdentifiers

/// Pass 64 (his 13 Nov request): models on an external drive — the folder he
/// picks once in Files (his Samsung T9 over USB-C, filled on the Mac by
/// `Scripts/ssd_models.sh`). CPU and MLX models read straight from it; any
/// model can be imported (copied) into this iPhone over USB, with how much
/// of how much and how fast. Core AI bundles — including copies compiled on
/// the Mac for this iPhone — are imported, never prepared on the phone.
struct ExternalModelLibraryView: View {
    @State private var model = ExternalModelImport.shared
    @State private var choosing = false
    /// Pass 66: the picker is choosing one model (a file or a folder), not the drive's folder.
    @State private var choosingModel = false

    var body: some View {
        List {
            Text("Keep models on an external drive and use them without downloading over Wi‑Fi. CPU and MLX models read straight from the drive while it’s connected; Import copies any model, including a Core AI model compiled on your Mac for this iPhone, into this iPhone so it works without the drive.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).contentRow()
            folderRow
            if let progress = model.progress { progressRow(progress) }
            if let message = model.message {
                Text(message).font(.subheadline).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).contentRow()
                    .accessibilityIdentifier("external.message")
            }
            if model.inventory.connected {
                SectionHeader("On the Drive")
                if model.inventory.items.isEmpty {
                    Text(model.reading ? "Reading the drive…" : "No model PodSkipper knows is in this folder. On your Mac, Scripts/ssd_models.sh downloads them into PodSkipper/Models on the drive.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).contentRow()
                }
                ForEach(model.inventory.items) { item in itemRow(item) }
            }
            Text("Keep the drive connected while a model reads from it: unplugging it then stops the read (and can close PodSkipper). Imported models don’t need the drive.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).contentRow()
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle("External Drive")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .task { model.refresh() }
        .fileImporter(isPresented: Binding(get: { choosing || choosingModel },
                                           set: { if !$0 { choosing = false; choosingModel = false } }),
                      allowedContentTypes: choosingModel ? [.item, .folder, .package] : [.folder]) { result in
            let forModel = choosingModel
            choosing = false
            choosingModel = false
            guard case .success(let url) = result else { return }
            if forModel { model.importChosen(url) } else { model.choose(url) }
        }
    }

    private var folderRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.inventory.folderName.isEmpty {
                Text("No folder chosen").font(.body.weight(.semibold))
            } else {
                Text(model.inventory.folderName).font(.body.weight(.semibold))
                Text(model.inventory.connected ? "Connected" : "Not connected: plug the drive in to use it")
                    .font(.subheadline).foregroundStyle(model.inventory.connected ? Color.secondary : Color.orange)
            }
            // Pass 66 audit: the three buttons flow onto more lines at large text sizes.
            WrappingRow(spacing: 10) {
                Button { choosing = true } label: {
                    PodTestButtonLabel(model.inventory.folderName.isEmpty ? "Choose Folder" : "Choose Another")
                }
                .buttonStyle(.glassProminent)
                .accessibilityHint("Pick the PodSkipper/Models folder on your drive in Files")
                .accessibilityIdentifier("external.choose")
                if !model.inventory.folderName.isEmpty {
                    Button { model.refresh() } label: { PodTestButtonLabel("Read Again") }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("external.refresh")
                    Button(role: .destructive) { model.forget() } label: { PodTestButtonLabel("Forget") }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("external.forget")
                }
            }
            // Pass 66 (his 16 Nov request): one model on its own — a CPU
            // model's .gguf, an MLX folder, a Core AI bundle with or without
            // its compiled copy, or a compiled .aimodelc — from anywhere in
            // Files, without choosing the drive's whole Models folder.
            Button { choosingModel = true } label: { PodTestButtonLabel("Choose Model File or Folder…") }
                .buttonStyle(.glass)
                .disabled(model.isImporting)
                .accessibilityHint("Import one model: a .gguf file, an MLX model folder, a Core AI model folder or a compiled .aimodelc")
                .accessibilityIdentifier("external.chooseModel")
        }
        .contentRow(top: 10, bottom: 10)
    }

    private func progressRow(_ p: ExternalModelImport.Progress) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Importing " + p.name).font(.subheadline.weight(.semibold))
                PlainBar(value: p.total > 0 ? Double(p.done) / Double(p.total) : 0)
                Text(TransferText.line(done: p.done, total: p.total, bytesPerSecond: p.bytesPerSecond))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityIdentifier("external.transfer")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.stop() } label: { PodTestButtonLabel("Stop") }
                .buttonStyle(.glass)
                .accessibilityLabel("Stop importing " + p.name)
        }
        .contentRow(top: 10, bottom: 10)
    }

    private func itemRow(_ item: ExternalModelInventory.Item) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.subheadline.weight(.semibold))
                Text(([Self.kind(item.kind), Self.graph(item.graph), ModelStore.gigabytes(item.bytes),
                       item.imported ? "on this iPhone" : item.readsInPlace ? "reads from the drive" : "import to use"] as [String?])
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !item.imported {
                Button { model.importItem(item) } label: { PodTestButtonLabel("Import") }
                    .buttonStyle(.glass)
                    .disabled(model.isImporting)
                    .accessibilityLabel("Import " + item.name)
                    .accessibilityIdentifier("external.import." + item.id)
            }
        }
        .frame(minHeight: 44)
        .contentRow(top: 6, bottom: 6)
    }

    /// Pass 66: which graph a Core AI import brings.
    static func graph(_ graph: CoreAIGraph?) -> String? {
        switch graph {
        case .compiled(let chip)?: "compiled on a Mac for \(chip)"
        case .portable?: "portable build (Core AI prepares it on this iPhone)"
        case nil: nil
        }
    }

    static func kind(_ kind: ExternalModelKind) -> String {
        switch kind {
        case .gguf: "CPU model"
        case .mlx: "MLX model"
        case .coreAI: "Core AI model"
        }
    }
}
