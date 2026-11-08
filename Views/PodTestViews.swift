import SwiftData
import SwiftUI

/// Pass 60: Compare Models › The PodSkipper Test (`PodTestRunner`). Every
/// engine reads his test episodes on this iPhone and is scored beside the
/// Reader on the same episodes, as the lab scores them.
struct PodTestSection: View {
    @State private var runner = PodTestRunner.shared
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings

    var body: some View {
        SectionHeader("The PodSkipper Test")
        Text("Every ad finder reads your \(runner.pack?.episodes.count ?? 0) test episodes, the ones checked by hand that the Reader never learned from, using the transcripts already on your iPhone. The cuts you listen with don’t change. Each finder is scored beside the Reader on the same episodes: 100 means every ad, plug, intro and outro skipped and none of the show cut; 0 means no better than skipping nothing.")
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .contentRow()
        if runner.isRunning {
            PodTestRunPanel().contentRow(top: 12, bottom: 12)
        } else {
            engineChoices
            actions
        }
        if let error = runner.requestError {
            Text(error).font(.subheadline).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true).contentRow()
        }
        if let error = runner.saveError {
            Text(error).font(.subheadline).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true).contentRow()
        }
        // Pass 62 (his 8 Nov run): the table shows the newest run that read
        // something — a run stopped before its first read never hides it.
        if let run = runner.resultsRun, let pack = runner.pack, run.reader?.cuts.isEmpty == false {
            PodTestResults(run: run, pack: pack)
        } else if let run = runner.latest, let pack = runner.pack, !runner.isRunning, runner.unfinished == nil {
            // A run that read nothing says why (e.g. the episodes aren't
            // in this library).
            NavigationLink {
                PodTestRunPage(run: run, pack: pack)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last run: " + PodTestRunPage.headline(run)).font(.subheadline)
                    if let reasons = PodTestRunPage.skipSummary(run) {
                        Text(reasons).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("podtest.lastRun")
            .contentRow()
        }
        let earlier = runner.runs.filter { $0.runID != runner.resultsRun?.runID }
        if !earlier.isEmpty, let pack = runner.pack {
            FoldRow(title: "Other runs (\(earlier.count))", key: "podtest.earlier", identifier: "podtest.earlier")
            if BenchDisclosure.shared.isOpen("podtest.earlier") {
                ForEach(earlier.reversed()) { run in
                    NavigationLink {
                        PodTestRunPage(run: run, pack: pack)
                    } label: {
                        Text(PodTestRunPage.headline(run)).font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 12)
                    .contentRow(top: 8, bottom: 8)
                }
            }
        }
    }

    @ViewBuilder
    private var engineChoices: some View {
        ForEach(runner.plans()) { plan in
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.name).font(.subheadline.weight(.semibold))
                    if let why = plan.unavailable {
                        Text(why).font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if plan.kind == .reader {
                        Text("Always reads: every finder is compared with it.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if plan.unavailable == nil, plan.kind != .reader {
                    Toggle(plan.name, isOn: Binding(get: { runner.isIncluded(plan) },
                                                    set: { runner.setIncluded(plan, $0) }))
                        .labelsHidden()
                        .accessibilityIdentifier("podtest.include." + plan.engine)
                }
            }
            .frame(minHeight: 44)
            .contentRow(top: 6, bottom: 6)
        }
    }

    @ViewBuilder
    private var unfinishedButtons: some View {
        Button { runner.resume(context: context, settings: settings) } label: { PodTestButtonLabel("Resume") }
            .buttonStyle(.glassProminent)
            .accessibilityIdentifier("podtest.resume")
        Button { runner.start(context: context, settings: settings) } label: { PodTestButtonLabel("Start Over") }
            .buttonStyle(.glass)
            .accessibilityIdentifier("podtest.startOver")
        Button { runner.dismissUnfinished() } label: { PodTestButtonLabel("Keep Earlier Results") }
            .buttonStyle(.glass)
            .accessibilityHint("Sets the stopped run aside and keeps the finished results")
            .accessibilityIdentifier("podtest.dismiss")
    }

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let unfinished = runner.unfinished {
                Text("The last run stopped after \(unfinished.doneReads) of \(unfinished.reads.count) reads. Resume carries on where it stopped; Keep Earlier Results sets it aside.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Pass 62 (his 8 Nov screenshot: "Resume" sat right of centre,
                // behind an icon drawn in the button's own pink): text only,
                // centred, every button the same height.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { unfinishedButtons }
                    VStack(alignment: .leading, spacing: 10) { unfinishedButtons }
                }
            } else {
                Button { runner.start(context: context, settings: settings) } label: {
                    PodTestButtonLabel("Run the Test")
                }
                .buttonStyle(.glassProminent)
                .disabled(runner.pack == nil)
                .accessibilityIdentifier("podtest.run")
            }
            Text("A model can take several minutes per episode. Keep PodSkipper open: the screen stays on, and if you leave, the test pauses and carries on when you’re back.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentRow(top: 10, bottom: 12)
    }
}

