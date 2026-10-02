import SwiftUI

/// Settings → Open-source models.
///
/// Pass 27g (his requests, 30 Sep): the models ranked best first by their
/// test results (accuracy, then speed), each one's results kept and one tap
/// away, a switch to turn each model on or off, every model downloadable
/// (iOS decides what fits), and Apple Intelligence and the reader put
/// through the same tests for comparison. The test keeps running (and can
/// be stopped) if he leaves the screen. Results belong to Compare models.
enum ModelLibraryMode { case mlx, coreAI, comparison }

struct LocalModelView: View {
    let mode: ModelLibraryMode

    init(mode: ModelLibraryMode = .mlx) { self.mode = mode }

    @State private var store = ModelStore.shared
    @State private var monitor = LocalJudgeMonitor.shared
    @State private var bench = ModelBench.shared
    @State private var confirmingDelete = false
    @State private var onDisk: Set<String> = []
    @State private var expanded: String?
    @State private var coreAI = CoreAIModelLibrary.shared

    var body: some View {
        List {
            switch mode {
            case .mlx: mlxContent
            case .coreAI: coreAIPageContent
            case .comparison: comparisonContent
            }
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle(pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .task { if mode != .mlx { coreAI.load() } }
        .onAppear(perform: refreshDisk)
        .onChange(of: store.hasFiles) { refreshDisk() }
        .confirmationDialog("Delete \(store.selected.name)?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.delete(); refreshDisk() }
        } message: {
            Text("Its files are removed and the space is freed. Its test results are kept.")
        }
    }

    private var pageTitle: String {
        switch mode {
        case .mlx: return "Open-source models"
        case .coreAI: return "Core AI Models"
        case .comparison: return "Compare models"
        }
    }

    private var compareLink: some View {
        NavigationLink { ModelComparisonView() } label: {
            Label("Compare models", systemImage: "chart.bar.xaxis")
        }
        .contentRow()
        .accessibilityIdentifier("model.compare")
    }

    @ViewBuilder
    private var mlxContent: some View {
        SectionHeader(store.selected.name)
        LocalModelStatusRow().contentRow()
        actionRow.contentRow()
        compareLink

        SectionHeader("Models")
        Text("Choose a model to download. Test results are kept in Compare models; tested models are ordered by accuracy, then speed.")
            .font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).contentRow()
        ForEach(ranked(enabled: true)) { spec in modelRow(spec) }
        let off = ranked(enabled: false)
        if !off.isEmpty {
            SectionHeader("Turned off")
            ForEach(off) { spec in modelRow(spec) }
        }
        SectionHeader("Downloading")
        Toggle("Allow cellular", isOn: $store.allowCellular)
            .tint(Theme.accentHot).contentRow()
    }

    @ViewBuilder
    private var coreAIPageContent: some View {
        coreAIRow
        compareLink
        Text("Models run on this device. Availability and downloads use the catalog's compatible iOS bundle.")
            .font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).contentRow()
    }

