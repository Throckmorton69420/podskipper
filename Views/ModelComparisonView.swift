import SwiftUI

/// Four engines remain visible; only the explicitly requested run is active.
///
/// Pass 32 (his 7 Oct request): each engine — and, inside the Core AI and
/// MLX lists, each downloaded model — has its own Basic and Hard buttons,
/// its latest result right under them and its earlier runs folded below,
/// so a test is started and read in one place instead of at the top and
/// the bottom of a long page. Core AI and MLX are separate sections.
struct ModelComparisonView: View {
    @State private var bench = ModelBench.shared
    @State private var coreAI = CoreAIModelLibrary.shared
    @State private var store = ModelStore.shared
    @AppStorage("compare.open.coreAI") private var coreAIListOpen = false
    @AppStorage("compare.open.mlx") private var mlxListOpen = false
    @AppStorage("compare.open.cpu") private var cpuListOpen = false
    @AppStorage(CPUReading.selectionKey) private var cpuChosenID = CPUReading.qwen35_4B_q4.id
    @State private var disclosure = BenchDisclosure.shared
    @State private var riskyCoreAI: Confirmation?
    @State private var preparation = CoreAIPreparation.shared

    var body: some View {
        List {
            Text("\(BenchSample.basic.title) is \(BenchSample.basic.purpose) \(BenchSample.hard.title) is \(BenchSample.hard.purpose) Each result shows ads cut, show kept and a score; a model shows its own answer and the answer after PodSkipper’s check. Both are made up: the PodSkipper Test measures finders on your own episodes.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).contentRow()
            PodTestSection()
            ModelScoreboard()
            if let error = bench.requestError, bench.requestErrorEngine == nil {
                Text(error).font(.subheadline).foregroundStyle(.orange).contentRow()
            }

            SectionHeader("Apple Intelligence")
            engineBlock(.apple, engineID: "apple", name: AdFinderChoice.apple.title)

            SectionHeader("PodSkipper Reader")
            engineBlock(.reader, engineID: "reader", name: AdFinderChoice.reader.title)

            SectionHeader("Core AI")
            if let job = preparation.current, job.stopRequestedAt != nil {
                preparationNotice(job)
            }
            // The engine row stays even with nothing usable chosen (its
            // buttons then say why they can't run), so all four engines
            // always read the same way.
            engineBlock(.coreAI, engineID: coreAI.selectedEntry.map { CoreAIQwen3.benchmarkID(for: $0.id) } ?? "coreAI",
                        name: coreAI.selectedEntry.map { "Chosen: " + $0.name } ?? "No Core AI model chosen")
            listToggle("All Core AI Models", symbol: "cpu", open: $coreAIListOpen, id: "model.coreAI.disclosure")
            if coreAIListOpen { ModelCatalogContent(mode: .coreAI, showsTests: true, riskyTest: $riskyCoreAI) }

            SectionHeader("MLX (Open Models)")
            engineBlock(.model, engineID: store.selected.id, name: "Chosen: " + store.selected.name)
            listToggle("All MLX Models", symbol: "square.stack.3d.up", open: $mlxListOpen, id: "model.mlx.disclosure")
            if mlxListOpen { ModelCatalogContent(mode: .mlx, showsTests: true, riskyTest: $riskyCoreAI) }

            // Pass 63: CPU models as the other two kinds — the chosen one,
            // then every model of the catalog, downloaded or not; a model
            // that is deleted keeps its row and its results.
            SectionHeader("CPU Models (Processor)")
            engineBlock(.cpu, engineID: (CPUReading.model(id: cpuChosenID) ?? CPUReading.selected).engineID,
                        name: "Chosen: " + (CPUReading.model(id: cpuChosenID) ?? CPUReading.selected).name)
            listToggle("All CPU Models", symbol: "memorychip", open: $cpuListOpen, id: "model.cpu.disclosure")
            if cpuListOpen { ModelCatalogContent(mode: .cpu, showsTests: true, riskyTest: $riskyCoreAI) }

            if !orphanEngines.isEmpty {
                SectionHeader("Earlier Models")
                FoldRow(title: "Results for models no longer in the lists (\(orphanEngines.count))",
                        key: "orphans", identifier: "model.results.orphans")
                if disclosure.isOpen("orphans") {
                    ForEach(orphanEngines, id: \.self) { id in
                        BenchHistoryList(engineID: id, title: bench.history.last { $0.engine == id }?.name ?? id)
                    }
                }
            }
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle("Compare models")
        .watchName("Compare models")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .task { coreAI.load(); store.refreshState() }
        .confirmation($riskyCoreAI)
    }

    /// Pass 36 (his 13 Oct phone: Stop sat at "Stopping…" until he restarted
    /// the app). The test ends at Stop; Core AI's preparation can't be
    /// interrupted, so it finishes by itself and holds the model slot. This
    /// says so, and offers the one real way to end it at once.
    private func preparationNotice(_ job: CoreAIPreparation.Job) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 6) {
                Text("Core AI is still preparing \(job.name) · " + CoreAIPreparation.clock(context.date.timeIntervalSince(job.started)))
                    .font(.subheadline.weight(.semibold))
                Text("You stopped the test. iOS gives apps no way to interrupt this step, so it finishes by itself and is kept for next time. Other tests wait until it ends. Closing PodSkipper ends it now, but it starts over the next time this model loads.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Close PodSkipper Now", role: .destructive) {
                    riskyCoreAI = Confirmation(title: "Close PodSkipper?",
                                               message: "This is the only way to end Core AI's preparation of \(job.name) right away. What it has done so far is lost.",
                                               actionTitle: "Close PodSkipper") {
                        BackgroundLog.shared.note("Closed PodSkipper to end Core AI's preparation of \(job.name)")
                        await BackgroundLog.shared.flush()
                        exit(0)
                    }
                }
                .buttonStyle(.borderless).font(.subheadline)
                .accessibilityIdentifier("model.coreAI.closeToStop")
            }
        }
        .contentRow(top: 8, bottom: 8)
        .accessibilityIdentifier("model.coreAI.preparingAfterStop")
    }

    /// Opens or closes a model list. A plain button with its own state, not
    /// a DisclosureGroup: the list's rows are List rows of their own, and
    /// VoiceOver hears "Expanded"/"Collapsed".
    private func listToggle(_ title: String, symbol: String, open: Binding<Bool>, id: String) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { open.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 8) {
                Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Image(systemName: open.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(open.wrappedValue ? "Expanded" : "Collapsed")
        .accessibilityIdentifier(id)
        .contentRow()
    }

    @ViewBuilder
    private func engineBlock(_ engine: AdFinderChoice, engineID: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Apple Intelligence and the Reader are named by their section
            // header already; Core AI and MLX say which model is chosen.
            if engine == .coreAI || engine == .model || engine == .cpu {
                Text(name).font(.body.weight(.semibold))
                    .accessibilityIdentifier("model.engine." + engine.rawValue)
            }
            Text(engine.explanation).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            BenchModelTests(engineID: engineID, title: name, unavailable: readiness(engine),
                            identifierStem: engine.rawValue, showsRunning: runsInSection(engine)) { sample in run(engine, sample: sample) }
        }
        .contentRow(top: 12, bottom: 12)
        // Its own rows, under the block (see `FoldRow`).
        BenchHistoryList(engineID: engineID, title: nil)
    }

    /// Pass 36 (his 12 Oct report): a Core AI or MLX test keeps showing in
    /// its engine's section while it runs, even when another model becomes
    /// the chosen one meanwhile (Gemma 4 E2B finished downloading during the
    /// Qwen3 4B test and replaced it there). It also shows in its own row in
    /// the full list.
    private func runsInSection(_ engine: AdFinderChoice) -> (String) -> Bool {
        switch engine {
        case .coreAI: return { $0.hasPrefix(CoreAIQwen3.benchmarkID(for: "")) || $0 == CoreAIQwen3.benchmarkID }
        case .model: return { id in LocalModelSpec.all.contains { $0.id == id } }
        case .cpu: return { id in CPUReading.catalog.contains { $0.engineID == id } }
        case .apple, .reader: return { _ in false }
        }
    }

    private func readiness(_ engine: AdFinderChoice) -> String? {
        switch engine {
        case .apple: return AdDetector.availability()
        case .reader: return SentenceTagger.isBundled ? nil : "The bundled reader is missing."
        case .model:
            #if targetEnvironment(simulator)
            return "MLX inference requires a physical device."
            #else
            return store.isReady ? nil : "Download and switch on a model to test it."
            #endif
        case .coreAI:
            #if targetEnvironment(simulator)
            return "Core AI inference requires a physical device."
            #else
            return coreAI.isReady ? nil : "Download and switch on a model this iPhone can run to test it."
            #endif
        case .cpu:
            let model = CPUReading.model(id: cpuChosenID) ?? CPUReading.selected
            if CPUReading.isDemo { return model.isDownloaded && bench.isEnabled(model.engineID) ? nil : "Download it under All CPU Models to test it." }
            #if targetEnvironment(simulator)
            return "CPU models run on iPhone only."
            #else
            if !CPUReading.engineIncluded { return "This build doesn’t include the CPU reader." }
            return model.isDownloaded && bench.isEnabled(model.engineID) ? nil : "Download and switch on a CPU model to test it."
            #endif
        }
    }

    private func run(_ engine: AdFinderChoice, sample: BenchSample) {
        bench.clearRequestError(); Feel.selection.play()
        switch engine {
        case .apple: bench.testDetector(apple: true, sample: sample)
        case .reader: bench.testDetector(apple: false, sample: sample)
        case .model: bench.testSelectedModel(sample: sample)
        case .cpu: bench.testCPU(CPUReading.model(id: cpuChosenID) ?? CPUReading.selected, sample: sample)
        case .coreAI:
            // Pass 33: a model that has closed the app asks first.
            if let entry = coreAI.selectedEntry, CoreAIStability.record(for: entry.id) != nil {
                riskyCoreAI = CoreAIStability.confirmation(entry: entry, sample: sample)
            } else {
                bench.testCoreAI(sample: sample)
            }
        }
    }

    /// Engines with results that no row on this page shows any more.
    private var orphanEngines: [String] {
        var shown: Set<String> = ["apple", "reader"]
        shown.formUnion(CPUReading.catalog.map(\.engineID))
        shown.formUnion(LocalModelSpec.all.map(\.id))
        shown.formUnion(coreAI.entries.map { CoreAIQwen3.benchmarkID(for: $0.id) })
        return Array(Set(bench.history.map(\.engine)).subtracting(shown)).sorted()
    }
}