/// Pass 62: the PodSkipper test's buttons — text centred in the capsule,
/// 44 pt tall, the same in every style.
struct PodTestButtonLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .multilineTextAlignment(.center)
            .frame(minWidth: 72, minHeight: 44)
            .padding(.horizontal, 4)
            .contentShape(Capsule())
    }
}

/// The run under way: which finder is reading which episode, a plain bar
/// of the read in progress, the reads done, time spent, and Stop.
struct PodTestRunPanel: View {
    @State private var runner = PodTestRunner.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text((runner.activeEngineName ?? "Getting ready")
                     + (runner.episodeCount > 0 && runner.activeEpisode > 0 ? " · episode \(runner.activeEpisode) of \(runner.episodeCount)" : ""))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("podtest.active")
                Text(runner.step).font(.subheadline)
                    .foregroundStyle(runner.pausedOffScreen ? Color.orange : Color.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                PlainBar(value: runner.fraction)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: 6) {
                        Text("\(runner.doneReads) of \(runner.totalReads) reads done")
                        if let started = runner.startedAt {
                            Text("· " + Duration.seconds(max(0, context.date.timeIntervalSince(started))).formatted(.time(pattern: .hourMinuteSecond)))
                        }
                    }
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { runner.stop() } label: { PodTestButtonLabel(runner.stopping ? "Stopping…" : "Stop") }
                .buttonStyle(.glass).disabled(runner.stopping)
                .accessibilityLabel("Stop the PodSkipper test")
                .accessibilityIdentifier("podtest.stop")
        }
        .transaction { $0.animation = nil }
    }
}

/// Each finder of a run beside the Reader on the episodes both read.
struct PodTestResults: View {
    let run: PodTestRun
    let pack: PodTestPack