    @ViewBuilder
    private var comparisonContent: some View {
        Text("Basic checks one clear ad. Hard includes plugs, intros, credits, ordinary brand discussion and a joke ad. These samples check compatibility and classification; real episodes decide which finder works best.")
            .font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).contentRow()
        if bench.isRunning {
            HStack {
                ProgressView()
                Text(runningLine).font(.footnote)
                Spacer()
                benchmarkStopButton
            }.contentRow()
        }
        SectionHeader("On-device finders")
        engineRow(id: "apple", name: "Apple Intelligence", detail: "Apple's on-device model")
        engineRow(id: "reader", name: "PodSkipper Reader", detail: "PodSkipper's small reader")
        SectionHeader("Core AI")
        if let selected = coreAI.selectedEntry {
            VStack(alignment: .leading, spacing: 10) {
                Text(selected.name).font(.body.weight(.semibold))
                benchmarkButtons { sample in bench.testCoreAI(sample: sample) }
                    .disabled(!coreAI.isDownloaded(selected))
                if !coreAI.isDownloaded(selected) {
                    Text("Download this model in the Core AI library to test it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                resultsBlock(CoreAIQwen3.benchmarkID(for: selected.id))
            }.contentRow()
        } else {
            Text("Choose and download a Core AI model in its library.")
                .font(.footnote).foregroundStyle(.secondary).contentRow()
        }
        if BenchSample.allCases.contains(where: { bench.result(CoreAIQwen3.benchmarkID, $0) != nil }) {
            SectionHeader("Earlier Core AI results")
            Text("These older results did not record which Core AI model was used.")
                .font(.footnote).foregroundStyle(.secondary).contentRow()
            resultsBlock(CoreAIQwen3.benchmarkID).contentRow()
        }
        let selectedCoreID = coreAI.selectedEntry.map { CoreAIQwen3.benchmarkID(for: $0.id) }
        let otherCoreIDs = Set(bench.history.map(\.engine))
            .filter { $0.hasPrefix("coreai.model:") && $0 != selectedCoreID }.sorted()
        if !otherCoreIDs.isEmpty {
            SectionHeader("Other Core AI results")
            ForEach(otherCoreIDs, id: \.self) { id in
                VStack(alignment: .leading, spacing: 8) {
                    Text(bench.history.last(where: { $0.engine == id })?.name ?? id)
                        .font(.body.weight(.semibold))
                    disclosure(id)
                }.contentRow()
            }
        }
        SectionHeader("Selected MLX model")
        Text(store.selected.name).font(.body.weight(.semibold)).contentRow()
        testRow.contentRow()
        SectionHeader("MLX results")
        ForEach(ranked(enabled: true)) { spec in
            VStack(alignment: .leading, spacing: 8) {
                Text(spec.name).font(.body.weight(.semibold))
                Text(scoreLine(spec.id) ?? "Not tested")
                    .font(.footnote).foregroundStyle(.secondary)
                disclosure(spec.id)
            }.contentRow()
        }
    }

    // MARK: The chosen model

    private var actionRow: some View {
        HStack(spacing: 10) {
            switch store.phase {
            case .downloading, .listing:
                Button("Pause", systemImage: "pause.fill") { store.pause() }
                    .buttonStyle(.glass)
            case .ready:
                EmptyView()
            default:
                Button("Download") { store.download() }
                    .buttonStyle(.glassProminent)
            }
            Spacer()
            if store.hasFiles {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                    .buttonStyle(.glass)
                    .disabled(HeavyWorkCoordinator.shared.isBusy)
            }
        }
    }

    private var testRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                benchmarkButtons { sample in bench.testSelectedModel(sample: sample) }
                    .disabled(!store.isReady || monitor.isRunning)
                benchmarkStopButton
            }
            if bench.isRunning {
                HStack(spacing: 7) {
                    ProgressView()
                    Text(runningLine).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            } else if !store.isReady {
                Text("Download the selected MLX model before running a benchmark.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("Basic is the quick sanity check. Hard deliberately mixes ads, self-promotion, guest plugs, another-show promotion, intros/outros and joke ads so the classifier has to use context. Only one benchmark runs at a time.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            resultsBlock(store.selected.id)
        }
    }

    @ViewBuilder
    private var benchmarkStopButton: some View {
        if bench.isRunning {
            Button("Stop", systemImage: "stop.fill", role: .destructive) {
                bench.stop()
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier("model.benchmarkStop")
        }
    }

    @ViewBuilder
    private func benchmarkButtons(engine: String = "", _ action: @escaping (BenchSample) -> Void) -> some View {
        HStack(spacing: 6) {
            ForEach(BenchSample.allCases, id: \.self) { sample in
                Button {
                    Feel.selection.play()
                    action(sample)
                } label: {
                    GlassButtonLabel(title: sample.title, systemImage: "play.fill", fills: false)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .disabled(bench.isRunning || HeavyWorkCoordinator.shared.isBusy)
                .accessibilityIdentifier("model.benchmark.\(sample.rawValue)\(engine.isEmpty ? "" : "." + engine)")
            }
        }
    }

    private var runningLine: String {
        guard let id = bench.running else { return "" }
        let name = bench.runningName ?? id
        return name + " · " + (bench.runningSample?.title ?? "") + " · " + bench.step
    }

    // MARK: Rows

    private var coreAIRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let selected = coreAI.selectedEntry {
                Text(selected.name).font(.body.weight(.semibold))
                    .accessibilityIdentifier("model.coreAI.selected")
                Text(CoreAIModelLibrary.displaySize(selected))
                    .font(.footnote).foregroundStyle(.secondary)
                if coreAI.isDownloaded(selected) {
                    Label("Downloaded", systemImage: "checkmark.circle.fill")
                        .font(.footnote).foregroundStyle(.green)
                }
            }
            if coreAI.loading { ProgressView("Loading models…") }
            if coreAI.downloadingID != nil {
                ProgressView(value: coreAI.downloadFraction).tint(Theme.accentHot)
                Text("Downloading · \(Int(coreAI.downloadFraction * 100))%")
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            CoreAIModelPicker()
            if let error = coreAI.error {
                Text(error).font(.footnote).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentRow(top: 12, bottom: 12)
        .task { coreAI.load() }
    }

    private func engineRow(id: String, name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text(scoreLine(id) ?? detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                benchmarkButtons(engine: id) { sample in bench.testDetector(apple: id == "apple", sample: sample) }
                    .frame(maxWidth: .infinity, alignment: .leading)

                benchmarkStopButton
            }
            disclosure(id)
        }
        .contentRow(top: 8, bottom: 8)
    }

    private func modelRow(_ spec: LocalModelSpec) -> some View {
        let enabled = bench.isEnabled(spec.id)
        let selected = spec == store.selected
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    guard enabled else { return }
                    store.select(spec)
                    Haptics.select()
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? Theme.accentHot : .secondary)
                            .font(.system(size: UIScale.pt(18)))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(spec.name).foregroundStyle(enabled ? .primary : .secondary)
                                if onDisk.contains(spec.id) {
                                    Text("On iPhone").font(.footnote.weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.green.opacity(0.25), in: Capsule())
                                }
                            }
                            Text(scoreLine(spec.id) ?? spec.summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                Toggle("On", isOn: Binding(get: { enabled }, set: { bench.setEnabled(spec.id, $0) }))
                    .labelsHidden()
                    .tint(Theme.accentHot)
                    .accessibilityLabel("\(spec.name) turned on")
            }
        }
        .contentRow(top: 10, bottom: 10)
    }

