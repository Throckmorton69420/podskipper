import SwiftUI

/// Four engines remain visible; only the explicitly requested run is active.
struct ModelComparisonView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var bench = ModelBench.shared
    @State private var coreAI = CoreAIModelLibrary.shared
    @State private var store = ModelStore.shared
    @State private var expandedModels: Set<AdFinderChoice> = []
    @State private var expandedResults: Set<String> = []

    var body: some View {
        List {
            Text("Basic checks a clear ad. Hard mixes ads and plugs with ordinary discussion, a joke ad, intros and credits. All engines use the same cutting policy.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).contentRow()
            ForEach([AdFinderChoice.apple, .reader, .coreAI, .model]) { engine in
                engineRow(engine).contentRow(top: 12, bottom: 12)
                if expandedModels.contains(engine) {
                    ModelCatalogContent(mode: engine == .coreAI ? .coreAI : .mlx)
                }
            }
            if let error = bench.requestError {
                Text(error).font(.subheadline).foregroundStyle(.orange).contentRow()
            }
            SectionHeader("Results")
            if resultEngines.isEmpty {
                Text("Completed and failed runs appear here. Leaving this page keeps an active test running; return here to stop it.")
                    .font(.subheadline).foregroundStyle(.secondary).contentRow()
            }
            ForEach(resultEngines, id: \.self) { id in
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedResults.contains(id) },
                    set: { if $0 { expandedResults.insert(id) } else { expandedResults.remove(id) } })) {
                        ForEach(bench.history.filter { $0.engine == id }.sorted { $0.date > $1.date }) { result in
                            BenchmarkResultView(result: result).padding(.vertical, 8)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(id == CoreAIQwen3.benchmarkID ? "Core AI · Unknown earlier model" : (bench.history.last { $0.engine == id }?.name ?? id))
                                .font(.body.weight(.semibold))
                            Text(bench.latestSummary(id) ?? "No results").font(.subheadline).foregroundStyle(.secondary)
                        }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
                    }.contentRow().accessibilityIdentifier("model.result." + id)
            }
            Text("These tests measure compatibility and sample classification. Real episodes determine quality. Earlier results are retained with their model and cutting policy.")
                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).contentRow()
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle("Compare models")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .task { coreAI.load(); store.refreshState() }
        .onChange(of: bench.history.count) {
            if let id = bench.history.last?.engine { expandedResults.insert(id) }
        }
    }

    private func engineRow(_ engine: AdFinderChoice) -> some View {
        let active = isActive(engine)
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return VStack(alignment: .leading, spacing: 8) {
            layout {
                engineTitle(engine).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    ForEach(BenchSample.allCases, id: \.self) { sample in
                        Button { run(engine, sample: sample) } label: {
                            Text(sample.title).font(.subheadline.weight(.semibold))
                                .frame(minWidth: 46, minHeight: 28)
                        }
                        .buttonStyle(.glass)
                        .disabled(bench.isRunning || readiness(engine) != nil)
                        .accessibilityLabel(engine.title + " " + sample.title + " test")
                        .accessibilityIdentifier("model.test." + engine.rawValue + "." + sample.rawValue)
                    }
                }
            }
            Text(engine.explanation).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if active {
                HStack(alignment: .top, spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 4) {
                        Text((bench.runningName ?? engine.title) + " · " + (bench.runningSample?.title ?? ""))
                            .font(.subheadline.weight(.semibold))
                        Text(bench.step).font(.subheadline)
                        if let started = bench.startedAt {
                            TimelineView(.periodic(from: started, by: 1)) { context in
                                Text("Elapsed " + Duration.seconds(max(0, context.date.timeIntervalSince(started))).formatted(.time(pattern: .minuteSecond)))
                                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }.fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { bench.stop() } label: { Text(bench.stopping ? "Stopping…" : "Stop").frame(minHeight: 44) }
                        .buttonStyle(.glass).disabled(bench.stopping)
                        .accessibilityLabel("Stop " + (bench.runningName ?? engine.title) + " test")
                        .accessibilityIdentifier("model.benchmarkStop")
                }.accessibilityIdentifier("model.active." + engine.rawValue)
            } else if let reason = readiness(engine) {
                Text(reason).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func engineTitle(_ engine: AdFinderChoice) -> some View {
        if engine == .coreAI || engine == .model {
            Button {
                if expandedModels.contains(engine) { expandedModels.remove(engine) }
                else { expandedModels.insert(engine) }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: expandedModels.contains(engine) ? "chevron.down" : "chevron.right")
                        .font(.subheadline.weight(.semibold)).accessibilityHidden(true)
                    Text(name(engine)).font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(minHeight: 44, alignment: .topLeading)
            }.buttonStyle(.plain)
                .accessibilityValue(expandedModels.contains(engine) ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("model." + (engine == .coreAI ? "coreAI" : "mlx") + ".disclosure")
        } else {
            Text(name(engine)).font(.body.weight(.semibold)).frame(minHeight: 44, alignment: .topLeading)
                .accessibilityIdentifier("model.engine." + engine.rawValue)
        }
    }

    private func name(_ engine: AdFinderChoice) -> String {
        switch engine {
        case .coreAI: return "Core AI (" + (coreAI.isReady ? coreAI.selectedEntry?.name ?? "Choose a model" : "Choose a model") + ")"
        case .model: return "MLX (" + (store.isReady ? store.selected.name : "Choose a model") + ")"
        default: return engine.title
        }
    }

    private func isActive(_ engine: AdFinderChoice) -> Bool {
        guard let id = bench.running else { return false }
        switch engine {
        case .apple: return id == "apple"
        case .reader: return id == "reader"
        case .coreAI: return id.hasPrefix("coreai.")
        case .model: return LocalModelSpec.all.contains { $0.id == id }
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
            return store.isReady ? nil : "Download and enable a model to test it."
            #endif
        case .coreAI:
            #if targetEnvironment(simulator)
            return "Core AI inference requires a physical device."
            #else
            return coreAI.isReady ? nil : "Download and enable a compatible iOS model to test it."
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

    private var resultEngines: [String] {
        Array(Set(bench.history.map(\.engine))).sorted { lhs, rhs in
            let a = bench.history.last { $0.engine == lhs }?.date ?? .distantPast
            let b = bench.history.last { $0.engine == rhs }?.date ?? .distantPast
            return a == b ? lhs < rhs : a > b
        }
    }
}

private struct BenchmarkResultView: View {
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
