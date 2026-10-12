import SwiftUI
import UniformTypeIdentifiers

/// Settings → Downloads & Storage → Models and Caches.
///
/// Pass 35 (his 9 Oct report): every model on the phone, each its own row
/// with its own Delete; what is chosen, downloaded, another version, or not
/// in this version's list are shown as separate facts. Nothing that holds a
/// model is removed in bulk as "unused" — his MLX models were, by Pass 33's
/// "Remove Unused Copies" (see `ModelStorage`).
struct ModelStorageView: View {
    @State private var report: ModelStorage.Report?
    @State private var measuring = false
    @State private var confirm: Confirmation?
    @State private var note: ResultNote?
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive
    @State private var coreAI = CoreAIModelLibrary.shared
    @State private var store = ModelStore.shared
    /// Core AI items whose bundle loads a compiled copy, by item id.
    @State private var compiled: [String: String] = [:]
    @State private var installing = false

    var body: some View {
        List(selection: $selection) {
            if let report {
                summary(report)
                if let note { Section { ResultNoteRow(note: note) } }
                modelSection(.coreAI, report)
                modelSection(.mlx, report)
                caches(report)
                partials(report)
                Section {
                    NavigationLink {
                        ScratchFilesView()
                    } label: {
                        LabeledContent("Temporary files and caches",
                                       value: formattedBytes(report.temporaryBytes + report.cacheBytes - report.compiledBytes))
                    }
                    .accessibilityIdentifier("modelStorage.scratch")
                } footer: {
                    Text("Every file in PodSkipper's temporary and cache folders, grouped by what made it, with what is safe to remove.")
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            BottomClearance()
        }
        .navigationTitle("Models and Caches")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditModeButton(editMode: $editMode) { selection = [] }
            }
        }
        .task { coreAI.load(); await measure() }
        .refreshable { await measure() }
        .confirmation($confirm)
        .accessibilityIdentifier("modelStorage.list")
        .selectionBar(editMode.isEditing) {
            SelectionActionBar(count: selectedItems.count, actions: [
                .init(title: "Delete", symbol: "trash") { askDelete(selectedItems) },
            ])
        }
    }

    // MARK: Sections

    @ViewBuilder
    private func summary(_ report: ModelStorage.Report) -> some View {
        Section {
            LabeledContent("Downloaded models", value: formattedBytes(report.modelBytes))
            LabeledContent("Compiled model copies", value: formattedBytes(report.compiledBytes))
            LabeledContent("Temporary files", value: formattedBytes(report.temporaryBytes))
            FreeSpaceRow(free: report.freeBytes)
        } footer: {
            Text("Measured from the files just now. iPhone Storage in Settings can take a few minutes to catch up after something is removed.")
        }
    }

