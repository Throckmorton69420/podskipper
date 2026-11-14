import SwiftUI

enum ModelLibraryMode { case mlx, coreAI, cpu }

struct LocalModelView: View {
    let mode: ModelLibraryMode
    init(mode: ModelLibraryMode = .mlx) { self.mode = mode }
    @State private var store = ModelStore.shared
    @State private var coreAI = CoreAIModelLibrary.shared
    @State private var riskyTest: Confirmation?

    var body: some View {
        List {
            Text(mode == .coreAI ? AdFinderChoice.coreAI.explanation
                 : mode == .cpu ? AdFinderChoice.cpu.explanation : AdFinderChoice.model.explanation)
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .contentRow()
            // Pass 63: the CPU library has each model's Basic and Hard, its
            // latest results and its earlier runs in the row, as Compare has.
            // Pass 64: models on an external drive, read there or imported.
            NavigationLink { ExternalModelLibraryView() } label: {
                Label("External Drive", systemImage: "externaldrive")
            }.contentRow().accessibilityIdentifier("model.externalDrive")
            ModelCatalogContent(mode: mode, showsTests: mode == .cpu, riskyTest: $riskyTest)
            NavigationLink { ModelComparisonView() } label: {
                Label("Compare models", systemImage: "chart.bar.xaxis")
            }.contentRow().accessibilityIdentifier("model.compare")
            if mode != .cpu {
                SectionHeader("Downloads")
                ModelCellularControl().contentRow()
            }
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle(mode == .coreAI ? "Core AI models" : mode == .cpu ? "CPU models" : "MLX models")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .task { coreAI.load(); store.refreshState() }
        .confirmation($riskyTest)
    }
}

/// The very same model rows appear in the libraries and comparison disclosures.
struct ModelCatalogContent: View {
    let mode: ModelLibraryMode
    /// Pass 32: in Compare models, each usable model has its own Basic and
    /// Hard buttons, latest results and earlier runs.
    var showsTests = false
    @State private var store = ModelStore.shared
    @State private var coreAI = CoreAIModelLibrary.shared
    @State private var bench = ModelBench.shared
    @State private var search = ""
    /// Pass 63: CPU models, in the same rows as the other two kinds.
    @State private var cpuCopy = CPUModelCopy.shared
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(CPUReading.selectionKey) private var cpuChosenID = CPUReading.qwen35_4B_q4.id
    /// Pass 35: owned by the screen's List, which is always on screen; a
    /// row-level alert exists only while its row is (List rows are lazy).
    @Binding var riskyTest: Confirmation?

    var body: some View {
        Text(mode == .coreAI
             ? "Core AI uses compiled Apple-runtime files. MLX versions of the same models use separate weights and need their own download."
             : mode == .cpu
             ? "A CPU model is its own download (one GGUF file), separate from the MLX and Core AI copies of the same model. The one you select reads for the other finders when the iPhone is locked, and everywhere when CPU models are chosen in Find Ads With."
             : "MLX uses GPU weights. A Core AI download of the same model cannot be used by this runtime.")
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).contentRow()
        TextField("Search models", text: $search)
            .font(.body).accessibilityIdentifier("model.\(prefix).search").contentRow()
        if mode == .coreAI {
            // Pass 30: say plainly what a Core AI model reads.
            Text("A Core AI model reads the stretches PodSkipper's reader and the audio flagged (with a minute and a half either side, and the first and last three minutes), not every line: reading whole episodes, these models called ordinary talk an ad. Every cut a model makes is checked against the episode's own words before it is kept.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentRow()
                .accessibilityIdentifier("model.coreAI.howItReads")
                .task(id: coreAI.entries.count) { await coreAI.refreshPrepared() }
            if coreAI.loading { ProgressView("Loading models…").contentRow() }
            // Pass 64: models this iPhone can't run, or that are too big for
            // it, or that need a Mac-compiled copy, fold away under the rest.
            let all = coreAI.entries(matching: search)
            let folded = all.filter { coreAIFolded($0) }
            ForEach(all.filter { !coreAIFolded($0) }) { entry in coreAIRow(entry) }
            if !folded.isEmpty {
                FoldRow(title: "Unsupported or Heavy on This iPhone (\(folded.count))", key: "catalog.heavy.coreAI",
                        identifier: "model.coreAI.heavy")
                if BenchDisclosure.shared.isOpen("catalog.heavy.coreAI") {
                    ForEach(folded) { entry in coreAIRow(entry) }
                }
            }
            if let error = coreAI.error { downloadMessage(error) }
            // Pass 63: the models he asked for that nobody has published.
            downloadMessage(CoreAIExtraModels.notPublishedNote)
        } else if mode == .cpu {
            cpuRows
        } else {
            mlxRows
        }
    }