/// Basic and Hard for one engine or model: the buttons, the latest result
/// of each right under them, the run in progress, and the earlier runs.
struct BenchModelTests: View {
    let engineID: String
    let title: String
    /// Why it can't be tested now, if it can't.
    let unavailable: String?
    let identifierStem: String
    /// Also show the run panel when this engine runs (a model in the same section).
    var showsRunning: (String) -> Bool = { _ in false }
    let run: (BenchSample) -> Void
    @State private var bench = ModelBench.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(BenchSample.allCases, id: \.self) { sample in
                    BenchmarkTestButton(title: title, sample: sample, identifier: "model.test." + identifierStem + "." + sample.rawValue,
                                        disabled: bench.isRunning || unavailable != nil) { run(sample) }
                }
                Spacer(minLength: 0)
            }
            if let running = bench.running, running == engineID || showsRunning(running) {
                BenchRunPanel(title: title)
            } else if let error = bench.requestError, bench.requestErrorEngine == engineID {
                // Pass 33: why a tap didn't start a test, where he tapped.
                Text(error).font(.subheadline).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("model.requestError." + engineID)
            } else if let unavailable {
                Text(unavailable).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(BenchSample.allCases, id: \.self) { sample in
                if let latest = bench.result(engineID, sample) {
                    BenchLatestLine(result: latest, lastScored: bench.lastScored(engineID, sample))
                }
            }
        }
    }
}

