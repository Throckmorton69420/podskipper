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
    @State private var orphansOpen = false

    var body: some View {
        List {
            Text("Basic checks a clear ad. Hard mixes ads and plugs with ordinary discussion, a joke ad, intros and credits. All engines use the same cutting policy. These tests measure whether a model runs and how it classifies two samples; your real episodes decide quality.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).contentRow()
            if let error = bench.requestError {
                Text(error).font(.subheadline).foregroundStyle(.orange).contentRow()
            }

            SectionHeader("Apple Intelligence")
            engineBlock(.apple, engineID: "apple", name: AdFinderChoice.apple.title)

            SectionHeader("PodSkipper Reader")
            engineBlock(.reader, engineID: "reader", name: AdFinderChoice.reader.title)

            SectionHeader("Core AI")
            // The engine row stays even with nothing usable chosen (its
            // buttons then say why they can't run), so all four engines
            // always read the same way.
            engineBlock(.coreAI, engineID: coreAI.selectedEntry.map { CoreAIQwen3.benchmarkID(for: $0.id) } ?? "coreAI",
                        name: coreAI.selectedEntry.map { "Chosen: " + $0.name } ?? "No Core AI model chosen")
            listToggle("All Core AI Models", symbol: "cpu", open: $coreAIListOpen, id: "model.coreAI.disclosure")
            if coreAIListOpen { ModelCatalogContent(mode: .coreAI, showsTests: true) }

            SectionHeader("MLX (Open Models)")
            engineBlock(.model, engineID: store.selected.id, name: "Chosen: " + store.selected.name)
            listToggle("All MLX Models", symbol: "square.stack.3d.up", open: $mlxListOpen, id: "model.mlx.disclosure")
            if mlxListOpen { ModelCatalogContent(mode: .mlx, showsTests: true) }

            if !orphanEngines.isEmpty {
                SectionHeader("Earlier Models")
                DisclosureGroup(isExpanded: $orphansOpen) {
                    ForEach(orphanEngines, id: \.self) { id in
                        BenchHistoryList(engineID: id, title: bench.history.last { $0.engine == id }?.name ?? id)
                    }
                } label: {
                    Text("Results for models no longer in the lists (\(orphanEngines.count))").font(.subheadline)
                }
                .contentRow().accessibilityIdentifier("model.results.orphans")
            }
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle("Compare models")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .task { coreAI.load(); store.refreshState() }
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

    private func engineBlock(_ engine: AdFinderChoice, engineID: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Apple Intelligence and the Reader are named by their section
            // header already; Core AI and MLX say which model is chosen.
            if engine == .coreAI || engine == .model {
                Text(name).font(.body.weight(.semibold))
                    .accessibilityIdentifier("model.engine." + engine.rawValue)
            }
            Text(engine.explanation).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            BenchModelTests(engineID: engineID, title: name, unavailable: readiness(engine),
                            identifierStem: engine.rawValue) { sample in run(engine, sample: sample) }
        }
        .contentRow(top: 12, bottom: 12)
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
        }
    }

    private func run(_ engine: AdFinderChoice, sample: BenchSample) {
        bench.clearRequestError(); Feel.selection.play()
        switch engine {
        case .apple: bench.testDetector(apple: true, sample: sample)
        case .reader: bench.testDetector(apple: false, sample: sample)
        case .model: bench.testSelectedModel(sample: sample)
        case .coreAI: bench.testCoreAI(sample: sample)
        }
    }

    /// Engines with results that no row on this page shows any more.
    private var orphanEngines: [String] {
        var shown: Set<String> = ["apple", "reader"]
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
            if bench.running == engineID {
                BenchRunPanel(title: title)
            } else if let unavailable {
                Text(unavailable).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(BenchSample.allCases, id: \.self) { sample in
                if let latest = bench.result(engineID, sample) {
                    BenchLatestLine(result: latest)
                }
            }
            BenchHistoryList(engineID: engineID, title: nil)
        }
    }
}

/// One line: "Basic · 91 % · 54 s · 6 Oct 23:55", or why it failed.
private struct BenchLatestLine: View {
    let result: BenchResult
    var body: some View {
        let when = result.date.formatted(date: .abbreviated, time: .shortened)
        let text: String
        if let error = result.error {
            text = result.sample.title + " · failed · " + when + "\n" + error
        } else if let score = result.score {
            text = result.sample.title + " · \(Int((score * 100).rounded())) % match · \(Int(result.seconds.rounded())) s · " + when
                + (result.isComparable ? "" : " · earlier cutting policy")
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

/// Every run of one engine or model, newest first, folded away.
struct BenchHistoryList: View {
    let engineID: String
    /// Shown above the runs when the list stands alone.
    let title: String?
    @State private var bench = ModelBench.shared
    @State private var open = false

    var body: some View {
        let runs = bench.history.filter { $0.engine == engineID }.sorted { $0.date > $1.date }
        if !runs.isEmpty {
            DisclosureGroup(isExpanded: $open) {
                ForEach(runs) { result in
                    BenchmarkResultView(result: result).padding(.vertical, 6)
                }
            } label: {
                Text((title.map { $0 + " · " } ?? "") + (runs.count == 1 ? "1 run, with details" : "All \(runs.count) runs, with details"))
                    .font(.subheadline)
            }
            .accessibilityIdentifier("model.result." + engineID)
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
                Text(bench.waiting ? "Waiting for the job in progress to finish" : bench.step).font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if let started = bench.startedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        let shown = bench.shownFraction(now: context.date)
                        VStack(alignment: .leading, spacing: 4) {
                            if let shown { PlainBar(value: shown) }
                            HStack(spacing: 6) {
                                if let shown { Text("\(Int((shown * 100).rounded()))%") }
                                Text("Elapsed " + Duration.seconds(max(0, context.date.timeIntervalSince(started))).formatted(.time(pattern: .minuteSecond)))
                            }
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            if let left = bench.timeLeftText(now: context.date) {
                                Text(left).font(.subheadline).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier("model.timeLeft")
                            }
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
private struct PlainBar: View {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(result.sample.title + " · " + result.date.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline.weight(.semibold))
            if let error = result.error {
                Text(error).foregroundStyle(.orange)
            } else if let score = result.score {
                Text("\(Int((score * 100).rounded()))% match").foregroundStyle(score >= 0.8 ? .green : .orange)
                Text(result.found.isEmpty ? "No cuts found" : result.found.map { found in
                    let bits = found.split(separator: " ", maxSplits: 1)
                    guard bits.count == 2 else { return found }
                    return (JudgeLabel(rawValue: String(bits[0]))?.plainName ?? String(bits[0])) + " · lines " + bits[1]
                }.joined(separator: "\n"))
            }
            if let identity = result.modelIdentity {
                DisclosureGroup("Model version and policy") {
                    Text(identity).textSelection(.enabled)
                    Text("Sample version \(result.sampleVersion) · Cutting policy \(result.policyVersion)")
                }
            }
            Text(measurements).foregroundStyle(.secondary).monospacedDigit()
            if !result.isComparable {
                Text("Earlier sample or cutting policy; excluded from current ranking.").foregroundStyle(.secondary)
            }
            if !result.answerStart.isEmpty {
                DisclosureGroup("Response excerpt") {
                    Text(result.answerStart).textSelection(.enabled)
                }
            }
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("model.run." + result.runID.uuidString)
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