    /// Pass 64: a Core AI model folded away — it can't run here, it's too
    /// big for this iPhone, or it closed PodSkipper unless compiled on a Mac
    /// (and isn't downloaded with such a copy yet).
    private func coreAIFolded(_ entry: CoreAIModelDescriptor) -> Bool {
        if !entry.isCompatible { return true }
        if coreAI.isDownloaded(entry) || coreAI.selectedID == entry.id { return false }
        if CoreAILoadGate.needsCompiledCopy.contains(entry.id) { return true }
        return ModelFit.isHeavy(bytes: Int64(entry.sizeMB ?? 0) * 1_000_000)
    }

    @ViewBuilder
    private func coreAIRow(_ entry: CoreAIModelDescriptor) -> some View {
                row(id: entry.id, benchmarkID: CoreAIQwen3.benchmarkID(for: entry.id), name: entry.name,
                    description: CoreAIModelLibrary.displaySize(entry),
                    downloaded: coreAI.isDownloaded(entry), compatible: entry.isCompatible,
                    selected: coreAI.selectedID == entry.id, downloading: coreAI.downloadingID == entry.id, removing: coreAI.removingIDs.contains(entry.id),
                    inUse: coreAI.deleteWaits(entry), unsupported: entry.unsupportedReason,
                    note: [CoreAILoadGate.needsCompiledCopy.contains(entry.id)
                           ? "Preparing it on this iPhone closed PodSkipper: it runs from a copy compiled on your Mac, imported under External Drive." : nil,
                           CoreAIStability.summary(for: entry.id), preparedNote(entry), entry.portableNote, entry.memoryNote, entry.isCompatible ? entry.readsAtATime : nil]
                        .compactMap { $0 }.joined(separator: " ").nilIfEmpty,
                    select: { coreAI.select(entry) }, download: { coreAI.download(entry) },
                    test: { sample in
                        // Pass 33: a model that has closed the app asks first.
                        if CoreAIStability.record(for: entry.id) != nil { riskyTest = CoreAIStability.confirmation(entry: entry, sample: sample); return }
                        ModelBench.shared.clearRequestError(); ModelBench.shared.testCoreAI(entry, sample: sample)
                    })
    }