    @ViewBuilder
    private func modelSection(_ engine: ModelStorage.Item.Engine, _ report: ModelStorage.Report) -> some View {
        let items = report.models(engine)
        Section {
            if items.isEmpty {
                Text("No \(engine.rawValue) models are on this iPhone.").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                modelRow(item)
                    .tag(item.id)
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) { askDelete([item]) }
                    }
                    .contextMenu {
                        if item.engine == .coreAI, item.status == .installed {
                            if compiled[item.id] != nil {
                                Button("Remove Compiled Copy", systemImage: "arrow.uturn.backward") { askRemoveCompiled(item) }
                            } else {
                                Button("Install Compiled Copy…", systemImage: "square.and.arrow.down") { pickCompiled(for: item) }
                            }
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { askDelete([item]) }
                    }
            }
        } header: {
            Text(engine == .coreAI ? "Core AI Models" : "MLX Models")
        } footer: {
            if items.contains(where: { $0.status == .notInList || $0.status == .otherVersion }) {
                Text("Models not in this version's list, and other versions of listed models, are kept until you delete them. PodSkipper can't load them as they are.")
            }
        }
    }

    private func modelRow(_ item: ModelStorage.Item) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name(item)).lineLimit(2)
                Text(detail(item)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 8)
            Text(formattedBytes(item.bytes)).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("modelStorage.row")
    }

    @ViewBuilder
    private func caches(_ report: ModelStorage.Report) -> some View {
        Section {
            LabeledContent("Compiled model copies", value: formattedBytes(report.compiledBytes))
            if report.compiledBytes > 0 {
                Button("Clear Compiled Copies", role: .destructive) {
                    confirm = Confirmation(
                        title: "Clear compiled model copies?",
                        message: "Frees \(formattedBytes(report.compiledBytes)). Your models stay downloaded. The next time each Core AI model loads, Core AI prepares it again for this iPhone, which takes minutes and warms the phone; Qwen3 4B has closed the app while being prepared.",
                        actionTitle: "Clear \(formattedBytes(report.compiledBytes))") { await clearCompiled() }
                }
                .accessibilityIdentifier("modelStorage.clearCompiled")
            }
        } header: {
            Text("Model Caches")
        } footer: {
            Text("Core AI prepares each model for this iPhone the first time it loads and keeps the result, so later loads are quick.")
        }
    }

    @ViewBuilder
    private func partials(_ report: ModelStorage.Report) -> some View {
        if !report.partials.isEmpty {
            Section {
                ForEach(report.partials) { partial in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(partial.label)
                            Text(partial.url.lastPathComponent + (partial.modified.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(formattedBytes(partial.bytes)).foregroundStyle(.secondary)
                    }
                }
                Button("Remove Stopped Downloads", role: .destructive) {
                    confirm = Confirmation(
                        title: "Remove stopped downloads?",
                        message: "Frees \(formattedBytes(report.partialBytes)). These are files from model downloads that stopped part way; no downloaded model is touched. A download started again begins from the start.",
                        actionTitle: "Remove \(formattedBytes(report.partialBytes))") {
                        let result = await Task.detached { ModelStorage.removeModelFiles(report.partials.map(\.url)) }.value
                        await finish(result, count: report.partials.count, noun: "stopped download")
                    }
                }
            } header: {
                Text("Incomplete Downloads")
            } footer: {
                Text("Model downloads that are running are never listed here. To continue a download, use Download on the model in Ad Skipping → On-Device AI.")
            }
        }
    }

    // MARK: Words

    private func name(_ item: ModelStorage.Item) -> String {
        switch item.engine {
        case .mlx:
            if let id = item.catalogID { return LocalModelSpec.named(id).name }
        case .coreAI:
            if let id = item.catalogID, let entry = coreAI.entry(id: id) { return entry.name }
        }
        return item.relativePath.split(separator: "/").prefix(2).joined(separator: "/")
    }

    private func detail(_ item: ModelStorage.Item) -> String {
        var parts: [String] = []
        switch item.status {
        case .installed:
            parts.append(isChosen(item) ? "Chosen" : "Downloaded")
        case .incomplete: parts.append("Download not finished")
        case .otherVersion: parts.append("Another version (this version loads a different copy)")
        case .notInList: parts.append("Not in this version's list")
        }
        if item.engine == .coreAI, item.status == .installed {
            parts.append(compiled[item.id] != nil ? "compiled for this iPhone"
                         : "compiled on this iPhone when first used")
        }
        if item.engine == .coreAI {
            let components = item.relativePath.split(separator: "/").map(String.init)
            if components.count > 3 { parts.append(components.dropFirst(3).joined(separator: "/")) }
            if let revision = item.revision { parts.append("revision " + String(revision.prefix(7))) }
        } else if item.catalogID == nil {
            parts.append(item.relativePath)
        }
        if let date = item.modified { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }

    private func isChosen(_ item: ModelStorage.Item) -> Bool {
        switch item.engine {
        case .mlx: item.catalogID == store.selected.id
        case .coreAI: item.catalogID == coreAI.selectedID
        }
    }

    private var selectedItems: [ModelStorage.Item] {
        (report?.models ?? []).filter { selection.contains($0.id) }
    }

    // MARK: Work

    private func askDelete(_ items: [ModelStorage.Item]) {
        guard !items.isEmpty else { return }
        let total = items.reduce(Int64(0)) { $0 + $1.bytes }
        let names = items.prefix(4).map { name($0) }.joined(separator: ", ") + (items.count > 4 ? " and \(items.count - 4) more" : "")
        let chosen = items.filter { $0.status == .installed && isChosen($0) }
        var message = "Deletes \(names), freeing \(formattedBytes(total)). Your episodes, transcripts, corrections and earlier test results are kept."
        if !chosen.isEmpty {
            message += " \(chosen.map { name($0) }.joined(separator: ", ")) is chosen; another downloaded model is chosen in its place, or its tests are unavailable until you download one."
        }
        confirm = Confirmation(title: items.count == 1 ? "Delete \(names)?" : "Delete \(items.count) models?",
                               message: message, actionTitle: "Delete \(formattedBytes(total))") {
            await delete(items)
        }
    }

    private func delete(_ items: [ModelStorage.Item]) async {
        let before = report?.modelBytes ?? 0
        var failures: [String] = []
        var loose: [URL] = []
        for item in items {
            // A listed, complete model goes through its owner, so the chosen
            // model, the in-use check and the download state stay right.
            if item.status == .installed, let id = item.catalogID {
                switch item.engine {
                case .mlx:
                    let spec = LocalModelSpec.named(id)
                    if store.deleteWaits(spec) { failures.append("\(spec.name) is in use; delete it when the job or test finishes") }
                    else { store.delete(spec) }
                case .coreAI:
                    guard let entry = coreAI.entry(id: id) else { loose.append(item.url); continue }
                    if coreAI.deleteWaits(entry) { failures.append("\(entry.name) is in use; delete it when the job or test finishes") }
                    else { coreAI.delete(entry) }
                }
            } else {
                loose.append(item.url)
            }
        }
        if !loose.isEmpty {
            let result = await Task.detached(priority: .userInitiated) { ModelStorage.removeModelFiles(loose) }.value
            failures += result.failures
        }
        // The owners delete on their own tasks; wait for them before measuring.
        for _ in 0..<40 where !store.removingIDs.isEmpty || !coreAI.removingIDs.isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
        }
        selection = []
        editMode = .inactive
        await measure()
        let freed = max(0, before - (report?.modelBytes ?? 0))
        note = .freed(freed, removed: items.count - failures.count, noun: "model", failures: failures)
        BackgroundLog.shared.note("Models and Caches: " + (note?.text ?? ""))
        store.refreshState()
    }

    private func clearCompiled() async {
        let before = report?.compiledBytes ?? 0
        let failure: String? = await Task.detached(priority: .userInitiated) {
            do { try ModelStorage.clearCompiledCache(); return nil } catch { return error.localizedDescription }
        }.value
        await measure()
        let freed = max(0, before - (report?.compiledBytes ?? 0))
        note = failure.map { ResultNote(text: "Couldn't clear the compiled copies: " + $0, failed: true) }
            ?? ResultNote(text: "Cleared compiled model copies, freeing \(formattedBytes(freed)).")
        BackgroundLog.shared.note("Models and Caches: " + (note?.text ?? ""))
    }

    private func finish(_ result: (freed: Int64, failures: [String]), count: Int, noun: String) async {
        await measure()
        note = .freed(result.freed, removed: count - result.failures.count, noun: noun, failures: result.failures)
        BackgroundLog.shared.note("Models and Caches: " + (note?.text ?? ""))
    }

    private func measure() async {
        guard !measuring else { return }
        measuring = true
        defer { measuring = false }
        let known = ModelStorage.Known.current()
        let measured = await Task.detached(priority: .userInitiated) { ModelStorage.measure(known) }.value
        report = measured
        compiled = Dictionary(uniqueKeysWithValues: measured.models(.coreAI).compactMap { item in
            CoreAICompiledCopy.installed(in: item.url).map { (item.id, $0) }
        })
    }

    // MARK: Compiled copies (CoreAICompiledCopy)

    private func pickCompiled(for item: ModelStorage.Item) {
        DocumentPicker.present(types: [.folder], asCopy: false) { urls in
            guard let source = urls.first else { return }
            Task { await installCompiled(from: source, into: item) }
        }
    }

    private func installCompiled(from source: URL, into item: ModelStorage.Item) async {
        guard !installing else { return }
        installing = true
        defer { installing = false }
        note = ResultNote(text: "Installing the compiled copy of \(name(item))…")
        let machine = Diagnostics.deviceModel
        let failure: String? = await Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do { try CoreAICompiledCopy.install(from: source, into: item.url, machine: machine); return nil }
            catch { return error.localizedDescription }
        }.value
        await measure()
        note = failure.map { ResultNote(text: $0, failed: true) }
            ?? ResultNote(text: "\(name(item)) now loads the copy compiled for this iPhone. Its next test or job shows “compiled for this iPhone” in Diagnostics.")
        BackgroundLog.shared.note("Models and Caches: " + (note?.text ?? ""))
    }

    private func askRemoveCompiled(_ item: ModelStorage.Item) {
        confirm = Confirmation(
            title: "Remove the compiled copy?",
            message: "\(name(item)) goes back to the download as it was, which Core AI compiles on this iPhone when first used. The download itself stays.",
            actionTitle: "Remove Compiled Copy") {
            let failure: String? = await Task.detached {
                do { try CoreAICompiledCopy.remove(from: item.url); return nil } catch { return error.localizedDescription }
            }.value
            await measure()
            note = failure.map { ResultNote(text: "Couldn't remove it: " + $0, failed: true) }
                ?? ResultNote(text: "Removed the compiled copy of \(name(item)).")
        }
    }
}