/// One line: "Basic · 91 % · 54 s · 6 Oct 23:55", or why it failed.
struct BenchLatestLine: View {
    let result: BenchResult
    /// Pass 36: the last attempt that scored, kept beside a newer failure.
    var lastScored: BenchResult?
    var body: some View {
        let when = result.date.formatted(date: .abbreviated, time: .shortened)
        var text: String
        if let error = result.error {
            text = result.sample.title + " · " + result.resolvedOutcome.title.lowercased() + " · " + when + "\n" + error
            if let last = lastScored, let score = last.score {
                text += "\nLast score: \(Int((score * 100).rounded()))% on " + last.date.formatted(date: .abbreviated, time: .shortened)
            }
        } else if let score = result.score {
            text = result.sample.title + " · Score \(Int((score * 100).rounded()))% · \(Int(result.seconds.rounded())) s · " + when
                + (result.isComparable ? "" : " · earlier sample or cutting policy")
                // Pass 63: ads cut and show kept, then (a model) its own
                // answer beside the checked one.
                + (result.breakdown.map { "\n" + $0 } ?? "")
                + (result.rawAndChecked.map { "\n" + $0 } ?? "")
                + (result.checks.map { "\n" + $0.summary } ?? "")
        } else {
            text = result.sample.title + " · no score · " + when
        }
        return Text(text)
            .font(.subheadline)
            .foregroundStyle(result.error != nil ? Color.orange : (result.score ?? 0) >= 0.8 ? Color.green : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("model.latest." + result.engine + "." + result.sample.rawValue)
    }
}

/// Which folds on the Compare page are open, shared by every row so a fold
/// keeps its state when the rows around it are rebuilt.
@MainActor @Observable
final class BenchDisclosure {
    static let shared = BenchDisclosure()
    private(set) var open: Set<String> = []
    func isOpen(_ key: String) -> Bool { open.contains(key) }
    func toggle(_ key: String) {
        withAnimation(.smooth(duration: 0.2)) {
            if open.contains(key) { open.remove(key) } else { open.insert(key) }
        }
    }
}

/// A row that opens and closes the rows under it. Pass 33 (his 9 Oct screen
/// recording: tapping a fold made the page jump and the text above it
/// blank out and overlap): the folds used to be DisclosureGroups inside one
/// List row, so opening "All 9 runs" grew that single row by hundreds of
/// points and the list cross-faded the whole row between its old and new
/// heights, while the test in progress redrew it every second. Each fold is
/// now a row of its own and what it opens are rows of their own, inserted
/// under it; the rows above never change.
struct FoldRow: View {
    let title: String
    let key: String
    let identifier: String
    var font: Font = .subheadline
    @State private var disclosure = BenchDisclosure.shared

