import SwiftUI

/// Settings → Open-source models.
///
/// Pass 27g (his requests, 30 Sep): the models ranked best first by their
/// test results (accuracy, then speed), each one's results kept and one tap
/// away, a switch to turn each model on or off, every model downloadable
/// (iOS decides what fits), and Apple Intelligence and the reader put
/// through the same tests for comparison. The test keeps running (and can
/// be stopped) if he leaves the screen.
struct LocalModelView: View {
    @State private var store = ModelStore.shared
    @State private var monitor = LocalJudgeMonitor.shared
    @State private var bench = ModelBench.shared
    @State private var confirmingDelete = false
    @State private var onDisk: Set<String> = []
    @State private var expanded: String?

    var body: some View {
        List {
            SectionHeader(store.selected.name)
            LocalModelStatusRow()
                .contentRow()
            actionRow
                .contentRow()
            testRow
                .contentRow()

            SectionHeader("Compare")
            engineRow(id: "apple", name: "Apple Intelligence", detail: "Apple's own on-device model")
            engineRow(id: "reader", name: "PodSkipper reader", detail: "The app's own small reader")

            SectionHeader("Models, best first")
            Text("Ranked by the two tests: how closely the parts each would cut match the parts that should be cut, then reading speed. Tap a model to choose it; tap Results to see what it found.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentRow()
            ForEach(ranked(enabled: true)) { spec in modelRow(spec) }

            let off = ranked(enabled: false)
            if !off.isEmpty {
                SectionHeader("Turned off")
                ForEach(off) { spec in modelRow(spec) }
            }

            SectionHeader("Downloading")
            Toggle(isOn: $store.allowCellular) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow cellular")
                    Text("Off: it downloads only on Wi-Fi, and waits when there is none.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(Theme.accentHot)
            .contentRow()
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle("Open-source models")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .onAppear(perform: refreshDisk)
        .onChange(of: store.hasFiles) { refreshDisk() }
        .confirmationDialog("Delete \(store.selected.name)?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.delete(); refreshDisk() }
        } message: {
            Text("Its files are removed and the space is freed. Its test results are kept.")
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
                    .disabled(bench.running == store.selected.id)
            }
        }
    }

    private var testRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if bench.isRunning {
                    Button("Stop Test", systemImage: "stop.fill", role: .destructive) { bench.stop() }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("model.selfTestStop")
                    ProgressView()
                    Text(runningLine).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Button {
                        bench.testSelectedModel()
                    } label: {
                        GlassButtonLabel(title: "Test the Model", systemImage: "play.fill")
                    }
                    .buttonStyle(.glassProminent)
                        .disabled(!store.isReady || monitor.isRunning)
                        .accessibilityIdentifier("model.selfTest")
                    if !store.isReady {
                        Text("Download it first.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Runs the Basic test (one obvious ad) and the Hard test (a plug, a guest's special, another show's promo, a joke ad and brand talk to keep). Keep PodSkipper open while it runs.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            resultsBlock(store.selected.id)
        }
    }

    private var runningLine: String {
        guard let id = bench.running else { return "" }
        let name = id == "apple" ? "Apple Intelligence" : id == "reader" ? "PodSkipper reader" : LocalModelSpec.named(id).name
        return name + " · " + bench.step
    }

    // MARK: Rows

    private func engineRow(id: String, name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text(scoreLine(id) ?? detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    bench.testDetector(apple: id == "apple")
                } label: {
                    GlassButtonLabel(title: bench.isRunning ? "Running…" : "Run Test",
                                     systemImage: "play.fill", fills: false)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .disabled(bench.isRunning)
                .accessibilityIdentifier("model.engineTest.\(id)")
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
                                    Text("On iPhone").font(.caption2.weight(.semibold))
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
            disclosure(spec.id)
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
                    Text("\(sample.title): " + (r.score.map { "\(Int(($0 * 100).rounded())) % match" } ?? "didn't finish"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Self.color(r.score))
                    if let error = r.error {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(r.found.isEmpty ? "Found nothing" : "Found: " + r.found.map(Self.plain).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(Self.speedLine(r)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Words and order

    private func ranked(enabled: Bool) -> [LocalModelSpec] {
        let specs = LocalModelSpec.all.filter { bench.isEnabled($0.id) == enabled }
        let order = Dictionary(uniqueKeysWithValues: LocalModelSpec.all.enumerated().map { ($1.id, $0) })
        return specs.sorted {
            let a = bench.rank($0.id), b = bench.rank($1.id)
            return a != b ? a > b : (order[$0.id] ?? 0) < (order[$1.id] ?? 0)
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
        if r.readTPS > 0 { bits.append("read \(Int(r.readTPS.rounded())) tok/s") }
        if r.writeTPS > 0 { bits.append(String(format: "wrote %.0f tok/s", r.writeTPS)) }
        if r.seconds > 0 { bits.append(String(format: "%.0f s", r.seconds)) }
        if r.peakBytes > 0 { bits.append("peak " + ModelStore.gigabytes(Int64(r.peakBytes))) }
        return bits.joined(separator: " · ")
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