extension ModelStorage.Known {
    /// What the app knows right now, read on the main actor.
    @MainActor static func current() -> ModelStorage.Known {
        let store = ModelStore.shared
        let coreAI = CoreAIModelLibrary.shared
        var downloading = coreAI.downloadingID != nil
        if case .downloading = store.phase { downloading = true }
        return ModelStorage.Known(mlxIDs: Set(LocalModelSpec.all.map(\.id)), mlxReady: store.readyIDs,
                                  coreAIPaths: coreAI.storagePathsByID, coreAIRepos: coreAI.repositoriesByID,
                                  downloadActive: downloading,
                                  workActive: HeavyWorkCoordinator.shared.isBusy || BackupService.isWorking)
    }
}

/// Everything in PodSkipper's temporary and cache folders, grouped by what
/// made it. Pass 35: his phone showed 28.88 GB of "Temporary files" as one
/// number and nothing else.
struct ScratchFilesView: View {
    @State private var report: ModelStorage.Report?
    @State private var confirm: Confirmation?
    @State private var note: ResultNote?
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive

    var body: some View {
        List(selection: $selection) {
            if let report {
                Section {
                    LabeledContent("Temporary folder", value: formattedBytes(report.temporaryBytes))
                    LabeledContent("Cache folder", value: formattedBytes(report.cacheBytes))
                    FreeSpaceRow(free: report.freeBytes)
                } footer: {
                    Text("Files written in the last 15 minutes, or used by work under way, are marked in use and are never removed.")
                }
                if let note { Section { ResultNoteRow(note: note) } }
                ForEach(ModelStorage.ScratchEntry.Kind.allCases, id: \.self) { kind in
                    let entries = report.scratch.filter { $0.kind == kind }
                    if !entries.isEmpty {
                        Section {
                            ForEach(entries) { entry in
                                row(entry)
                                    .tag(entry.id)
                                    .selectionDisabled(entry.inUse)
                                    .swipeActions(edge: .trailing) {
                                        if !entry.inUse { Button("Remove", role: .destructive) { ask([entry]) } }
                                    }
                                    .contextMenu {
                                        if !entry.inUse { Button("Remove", systemImage: "trash", role: .destructive) { ask([entry]) } }
                                    }
                            }
                        } header: {
                            Text("\(kind.label) · \(formattedBytes(entries.reduce(0) { $0 + $1.bytes }))")
                        } footer: {
                            Text(kind.explanation)
                        }
                    }
                }
                if report.scratch.isEmpty {
                    Text("The temporary and cache folders are empty.").foregroundStyle(.secondary)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            BottomClearance()
        }
        .navigationTitle("Temporary Files")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditModeButton(editMode: $editMode) { selection = [] } }
        }
        .task { await measure() }
        .refreshable { await measure() }
        .confirmation($confirm)
        .selectionBar(editMode.isEditing) {
            SelectionActionBar(count: selected.count, actions: [
                .init(title: "Remove", symbol: "trash") { ask(selected) },
            ])
        }
    }