    @ViewBuilder
    private var cpuRows: some View {
            if !CPUReading.engineIncluded && !CPUReading.isDemo {
                downloadMessage("CPU models run on iPhone only: this build can list them but not download or run them.")
            }
            ForEach(CPUReading.catalog.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { model in
                let state = cpuCopy.state(of: model)
                row(id: model.id, benchmarkID: model.engineID, name: model.name,
                    description: ModelStore.gigabytes(model.bytes),
                    downloaded: state == .ready, compatible: CPUReading.engineIncluded || CPUReading.isDemo,
                    selected: cpuChosenID == model.id, downloading: cpuCopy.downloadingID == model.id || state == .checking,
                    removing: false, inUse: bench.running == model.engineID, unsupported: "Runs on iPhone only",
                    note: [model.summary, state == .ready ? Self.howAsked(model) : nil,
                           Self.failure(state)].compactMap { $0 }.joined(separator: " "),
                    select: { cpuChosenID = model.id; return true }, download: { cpuCopy.download(model) },
                    test: { sample in ModelBench.shared.clearRequestError(); ModelBench.shared.testCPU(model, sample: sample) })
            }
    }

    /// Pass 64: an MLX model too big for this iPhone, not downloaded.
    private func mlxFolded(_ spec: LocalModelSpec) -> Bool {
        !store.isDownloaded(spec) && store.selected != spec && ModelFit.isHeavy(bytes: spec.memoryNeeded)
    }

    @ViewBuilder
    private var mlxRows: some View {
            let all = LocalModelSpec.all.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            let folded = all.filter(mlxFolded)
            ForEach(all.filter { !mlxFolded($0) }) { spec in mlxRow(spec) }
            if !folded.isEmpty {
                FoldRow(title: "Heavy on This iPhone (\(folded.count))", key: "catalog.heavy.mlx", identifier: "model.mlx.heavy")
                if BenchDisclosure.shared.isOpen("catalog.heavy.mlx") {
                    ForEach(folded) { spec in mlxRow(spec) }
                }
            }
            if case .failed(let message) = store.phase { downloadMessage(message) }
            if case .paused(let message) = store.phase { downloadMessage(message) }
            if let note = store.memoryNote { downloadMessage(note) }
            if let error = store.managementError { downloadMessage(error) }
    }

    @ViewBuilder
    private func mlxRow(_ spec: LocalModelSpec) -> some View {
                row(id: spec.id, benchmarkID: spec.id, name: spec.name,
                    description: ModelStore.bytes(spec.downloadBytes),
                    downloaded: store.isDownloaded(spec), compatible: true,
                    selected: store.selected == spec,
                    downloading: store.downloadTarget == spec && isMLXDownloading, removing: store.removingIDs.contains(spec.id),
                    inUse: store.deleteWaits(spec), unsupported: nil,
                    // Pass 31: how this model is asked, once it's on the phone.
                    note: [store.isOnlyExternal(spec) ? "Reads from your external drive." : nil,
                           store.isDownloaded(spec) ? ModelPromptPlan.cached(for: spec).summary : nil]
                        .compactMap { $0 }.joined(separator: " ").nilIfEmpty,
                    select: { store.select(spec) }, download: { store.download(spec) },
                    test: { sample in ModelBench.shared.clearRequestError(); ModelBench.shared.testModel(spec, sample: sample) })
    }

    private var prefix: String { mode == .coreAI ? "coreAI" : mode == .cpu ? "cpu" : "mlx" }

    /// How a CPU model is asked, with the stretch the processor is shown at a time.
    private static func howAsked(_ model: CPUModel) -> String {
        let plan = ModelPromptPlan.plan(for: model.twin, folder: nil)
        return plan.summary(stretch: CPUJudge.windowTokens(plan))
    }

    private static func failure(_ state: CPUModelCopy.State) -> String? {
        if case .failed(let message) = state { return "The download failed: " + message }
        return nil
    }

    /// Pass 36: whether the first use still has to prepare it.
    private func preparedNote(_ entry: CoreAIModelDescriptor) -> String? {
        guard entry.isCompatible, coreAI.isDownloaded(entry) else { return nil }
        switch coreAI.prepared(entry) {
        case true?: return "Prepared for this iPhone."
        case false?:
            let last = CoreAIPreparation.shared.lastDuration(entry.id).map { " It took " + CoreAIPreparation.clock($0) + " last time." } ?? ""
            return "Not prepared for this iPhone yet: its first test or Find Ads prepares it once (minutes for large models; keep PodSkipper open until it finishes)." + last
        case nil: return nil
        }
    }

    private static var deviceOnly: String? {
        #if targetEnvironment(simulator)
        if CPUReading.isDemo { return nil }
        return "Model tests run on iPhone only."
        #else
        return nil
        #endif
    }
    private var isMLXDownloading: Bool {
        switch store.phase { case .listing, .downloading: return true; default: return false }
    }

    private func downloadMessage(_ message: String) -> some View {
        Text(message).font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).contentRow()
    }