    var body: some View {
        let open = disclosure.isOpen(key)
        Button { disclosure.toggle(key) } label: {
            HStack(spacing: 8) {
                Text(title).font(font).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityIdentifier(identifier)
        .contentRow()
    }
}

/// Every run of one engine or model, newest first, folded away: the fold is
/// one row and each run, when open, is rows of its own.
struct BenchHistoryList: View {
    let engineID: String
    /// Shown above the runs when the list stands alone.
    let title: String?
    @State private var bench = ModelBench.shared
    @State private var disclosure = BenchDisclosure.shared

    var body: some View {
        let runs = bench.runs(engineID)
        if !runs.isEmpty {
            let key = "history." + engineID
            FoldRow(title: (title.map { $0 + " · " } ?? "") + (runs.count == 1 ? "1 run, with details" : "All \(runs.count) runs, with details"),
                    key: key, identifier: "model.result." + engineID)
            if disclosure.isOpen(key) {
                ForEach(runs) { result in
                    BenchmarkResultView(result: result)
                }
            }
        }
    }
}

/// The test under way: what it is doing, a plain bar, time spent and an
/// honest time left, and Stop. Nothing spins or pulses (his 7 Oct note).
struct BenchRunPanel: View {
    let title: String
    @State private var bench = ModelBench.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text((bench.runningName ?? title) + " · " + (bench.runningSample?.title ?? ""))
                    .font(.subheadline.weight(.semibold))
                // Pass 33: from the moment it is tapped, the panel says what
                // the test is doing; the bar is only ever work done, so it
                // holds still while the test is queued, loading or cooling.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let state = bench.runState()
                    let shown = bench.shownFraction(now: context.date)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.label)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(state == .cooling ? Color.orange : Color.primary)
                            .accessibilityIdentifier("model.runState")
                        Text(bench.waiting ? bench.step : (state == .cooling ? "No model work is done while it waits." : bench.step))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let stage = bench.stageDetail(now: context.date) {
                            Text(stage).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        PlainBar(value: shown)
                        HStack(spacing: 6) {
                            Text("\(Int((shown * 100).rounded()))%")
                            if let started = bench.startedAt {
                                Text("Elapsed " + Duration.seconds(max(0, context.date.timeIntervalSince(started))).formatted(.time(pattern: .minuteSecond)))
                            }
                        }
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        if let left = bench.timeLeftText(now: context.date) {
                            Text(left).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("model.timeLeft")
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { bench.stop() } label: { Text(bench.stopping ? "Stopping…" : "Stop").frame(minHeight: 44) }
                .buttonStyle(.glass).disabled(bench.stopping)
                .accessibilityLabel("Stop " + (bench.runningName ?? title) + " test")
                .accessibilityIdentifier("model.benchmarkStop")
        }
        .transaction { $0.animation = nil }
        .accessibilityIdentifier("model.active." + (bench.running ?? ""))
    }
}

/// A progress bar with no system animation or glass shimmer.
struct PlainBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(Theme.accentHot)
                    .frame(width: max(4, geometry.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Test progress")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

private struct BenchmarkTestButton: View {
    let title: String
    let sample: BenchSample
    let identifier: String
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                Text(sample.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(disabled ? Color.secondary : Color.primary)
            .frame(width: 72, height: 44)
            .contentShape(Capsule())
            .glassEffect(.regular, in: .capsule)
        }
        // `.buttonStyle(.glass)` pads outside the label's declared frame, so
        // these controls grew to ~107 points apiece and crowded the engine
        // name. The plain button makes 72 x 44 the actual outer geometry;
        // glass remains the control surface rather than an extra layout layer.
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(title + " " + sample.title + " test")
        .accessibilityIdentifier(identifier)
    }
}

struct BenchmarkResultView: View {
    let result: BenchResult
    @State private var disclosure = BenchDisclosure.shared

    var body: some View {
        let id = result.runID.uuidString
        VStack(alignment: .leading, spacing: 8) {
            Text(result.sample.title + " · " + result.date.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline.weight(.semibold))
            if let error = result.error {
                Text(error).foregroundStyle(.orange)
            } else if let score = result.score {
                Text("Score \(Int((score * 100).rounded()))%").foregroundStyle(score >= 0.8 ? .green : .orange)
                if let quality = result.quality { Text(quality.summary) }
                if let raw = result.rawScore {
                    Text("The model’s own answer, before PodSkipper’s check: \(Int((raw * 100).rounded()))%"
                         + (result.rawQuality.map { " · " + $0.summary } ?? ""))
                }
                if let share = result.shareRead, share < 0.995 {
                    Text("Shown \(Int((share * 100).rounded()))% of the lines: the stretches Find Ads would show it.")
                        .foregroundStyle(.secondary)
                }
                if let checks = result.checks { Text(checks.summary) }
                Text(result.found.isEmpty ? "No cuts found" : result.found.map { found in
                    let bits = found.split(separator: " ", maxSplits: 1)
                    guard bits.count == 2 else { return found }
                    return (JudgeLabel(rawValue: String(bits[0]))?.plainName ?? String(bits[0])) + " · lines " + bits[1]
                }.joined(separator: "\n"))
            }
            Text(measurements).foregroundStyle(.secondary).monospacedDigit()
            if !result.isComparable {
                Text("Earlier sample or cutting policy; excluded from current ranking.").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 12)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("model.run." + id)
        .contentRow(top: 10, bottom: 4)
        if let identity = result.modelIdentity {
            FoldRow(title: "Model version and policy", key: "identity." + id,
                    identifier: "model.run.identity." + id).padding(.leading, 12)
            if disclosure.isOpen("identity." + id) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(identity).textSelection(.enabled)
                    Text("Sample version \(result.sampleVersion) · Cutting policy \(result.policyVersion)")
                }
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 24)
                .contentRow()
            }
        }
        if !result.answerStart.isEmpty {
            FoldRow(title: "Response excerpt", key: "excerpt." + id,
                    identifier: "model.run.excerpt." + id).padding(.leading, 12)
            if disclosure.isOpen("excerpt." + id) {
                Text(result.answerStart).textSelection(.enabled)
                    .font(.subheadline.monospaced()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
                    .contentRow()
            }
        }
    }

    private var measurements: String {
        var bits = [String(format: "%.1f s", result.seconds)]
        if result.readTPS > 0 { bits.append(String(format: "input %.0f tokens/s", result.readTPS)) }
        if result.writeTPS > 0 { bits.append(String(format: "generation %.1f tokens/s", result.writeTPS)) }
        bits.append(result.peakBytes > 0 ? "Peak " + ModelStore.gigabytes(Int64(result.peakBytes)) : "Peak memory unknown")
        let thermal = ["Nominal", "Fair", "Serious", "Critical"]
        if thermal.indices.contains(result.thermalBefore), thermal.indices.contains(result.thermalAfter) {
            bits.append("Thermal " + thermal[result.thermalBefore] + " → " + thermal[result.thermalAfter])
        } else { bits.append("Thermal unknown") }
        if let delta = result.batteryDelta { bits.append(String(format: "Battery %+.1f%%", delta * 100)) }
        else { bits.append("Battery unknown") }
        return bits.joined(separator: " · ")
    }
}


/// Pass 62 (his 8 Nov request: running Basic, Hard or the PodSkipper Test
/// must change the scores shown; no numbers measured once on the Mac and
/// typed in): every finder's latest scores on this iPhone, worked out from
/// the records each test keeps, so a test that finishes changes its row at
/// once.
struct ModelScoreboard: View {
    @State private var bench = ModelBench.shared
    @State private var runner = PodTestRunner.shared

