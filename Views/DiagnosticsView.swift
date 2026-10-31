import SwiftUI
import SwiftData

/// Settings → Diagnostics.
///
/// Pass 35 (his request): a diagnostics centre instead of one long page of
/// folds. The overview leads with this iPhone's resources, then each subject
/// has a page of its own: speed, background work, model tests, episodes
/// processed, his corrections, sound output, reports from iOS, logs, and
/// exporting or clearing what is kept. Exports are built only when asked,
/// off the main thread (the old page rebuilt the whole file every visit).
struct DiagnosticsView: View {
    @State private var log = TimingLog.shared
    @State private var bench = ModelBench.shared
    @State private var resources: DeviceResources?
    @State private var reportCount = 0

    var body: some View {
        List {
            Section {
                if let resources {
                    ForEach(resources.lines.prefix(6)) { line in
                        LabeledContent(line.title, value: line.value)
                    }
                    NavigationLink("All Device Details") { DeviceResourcesPage() }
                        .accessibilityIdentifier("diagnostics.device")
                } else {
                    ProgressView()
                }
            } header: {
                Text("This iPhone Now")
            }

            Section("Work") {
                link("Speed", "speedometer", detail: speedSummary) { PerformancePage() }
                link("Processing & Background", "moon.zzz", detail: nil) { BackgroundPage() }
                link("Model Tests", "cpu", detail: "\(bench.history.count) runs") { ModelTestsPage() }
                link("Episodes Processed", "list.bullet.rectangle", detail: "\(log.entries.count)") { EpisodesProcessedPage() }
                    .accessibilityIdentifier("DiagnosticsFold.episodes")
                link("Your Corrections", "pencil.and.list.clipboard", detail: nil) { CorrectionsPage() }
            }

            Section("Listening and the System") {
                link("Sound Output & Playback", "hifispeaker", detail: "\(PlaybackTrace.shared.entries.count) events") { AudioOutputPage() }
                link("Reports from iOS", "stethoscope", detail: "\(reportCount)") { ReportsPage() }
                    .accessibilityIdentifier("DiagnosticsFold.reports")
                link("Log Files", "doc.text", detail: nil) { LogFilesView() }
                    .accessibilityIdentifier("diagnostics.logsLink")
            }

            Section {
                link("Share Diagnostics…", "square.and.arrow.up", detail: nil) { DiagnosticsExportPage() }
                    .accessibilityIdentifier("ShareDiagnostics")
                link("Share Ad-Finding Results…", "square.and.arrow.up.on.square", detail: nil) { ResultsExportPage() }
                    .accessibilityIdentifier("PrepareResults")
                link("Clear Diagnostic Records…", "trash", detail: nil) { DiagnosticsDataPage() }
                    .accessibilityIdentifier("diagnostics.clear")
            } header: {
                Text("Export & Data")
            } footer: {
                Text("Choose what goes into an export: everything, recent days, a date range, or particular parts. Your corrections and ads found are never removed from here.")
            }
            BottomClearance()
        }
        .navigationTitle("Diagnostics")
        .watchName("Diagnostics")
        .amoledScreen()
        .task {
            resources = DeviceResources.measure()
            reportCount = await Task.detached { MetricsSubscriber.savedReports().count }.value
        }
    }

    private var speedSummary: String? {
        log.median(\.detectPerHour).map { "finding ads \(Int($0.rounded())) s per audio hour" }
    }

    private func link<Destination: View>(_ title: String, _ symbol: String, detail: String?,
                                         @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }
}

// MARK: - Device

struct DeviceResourcesPage: View {
    @State private var resources: DeviceResources?