    var body: some View {
        NavigationLink {
            PodTestRunPage(run: run, pack: pack)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(PodTestRunPage.headline(run)).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Finder").font(.footnote.weight(.semibold))
                        Text("Score").font(.footnote.weight(.semibold)).gridColumnAlignment(.trailing)
                        Text("Reader").font(.footnote.weight(.semibold)).gridColumnAlignment(.trailing)
                    }
                    ForEach(run.engines) { engine in
                        GridRow {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(engine.name).font(.footnote)
                                Text(PodTestRunPage.episodesLine(run, engine, pack: pack)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(PodTestRunPage.score(run, engine, pack: pack)).font(.footnote.monospacedDigit())
                            Text(engine.kind == .reader ? "" : PodTestRunPage.readerScore(run, engine, pack: pack))
                                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .accessibilityIdentifier("podtest.results")
        .contentRow()
    }
}

/// One run in full: each finder's Everyday and Challenge scores beside the
/// Reader's, situation by situation and episode by episode.
struct PodTestRunPage: View {
    let run: PodTestRun
    let pack: PodTestPack
    @Environment(\.modelContext) private var context
    @State private var titles: [String: String] = [:]

    var body: some View {
        List {
            Section {
                Text(Self.headline(run)).font(.subheadline)
                if !run.skipped.isEmpty {
                    ForEach(run.skipped, id: \.guid) { skip in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(skip.guid)).font(.subheadline)
                            Text(skip.reason).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("Everyday: whole episodes as you hear them, every show counting the same. A break you’d notice (more than 5 s of it heard) costs more than a cut a second late, and cutting the show counts double. Situations: the share of each kind of break handled, each counting the same however rare.")
            }
            ForEach(run.engines) { engine in
                engineSection(engine)
            }
            BottomClearance()
        }
        .navigationTitle("PodSkipper Test")
        .navigationBarTitleDisplayMode(.inline)
        .task { loadTitles() }
    }

    @ViewBuilder
    private func engineSection(_ engine: PodTestRun.Engine) -> some View {
        let comparison = engine.kind == .reader ? nil : run.comparison(engine.engine, pack: pack)
        let own = PodTestScore.summary(pack: pack, cuts: engine.cuts)
        Section {
            if let comparison {
                summaryRows(comparison.engine, against: comparison.reader)
            } else if own.episodes > 0 {
                summaryRows(own, against: nil)
            } else {
                Text("No episode read yet.").foregroundStyle(.secondary)
            }
            if let identity = engine.modelIdentity {
                Text(identity).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ForEach(engine.reads.filter { read in read.outcome != .skipped || !run.skipped.contains { $0.guid == read.guid } },
                    id: \.guid) { read in
                readRow(engine, read)
            }
        } header: {
            Text(engine.name)
        }
    }

    @ViewBuilder
    private func summaryRows(_ s: PodTestScore.Summary, against reader: PodTestScore.Summary?) -> some View {
        let label = reader == nil ? "" : " · Reader "
        LabeledContent("Everyday score", value: Self.number(s.everyday) + (reader.map { label + Self.number($0.everyday) } ?? ""))
        LabeledContent("Situations handled", value: Self.number(s.challenge) + (reader.map { label + Self.number($0.challenge) } ?? ""))
        LabeledContent("Breaks you’d notice", value: "\(s.noticed) of \(s.breaks)" + (reader.map { label + "\($0.noticed)" } ?? ""))
        LabeledContent("Show cut", value: String(format: "%.1f s an hour", s.showCutPerHour)
                       + (reader.map { label + String(format: "%.1f", $0.showCutPerHour) } ?? ""))
        LabeledContent("Episodes", value: "\(s.episodes) from \(s.shows) show\(s.shows == 1 ? "" : "s")")
        ForEach(pack.situations.filter { (s.counts[$0] ?? 0) > 0 }, id: \.self) { situation in
            LabeledContent(Self.situationName(situation) + " (\(s.counts[situation] ?? 0))",
                           value: Self.percent(s.rates[situation]) + (reader.map { label + Self.percent($0.rates[situation]) } ?? ""))
                .font(.footnote)
        }
    }

    private func readRow(_ engine: PodTestRun.Engine, _ read: PodTestRun.Read) -> some View {
        var detail: [String] = []
        switch read.outcome {
        case .completed:
            if let e = pack.episode(read.guid) {
                let mine = PodTestScore.everyday([read.guid: PodTestScore.episode(e, cuts: read.cuts, constants: pack.constants)],
                                                 showOf: [read.guid: e.show])
                detail.append("Score " + Self.number(mine))
                if engine.kind != .reader, let readerCuts = run.reader?.read(read.guid), readerCuts.outcome == .completed {
                    let theirs = PodTestScore.everyday([read.guid: PodTestScore.episode(e, cuts: readerCuts.cuts, constants: pack.constants)],
                                                       showOf: [read.guid: e.show])
                    detail.append("Reader " + Self.number(theirs))
                }
            }
            detail.append("\(read.cuts.count) cut\(read.cuts.count == 1 ? "" : "s")")
            if let share = read.share, share < 1 { detail.append("read \(Int((share * 100).rounded())) %") }
            if read.seconds > 0 { detail.append(Duration.seconds(read.seconds.rounded()).formatted(.time(pattern: .minuteSecond))) }
            if let n = read.lessonsLeftOut, n > 0 { detail.append("\(n) of your lessons from this episode left out") }
        case .failed: detail.append("Couldn’t read it: " + (read.note ?? "no answer"))
        case .skipped: detail.append("Not read: " + (read.note ?? ""))
        case .pending, .reading: detail.append("Not read yet")
        }
        if read.outcome == .completed, let note = read.note { detail.append(note) }
        return VStack(alignment: .leading, spacing: 2) {
            Text(title(read.guid)).font(.subheadline).lineLimit(2)
            Text(detail.joined(separator: " · ")).font(.footnote)
                .foregroundStyle(read.outcome == .failed ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// The episode's title in this library, else its show's name.
    private func title(_ guid: String) -> String {
        titles[guid] ?? (pack.episode(guid).map { "An episode of " + $0.show + " not on this iPhone" } ?? "An episode not on this iPhone")
    }

    private func loadTitles() {
        let guids = pack.episodes.map(\.guid)
        let found = (try? context.fetch(FetchDescriptor<Episode>(predicate: #Predicate { guids.contains($0.guid) }))) ?? []
        titles = Dictionary(found.map { ($0.guid, $0.title) }, uniquingKeysWith: { a, _ in a })
    }

    static func headline(_ run: PodTestRun) -> String {
        let when = run.started.formatted(date: .abbreviated, time: .shortened)
        let state = switch run.state {
        case .completed: "finished"
        case .running: "running"
        case .stopped: "stopped by you"
        case .interrupted: "interrupted"
        }
        return "\(when) · \(state) · \(run.doneReads) of \(run.reads.count) reads"
    }

    /// "11 episodes not read: Not in your library (9), No transcript on this iPhone (2)".
    static func skipSummary(_ run: PodTestRun) -> String? {
        guard !run.skipped.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for skip in run.skipped {
            let reason = skip.reason.hasPrefix("A different version") ? "A different version of the episode" : skip.reason
            counts[reason, default: 0] += 1
        }
        let parts = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) (\($0.value))" }
        return "\(run.skipped.count) episode\(run.skipped.count == 1 ? "" : "s") not read: " + parts.joined(separator: ", ")
    }

    static func episodesLine(_ run: PodTestRun, _ engine: PodTestRun.Engine, pack: PodTestPack) -> String {
        let done = engine.reads.filter { $0.outcome == .completed }.count
        let failed = engine.reads.filter { $0.outcome == .failed }.count
        if engine.kind == .reader { return "\(done) episodes" }
        let both = run.comparison(engine.engine, pack: pack)?.engine.episodes ?? 0
        return "\(both) episodes" + (failed > 0 ? " · \(failed) couldn’t be read" : "")
    }

    static func score(_ run: PodTestRun, _ engine: PodTestRun.Engine, pack: PodTestPack) -> String {
        if engine.kind == .reader { return number(PodTestScore.summary(pack: pack, cuts: engine.cuts).everyday) }
        return number(run.comparison(engine.engine, pack: pack)?.engine.everyday)
    }

    static func readerScore(_ run: PodTestRun, _ engine: PodTestRun.Engine, pack: PodTestPack) -> String {
        number(run.comparison(engine.engine, pack: pack)?.reader.everyday)
    }

    static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        return String(format: "%.1f", value)
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "–" }
        return "\(Int((value * 100).rounded())) %"
    }

    static func situationName(_ key: String) -> String {
        switch key {
        case "host read": "Ads the hosts read"
        case "produced spot": "Recorded ads"
        case "back to back": "Ads back to back"
        case "short spot": "Short ads (under 20 s)"
        case "long read": "Long reads (over 2 min)"
        case "pre-roll": "Breaks in the first minute"
        case "post-roll": "Breaks in the last 2 minutes"
        case "plug round": "Plugs the host asks for"
        case "own plug": "The show’s own plugs"
        case "other show": "Other shows’ promos"
        case "intro": "Intros"
        case "outro": "Outros and credits"
        case "selling words in the show": "Show talk with ad words (kept)"
        case "plug words in the show": "Talk about tours and merch (kept)"
        default: key.prefix(1).uppercased() + key.dropFirst()
        }
    }
}