    var body: some View {
        let rows = Scoreboard.rows(runs: runner.runs, pack: runner.pack, history: bench.history)
        SectionHeader("Scores on This iPhone")
        Text("Each finder’s latest result, updated the moment a test finishes. Test is the PodSkipper Test on your own episodes; Basic and Hard are the two samples above. Ads cut is the share of every ad, plug, intro and outro removed; Show kept is the share of the show still there. Score puts them together: 100 is every break cut and none of the show; cutting nothing, or everything, is 0.")
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).contentRow()
        if rows.isEmpty {
            Text("No results yet. Run the PodSkipper Test, or Basic and Hard on a finder below.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).contentRow()
        } else {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name).font(.subheadline.weight(.semibold))
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                        GridRow {
                            Text("").gridColumnAlignment(.leading)
                            Text("Score").font(.caption.weight(.semibold)).gridColumnAlignment(.trailing)
                            Text("Ads cut").font(.caption.weight(.semibold)).gridColumnAlignment(.trailing)
                            Text("Show kept").font(.caption.weight(.semibold)).gridColumnAlignment(.trailing)
                        }
                        .foregroundStyle(.secondary)
                        ForEach(row.lines) { line in
                            GridRow {
                                Text(line.label).font(.footnote)
                                Text(line.score).font(.footnote.monospacedDigit().weight(.semibold))
                                Text(line.adsCut).font(.footnote.monospacedDigit())
                                Text(line.showKept).font(.footnote.monospacedDigit())
                            }
                            if let note = line.note {
                                GridRow {
                                    Text(note).font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .gridCellColumns(4)
                                }
                            }
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("scoreboard." + row.id)
                .contentRow(top: 6, bottom: 6)
            }
            Color.clear.frame(height: 1).accessibilityIdentifier("model.scoreboard").contentRow()
        }
    }
}

/// Pass 62: the scoreboard's numbers, from the records alone (testable).
enum Scoreboard {
    struct Row: Identifiable, Equatable {
        var id: String
        var name: String
        var isReader = false
        /// PodSkipper Test Everyday score and the Reader's on the same episodes.
        var test: Double?
        var reader: Double?
        var episodes = 0
        var testDate: Date?
        /// Basic / Hard (0–1) under today's samples.
        var basic: Double?
        var hard: Double?
        /// Pass 63: the parts behind each number, and a model's own answer
        /// before PodSkipper's check.
        var testQuality: PodTestScore.Quality?
        var basicQuality: PodTestScore.Quality?
        var hardQuality: PodTestScore.Quality?
        var basicRaw: Double?
        var hardRaw: Double?

