import SwiftUI

/// Settings → Open-source models (pass 27c).
///
/// Download, pause and delete the model, choose which one, and allow cellular.
/// "Test the Model" (pass 27, a plain button): the model reads a 40-line
/// sample with one obvious ad and says what it found and how fast it read.
struct LocalModelView: View {
    @State private var store = ModelStore.shared
    @State private var monitor = LocalJudgeMonitor.shared
    @State private var confirmingDelete = false
    /// The self-test running now, so it can be stopped (pass 27b).
    @State private var testTask: Task<Void, Never>?
    @State private var testResult: JudgeReport?
    @State private var testError: String?

    var body: some View {
        List {
            SectionHeader("Status")
            LocalModelStatusRow()
                .contentRow()
            actionRow
                .contentRow()

            // Pass 27: a plain button, always here. The long press on the
            // title it used to hide behind did nothing on his phone (twice).
            selfTestSection

            modelSection

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
            Text("The download carries on while the phone is locked. The model reads transcripts on this iPhone; nothing is sent anywhere.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentRow()

            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle("Open-source models")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .confirmationDialog("Delete \(store.selected.name)?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.delete() }
        } message: {
            Text("Its files are removed and the space is freed. You can download it again later.")
        }
    }

    // MARK: Buttons

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
                    .disabled(monitor.isRunning)
            }
            Spacer()
            if store.hasFiles {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                    .buttonStyle(.glass)
                    .disabled(monitor.isRunning)
            }
        }
    }

    // MARK: Which model

    private func finderRow(title: String, summary: String, selected: Bool, warn: Bool,
                           choose: @escaping () -> Void) -> some View {
        Button {
            choose()
            Haptics.select()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Theme.accentHot : .secondary)
                    .font(.system(size: UIScale.pt(18)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).foregroundStyle(.primary)
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(warn ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Pass 27f: never greyed out (his phone: every row was, while the
        // catch-up read an episode with the model). Choosing another model
        // doesn't touch a read already running.
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contentRow(top: 10, bottom: 10)
    }

    /// Only the downloadable open-source models (pass 27c, his call: Apple
    /// Intelligence and the reader are chosen in Settings → Find ads with,
    /// and this screen only opens when "Open-source model" is chosen there).
    @ViewBuilder
    private var modelSection: some View {
        SectionHeader("Model")
        ForEach(LocalModelSpec.all) { spec in
            finderRow(title: spec.name, summary: spec.summary,
                      selected: spec == store.selected, warn: true) {
                store.select(spec)
            }
        }
        if let other = store.otherOnDisk {
            HStack {
                Text("\(other.spec.name) is also on this iPhone (\(ModelStore.bytes(other.bytes))).")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Delete It", role: .destructive) { store.deleteOther() }
                    .font(.footnote)
                    .disabled(monitor.isRunning)
            }
            .contentRow()
        }
    }

    // MARK: Self-test

    @ViewBuilder
    private var selfTestSection: some View {
        SectionHeader("Test the downloaded model")
        VStack(alignment: .leading, spacing: 10) {
            Text("Reads a 40-line sample with one ad in it and shows how fast it read. Keep PodSkipper open while it runs. Expected: \(LocalJudgeSelfTest.expected)")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                // Tappable before the download finishes too: the judge then
                // says in plain words that the model isn't downloaded.
                if testTask != nil {
                    Button("Stop Test", systemImage: "stop.fill", role: .destructive) { stopSelfTest() }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("model.selfTestStop")
                    ProgressView().padding(.leading, 8)
                    Text("Reading…").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Button("Test the Model") { runSelfTest() }
                        .buttonStyle(.glassProminent)
                        .disabled(monitor.isRunning)
                        .accessibilityIdentifier("model.selfTest")
                    if monitor.isRunning {
                        // Another read (an episode) holds the model.
                        Text("The model is reading an episode").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .contentRow()

        if let testError {
            Text(testError)
                .font(.footnote).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .contentRow()
        }
        if let report = testResult {
            SelfTestResultView(report: report)
                .contentRow()
        }
    }

    private func runSelfTest() {
        testResult = nil
        testError = nil
        testTask = Task {
            defer { testTask = nil }
            do {
                testResult = try await LocalJudge.shared.judgeReport(
                    lines: LocalJudgeSelfTest.lines, show: LocalJudgeSelfTest.show,
                    title: LocalJudgeSelfTest.title, notes: LocalJudgeSelfTest.notes,
                    evidence: [], only: nil, progress: { _ in })
                SelfTestRecord.save(testResult, error: nil)
                Haptics.success()
            } catch is CancellationError {
                testError = "Stopped."
            } catch {
                testError = Task.isCancelled ? "Stopped." : error.localizedDescription
                if !Task.isCancelled { SelfTestRecord.save(nil, error: error.localizedDescription) }
            }
        }
    }

    /// Ends the test at the model's next check (it finishes the reading
    /// step it is on, a few seconds at most for the sample).
    private func stopSelfTest() {
        testTask?.cancel()
        Haptics.select()
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
