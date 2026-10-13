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
    /// Pass 36: whether Core AI holds each installed model prepared for this
    /// iPhone (read from Core AI's cache; nil = can't be told).
    @State private var prepared: [String: Bool] = [:]
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name(item)).lineLimit(2)
                    Text(detail(item)).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
                Spacer(minLength: 8)
                Text(formattedBytes(item.bytes)).foregroundStyle(.secondary).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            // Pass 36 (his 12 Oct note: he couldn't find where to install the
            // copy compiled on the Mac — it was only in a long-press menu).
            if item.engine == .coreAI, item.status == .installed, !editMode.isEditing {
                compiledControl(item)
            }
        }
        .accessibilityIdentifier("modelStorage.row")
    }

    @ViewBuilder
    private func compiledControl(_ item: ModelStorage.Item) -> some View {
        if compiled[item.id] != nil {
            Button("Remove Compiled Copy", systemImage: "arrow.uturn.backward") { askRemoveCompiled(item) }
                .font(.subheadline).buttonStyle(.borderless)
                .disabled(installing)
                .accessibilityIdentifier("modelStorage.removeCompiled")
        } else if prepared[item.id] != true {
            VStack(alignment: .leading, spacing: 4) {
                Button("Install a Copy Compiled on a Mac…", systemImage: "square.and.arrow.down") { pickCompiled(for: item) }
                    .font(.subheadline).buttonStyle(.borderless)
                    .disabled(installing)
                    .accessibilityIdentifier("modelStorage.installCompiled")
                Text("Optional. Without it, Core AI prepares this model on the iPhone the first time it is used. A copy compiled on a Mac for this iPhone's chip skips that; choose its .aimodelc folder in Files. PodSkipper checks it was made from this exact download and chip, and the download is kept so the copy can be removed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func caches(_ report: ModelStorage.Report) -> some View {
        Section {
            LabeledContent("Compiled model copies", value: formattedBytes(report.compiledBytes))
        } header: {
            Text("Model Caches")
        } footer: {
            Text("Core AI prepares each model for this iPhone the first time it loads and keeps the result, so later loads are quick. A model's prepared copy is removed when you delete that model; PodSkipper doesn't clear them all at once, because which file belongs to which model can't be told from the files.")
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
            if compiled[item.id] != nil {
                let match = CoreAICompiledCopy.matchesDownload(in: item.url)
                parts.append("loads a copy compiled for this iPhone" + (match == true ? " (made from this download)" : match == false ? " (made from another version)" : ""))
            }
            switch prepared[item.id] {
            case true?: parts.append("prepared for this iPhone")
            case false?: parts.append("not prepared yet: its first use prepares it once (minutes for large models; keep PodSkipper open)")
            case nil: break
            }
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
        var message = "Deletes \(names), freeing about \(formattedBytes(total))."
        if items.contains(where: { $0.engine == .coreAI }) {
            message += " For a Core AI model, only this copy goes, with any compiled copy installed in it, Core AI's prepared copy of it for this iPhone, and its own stopped download. Other versions or builds of the same model stay, each with its own Delete."
        }
        message += " Your episodes, transcripts, corrections, other models and earlier test results are kept."
        if !chosen.isEmpty {
            message += " \(chosen.map { name($0) }.joined(separator: ", ")) is chosen; another downloaded model is chosen in its place, or its tests are unavailable until you download one."
        }
        confirm = Confirmation(title: items.count == 1 ? "Delete \(names)?" : "Delete \(items.count) models?",
                               message: message, actionTitle: "Delete \(formattedBytes(total))") {
            await delete(items)
        }
    }

    /// Pass 36 (his request): waits for each deletion to really finish (it
    /// used to give up after ten seconds and measure whatever was there),
    /// then says what was deleted, what was kept and why, and the space
    /// actually recovered.
    private func delete(_ items: [ModelStorage.Item]) async {
        let before = report?.modelBytes ?? 0
        var failures: [String] = []
        var deleted: [String] = []
        var retained: [String] = []
        var loose: [ModelStorage.Item] = []
        for item in items {
            // A listed, complete model goes through its owner, so the chosen
            // model, the in-use check and the download state stay right.
            if item.status == .installed, let id = item.catalogID {
                switch item.engine {
                case .mlx:
                    let spec = LocalModelSpec.named(id)
                    if store.deleteWaits(spec) { failures.append("\(spec.name) is in use; delete it when the job or test finishes"); continue }
                    guard let task = store.delete(spec) else { failures.append(store.managementError ?? "\(spec.name) couldn't be deleted now"); continue }
                    if let failure = await task.value { failures.append(failure) } else { deleted.append(spec.name) }
                case .coreAI:
                    guard let entry = coreAI.entry(id: id) else { loose.append(item); continue }
                    if coreAI.deleteWaits(entry) { failures.append("\(entry.name) is in use; delete it when the job or test finishes"); continue }
                    guard let task = coreAI.delete(entry) else { failures.append(coreAI.error ?? "\(entry.name) couldn't be deleted now"); continue }
                    let result = await task.value
                    deleted += result.deleted; retained += result.retained; failures += result.failures
                }
            } else {
                loose.append(item)
            }
        }
        if !loose.isEmpty {
            let urls = loose.map(\.url)
            let names = loose.map { name($0) }
            let result = await Task.detached(priority: .userInitiated) { () -> (freed: Int64, failures: [String]) in
                var items: [CleanupLog.Item] = []
                var freed: Int64 = 0, failures: [String] = []
                for (url, name) in zip(urls, names) {
                    let bytes = ModelStorage.size(of: url)
                    // Core AI's prepared copy of a loose bundle goes with it.
                    let prepared = CoreAIPreparation.removePrepared(bundle: url)
                    let removed = ModelStorage.removeModelFiles([url])
                    failures += prepared + removed.failures
                    if removed.failures.isEmpty { freed += bytes }
                    items.append(CleanupLog.Item(name: name, area: "Models", kind: "model files", evidence: "Chosen in Models and Caches",
                                                 bytes: bytes, result: removed.failures.first.map { "failed: " + $0 } ?? "removed"))
                }
                CleanupLog.record(CleanupLog.Operation(date: .now, context: "Models and Caches", items: items))
                return (freed, failures)
            }.value
            failures += result.failures
            deleted += loose.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.map { name($0) }
        }
        selection = []
        editMode = .inactive
        await measure()
        let freed = max(0, before - (report?.modelBytes ?? 0))
        var text = deleted.isEmpty ? "Nothing was deleted." : "Deleted " + deleted.joined(separator: ", ") + ", freeing \(formattedBytes(freed))."
        if !retained.isEmpty { text += "\nKept: " + retained.joined(separator: "\n") }
        if !failures.isEmpty { text += "\nNot done: " + failures.joined(separator: "; ") }
        note = ResultNote(text: text, failed: !failures.isEmpty)
        BackgroundLog.shared.note("Models and Caches: " + text.replacingOccurrences(of: "\n", with: " "))
        store.refreshState()
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
        var readiness: [String: Bool] = [:]
        for item in measured.models(.coreAI) where item.status == .installed {
            readiness[item.id] = await CoreAIPreparation.shared.refresh(bundle: item.url)
        }
        prepared = readiness
    }

    // MARK: Compiled copies (CoreAICompiledCopy)

    private func pickCompiled(for item: ModelStorage.Item) {
        DocumentPicker.present(types: [.folder], asCopy: false) { urls in
            guard let source = urls.first else { return }
            Task { await installCompiled(from: source, into: item) }
        }
    }

    /// Never while the model is loaded, being prepared, or deleted.
    private func busy(_ item: ModelStorage.Item) -> Bool {
        guard let id = item.catalogID else { return false }
        return coreAI.inUse.contains(id) || coreAI.removingIDs.contains(id) || CoreAIPreparation.shared.current?.modelID == id
    }

    private func installCompiled(from source: URL, into item: ModelStorage.Item) async {
        guard !installing else { return }
        if busy(item) {
            note = ResultNote(text: CoreAICompiledCopy.Failure.inUse(name(item)).localizedDescription, failed: true)
            return
        }
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
            ?? ResultNote(text: "\(name(item)) now loads the copy compiled for this iPhone. Whether iOS accepts it is only known when the model next loads: run one Basic test. If it fails to load, Remove Compiled Copy goes back to the download.")
        BackgroundLog.shared.note("Models and Caches: " + (note?.text ?? ""))
    }

    private func askRemoveCompiled(_ item: ModelStorage.Item) {
        confirm = Confirmation(
            title: "Remove the compiled copy?",
            message: "\(name(item)) goes back to the download as it was, which Core AI compiles on this iPhone when first used. The download itself stays.",
            actionTitle: "Remove Compiled Copy") {
            if busy(item) {
                note = ResultNote(text: CoreAICompiledCopy.Failure.inUse(name(item)).localizedDescription, failed: true)
                return
            }
            let failure: String? = await Task.detached {
                // Core AI's prepared copy of the compiled graph goes with it;
                // the download's own prepared copy stays.
                if let graph = CoreAICompiledCopy.installed(in: item.url) {
                    _ = CoreAIPreparation.removePrepared(assets: [item.url.appending(path: graph)])
                }
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
                            Text(kind.explanation + "\n" + kind.need + ". If removed: " + kind.ifRemoved
                                 + (kind.safeByKind ? "" : " Not included in Tidy Up."))
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
                if !entry.evidence.isEmpty {
                    Text("Identified by: " + entry.evidence).font(.caption).foregroundStyle(.secondary)
                }
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
        for kind in Set(risky.map(\.kind)).sorted(by: { $0.rawValue < $1.rawValue }) {
            message += " \(kind.label): \(kind.ifRemoved)"
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