        struct Line: Identifiable, Equatable {
            var label: String
            var score: String
            var adsCut: String
            var showKept: String
            var note: String?
            var id: String { label }
        }

        /// One line per test taken: its score, ads cut and show kept.
        var lines: [Line] {
            func part(_ value: Double?) -> String { value.map { PodTestScore.Quality.percent($0) } ?? "–" }
            var out: [Line] = []
            if let test {
                var note = detail
                if !isReader, let reader {
                    note = (note.map { $0 + " · " } ?? "") + "Reader \(PodTestRunPage.number(reader)) on the same episodes"
                }
                out.append(Line(label: "Test", score: PodTestRunPage.number(test), adsCut: part(testQuality?.adsCut),
                                showKept: part(testQuality?.showKept), note: note))
            }
            if let basic {
                out.append(Line(label: "Basic", score: Scoreboard.percent(basic), adsCut: part(basicQuality?.adsCut),
                                showKept: part(basicQuality?.showKept),
                                note: basicRaw.map { "The model alone, before PodSkipper’s check: " + Scoreboard.percent($0) }))
            }
            if let hard {
                out.append(Line(label: "Hard", score: Scoreboard.percent(hard), adsCut: part(hardQuality?.adsCut),
                                showKept: part(hardQuality?.showKept),
                                note: hardRaw.map { "The model alone, before PodSkipper’s check: " + Scoreboard.percent($0) }))
            }
            return out
        }

