import SwiftUI
import SwiftData

/// Settings → Diagnostics (pass 16): what this phone measured.
///
/// The point is that "how fast is ad finding on the phone" and "does it get
/// hot" get answered with numbers he can send, not descriptions. Share makes
/// one JSON file (timings, device, every MetricKit report) to AirDrop to the
/// Mac or save to Files.
struct DiagnosticsView: View {
    @State private var log = TimingLog.shared
    @State private var reports: [MetricsSubscriber.SavedReport] = []
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var resultsURL: URL?
    @State private var preparingResults = false
    @State private var edits: [(show: String, episode: String, edits: EditCounts)] = []
    @State private var backgroundEvents: [BackgroundLog.Event] = []
    @Environment(\.modelContext) private var context

    /// Pass 32 (his 7 Oct request): the export buttons are first, and each
    /// part below folds away (remembered), so nothing needs a long scroll.
    @AppStorage("diagnostics.open.phone") private var openPhone = true
    @AppStorage("diagnostics.open.speed") private var openSpeed = true
    @AppStorage("diagnostics.open.corrections") private var openCorrections = false
    @AppStorage("diagnostics.open.background") private var openBackground = false
    @AppStorage("diagnostics.open.episodes") private var openEpisodes = false
    @AppStorage("diagnostics.open.reports") private var openReports = false