    @ViewBuilder
    private func row(id: String, benchmarkID: String, name: String, description: String,
                     downloaded: Bool, compatible: Bool, selected: Bool, downloading: Bool, removing: Bool,
                     inUse: Bool, unsupported: String?, note: String?,
                     select: @escaping () -> Bool, download: @escaping () -> Void,
                     test: @escaping (BenchSample) -> Void) -> some View {
        let enabled = bench.isEnabled(benchmarkID)
        let usable = downloaded && compatible && enabled
        let selectionSymbol = selected && usable ? "checkmark.circle.fill" : "circle"
        let selectionColor: Color = selected && usable ? Theme.accentHot : .secondary
        let availability: String = !compatible
            ? (unsupported ?? "Unavailable on iOS") + (downloaded ? " · downloaded" : "")
            : downloading ? "Downloading"
            : !downloaded ? "Not downloaded"
            : enabled ? "Ready" : "Turned off"
        let actionTitle = removing ? "Removing…" : downloading ? "Stop" : downloaded ? "Delete" : "Download"
        let actionSymbol = downloading ? "stop.fill" : downloaded ? "trash" : "arrow.down"
        let actionLabel = downloading ? "Stop downloading " + name : downloaded ? "Delete " + name : "Download " + name
        let detail = description + " · " + availability
        // Pass 30: a downloaded model can always be deleted unless it is the
        // one in use (it used to grey out for every model while anything ran,
        // and for a model this iPhone can't run, which left its gigabytes
        // stuck on the phone).
        let actionDisabled = removing || (downloaded && inUse)
            || (!downloaded && !compatible)
            || (!downloaded && !downloading && anotherDownload(id))
        VStack(alignment: .leading, spacing: 10) {
            Button { if select() { Feel.selection.play() } } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: selectionSymbol)
                        .foregroundStyle(selectionColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.body.weight(.semibold))
                        Text(detail)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }.fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
            }
            .buttonStyle(.plain).disabled(!usable || bench.isRunning)
            .accessibilityIdentifier("model.\(prefix).select." + id)
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button {
                    if downloading {
                        switch mode {
                        case .coreAI: coreAI.stopDownload()
                        case .cpu: cpuCopy.stop()
                        case .mlx: store.pause()
                        }
                    }
                    else if downloaded {
                        riskyTest = Confirmation(title: "Delete " + name + "?",
                                                 message: "Its downloaded files are removed, including any compiled copy. Test history and results are kept.",
                                                 actionTitle: "Delete Download") {
                            if mode == .coreAI, let entry = coreAI.entry(for: id) { coreAI.delete(entry) }
                            else if mode == .cpu, let model = CPUReading.model(id: id) { cpuCopy.delete(model) }
                            else if let spec = LocalModelSpec.all.first(where: { $0.id == id }) { store.delete(spec) }
                        }
                    }
                    else { download() }
                } label: {
                    SharedActionLabel(actionTitle, symbol: actionSymbol)
                        .foregroundStyle(actionDisabled ? Color.secondary : (downloaded ? Color.red : Theme.accentHot))
                        // Pass 65: as wide as its words at accessibility sizes
                        // (118 points broke "Delete" into letters).
                        .padding(.horizontal, typeSize.isAccessibilitySize ? 16 : 0)
                        .frame(width: typeSize.isAccessibilitySize ? nil : 118)
                        .frame(minHeight: 44)
                        .contentShape(Capsule())
                        .glassEffect(.regular, in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(actionDisabled)
                .accessibilityLabel(actionLabel)
                .accessibilityIdentifier("model.\(prefix).download." + id)
                Toggle("Enable " + name, isOn: Binding(
                    get: { downloaded && bench.isEnabled(benchmarkID) },
                    set: { bench.setEnabled(benchmarkID, $0) }))
                    .labelsHidden().tint(Theme.accentHot)
                    .disabled(bench.isRunning || !downloaded || !compatible)
                    .accessibilityLabel("Enable " + name)
                    .accessibilityIdentifier("model.\(prefix).enabled." + id)
            }
            if downloading {
                // Pass 64 (his 13 Nov request): every download says how much of
                // how much, and how fast.
                if mode == .coreAI {
                    ProgressView(value: coreAI.downloadFraction)
                    Text(coreAI.downloadTotalBytes > 0
                         ? TransferText.line(done: Int64(coreAI.downloadFraction * Double(coreAI.downloadTotalBytes)),
                                             total: coreAI.downloadTotalBytes, bytesPerSecond: coreAI.downloadBytesPerSecond)
                         : "Downloading \(Int(coreAI.downloadFraction * 100))% of " + description)
                        .font(.subheadline.monospacedDigit())
                        .accessibilityIdentifier("model.coreAI.transfer." + id)
                } else if mode == .cpu {
                    if let model = CPUReading.model(id: id), case .downloading(let fraction) = cpuCopy.state(of: model) {
                        ProgressView(value: fraction)
                        Text((cpuCopy.transfer.map { TransferText.line(done: $0.done, total: $0.total, bytesPerSecond: $0.bytesPerSecond) }
                              ?? "Downloading \(Int(fraction * 100))% of " + description)
                             + ". Keep PodSkipper open until it finishes; it carries on from where it stopped if you leave.")
                            .font(.subheadline.monospacedDigit())
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("model.cpu.transfer." + id)
                    } else { ProgressView("Checking the download…") }
                } else if case .downloading(let done, let total, let speed) = store.phase {
                    ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                    Text(TransferText.line(done: done, total: total, bytesPerSecond: speed))
                        .font(.subheadline.monospacedDigit())
                        .accessibilityIdentifier("model.mlx.transfer." + id)
                } else { ProgressView("Starting download…") }
            }
            if downloaded, inUse, !removing {
                Text("In use by a job or a test. Delete comes back when it finishes.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("model.\(prefix).inUse." + id)
            }
            if let note {
                Text(note).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsTests, usable {
                BenchModelTests(engineID: benchmarkID, title: name, unavailable: Self.deviceOnly,
                                identifierStem: prefix + "." + id, run: test)
            } else if showsTests {
                // Pass 63: a model that isn't downloaded (or was deleted)
                // keeps its results in view, with its runs under the row.
                ForEach(BenchSample.allCases, id: \.self) { sample in
                    if let latest = bench.result(benchmarkID, sample) {
                        BenchLatestLine(result: latest, lastScored: bench.lastScored(benchmarkID, sample))
                    }
                }
            } else if !showsTests, let summary = bench.latestSummary(benchmarkID) {
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Pass 31: how it did on his own episodes, from his fixes — the
            // number the two samples can't give.
            if let real = FinderGrades.summary(for: name) {
                Text("Your fixes on real episodes: \(CutGrade.letter(real.score)) (\(real.score) %) over \(real.episodes) episode\(real.episodes == 1 ? "" : "s")")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("model.\(prefix).realGrade." + id)
            }
        }
        .contentRow(top: 12, bottom: 12)
        // Pass 33: the runs are rows of their own under the model's row, so
        // opening them never resizes (and cross-fades) the row itself.
        if showsTests { BenchHistoryList(engineID: benchmarkID, title: nil) }
    }

    private func anotherDownload(_ id: String) -> Bool {
        if mode == .coreAI { return coreAI.downloadingID != nil && coreAI.downloadingID != id }
        if mode == .cpu { return cpuCopy.downloadingID != nil && cpuCopy.downloadingID != id }
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
        case .networkPromo:     return "Other podcast's promo"
        case .selfPromo:        return "Their own plug"
        case .guestPlug:        return "Guest's plug"
        case .intro:            return "Intro"
        case .outro:            return "Outro"
        case .credits:          return "Credits"
        case .recurringSegment: return "Regular segment (kept)"
        case .mockAd:           return "Joke ad (kept)"
        case .show:             return "The show (kept)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