    /// "Results" under a row: what each test found.
    @ViewBuilder
    private func disclosure(_ id: String) -> some View {
        if BenchSample.allCases.contains(where: { bench.result(id, $0) != nil }) {
            Button(expanded == id ? "Hide Results" : "Results") {
                withAnimation(.snappy) { expanded = expanded == id ? nil : id }
            }
            .font(.footnote.weight(.semibold))
            .frame(minHeight: 44)
            .foregroundStyle(Theme.accentHot)
            .buttonStyle(.plain)
            if expanded == id { resultsBlock(id) }
        }
    }

    @ViewBuilder
    private func resultsBlock(_ id: String) -> some View {
        ForEach(BenchSample.allCases, id: \.self) { sample in
            if let r = bench.result(id, sample) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(sample.title)\(r.isComparable ? "" : " · earlier test"): " + (r.score.map { "\(Int(($0 * 100).rounded())) % match" } ?? "didn't finish"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Self.color(r.score))
                    if let error = r.error {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text(r.found.isEmpty ? "Found nothing" : "Found: " + r.found.map(Self.plain).joined(separator: ", "))
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(Self.speedLine(r)).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        if r.isComparable {
                            Text(Self.telemetryLine(r)).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        let earlier = bench.history.filter { $0.engine == id && bench.result(id, $0.sample)?.runID != $0.runID }
            .sorted { $0.date > $1.date }
        if !earlier.isEmpty {
            DisclosureGroup("Previous runs (\(earlier.count))") {
                ForEach(earlier) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(result.sample.title) · " + result.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.footnote.weight(.semibold))
                        Text(result.score.map { "\(Int(($0 * 100).rounded()))% match" } ?? result.error ?? "Did not finish")
                            .font(.footnote)
                        Text(result.isComparable ? Self.speedLine(result) : "Earlier cutting policy; excluded from current ranking")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
            }.font(.footnote)
        }
    }

    // MARK: Words and order

    private func ranked(enabled: Bool) -> [LocalModelSpec] {
        let specs = LocalModelSpec.all.filter { bench.isEnabled($0.id) == enabled }
        let order = Dictionary(uniqueKeysWithValues: LocalModelSpec.all.enumerated().map { ($1.id, $0) })
        return specs.sorted {
            let a = bench.rank($0.id), b = bench.rank($1.id)
            if a != b { return a > b }
            let speedA = bench.speed($0.id), speedB = bench.speed($1.id)
            if speedA != speedB { return speedA > speedB }
            return (order[$0.id] ?? 0) < (order[$1.id] ?? 0)
        }
    }

    private func scoreLine(_ id: String) -> String? {
        guard let score = bench.score(id) else { return nil }
        let parts = BenchSample.allCases.compactMap { sample -> String? in
            guard let r = bench.result(id, sample) else { return nil }
            return "\(sample.title) " + (r.score.map { "\(Int(($0 * 100).rounded()))%" } ?? "✕")
        }
        let speed = BenchSample.allCases.compactMap { bench.result(id, $0)?.readTPS }.max() ?? 0
        return "\(Int((score * 100).rounded()))% overall · " + parts.joined(separator: " · ")
            + (speed > 0 ? " · \(Int(speed.rounded())) tok/s" : "")
    }

    private static func speedLine(_ r: BenchResult) -> String {
        var bits: [String] = []
        if r.engine.hasPrefix("coreai") {
            if r.readTPS > 0 { bits.append(String(format: "effective input %.0f tok/s", r.readTPS)) }
            if r.writeTPS > 0 { bits.append(String(format: "effective output %.0f tok/s", r.writeTPS)) }
        } else {
            if r.readTPS > 0 { bits.append("read \(Int(r.readTPS.rounded())) tok/s") }
            if r.writeTPS > 0 { bits.append(String(format: "wrote %.0f tok/s", r.writeTPS)) }
        }
        if r.seconds > 0 { bits.append(String(format: "%.0f s", r.seconds)) }
        if r.peakBytes > 0 { bits.append("peak " + ModelStore.gigabytes(Int64(r.peakBytes))) }
        else { bits.append("peak memory unknown") }
        return bits.joined(separator: " · ")
    }

    private static func telemetryLine(_ r: BenchResult) -> String {
        let names = ["nominal", "fair", "serious", "critical"]
        let before = r.thermalBefore >= 0 && r.thermalBefore < names.count ? names[r.thermalBefore] : "unknown"
        let after = r.thermalAfter >= 0 && r.thermalAfter < names.count ? names[r.thermalAfter] : "unknown"
        var line = "Thermal \(before) → \(after)"
        if let delta = r.batteryDelta {
            line += String(format: " · battery %.1f%%", delta * 100)
        } else {
            line += " · battery unknown"
        }
        if r.freeMemoryBefore > 0 && r.freeMemoryAfter > 0 {
            line += " · free memory \(ModelStore.gigabytes(Int64(r.freeMemoryBefore))) → \(ModelStore.gigabytes(Int64(r.freeMemoryAfter)))"
        }
        return line
    }

    /// "HOST_READ_AD 13–23" → "Host-read ad, lines 13–23".
    private static func plain(_ found: String) -> String {
        let bits = found.split(separator: " ", maxSplits: 1)
        guard bits.count == 2 else { return found }
        let name = JudgeLabel(rawValue: String(bits[0]))?.plainName
            ?? SegmentKind(rawValue: String(bits[0])).map { "\($0)" } ?? String(bits[0])
        return "\(name) \(bits[1])"
    }

    private static func color(_ score: Double?) -> Color {
        guard let score else { return .orange }
        return score >= 0.8 ? .green : score >= 0.5 ? .yellow : .orange
    }

    private func refreshDisk() {
        let fm = FileManager.default
        onDisk = Set(LocalModelSpec.all.filter { fm.fileExists(atPath: ModelStore.folder(for: $0).path) }.map(\.id))
    }
}

/// The download state. Its own view because it changes twice a second while
/// downloading, and nothing else on the screen needs to redraw with it.
private struct LocalModelStatusRow: View {
    @State private var store = ModelStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch store.phase {
            case .notDownloaded:
                Text("Not downloaded").font(.body.weight(.medium))
                Text("\(store.selected.name) is a \(ModelStore.bytes(store.selected.downloadBytes)) download.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .listing:
                Text("Starting the download…").font(.body.weight(.medium))
            case .downloading(let done, let total, let speed):
                Text("Downloading \(store.selected.name)").font(.body.weight(.medium))
                ProgressView(value: total > 0 ? Double(done) / Double(total) : 0)
                    .tint(Theme.accentHot)
                Text(Self.progressLine(done: done, total: total, speed: speed))
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            case .paused(let reason):
                Text("Paused").font(.body.weight(.medium))
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            case .ready(let size):
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.body.weight(.medium))
                Text("\(store.selected.name), \(ModelStore.bytes(size)) on this iPhone.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .failed(let reason):
                Label("Couldn't download", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.body.weight(.medium))
                Text(reason).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = store.memoryNote {
                Text(note).font(.footnote).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func progressLine(done: Int64, total: Int64, speed: Double) -> String {
        var line = "\(ModelStore.bytes(done)) of \(ModelStore.bytes(total))"
        if speed > 0 {
            line += " · \(ModelStore.bytes(Int64(speed)))/s"
            let seconds = Double(total - done) / speed
            if seconds.isFinite, seconds > 0 {
                let minutes = Int((seconds / 60).rounded(.up))
                line += minutes < 60 ? " · about \(minutes) min left"
                                     : " · about \(minutes / 60) h \(minutes % 60) min left"
            }
        }
        return line
    }
}

/// What the self-test found and how fast it read.
private struct SelfTestResultView: View {
    let report: JudgeReport

    var body: some View {
        let stats = report.stats
        VStack(alignment: .leading, spacing: 8) {
            if report.parts.isEmpty {
                Text("It found nothing.").font(.body.weight(.medium))
            }
            ForEach(Array(report.parts.enumerated()), id: \.offset) { _, part in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lines \(part.firstLine)–\(part.lastLine): \(part.label.plainName)"
                         + (part.sponsor.isEmpty ? "" : ", \(part.sponsor)"))
                        .font(.body.weight(.medium))
                    Text("Sure: \(part.confidence)%\(part.funny ? " · funny" : "") · \(part.why)")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !report.failedLines.isEmpty {
                Text("Couldn't read its answer for \(report.failedLines.count) part\(report.failedLines.count == 1 ? "" : "s").")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Divider()
            Group {
                Text("Reading speed: \(Int(stats.readTokensPerSecond.rounded())) tokens a second")
                    .font(.body.weight(.semibold).monospacedDigit())
                Text("Writing speed: \(String(format: "%.1f", stats.writeTokensPerSecond)) tokens a second")
                Text("Read \(stats.promptTokens) tokens in \(String(format: "%.1f", stats.promptSeconds)) s, wrote \(stats.generatedTokens) in \(String(format: "%.1f", stats.generateSeconds)) s")
                Text("Loading took \(String(format: "%.1f", stats.loadSeconds)) s · on the GPU · \(stats.constrained ? "answer held to the format" : "free answer")")
                Text("Peak memory \(ModelStore.gigabytes(Int64(stats.peakMemoryBytes))) · \(ModelStore.gigabytes(Int64(stats.availableBeforeLoad))) free before loading · parts of \(stats.windowTokens) tokens · \(stats.model)")
                Text("Also saved in Settings → Diagnostics → Share.")
            }
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
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

/// The Settings row's label: the name and a word on the download. Its own
/// view so a running download redraws only this row, not all of Settings.
struct LocalModelSettingsLabel: View {
    @State private var store = ModelStore.shared

    var body: some View {
        HStack {
            Text("Open-source models")
            Spacer()
            Text(status).foregroundStyle(.secondary).font(.footnote)
        }
    }

    private var status: String { store.selected.name + " · " + store.shortStatus }
}


@available(iOS 27.0, *)
private struct CoreAIModelPicker: View {
    @State private var bench = ModelBench.shared
    @State private var library = CoreAIModelLibrary.shared
    @State private var search = ""

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Search models", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("model.coreAI.search")
                ForEach(library.entries(matching: search)) { entry in
                    coreAIEntryRow(entry)
                }
            }
            .padding(.top, 10)
        } label: {
            Text("Choose a Core AI model").font(.body.weight(.semibold))
        }
    }

    private func coreAIEntryRow(_ entry: CoreAIModelDescriptor) -> some View {
        let downloaded = library.isDownloaded(entry)
        let selected = library.selectedID == entry.id
        let downloading = library.downloadingID == entry.id

        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    library.select(entry)
                    Feel.selection.play()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? Theme.accentHot : .secondary)
                            Text(entry.name)
                                .foregroundStyle(.primary)
                            if downloaded {
                                Text("Downloaded")
                                    .font(.footnote.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.25), in: Capsule())
                            }
                        }
                        Text("\(CoreAIModelLibrary.displaySize(entry)) · \(entry.repo)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("model.coreAI.select.\(entry.id)")

                Spacer(minLength: 8)

                if downloading {
                    ProgressView(value: library.downloadFraction)
                        .frame(width: 60)
                } else if downloaded {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        library.delete(entry)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(HeavyWorkCoordinator.shared.isBusy)
                } else if entry.isCompatible {
                    Button("Download") {
                        library.download(entry)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                } else {
                    Text("iOS unavailable")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle("Enabled", isOn: Binding(
                get: { bench.isEnabled(CoreAIQwen3.benchmarkID(for: entry.id)) },
                set: { bench.setEnabled(CoreAIQwen3.benchmarkID(for: entry.id), $0) }))
                .font(.footnote)
                .accessibilityLabel("Enable " + entry.name)
                .accessibilityIdentifier("model.coreAI.enabled." + entry.id)
        }
        .padding(.vertical, 8)
    }
}

/// One comparison destination shared by settings and both model libraries.
struct ModelComparisonView: View {
    var body: some View { LocalModelView(mode: .comparison) }
}