    var body: some View {
        List {
            if let resources {
                Section {
                    ForEach(resources.lines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            LabeledContent(line.title, value: line.value)
                            Text(line.source.rawValue).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                } footer: {
                    Text("iOS doesn't let apps read processor or graphics load, so they aren't shown. Memory is what this app may still use before iOS closes it.")
                }
            }
            Section("Background and Model Capabilities") {
                ForEach(BackgroundWork.facts, id: \.0) { fact in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.0).font(.subheadline)
                        Text(fact.1).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            BottomClearance()
        }
        .navigationTitle("This iPhone")
        .watchName("This iPhone")
        .navigationBarTitleDisplayMode(.inline)
        .task { resources = DeviceResources.measure() }
        .refreshable { resources = DeviceResources.measure() }
    }
}

// MARK: - Speed

struct PerformancePage: View {
    @State private var log = TimingLog.shared
    @AppStorage(ThermalPacing.policyKey) private var heatPolicy = ThermalPacing.Policy.keepReading.rawValue
    @State private var bench = ModelBench.shared

    private struct Stat { var median: Double; var count: Int }

    private func stat(_ values: [Double]) -> Stat? {
        let xs = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !xs.isEmpty else { return nil }
        return Stat(median: xs[xs.count / 2], count: xs.count)
    }

    var body: some View {
        let entries = log.entries
        let period = entries.map(\.date).min().map { "since " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
        List {
            Section {
                row("Transcribing", stat(entries.compactMap(\.transcribePerHour)), unit: "s per hour of audio")
                row("Measuring silences and loudness", stat(entries.compactMap { e in e.analyzeSeconds.map { $0 / max(1, e.audioSeconds / 3600) } }), unit: "s per hour of audio")
                row("Finding ads (reader and model)", stat(entries.compactMap(\.detectPerHour)), unit: "s per hour of audio")
                row("Whole job", stat(entries.map { e in ((e.transcribeSeconds ?? 0) + (e.analyzeSeconds ?? 0) + e.detectSeconds) / max(1, e.audioSeconds / 3600) }), unit: "s per hour of audio")
                row("Ad-free copy comparison", stat(entries.compactMap { $0.adFree?.seconds }), unit: "s per episode")
            } header: {
                Text("Episodes · median")
            } footer: {
                Text("Medians over \(entries.count) processed episode\(entries.count == 1 ? "" : "s") \(period). n = how many episodes measured that step (a reused transcript has no transcription time).")
            }
            Section {
                let byModel = Dictionary(grouping: entries.compactMap { e -> (String, ModelFinder.Run)? in
                    guard let run = e.finder, run.byModel else { return nil }
                    return (run.mode ?? "full", run)
                }, by: \.0)
                if byModel.isEmpty { Text("No episode has been read by an on-device model yet.").foregroundStyle(.secondary) }
                ForEach(byModel.keys.sorted(), id: \.self) { mode in
                    let runs = byModel[mode]!.map(\.1)
                    row(mode == "fast" ? "Model, fast read" : "Model, full read", stat(runs.map(\.tokensPerSecond)), unit: "tokens/s")
                    row("   time per episode", stat(runs.map(\.seconds)), unit: "s")
                }
            } header: {
                Text("On-device model in episodes")
            }
            Section {
                let ok = bench.history.filter { $0.error == nil }
                let engines = Dictionary(grouping: ok, by: \.name)
                if engines.isEmpty { Text("No completed model tests yet.").foregroundStyle(.secondary) }
                ForEach(engines.keys.sorted(), id: \.self) { name in
                    let runs = engines[name]!
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.subheadline.weight(.semibold))
                        Text(["reading " + (stat(runs.map(\.readTPS)).map { "\(Int($0.median)) tok/s" } ?? "—"),
                              "writing " + (stat(runs.map(\.writeTPS)).map { "\(Int($0.median)) tok/s" } ?? "—"),
                              "test " + (stat(runs.map(\.seconds)).map { "\(Int($0.median)) s" } ?? "—"),
                              "n = \(runs.count)"].joined(separator: " · "))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Model tests · reading (prompt) and writing (answer) speed")
            }
            Section {
                Picker("When the iPhone is hot", selection: $heatPolicy) {
                    ForEach(ThermalPacing.Policy.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                let heat = HeatLog.timeline(from: HeatLog.launchedAt)
                LabeledContent("Heat this launch") {
                    Text(["nominal", "fair", "serious", "critical"].compactMap { state in
                        heat.seconds[state].map { "\(state) \(ThermalPacing.clock($0))" }
                    }.joined(separator: " · "))
                    .font(.footnote.monospacedDigit())
                }
            } header: {
                Text("Heat")
            } footer: {
                Text("Keep reading lets iOS set the pace and pauses only when the iPhone is too hot. The 20-second rest is the earlier behaviour, kept so the two can be compared on the same episode. Every read records which one it used.")
            }
            Section {
                LabeledContent("Waiting for the phone to cool, this launch", value: "\(Int(ThermalPacing.cooledSeconds())) s")
                let background = entries.filter { !$0.foreground }.count
                LabeledContent("Episodes finished in the background", value: "\(background) of \(entries.count)")
                NavigationLink("Each Episode") { EpisodesProcessedPage() }
            } header: {
                Text("Waiting and background")
            }
            BottomClearance()
        }
        .navigationTitle("Speed")
        .watchName("Speed")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ stat: Stat?, unit: String) -> some View {
        LabeledContent(title) {
            Text(stat.map { "\(Int($0.median.rounded())) \(unit) · n = \($0.count)" } ?? "Not measured yet")
                .font(.footnote.monospacedDigit())
        }
    }
}

// MARK: - Background

struct BackgroundPage: View {
    @Environment(ProcessingPipeline.self) private var pipeline
    @State private var events: [BackgroundLog.Event] = []
    @State private var filter: Kind = .all

    enum Kind: String, CaseIterable, Identifiable {
        case all = "All", jobs = "Jobs", ios = "iOS", models = "Models", heat = "Heat", sound = "Sound", launches = "Launches"
        var id: Self { self }
        func matches(_ text: String) -> Bool {
            let t = text.lowercased()
            switch self {
            case .all: return true
            case .jobs: return t.contains("started") || t.contains("finished") || t.contains("stopped") || t.contains("left the app")
            case .ios: return t.contains("ios ") || t.contains("processing window") || t.contains("refus") || t.contains("expired")
            case .models: return t.contains("model") || t.contains("core ai") || t.contains("mlx")
            case .heat: return t.contains("heat") || t.contains("cool") || t.contains("thermal")
            case .sound: return t.contains("sound") || t.contains("output") || t.contains("audio")
            case .launches: return t.hasPrefix("launch")
            }
        }
        var symbol: String {
            switch self {
            case .all: "list.bullet"; case .jobs: "wand.and.sparkles"; case .ios: "apple.logo"; case .models: "cpu"
            case .heat: "thermometer.medium"; case .sound: "hifispeaker"; case .launches: "power"
            }
        }
    }

    var body: some View {
        List {
            Section("Now") {
                ProcessingBanner(pipeline: pipeline, inList: true)
                LabeledContent("Waiting in line", value: "\(pipeline.waitingQueue.count)")
                if let refusal = BackgroundWork.shared.lastRefusal {
                    Label("iOS last refused: \(refusal)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
                }
            }
            Section {
                Picker("Show", selection: $filter) { ForEach(Kind.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.menu)
                let shown = events.filter { filter.matches($0.text) }
                if shown.isEmpty { Text("Nothing of this kind recorded.").foregroundStyle(.secondary) }
                ForEach(shown.prefix(300)) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: (Kind.allCases.dropFirst().first { $0.matches(event.text) } ?? .all).symbol)
                            .foregroundStyle(.secondary).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.text).font(.footnote).fixedSize(horizontal: false, vertical: true)
                            Text(event.date, format: .dateTime.month().day().hour().minute().second())
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("What happened, newest first")
            } footer: {
                Text("Jobs you started, when iOS let them carry on after the screen locked or stopped them, model loads, heat waits, sound output changes and launches.")
            }
            BottomClearance()
        }
        .navigationTitle("Processing & Background")
        .watchName("Processing & Background")
        .navigationBarTitleDisplayMode(.inline)
        .task { events = BackgroundLog.shared.events }
    }
}

// MARK: - Model tests

/// Model test runs, grouped by engine then model; each run is the same row
/// Compare Models shows (BenchHistoryList), with heat and memory.
struct ModelTestsPage: View {
    @State private var bench = ModelBench.shared

    enum Family: String, CaseIterable { case apple = "Apple Intelligence", reader = "PodSkipper Reader", coreAI = "Core AI", mlx = "MLX" }

    static func family(_ engine: String) -> Family {
        if engine == "apple" { return .apple }
        if engine == "reader" { return .reader }
        if engine.hasPrefix("coreai") { return .coreAI }
        return .mlx
    }

    var body: some View {
        let grouped = Dictionary(grouping: bench.history, by: { Self.family($0.engine) })
        List {
            if bench.history.isEmpty { Text("No model tests yet. Run one from Ad Skipping → Compare Models.").foregroundStyle(.secondary) }
            ForEach(Family.allCases, id: \.self) { family in
                if let runs = grouped[family] {
                    SectionHeader(family.rawValue)
                    let engines = Dictionary(grouping: runs, by: \.engine)
                    ForEach(engines.keys.sorted { (engines[$0]?.last?.name ?? $0) < (engines[$1]?.last?.name ?? $1) }, id: \.self) { engine in
                        BenchHistoryList(engineID: engine, title: engines[engine]?.last?.name ?? engine)
                    }
                }
            }
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle("Model Tests")
        .watchName("Model Tests")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
    }
}

// MARK: - Episodes processed

struct EpisodesProcessedPage: View {
    @Environment(\.modelContext) private var context
    @State private var episodes: [Episode] = []
    @State private var timings: [String: ProcessingTiming] = [:]
    @State private var search = ""

    var body: some View {
        List {
            if episodes.isEmpty { Text("Nothing processed yet.").foregroundStyle(.secondary) }
            ForEach(episodes.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                || ($0.podcast?.title ?? "").localizedCaseInsensitiveContains(search) }) { episode in
                NavigationLink {
                    EpisodeProcessingDetail(episode: episode, timing: timings[key(episode)])
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Artwork(url: episode.artworkURL ?? episode.podcast?.artworkURL, size: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(episode.podcast?.title ?? "").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                            Text(episode.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text([RelativeDate.release(episode.publishedAt), formatDuration(episode.duration),
                                  episode.lastProcessedAt.map { "processed " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(status(episode)).font(.caption).foregroundStyle(episode.processingError == nil ? Color.secondary : .orange).lineLimit(2)
                        }
                    }
                }
            }
            BottomClearance()
        }
        .navigationTitle("Episodes Processed")
        .watchName("Episodes Processed")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Episodes or shows")
        .task {
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.lastProcessedAt != nil },
                                                      sortBy: [SortDescriptor(\.lastProcessedAt, order: .reverse)])
            descriptor.fetchLimit = 300
            episodes = (try? context.fetch(descriptor)) ?? []
            // Timings name episodes by show and title; newest wins.
            var map: [String: ProcessingTiming] = [:]
            for entry in TimingLog.shared.entries.sorted(by: { $0.date < $1.date }) { map[entry.show + "|" + entry.episode] = entry }
            timings = map
        }
    }

    private func key(_ e: Episode) -> String { (e.podcast?.title ?? "") + "|" + e.title }

    private func status(_ e: Episode) -> String {
        if let error = e.processingError { return "Problem: " + error }
        let cuts = e.adSegments.count
        return (e.processingState == .ready ? "Ad-free" : String(describing: e.processingState))
            + " · \(cuts) cut\(cuts == 1 ? "" : "s")" + (e.finderNote.isEmpty ? "" : " · " + e.finderNote)
    }
}

/// One episode's processing, stage by stage.
struct EpisodeProcessingDetail: View {
    let episode: Episode
    let timing: ProcessingTiming?

    var body: some View {
        let attempts = FinderAttemptLog.shared.attempts(for: episode.guid)
        let deltas = CorrectionLedger.deltas(for: episode)
        let readerCount = (episode.readerSegmentsData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] })?.count
        List {
            Section("Episode") {
                LabeledContent("Show", value: episode.podcast?.title ?? "")
                LabeledContent("Published", value: episode.publishedAt.formatted(date: .abbreviated, time: .omitted))
                LabeledContent("Length", value: formatDuration(episode.editableLength))
                if let processed = episode.lastProcessedAt {
                    LabeledContent("Last processed", value: processed.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section("Download") {
                LabeledContent("Audio on this iPhone", value: episode.isDownloaded ? "Yes" : "No (streams)")
                if episode.audioFileLength > 0 { LabeledContent("File length", value: formatDuration(episode.audioFileLength)) }
                if episode.duration > 0, episode.audioFileLength > episode.duration + 5 {
                    LabeledContent("Longer than the feed says", value: "+" + formatDuration(episode.audioFileLength - episode.duration))
                }
            }
            Section("Transcription") {
                LabeledContent("Transcript", value: episode.hasTranscript ? "Kept" : "None")
                if let timing { LabeledContent("Time", value: timing.transcribeSeconds.map { "\(Int($0)) s" } ?? "reused") }
            }
            Section("Finding ads") {
                LabeledContent("Reader", value: readerCount.map { "\($0) stretch\($0 == 1 ? "" : "es") proposed" } ?? "—")
                LabeledContent("Finder", value: episode.finderNote.isEmpty ? "—" : episode.finderNote)
                if let timing {
                    LabeledContent("Time", value: "\(Int(timing.detectSeconds)) s")
                    if let run = timing.finder, run.byModel {
                        LabeledContent("Model", value: "\(run.windows) part\(run.windows == 1 ? "" : "s") · \(Int(run.tokensPerSecond)) tok/s · \(run.attempts) tr\(run.attempts == 1 ? "y" : "ies")")
                        if let failure = run.failure { Text("Model: " + failure).font(.caption).foregroundStyle(.orange) }
                    }
                    if let adFree = timing.adFree {
                        LabeledContent("Ad-free copy", value: adFree.source.isEmpty ? (adFree.note.isEmpty ? "none" : adFree.note) : "\(adFree.inserted.count) inserted ads")
                    }
                }
                ForEach(attempts.prefix(10)) { attempt in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attempt.method).font(.subheadline.weight(.semibold))
                        Text("\(attempt.date.formatted(date: .abbreviated, time: .shortened)) · proposed \(attempt.proposedCuts.count) · kept \(attempt.savedCuts.count) · \(Int(attempt.seconds)) s · heat \(attempt.thermalAtStart)→\(attempt.thermalAtEnd)\(attempt.foreground ? "" : " · background")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Results") {
                let byKind = Dictionary(grouping: episode.adSegments, by: \.kind)
                ForEach(byKind.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { kind in
                    let cuts = byKind[kind]!
                    LabeledContent(kind.label, value: "\(cuts.count) · \(formatDuration(cuts.reduce(0) { $0 + $1.duration }))")
                }
                if episode.adSegments.isEmpty { Text("Nothing cut.").foregroundStyle(.secondary) }
            }
            Section("Your corrections") {
                if deltas.isEmpty { Text("None on this episode.").foregroundStyle(.secondary) }
                ForEach(deltas.reversed()) { CorrectionRow(delta: $0) }
            }
            if let timing {
                Section("Conditions") {
                    LabeledContent("Heat", value: "\(timing.thermalAtStart) → \(timing.thermalAtEnd)")
                    LabeledContent("Power", value: (timing.onPower ? "plugged in" : "on battery") + (timing.lowPowerMode ? ", Low Power Mode" : ""))
                    LabeledContent("Where", value: timing.foreground ? "app open" : "in the background")
                    LabeledContent("Build", value: timing.build)
                }
            }
            if let error = episode.processingError {
                Section("Problem") { Text(error).foregroundStyle(.orange) }
            }
            BottomClearance()
        }
        .navigationTitle(episode.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Corrections

struct CorrectionRow: View {
    let delta: CorrectionDelta
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(action).font(.subheadline.weight(.semibold))
                Spacer()
                Text("grade \(delta.grade.letter) (\(delta.grade.score) %)").font(.caption).foregroundStyle(.secondary)
            }
            Text("\(formatDuration(delta.start))–\(formatDuration(delta.end)) as \(SegmentKind(rawValue: delta.kind)?.label.lowercased() ?? delta.kind)")
                .font(.caption.monospacedDigit())
            if delta.predictions.isEmpty {
                Text("The detector had nothing here.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(Array(delta.predictions.prefix(4).enumerated()), id: \.offset) { _, p in
                    Text("Found: \(formatDuration(p.start))–\(formatDuration(p.end)) as \(SegmentKind(rawValue: p.kind)?.label.lowercased() ?? p.kind)\(p.sponsor.isEmpty ? "" : " (\(p.sponsor))")")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text([delta.date.formatted(date: .abbreviated, time: .shortened), delta.finder.isEmpty ? nil : delta.finder,
                  delta.absorbed > 0 ? "took in \(delta.absorbed) cut\(delta.absorbed == 1 ? "" : "s")" : nil]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private var action: String {
        switch delta.action {
        case "lock": "Locked"
        case "notAnAd": "Not an ad"
        case "confirm": "Confirmed"
        case "add": "Added by you"
        case "edit": "Edges or type changed"
        default: delta.action.capitalized
        }
    }
}

/// Every correction he made, by show and episode, with what the detector
/// had found there. Only episodes with recorded corrections are listed;
/// older edits made before corrections were recorded show as counts only.
struct CorrectionsPage: View {
    @Environment(\.modelContext) private var context
    @State private var rows: [(show: String, episodes: [Episode])] = []
    @State private var counts: [(show: String, episode: String, edits: EditCounts)] = []

    var body: some View {
        List {
            let total = counts.reduce(EditCounts()) { $0 + $1.edits }
            Section {
                LabeledContent("Cuts confirmed", value: "\(total.confirmed) of \(total.detected)")
                LabeledContent("Cuts rejected", value: "\(total.rejected)")
                LabeledContent("Edges moved", value: "\(total.moved)")
                LabeledContent("Cuts you added", value: "\(total.added)")
                LabeledContent("Cuts locked", value: "\(total.locked)")
            } header: {
                Text("All episodes")
            } footer: {
                Text("Counts come from the cuts as they are now. The entries below are the corrections recorded one by one, with what the detector first said and its grade.")
            }
            if rows.isEmpty { Text("No individual corrections recorded yet.").foregroundStyle(.secondary) }
            ForEach(rows, id: \.show) { group in
                Section(group.show) {
                    ForEach(group.episodes) { episode in
                        NavigationLink {
                            List {
                                ForEach(CorrectionLedger.deltas(for: episode).reversed()) { CorrectionRow(delta: $0) }
                                BottomClearance()
                            }
                            .navigationTitle(episode.title)
                            .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(episode.title).lineLimit(2)
                                let deltas = CorrectionLedger.deltas(for: episode)
                                Text("\(deltas.count) correction\(deltas.count == 1 ? "" : "s")"
                                     + (CorrectionLedger.episodeGrade(episode).map { " · detector's grade \($0.letter) (\($0.score) %)" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            BottomClearance()
        }
        .navigationTitle("Your Corrections")
        .watchName("Your Corrections")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            counts = DetectionReport.editsByEpisode(context)
            let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.correctionLogData != nil })
            let episodes = ((try? context.fetch(descriptor)) ?? []).filter { !CorrectionLedger.deltas(for: $0).isEmpty }
            rows = Dictionary(grouping: episodes, by: { $0.podcast?.title ?? "Unknown show" })
                .map { (show: $0.key, episodes: $0.value.sorted { $0.publishedAt > $1.publishedAt }) }
                .sorted { $0.show < $1.show }
        }
    }
}

// MARK: - Sound output

struct AudioOutputPage: View {
    @State private var trace = PlaybackTrace.shared
    @State private var soundEvents: [BackgroundLog.Event] = []

    var body: some View {
        List {
            if let last = trace.entries.first {
                Section("Most recent") {
                    LabeledContent("Route", value: last.route)
                    LabeledContent("Audio session", value: "\(last.category) · \(last.mode)")
                    LabeledContent("Player", value: "\(last.engine) · \(last.phase)")
                    LabeledContent("Engine state", value: last.engineState)
                    LabeledContent("System volume", value: "\(Int(last.outputVolume * 100)) %")
                    LabeledContent("Other audio playing", value: last.otherAudioPlaying ? "Yes" : "No")
                }
            }
            Section {
                if trace.entries.isEmpty { Text("Nothing recorded yet.").foregroundStyle(.secondary) }
                ForEach(Array(trace.entries.prefix(300).enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.event).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(entry.date, format: .dateTime.month().day().hour().minute().second())
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("\(entry.route) · \(entry.engine) \(entry.engineState) · at \(formatDuration(entry.position))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Play, pause, interruptions, route and format changes")
            }
            if !soundEvents.isEmpty {
                Section("Output devices and delay") {
                    ForEach(soundEvents.prefix(100)) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.text).font(.footnote)
                            Text(event.date, format: .dateTime.month().day().hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            BottomClearance()
        }
        .navigationTitle("Sound Output & Playback")
        .watchName("Sound Output & Playback")
        .navigationBarTitleDisplayMode(.inline)
        .task { soundEvents = BackgroundLog.shared.events.filter { $0.text.hasPrefix("Sound output") || $0.text.contains("silence") } }
    }
}

// MARK: - Reports from iOS

struct ReportsPage: View {
    @State private var reports: [MetricsSubscriber.SavedReport] = []
    @State private var filter = 0

    var body: some View {
        List {
            Picker("Kind", selection: $filter) {
                Text("All").tag(0); Text("Problems").tag(1); Text("Daily").tag(2)
            }
            .pickerStyle(.segmented)
            let shown = reports.filter { filter == 0 || (filter == 1) == ($0.kind != "daily") }
            if shown.isEmpty {
                Text("None yet. iOS sends the first daily report about a day after install, and crash or hang reports when they happen.")
                    .foregroundStyle(.secondary)
            }
            ForEach(shown) { report in
                NavigationLink { ReportDetail(report: report) } label: {
                    HStack {
                        Image(systemName: report.kind == "daily" ? "calendar" : "exclamationmark.triangle")
                            .foregroundStyle(report.kind == "daily" ? Color.secondary : Color.orange)
                        Text(report.kind == "daily" ? "Daily report" : "Problem report")
                        Spacer()
                        Text(report.date, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary)
                    }
                }
            }
            BottomClearance()
        }
        .navigationTitle("Reports from iOS")
        .watchName("Reports from iOS")
        .navigationBarTitleDisplayMode(.inline)
        .task { reports = await Task.detached { MetricsSubscriber.savedReports() }.value }
    }
}

/// One MetricKit report, read: for a crash, what stopped the app and the
/// top of the stack that was running; for a daily report, the headline
/// figures. iOS's own words; the report doesn't say why on its own.
struct ReportDetail: View {
    let report: MetricsSubscriber.SavedReport
    @State private var sections: [(title: String, lines: [String])] = []

    var body: some View {
        List {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                Section(section.title) {
                    ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            Section {
                NavigationLink("Whole Report") {
                    LogFileDetailView(file: .init(url: report.url, category: report.kind == "daily" ? .daily : .diagnostic,
                                                  date: report.date, bytes: 0))
                }
            } footer: {
                Text("The stack lists the code running when iOS stopped the app, newest first. It shows where, not why; Apple's frameworks appear by name only.")
            }
            BottomClearance()
        }
        .navigationTitle(report.kind == "daily" ? "Daily Report" : "Problem Report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { SharePresenter.present([report.url]) } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share")
            }
        }
        .task {
            let url = report.url
            sections = await Task.detached { ReportReader.read(url) }.value
        }
    }
}

enum ReportReader {
    static func read(_ url: URL) -> [(title: String, lines: [String])] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [("Report", ["This report couldn't be read."])]
        }
        var out: [(String, [String])] = []
        let kinds: [(String, String)] = [("crashDiagnostics", "Crash"), ("hangDiagnostics", "Hang"),
                                        ("cpuExceptionDiagnostics", "Processor use"), ("diskWriteExceptionDiagnostics", "Disk writes"),
                                        ("appLaunchDiagnostics", "Slow launch")]
        for (key, title) in kinds {
            for (index, item) in ((json[key] as? [[String: Any]]) ?? []).enumerated() {
                var lines: [String] = []
                if let meta = item["diagnosticMetaData"] as? [String: Any] {
                    for field in ["appBuildVersion", "exceptionType", "exceptionCode", "signal", "terminationReason",
                                  "hangDuration", "totalCPUTime", "totalSampledTime", "writesCaused", "launchDuration", "osVersion"] {
                        if let value = meta[field] { lines.append("\(field): \(value)") }
                    }
                }
                lines += topFrames(item["callStackTree"] as? [String: Any])
                out.append((title + (index > 0 ? " \(index + 1)" : ""), lines))
            }
        }
        if out.isEmpty {
            // A daily report: the headline figures that are there.
            var lines: [String] = []
            func dig(_ path: [String]) -> Any? {
                var node: Any? = json
                for key in path { node = (node as? [String: Any])?[key] }
                return node
            }
            let picks: [(String, [String])] = [
                ("Peak memory", ["memoryMetrics", "peakMemoryUsage"]),
                ("CPU time", ["cpuMetrics", "cumulativeCPUTime"]),
                ("GPU time", ["gpuMetrics", "cumulativeGPUTime"]),
                ("Disk writes", ["diskIOMetrics", "cumulativeLogicalWrites"]),
                ("Time in foreground", ["applicationTimeMetrics", "cumulativeForegroundTime"]),
                ("Time in background", ["applicationTimeMetrics", "cumulativeBackgroundTime"]),
                ("Hangs", ["applicationResponsivenessMetrics", "histogrammedAppHangTime"]),
                ("App storage", ["diskSpaceUsageMetrics", "totalBinaryFileSize"]),
                ("Caches", ["diskSpaceUsageMetrics", "totalCacheFolderSize"]),
                ("Data", ["diskSpaceUsageMetrics", "totalDataFileSize"]),
            ]
            for (title, path) in picks {
                if let value = dig(path) {
                    let text = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])).map { String(decoding: $0.prefix(240), as: UTF8.self) } ?? "\(value)"
                    lines.append("\(title): \(text)")
                }
            }
            out.append(("Summary", lines.isEmpty ? ["No headline figures in this report."] : lines))
        }
        return out
    }

    /// The attributed thread's frames, top first: binary and offset.
    private static func topFrames(_ tree: [String: Any]?) -> [String] {
        guard let stacks = tree?["callStacks"] as? [[String: Any]] else { return [] }
        let stack = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        var frame = (stack?["callStackRootFrames"] as? [[String: Any]])?.first
        var lines: [String] = ["Stack (top first):"]
        while let current = frame, lines.count < 26 {
            let binary = current["binaryName"] as? String ?? "?"
            let offset = (current["offsetIntoBinaryTextSegment"] as? NSNumber)?.int64Value ?? 0
            lines.append("  \(binary) + 0x\(String(offset, radix: 16))")
            frame = (current["subFrames"] as? [[String: Any]])?.first
        }
        return lines
    }
}

// MARK: - Export

struct DiagnosticsExportPage: View {
    @Environment(\.modelContext) private var context
    @State private var parts = Set(Diagnostics.Scope.Part.allCases)
    @State private var range: Range = .all
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    @State private var to = Date.now
    @State private var engines: Set<String> = []
    /// Pass 36: individual runs (empty = all that match).
    @State private var runs: Set<UUID> = []
    @State private var reports: Set<String> = []
    @State private var working = false
    @State private var made: URL?
    @State private var error: String?
    @State private var bench = ModelBench.shared

    enum Range: String, CaseIterable, Identifiable {
        case all = "Everything kept", day = "Last 24 hours", week = "Last 7 days", custom = "Dates…"
        var id: Self { self }
    }

    var body: some View {
        List {
            Section("When") {
                Picker("Time", selection: $range) { ForEach(Range.allCases) { Text($0.rawValue).tag($0) } }
                if range == .custom {
                    DatePicker("From", selection: $from, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("To", selection: $to, displayedComponents: [.date, .hourAndMinute])
                }
            }
            Section {
                ForEach(Diagnostics.Scope.Part.allCases) { part in
                    Toggle(part.title, isOn: Binding(get: { parts.contains(part) },
                                                     set: { if $0 { parts.insert(part) } else { parts.remove(part) } }))
                        .tint(Theme.accentHot)
                }
            } header: {
                HStack {
                    Text("What")
                    Spacer()
                    Button(parts.count == Diagnostics.Scope.Part.allCases.count ? "None" : "All") {
                        parts = parts.count == Diagnostics.Scope.Part.allCases.count ? [] : Set(Diagnostics.Scope.Part.allCases)
                    }
                    .font(.footnote)
                }
            }
            if parts.contains(.crashes) || parts.contains(.dailyReports) {
                Section {
                    NavigationLink {
                        ReportPicker(kinds: Set([parts.contains(.crashes) ? "diagnostic" : nil, parts.contains(.dailyReports) ? "daily" : nil].compactMap { $0 }),
                                     chosen: $reports)
                    } label: {
                        LabeledContent("Reports from iOS", value: reports.isEmpty ? "All in the period" : "\(reports.count) chosen")
                    }
                    .accessibilityIdentifier("diagnostics.export.reports")
                }
            }
            if parts.contains(.modelTests) {
                Section {
                    let all = Dictionary(bench.history.map { ($0.engine, $0.name) }, uniquingKeysWith: { _, b in b })
                    ForEach(all.keys.sorted { all[$0]! < all[$1]! }, id: \.self) { engine in
                        Toggle(all[engine]!, isOn: Binding(get: { engines.isEmpty || engines.contains(engine) },
                                                           set: { on in
                            if engines.isEmpty { engines = Set(all.keys) }
                            if on { engines.insert(engine) } else { engines.remove(engine) }
                            if engines == Set(all.keys) { engines = [] }
                        }))
                        .tint(Theme.accentHot)
                    }
                    NavigationLink {
                        ModelRunPicker(engines: engines, chosen: $runs)
                    } label: {
                        LabeledContent("Runs", value: runs.isEmpty ? "All of these models' runs" : "\(runs.count) chosen")
                    }
                    .accessibilityIdentifier("diagnostics.export.runs")
                } header: {
                    Text("Model tests of")
                }
            }
            Section {
                Button {
                    Task { await make() }
                } label: {
                    HStack { Label(working ? "Preparing…" : "Prepare and Share", systemImage: "square.and.arrow.up"); if working { Spacer(); ProgressView() } }
                }
                .disabled(working || parts.isEmpty)
                .accessibilityIdentifier("diagnostics.export.make")
                if let made { FileResultRow(url: made, location: "Ready to share") }
                if let error { Text(error).foregroundStyle(.orange) }
            } footer: {
                Text("The file says what it holds and what was left out, so a partial export is marked as partial. Some logs keep only their newest entries; when a period reaches back further than they do, the file says so.")
            }
            BottomClearance()
        }
        .navigationTitle("Share Diagnostics")
        .watchName("Share Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func make() async {
        working = true
        defer { working = false }
        var scope = Diagnostics.Scope(parts: parts)
        switch range {
        case .all: break
        case .day: scope.from = Date.now.addingTimeInterval(-86_400)
        case .week: scope.from = Date.now.addingTimeInterval(-7 * 86_400)
        case .custom: scope.from = from; scope.to = to
        }
        scope.engines = engines.isEmpty ? nil : engines
        scope.runs = runs.isEmpty ? nil : runs
        scope.reports = reports.isEmpty ? nil : reports
        let edits = parts.contains(.corrections) ? DetectionReport.editsByEpisode(context) : []
        do {
            let url = try await Diagnostics.exportFile(edits: edits, scope: scope)
            made = url
            SharePresenter.present([url])
        } catch { self.error = error.localizedDescription }
    }
}

struct ResultsExportPage: View {
    @Environment(\.modelContext) private var context
    @State private var range: DiagnosticsExportPage.Range = .all
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    @State private var to = Date.now
    @State private var shows: [String] = []
    @State private var chosenShows: Set<String> = []
    @State private var parts = DetectionExport.Parts.all
    @State private var limit = 150
    /// Pass 36: individual episodes chosen (empty = every match, up to the limit).
    @State private var chosenEpisodes: Set<String> = []
    @State private var working = false
    @State private var made: URL?
    @State private var error: String?

    var body: some View {
        List {
            Section("When processed") {
                Picker("Time", selection: $range) { ForEach(DiagnosticsExportPage.Range.allCases) { Text($0.rawValue).tag($0) } }
                if range == .custom {
                    DatePicker("From", selection: $from, displayedComponents: .date)
                    DatePicker("To", selection: $to, displayedComponents: .date)
                }
                Stepper("At most \(limit) episodes", value: $limit, in: 10...1000, step: 10)
                    .disabled(!chosenEpisodes.isEmpty)
                NavigationLink {
                    ResultsEpisodePicker(lower: bounds.lower, upper: bounds.upper, shows: chosenShows, chosen: $chosenEpisodes)
                } label: {
                    LabeledContent("Episodes", value: chosenEpisodes.isEmpty ? "All that match" : "\(chosenEpisodes.count) chosen")
                }
                .accessibilityIdentifier("results.export.episodes")
            }
            Section {
                ForEach(shows, id: \.self) { show in
                    Toggle(show, isOn: Binding(get: { chosenShows.isEmpty || chosenShows.contains(show) },
                                               set: { on in
                        if chosenShows.isEmpty { chosenShows = Set(shows) }
                        if on { chosenShows.insert(show) } else { chosenShows.remove(show) }
                        if chosenShows == Set(shows) { chosenShows = [] }
                    }))
                    .tint(Theme.accentHot)
                }
            } header: {
                Text("Shows")
            }
            Section {
                Toggle("Transcripts", isOn: $parts.transcript)
                Toggle("Reader's own proposals", isOn: $parts.readerSegments)
                Toggle("Every model attempt", isOn: $parts.attempts)
                Toggle("Your corrections and grades", isOn: $parts.corrections)
                Toggle("What each show has learned", isOn: $parts.showLessons)
            } header: {
                Text("Per episode")
            } footer: {
                Text("Final cuts always go in, each with what the detector originally found, its verdict, lock and edits — so detected, edited, confirmed and rejected stay told apart.")
            }
            .tint(Theme.accentHot)
            Section {
                Button {
                    Task { await make() }
                } label: {
                    HStack { Label(working ? "Preparing…" : "Prepare and Share", systemImage: "square.and.arrow.up.on.square"); if working { Spacer(); ProgressView() } }
                }
                .disabled(working)
                .accessibilityIdentifier("results.export.make")
                if let made { FileResultRow(url: made, location: "Ready to share") }
                if let error { Text(error).foregroundStyle(.orange) }
            }
            BottomClearance()
        }
        .navigationTitle("Share Results")
        .watchName("Share Results")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.lastProcessedAt != nil })
            shows = Array(Set(((try? context.fetch(descriptor)) ?? []).compactMap { $0.podcast?.title })).sorted()
        }
    }

    private var bounds: (lower: Date?, upper: Date?) {
        switch range {
        case .all: return (nil, nil)
        case .day: return (Date.now.addingTimeInterval(-86_400), nil)
        case .week: return (Date.now.addingTimeInterval(-7 * 86_400), nil)
        case .custom: return (Calendar.current.startOfDay(for: from), Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to)))
        }
    }

    private func make() async {
        working = true
        defer { working = false }
        let (start, end) = bounds
        // Pass 36: the date and show filters run over every processed episode
        // (it fetched the newest 2,000 first and filtered those, so an older
        // period or a show could come out short), and a chosen set of
        // episodes is exactly that set.
        let episodes = Self.matching(context, lower: start, upper: end, shows: chosenShows)
            .filter { chosenEpisodes.isEmpty || chosenEpisodes.contains($0.guid) }
        let chosen = chosenEpisodes.isEmpty ? Array(episodes.prefix(limit)) : episodes
        let iso = ISO8601DateFormatter()
        let partial = range != .all || !chosenShows.isEmpty || !chosenEpisodes.isEmpty || parts != .all || episodes.count > chosen.count
        let note: [String: Any] = ["partial": partial, "from": start.map { iso.string(from: $0) } ?? "",
                                   "to": end.map { iso.string(from: $0) } ?? "",
                                   "shows": chosenShows.isEmpty ? [] : Array(chosenShows).sorted(),
                                   "episodesChosen": chosenEpisodes.isEmpty ? [] : Array(chosenEpisodes).sorted(),
                                   "matching": episodes.count, "included": chosen.count,
                                   "limit": chosenEpisodes.isEmpty ? limit : chosen.count,
                                   "complete": !partial]
        do {
            let url = try await DetectionExport.file(episodes: chosen, parts: parts, scopeNote: note)
            if chosen.count < episodes.count {
                self.error = "This file holds the newest \(chosen.count) of \(episodes.count) matching episodes and says so inside; raise the limit or choose episodes to include others."
            }
            made = url
            SharePresenter.present([url])
        } catch { self.error = error.localizedDescription }
    }
}

/// Pass 36: pick individual iOS reports (crash, hang, CPU, disk; daily).
struct ReportPicker: View {
    let kinds: Set<String>
    @Binding var chosen: Set<String>
    @State private var reports: [MetricsSubscriber.SavedReport] = []

    var body: some View {
        List {
            Section {
                if reports.isEmpty { Text("No reports from iOS are kept.").foregroundStyle(.secondary) }
                ForEach(reports, id: \.url) { report in
                    let name = report.url.lastPathComponent
                    Button {
                        if chosen.contains(name) { chosen.remove(name) } else { chosen.insert(name) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: chosen.contains(name) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(chosen.contains(name) ? Theme.accentHot : .secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(report.kind == "daily" ? "Daily report" : "Crash, hang or resource report")
                                Text(report.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen.contains(name) ? .isSelected : [])
                }
            } header: {
                HStack {
                    Text("\(chosen.count) of \(reports.count) chosen")
                    Spacer()
                    Button(chosen.isEmpty ? "All" : "None") { chosen = chosen.isEmpty ? Set(reports.map(\.url.lastPathComponent)) : [] }
                        .font(.footnote)
                }
            } footer: {
                Text("With none chosen, every report in the period goes in. PodSkipper keeps the newest 40 reports.")
            }
            BottomClearance()
        }
        .navigationTitle("Choose Reports")
        .watchName("Choose Reports")
        .navigationBarTitleDisplayMode(.inline)
        .task { reports = MetricsSubscriber.savedReports().filter { kinds.contains($0.kind) }.sorted { $0.date > $1.date } }
    }
}

/// Pass 36: pick individual model-test runs for a Diagnostics export.
struct ModelRunPicker: View {
    let engines: Set<String>
    @Binding var chosen: Set<UUID>
    @State private var bench = ModelBench.shared

    var body: some View {
        let runs = bench.history.filter { engines.isEmpty || engines.contains($0.engine) }.sorted { $0.date > $1.date }
        List {
            Section {
                ForEach(runs) { run in
                    Button {
                        if chosen.contains(run.runID) { chosen.remove(run.runID) } else { chosen.insert(run.runID) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: chosen.contains(run.runID) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(chosen.contains(run.runID) ? Theme.accentHot : .secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.name + " · " + run.sample.title).lineLimit(2)
                                Text([run.date.formatted(date: .abbreviated, time: .shortened),
                                      run.score.map { "\(Int(($0 * 100).rounded())) %" } ?? run.resolvedOutcome.title,
                                      run.appBuild.map { "build " + $0 }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen.contains(run.runID) ? .isSelected : [])
                }
            } header: {
                HStack {
                    Text("\(chosen.count) of \(runs.count) chosen")
                    Spacer()
                    Button(chosen.isEmpty ? "All" : "None") { chosen = chosen.isEmpty ? Set(runs.map(\.runID)) : [] }
                        .font(.footnote)
                }
            } footer: {
                Text("With none chosen, every run of the models above goes in.")
            }
            BottomClearance()
        }
        .navigationTitle("Choose Runs")
        .watchName("Choose Runs")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension ResultsExportPage {
    /// Every processed episode in the period (all of them, newest first),
    /// then the shows chosen.
    @MainActor static func matching(_ context: ModelContext, lower: Date?, upper: Date?, shows: Set<String>) -> [Episode] {
        let from = lower ?? .distantPast, to = upper ?? .distantFuture
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { e in
                e.lastProcessedAt != nil && e.lastProcessedAt! >= from && e.lastProcessedAt! <= to
            },
            sortBy: [SortDescriptor(\.lastProcessedAt, order: .reverse)])
        return ((try? context.fetch(descriptor)) ?? []).filter { shows.isEmpty || shows.contains($0.podcast?.title ?? "") }
    }
}

/// Pass 36 (his request: individual records, not just categories): pick the
/// exact episodes to include, from those the period and shows match.
struct ResultsEpisodePicker: View {
    @Environment(\.modelContext) private var context
    let lower: Date?
    let upper: Date?
    let shows: Set<String>
    @Binding var chosen: Set<String>
    @State private var episodes: [(guid: String, title: String, show: String, processed: Date?)] = []
    @State private var search = ""

    var body: some View {
        List {
            Section {
                if episodes.isEmpty { Text("No processed episodes match the period and shows.").foregroundStyle(.secondary) }
                ForEach(visible, id: \.guid) { episode in
                    Button {
                        if chosen.contains(episode.guid) { chosen.remove(episode.guid) } else { chosen.insert(episode.guid) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: chosen.contains(episode.guid) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(chosen.contains(episode.guid) ? Theme.accentHot : .secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(episode.title).lineLimit(2)
                                Text([episode.show, episode.processed.map { $0.formatted(date: .abbreviated, time: .omitted) }]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen.contains(episode.guid) ? .isSelected : [])
                }
            } header: {
                HStack {
                    Text("\(chosen.count) of \(episodes.count) chosen")
                    Spacer()
                    Button(chosen.isEmpty ? "All" : "None") {
                        chosen = chosen.isEmpty ? Set(episodes.map(\.guid)) : []
                    }
                    .font(.footnote)
                }
            } footer: {
                Text("With none chosen, the file holds every matching episode up to the limit.")
            }
            BottomClearance()
        }
        .searchable(text: $search)
        .navigationTitle("Choose Episodes")
        .watchName("Choose Episodes")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            episodes = ResultsExportPage.matching(context, lower: lower, upper: upper, shows: shows)
                .map { ($0.guid, $0.title, $0.podcast?.title ?? "", $0.lastProcessedAt) }
        }
    }

    private var visible: [(guid: String, title: String, show: String, processed: Date?)] {
        guard !search.isEmpty else { return episodes }
        return episodes.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.show.localizedCaseInsensitiveContains(search) }
    }
}

// MARK: - Clearing records

/// Pass 35 (his question about "Clear Timings"): what each kind of record
/// is, and clearing each one — all of it or what's older than a date.
/// Corrections, ads found and model test results stay; they're the app's
/// learning and his history, not diagnostics.
struct DiagnosticsDataPage: View {
    @State private var cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
    @State private var confirm: Confirmation?
    @State private var note: ResultNote?
    @State private var log = TimingLog.shared

    private enum Record: String, CaseIterable, Identifiable {
        case timings, background, attempts, reports, playback
        var id: Self { self }
        var title: String {
            switch self {
            case .timings: "Processing timings"
            case .background: "Background activity log"
            case .attempts: "Ad-finder attempt records"
            case .reports: "iOS reports"
            case .playback: "Playback and sound records"
            }
        }
        var detail: String {
            switch self {
            case .timings: "How long each episode's steps took (Speed and Episodes Processed use these)."
            case .background: "What happened in the background, launches and sound output changes."
            case .attempts: "Each model's proposals per episode, kept for comparing finders. The cuts themselves stay."
            case .reports: "Crash, hang and daily reports iOS sent."
            case .playback: "Play, pause, route and format changes, for silent-playback problems."
            }
        }
    }

    var body: some View {
        List {
            if let note { Section { ResultNoteRow(note: note) } }
            Section {
                DatePicker("Older than", selection: $cutoff, in: ...Date.now, displayedComponents: .date)
            } footer: {
                Text("Your corrections, the ads found, model test results and settings are never cleared here.")
            }
            ForEach(Record.allCases) { record in
                Section {
                    Button("Clear Older Than \(cutoff.formatted(date: .abbreviated, time: .omitted))") { ask(record, before: cutoff) }
                    Button("Clear All", role: .destructive) { ask(record, before: nil) }
                } header: {
                    Text(record.title)
                } footer: {
                    Text(record.detail)
                }
            }
            if let message = log.storageError {
                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    .accessibilityIdentifier("DiagnosticsTimingError")
            }
            BottomClearance()
        }
        .navigationTitle("Clear Diagnostic Records")
        .watchName("Clear Diagnostic Records")
        .navigationBarTitleDisplayMode(.inline)
        .confirmation($confirm)
    }

    private func ask(_ record: Record, before: Date?) {
        let when = before.map { "older than " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "all"
        confirm = Confirmation(title: "Clear \(record.title.lowercased())?",
                               message: "Removes \(when) \(record.title.lowercased()). \(record.detail) Exports made after this won't include them.",
                               actionTitle: "Clear") {
            let result: DiagnosticLogCleanupResult
            switch record {
            case .timings: result = await TimingLog.shared.prune(before: before)
            case .background: result = await BackgroundLog.shared.prune(before: before)
            case .attempts: result = await FinderAttemptLog.shared.prune(before: before)
            case .reports: result = await MetricsSubscriber.shared.prune(before: before)
            case .playback:
                PlaybackTrace.shared.clear(before: before)
                result = DiagnosticLogCleanupResult()
            }
            note = result.failures.isEmpty
                ? ResultNote(text: "Cleared \(record.title.lowercased())" + (result.removedEntries > 0 ? ": \(result.removedEntries) records" : "") + (result.freedBytes > 0 ? ", \(formattedBytes(result.freedBytes))" : "") + ".")
                : ResultNote(text: result.failures.joined(separator: "; "), failed: true)
        }
    }
}