    var body: some View {
        List {
            exportSection

            Section {
                DisclosureGroup(isExpanded: $openPhone) {
                    row("Phone", Diagnostics.deviceModel)
                    row("iOS", UIDevice.current.systemVersion)
                    row("Build", BuildInfo.commit)
                    row("Ad reader", SentenceTagger.isBundled ? "Ready" : "Missing")
                    row("Heat right now", Diagnostics.thermalName.capitalized)
                } label: { foldLabel("This Phone", "iphone") }
                    .accessibilityIdentifier("DiagnosticsFold.phone")
            }

            // Task 15 (PR #11): size of the logs and Delete Older Logs.
            DiagnosticsLogsSection()

            Section {
                DisclosureGroup(isExpanded: $openSpeed) {
                    row("Transcribing", perHour(log.median(\.transcribePerHour)))
                    row("Finding ads", perHour(log.median(\.detectPerHour)))
                    Text("Median seconds of work per hour of audio, over the episodes processed.")
                        .font(.footnote).foregroundStyle(.secondary)
                } label: { foldLabel("Typical Speed", "speedometer") }
                    .accessibilityIdentifier("DiagnosticsFold.speed")
            }

            Section {
                DisclosureGroup(isExpanded: $openCorrections) {
                    let total = edits.reduce(EditCounts()) { $0 + $1.edits }
                    let reviewed = edits.filter { $0.edits.detected + $0.edits.added > 0 }.count
                    row("Episodes with cuts", "\(reviewed)")
                    row("Fixes per episode", reviewed == 0 ? "—" : String(format: "%.1f", Double(total.fixes) / Double(reviewed)))
                    row("Cuts confirmed", "\(total.confirmed) of \(total.detected)")
                    row("Cuts rejected", "\(total.rejected)")
                    row("Edges moved", "\(total.moved)")
                    row("Cuts you added", "\(total.added)")
                    Text("How often the ad finder needed fixing: every cut you rejected, moved or added counts as a fix.")
                        .font(.footnote).foregroundStyle(.secondary)
                } label: { foldLabel("Your Corrections", "pencil.and.list.clipboard") }
                    .accessibilityIdentifier("DiagnosticsFold.corrections")
            }

            Section {
                DisclosureGroup(isExpanded: $openBackground) {
                    ForEach(BackgroundWork.facts, id: \.0) { fact in
                        row(fact.0, fact.1)
                    }
                    if let refusal = BackgroundWork.shared.lastRefusal {
                        Text("Last refused: \(refusal)")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if backgroundEvents.isEmpty {
                        Text("Nothing yet. Start Find Ads, lock the phone, and what iOS does is written here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(backgroundEvents.prefix(25)) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.text)
                                .font(.footnote)
                            Text(event.date, format: .dateTime.month().day().hour().minute().second())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Whether iOS let a job you started carry on after the screen locked, and when it stopped it.")
                        .font(.footnote).foregroundStyle(.secondary)
                } label: { foldLabel("Working in the Background", "moon.zzz") }
                    .accessibilityIdentifier("DiagnosticsFold.background")
            }

            Section {
                DisclosureGroup(isExpanded: $openEpisodes) {
                    if log.entries.isEmpty {
                        Text("Nothing yet. Each episode the app finds ads in adds a line here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(log.entries.prefix(50)) { entry in
                        TimingRow(entry: entry)
                    }
                } label: { foldLabel("Episodes Processed", "list.bullet.rectangle", count: log.entries.count) }
                    .accessibilityIdentifier("DiagnosticsFold.episodes")
            }

            Section {
                DisclosureGroup(isExpanded: $openReports) {
                    if reports.isEmpty {
                        Text("None yet. iOS sends the first daily report about a day after install, and crash or hang reports when they happen.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(reports.prefix(20)) { report in
                        HStack {
                            Image(systemName: report.kind == "daily" ? "calendar" : "exclamationmark.triangle")
                                .foregroundStyle(report.kind == "daily" ? Color.secondary : Color.orange)
                            Text(report.kind == "daily" ? "Daily report" : "Problem report")
                            Spacer()
                            Text(report.date, format: .dateTime.month().day().hour().minute())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Battery use, heat, hangs and crashes, measured by iOS itself.")
                        .font(.footnote).foregroundStyle(.secondary)
                } label: { foldLabel("Reports from iOS", "stethoscope", count: reports.count) }
                    .accessibilityIdentifier("DiagnosticsFold.reports")
            }

            Section {
                Button("Clear Timings", role: .destructive) { log.clear() }
                    .disabled(log.entries.isEmpty)
                if let message = log.storageError {
                    Label(message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("DiagnosticsTimingError")
                }
            }
        }
        .navigationTitle("Diagnostics")
        .amoledScreen()
        .task {
            reports = MetricsSubscriber.savedReports()
            backgroundEvents = BackgroundLog.shared.events
            edits = DetectionReport.editsByEpisode(context)
            do { exportURL = try Diagnostics.exportFile(edits: edits) }
            catch { exportError = error.localizedDescription }
        }
        .onChange(of: log.entries.count) { _, _ in
            exportURL = try? Diagnostics.exportFile(edits: edits)
        }
    }

    /// Both files he sends to the Mac, at the top of the page.
    private var exportSection: some View {
        Section {
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("ShareDiagnostics")
            } else if let exportError {
                Text(exportError).foregroundStyle(.orange)
            } else {
                Label("Preparing diagnostics…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            }
            if let resultsURL {
                ShareLink(item: resultsURL) {
                    Label("Share Ad-Finding Results", systemImage: "square.and.arrow.up.on.square")
                }
                .accessibilityIdentifier("ShareResults")
            } else {
                Button {
                    Task { await prepareResults() }
                } label: {
                    Label(preparingResults ? "Preparing Results…" : "Prepare Ad-Finding Results",
                          systemImage: "doc.badge.gearshape")
                }
                .disabled(preparingResults)
                .accessibilityIdentifier("PrepareResults")
            }
        } header: {
            Text("Send to the Mac")
        } footer: {
            Text("Diagnostics: one file with everything on this page. Results: every episode the phone found ads in — what it cut, where, and the transcript — so it can be checked on the Mac. AirDrop either to the Mac, or save it to Files.")
        }
    }

    private func foldLabel(_ title: String, _ symbol: String, count: Int? = nil) -> some View {
        HStack {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
            Spacer()
            if let count, count > 0 {
                Text("\(count)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func prepareResults() async {
        preparingResults = true
        defer { preparingResults = false }
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.lastProcessedAt != nil },
            sortBy: [SortDescriptor(\.lastProcessedAt, order: .reverse)])
        descriptor.fetchLimit = 150
        let episodes = (try? context.fetch(descriptor)) ?? []
        do { resultsURL = try await DetectionExport.file(episodes: episodes) }
        catch { exportError = error.localizedDescription }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }

    private func perHour(_ seconds: Double?) -> String {
        guard let seconds else { return "Not measured yet" }
        return "\(Int(seconds.rounded())) s per hour"
    }
}

private struct TimingRow: View {
    let entry: ProcessingTiming

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.episode).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("\(entry.show) · \(formatDuration(entry.audioSeconds)) of audio")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 12) {
                stat("Transcribe", entry.transcribeSeconds.map(seconds) ?? "reused")
                stat("Find ads", seconds(entry.detectSeconds))
                stat("Heat", entry.thermalAtEnd)
            }
            .font(.caption.monospacedDigit())
            if let adFree = entry.adFree {
                Text(adFreeLine(adFree)).font(.caption2).foregroundStyle(.secondary)
            }
            if let finder = entry.finder {
                Text(finderLine(finder)).font(.caption2).foregroundStyle(.secondary)
            }
            Text(conditions).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// "Ad-free copy: 4 ads, 10 min, 104 requests" or why there was none.
    private func adFreeLine(_ o: AdFreeCopy.Outcome) -> String {
        if o.source.isEmpty { return "Ad-free copy: \(o.note.isEmpty ? "none" : o.note)" }
        let minutes = o.insertedSeconds >= 90 ? "\(Int(o.insertedSeconds / 60)) min" : "\(Int(o.insertedSeconds)) s"
        return "Ad-free copy (\(o.source)): \(o.inserted.count) inserted, \(minutes), "
            + "\(o.requests) requests, \(o.bytes / 1024) KB, \(Int(o.seconds.rounded())) s"
    }

    /// Task 05: "On-device model, full read: 7 windows, 94 s, 310 tokens/s,
    /// 1 try" or why the reader's cuts were kept.
    private func finderLine(_ run: ModelFinder.Run) -> String {
        var line = run.byModel ? "On-device model, \(run.mode == "fast" ? "fast read (locked)" : "full read")" : "Reader"
        if run.attempts > 0 {
            if run.byModel {
                line += ": \(run.windows) window\(run.windows == 1 ? "" : "s"), \(Int(run.seconds.rounded())) s, "
                    + "\(Int(run.tokensPerSecond.rounded())) tokens/s"
            }
            line += " · \(run.attempts) tr\(run.attempts == 1 ? "y" : "ies")"
        }
        if let failure = run.failure { line += " · model: \(failure)" }
        return line
    }

    private var conditions: String {
        var parts = [entry.date.formatted(.dateTime.month().day().hour().minute())]
        parts.append(entry.onPower ? "plugged in" : "on battery")
        if entry.lowPowerMode { parts.append("Low Power Mode") }
        parts.append(entry.foreground ? "app open" : "in background")
        return parts.joined(separator: " · ")
    }

    private func seconds(_ s: Double) -> String {
        s >= 90 ? "\(Int(s / 60))m \(Int(s) % 60)s" : "\(Int(s.rounded()))s"
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