    private var selected: [ModelStorage.ScratchEntry] {
        (report?.scratch ?? []).filter { selection.contains($0.id) && !$0.inUse }
    }

    private func row(_ entry: ModelStorage.ScratchEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).lineLimit(2).font(.subheadline.monospaced())
                Text([entry.area, "\(entry.fileCount) file\(entry.fileCount == 1 ? "" : "s")",
                      entry.modified.map { "changed " + $0.formatted(.relative(presentation: .named)) },
                      entry.inUse ? "in use" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(entry.inUse ? .orange : .secondary)
            }
            Spacer(minLength: 8)
            Text(formattedBytes(entry.bytes)).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func ask(_ entries: [ModelStorage.ScratchEntry]) {
        guard !entries.isEmpty else { return }
        let total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        let risky = entries.filter { !$0.kind.safeByKind }
        var message = "Removes \(entries.count == 1 ? entries[0].name : "\(entries.count) items"), freeing \(formattedBytes(total)). Nothing outside PodSkipper's temporary and cache folders is touched."
        if risky.contains(where: { $0.kind == .compiledModels }) {
            message += " Compiled model copies are made again the next time each Core AI model loads, which takes minutes."
        }
        if risky.contains(where: { $0.kind == .unknown }) {
            message += " What made the unidentified items is unknown; iOS itself may remove them at any time, but whatever wrote them may need to again."
        }
        confirm = Confirmation(title: entries.count == 1 ? "Remove \(entries[0].name)?" : "Remove \(entries.count) items?",
                               message: message, actionTitle: "Remove \(formattedBytes(total))") {
            let result = await Task.detached(priority: .userInitiated) { ModelStorage.removeScratch(entries) }.value
            selection = []
            editMode = .inactive
            await measure()
            note = .freed(result.freed, removed: entries.count - result.failures.count, noun: "item", failures: result.failures)
            BackgroundLog.shared.note("Temporary files: " + (note?.text ?? ""))
        }
    }

    private func measure() async {
        let known = ModelStorage.Known.current()
        report = await Task.detached(priority: .userInitiated) { ModelStorage.measure(known) }.value
    }
}