        var detail: String? {
            guard episodes > 0 else { return nil }
            return "\(episodes) episode\(episodes == 1 ? "" : "s")" + (testDate.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "")
        }
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        return String(format: "%.0f", value * 100)
    }

    static func rows(runs: [PodTestRun], pack: PodTestPack?, history: [BenchResult]) -> [Row] {
        var rows: [String: Row] = [:]
        var order: [String] = []
        func touch(_ id: String, _ name: String) {
            if rows[id] == nil { rows[id] = Row(id: id, name: name, isReader: id == "reader"); order.append(id) }
        }
        // The PodSkipper Test: each finder's newest run with episodes read.
        if let pack {
            for run in runs.sorted(by: { $0.started > $1.started }) {
                for engine in run.engines {
                    let id = engine.engine
                    if rows[id]?.test != nil { continue }
                    if engine.kind == .reader {
                        let summary = PodTestScore.summary(pack: pack, cuts: engine.cuts)
                        guard summary.episodes > 0, let everyday = summary.everyday else { continue }
                        touch(id, engine.name)
                        rows[id]?.test = everyday
                        rows[id]?.episodes = summary.episodes
                        rows[id]?.testDate = run.finished ?? run.started
                        rows[id]?.testQuality = PodTestScore.quality(pack: pack, cuts: engine.cuts)
                    } else if let comparison = run.comparison(id, pack: pack), let everyday = comparison.engine.everyday {
                        touch(id, engine.name)
                        rows[id]?.test = everyday
                        rows[id]?.reader = comparison.reader.everyday
                        rows[id]?.episodes = comparison.engine.episodes
                        rows[id]?.testDate = run.finished ?? run.started
                        if let reader = run.reader {
                            rows[id]?.testQuality = PodTestScore.quality(
                                pack: pack, cuts: engine.cuts, guids: Set(engine.cuts.keys).intersection(reader.cuts.keys))
                        }
                    }
                }
            }
        }
        // Basic and Hard: the newest scored result under today's samples.
        for result in history.sorted(by: { $0.date > $1.date }) where result.isComparable && result.score != nil {
            let id = result.engine
            touch(id, rows[id]?.name ?? result.name)
            switch result.sample {
            case .basic:
                if rows[id]?.basic == nil {
                    rows[id]?.basic = result.score; rows[id]?.basicQuality = result.quality; rows[id]?.basicRaw = result.rawScore
                }
            case .hard:
                if rows[id]?.hard == nil {
                    rows[id]?.hard = result.score; rows[id]?.hardQuality = result.quality; rows[id]?.hardRaw = result.rawScore
                }
            }
        }
        return order.compactMap { rows[$0] }.sorted { a, b in
            if a.isReader != b.isReader { return a.isReader }
            switch (a.test, b.test) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return (a.hard ?? -1, a.basic ?? -1, a.name) > (b.hard ?? -1, b.basic ?? -1, b.name)
            }
        }
    }
}
