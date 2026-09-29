import SwiftUI
import SwiftData

/// Everything the ad finder is doing and has done, on one screen (pass 20).
///
/// He asked (24 Sep) where to see the line of jobs and the episodes already
/// processed. From the top: the job running now, the line (numbered, drag to
/// reorder, swipe to take one out, folds away), jobs of his that paused, then
/// the finished episodes with what was cut. Pull down refreshes the line
/// itself, not the feeds. Opened from the activity bar, the Library and
/// Settings.
struct ActivityView: View {
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(\.modelContext) private var context
    @State private var lineOpen = true
    @State private var historyOpen = false
    @State private var finished: [Episode] = []
    @State private var lookup: [String: Episode] = [:]

    var body: some View {
        List {
            nowSection
            lineSection
            pausedSection
            finishedSection
            historySection
            BottomClearance()
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await pipeline.refreshLine()
            reload()
        }
        .onAppear(perform: reload)
        .onChange(of: pipeline.waitingQueue) { _, _ in reload() }
        .onChange(of: pipeline.isRunning) { _, _ in reload() }
        .accessibilityIdentifier("activity.screen")
    }

    private func episode(_ guid: String) -> Episode? {
        if let known = lookup[guid] { return known }
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func reload() {
        var map: [String: Episode] = [:]
        for guid in pipeline.waitingQueue + pipeline.unfinishedJobs + [pipeline.currentEpisodeGUID].compactMap({ $0 }) {
            if let found = episode(guid) { map[guid] = found }
        }
        lookup = map
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.lastProcessedAt != nil },
            sortBy: [SortDescriptor(\.lastProcessedAt, order: .reverse)])
        descriptor.fetchLimit = 40
        finished = (try? context.fetch(descriptor))?.filter { $0.processingState == .ready } ?? []
    }

    // MARK: Now

    @ViewBuilder
    private var nowSection: some View {
        Section("Now") {
            if pipeline.isRunning, let guid = pipeline.currentEpisodeGUID {
                VStack(alignment: .leading, spacing: 10) {
                    ActivityEpisodeLine(episode: lookup[guid], fallbackTitle: pipeline.currentEpisodeTitle ?? "",
                                        detail: pipeline.currentOrigin == .user
                                            ? "You asked for this" + (pipeline.waitingQueue.isEmpty ? "" : " · \(pipeline.waitingQueue.count) more in line")
                                            : "Getting Up Next ready by itself · steps aside when you ask for one")
                    NowProgress(pipeline: pipeline)
                    if let minutes = pipeline.stalledMinutes, let episode = lookup[guid] {
                        HStack {
                            Label("No progress for \(minutes) min", systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline).foregroundStyle(.orange)
                            Spacer()
                            Button("Restart") { Task { await pipeline.restart(episode) } }
                                .buttonStyle(.glass)
                        }
                    }
                    if let episode = lookup[guid] {
                        Button(role: .destructive) {
                            Haptics.select()
                            pipeline.stopJob(episode)
                        } label: {
                            Label(pipeline.stopping ? "Stopping…" : "Stop Finding Ads", systemImage: "stop.circle")
                        }
                        .disabled(pipeline.stopping)
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                        .accessibilityIdentifier("activity.stop")
                    }
                }
                .padding(.vertical, 4)
            } else if pipeline.modelCatchUpRemaining > 0 {
                // Task 05: episodes read while locked, read in full now.
                CatchUpLine(pipeline: pipeline)
            } else if let reason = pipeline.speculativePausedReason {
                Label("Getting Up Next ready — \(reason.lowercased())", systemImage: "hourglass")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text(pipeline.waitingQueue.isEmpty
                     ? "Nothing running. Find Ads on any episode puts it here, and more go in line behind it."
                     : "Starting the next one…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: The line

    @ViewBuilder
    private var lineSection: some View {
        if !pipeline.waitingQueue.isEmpty {
            Section {
                if lineOpen {
                    ForEach(Array(pipeline.waitingQueue.enumerated()), id: \.element) { index, guid in
                        LineRow(number: index + 1, episode: lookup[guid],
                                preparing: pipeline.isPreparing(guid))
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    Haptics.select()
                                    pipeline.cancelWaiting(guid)
                                }
                            }
                    }
                    .onMove { pipeline.moveInLine(from: $0, to: $1) }
                }
            } header: {
                Button {
                    withAnimation(.snappy) { lineOpen.toggle() }
                } label: {
                    HStack {
                        Text("In Line (\(pipeline.waitingQueue.count))")
                        Spacer()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(lineOpen ? 0 : -90))
                    }
                    // The whole width, not only the words and the chevron:
                    // with a plain button the gap between them didn't take
                    // a tap (the first photograph showed the fold ignored).
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("activity.lineHeader")
            } footer: {
                if lineOpen, pipeline.waitingQueue.count > 1 {
                    Text("Touch and hold, then drag to change the order. Swipe left to take one out.")
                }
            }
        }
    }

    // MARK: Paused and finished

    @ViewBuilder
    private var pausedSection: some View {
        let paused = pipeline.unfinishedJobs.filter {
            !pipeline.waitingQueue.contains($0) && $0 != pipeline.currentEpisodeGUID
        }
        if !paused.isEmpty {
            Section {
                ForEach(paused, id: \.self) { guid in
                    HStack {
                        ActivityEpisodeLine(episode: lookup[guid], fallbackTitle: "Episode")
                        Spacer()
                        if let episode = lookup[guid] {
                            Button("Resume") { Task { await pipeline.processNow(episode) } }
                                .buttonStyle(.glass)
                        }
                    }
                    .swipeActions {
                        Button("Forget", role: .destructive) {
                            if let episode = lookup[guid] { pipeline.forgetPaused(episode.guid) }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Paused")
                    Spacer()
                    if paused.count > 1 {
                        Button("Resume All") {
                            Haptics.select()
                            pipeline.processNow(paused.compactMap { lookup[$0] })
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
            } footer: {
                Text("Stopped part way: by iOS while you were away, or by the app closing. Everything done so far is kept; Resume carries on from there.")
            }
        }
    }

    /// What happened lately, in words: joined the line, left the app, iOS
    /// paused it, finished… (the same lines Diagnostics keeps). His 27 Sep
    /// report was of an episode that joined the line and later wasn't
    /// there; this is where that would now be seen.
    @ViewBuilder
    private var historySection: some View {
        let events = Array(BackgroundLog.shared.events.prefix(historyOpen ? 40 : 8))
        if !events.isEmpty {
            Section {
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.text).font(.footnote).lineLimit(3)
                        Text(event.date, format: .relative(presentation: .named))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !historyOpen, BackgroundLog.shared.events.count > 8 {
                    Button("Show More") { withAnimation(.snappy) { historyOpen = true } }
                        .font(.footnote)
                }
            } header: {
                Text("What Happened")
            }
        }
    }

    @ViewBuilder
    private var finishedSection: some View {
        if !finished.isEmpty {
            Section("Finished") {
                ForEach(finished) { episode in
                    NavigationLink(value: EpisodeRoute(episode)) {
                        FinishedRow(episode: episode)
                    }
                    .navigationLinkIndicatorVisibility(.hidden)
                }
            }
        }
    }
}

/// Cover, show and title of one episode, for the Activity screen.
private struct ActivityEpisodeLine: View {
    let episode: Episode?
    let fallbackTitle: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: episode?.artworkURL ?? episode?.podcast?.artworkURL, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                if let show = episode?.podcast?.title {
                    Text(show).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(episode?.title ?? fallbackTitle)
                    .font(.subheadline.weight(.semibold)).lineLimit(2)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// The running job's bar, time spent and left, and every step with what it
/// is doing (pass 21b, his 28 Sep report: "it doesn't show the details of
/// what step something is on and the specifics"). Its own view: it redraws
/// every second.
private struct NowProgress: View {
    let pipeline: ProcessingPipeline

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: min(1, max(0, pipeline.overallFraction)))
                HStack {
                    Text((pipeline.batchLabel.map { $0 + " · " } ?? "") + "\(Int(min(1, max(0, pipeline.overallFraction)) * 100))% overall")
                    Spacer()
                    if let started = pipeline.jobStartedAt {
                        Text("Spent " + Self.minutes(context.date.timeIntervalSince(started)))
                    }
                    if let eta = pipeline.etaSeconds {
                        Text("· about " + Self.minutes(eta) + " left")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(ProcessingPipeline.Stage.ordered, id: \.self) { step in
                        StepLine(step: step, pipeline: pipeline, now: context.date)
                    }
                }
                .padding(.top, 2)
                .accessibilityIdentifier("activity.steps")
            }
        }
    }

    static func minutes(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        return m < 1 ? "under a minute" : m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? "\(s) s" : s < 3600 ? "\(s / 60) min \(s % 60) s" : "\(s / 3600) h \(s % 3600 / 60) min"
    }
}

/// One step of the running job: done (how long it took, or already done
/// before), under way (percent and what exactly), or still to come.
private struct StepLine: View {
    let step: ProcessingPipeline.Stage
    let pipeline: ProcessingPipeline
    let now: Date

    private var order: Int { ProcessingPipeline.Stage.ordered.firstIndex(of: step) ?? 0 }
    private var currentOrder: Int { ProcessingPipeline.Stage.ordered.firstIndex(of: pipeline.stage) ?? -1 }
    private var record: ProcessingPipeline.StepRecord? { pipeline.steps[step] }
    private var isCurrent: Bool { pipeline.stage == step }
    private var isDone: Bool { order < currentOrder }
    /// Planned at nothing: the download or transcript was already there.
    private var alreadyDone: Bool {
        (step == .downloading || step == .transcribing) && (pipeline.stagePlan[step] ?? 1) == 0
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(isCurrent ? Theme.accentHot : isDone ? Color.green : Color.secondary)
                .symbolEffect(.pulse, isActive: isCurrent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.subheadline.weight(isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent || isDone ? .primary : .secondary)
                    Spacer()
                    Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                ForEach(details, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        if isCurrent { return "circle.dotted.circle" }
        if isDone { return "checkmark.circle.fill" }
        return "circle"
    }

    private var title: String {
        switch step {
        case .downloading: return "Download"
        case .transcribing: return "Transcribe on your iPhone"
        case .analyzing: return "Measure silences and loudness"
        case .detecting: return "Find the ads"
        case .saving: return "Save the cuts"
        case .idle: return ""
        }
    }

    private var trailing: String {
        if isCurrent { return "\(Int(min(1, max(0, pipeline.stageFraction)) * 100))%" + elapsed }
        if isDone {
            if alreadyDone { return "already done" }
            if let s = record?.started, let e = record?.ended, e.timeIntervalSince(s) >= 1 {
                return NowProgress.clock(e.timeIntervalSince(s))
            }
            return "done"
        }
        return ""
    }

    private var elapsed: String {
        guard let s = record?.started else { return "" }
        return " · " + NowProgress.clock(now.timeIntervalSince(s))
    }

    private var details: [String] {
        guard isCurrent else {
            if step == .detecting, isDone {
                return [pipeline.adFreeNote, pipeline.finderNote].compactMap { $0 }
            }
            return []
        }
        switch step {
        case .downloading:
            return [pipeline.waitingForConnection ? "Waiting for the connection to come back" : "Getting the audio file"]
        case .transcribing:
            return ["Turning the speech into text on the phone; kept for good once made"]
        case .analyzing:
            return ["Finding the pauses, so cuts land between words"]
        case .detecting:
            let d = JobHeartbeat.shared.detail
            var lines: [String] = []
            if let note = pipeline.adFreeNote { lines.append(note) }
            // The on-device model at work (task 05): what it's doing, and
            // how many parts it has read — the progress is windows done.
            if let status = pipeline.finderStatus {
                lines.append(status)
                return lines
            }
            lines.append(d.phase.isEmpty ? "Comparing with the ad-free copy and repeated audio" : d.phase)
            var counts = "\(d.fresh) answer\(d.fresh == 1 ? "" : "s") from the on-device model"
            if d.reused > 0 { counts += ", \(d.reused) kept from before" }
            if d.waits > 0 { counts += " · iOS made it wait \(d.waits)×" }
            lines.append(counts)
            let quiet = Date().timeIntervalSince(JobHeartbeat.shared.last)
            if quiet > 20, JobHeartbeat.shared.last != .distantPast {
                lines.append("Last answer \(Int(quiet)) s ago")
            }
            return lines
        case .saving, .idle:
            return []
        }
    }
}

/// "Checking 2 episodes read while locked" (task 05), with the model's
/// progress on the one being read. Its own view: it redraws every second.
private struct CatchUpLine: View {
    let pipeline: ProcessingPipeline

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let monitor = LocalJudgeMonitor.shared
            let count = pipeline.modelCatchUpRemaining
            VStack(alignment: .leading, spacing: 4) {
                Label("Checking \(count) episode\(count == 1 ? "" : "s") read while locked",
                      systemImage: "text.magnifyingglass")
                    .font(.subheadline)
                if let title = pipeline.modelCatchUpTitle {
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if monitor.isRunning {
                    Text(monitor.windowsTotal == 0 ? "Loading the on-device model"
                         : "Reading with the on-device model — part \(min(monitor.windowsDone + 1, monitor.windowsTotal)) of \(monitor.windowsTotal)"
                            + (monitor.wordsPerSecond > 0 ? " (\(Int(monitor.wordsPerSecond.rounded())) words/s)" : ""))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Text("Only while PodSkipper is open.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct LineRow: View {
    let number: Int
    let episode: Episode?
    let preparing: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            ActivityEpisodeLine(episode: episode, fallbackTitle: "Episode", detail: detail)
        }
        .accessibilityIdentifier("activity.line.\(number)")
    }

    private var detail: String {
        guard let episode else { return "" }
        var parts = [episode.publishedAt.formatted(date: .abbreviated, time: .omitted)]
        if episode.duration > 0 { parts.append(formatDuration(episode.duration)) }
        if preparing { parts.append("Getting ready") }
        else {
            let plan = ProcessingPipeline.plan(for: episode).values.reduce(0, +)
            parts.append("about " + NowProgress.minutes(plan))
        }
        return parts.joined(separator: " · ")
    }
}

private struct FinishedRow: View {
    let episode: Episode

    var body: some View {
        ActivityEpisodeLine(episode: episode, fallbackTitle: "", detail: detail)
    }

    private var detail: String {
        let cuts = episode.adSegments.filter { $0.userVerdict != .notAnAd }
        let seconds = cuts.reduce(0) { $0 + $1.duration }
        let when = episode.lastProcessedAt.map { $0.formatted(.relative(presentation: .named)) } ?? ""
        let what = cuts.isEmpty ? "Nothing cut" : "\(cuts.count) cut\(cuts.count == 1 ? "" : "s") · \(formatDuration(seconds))"
        // Who found them (task 05), in a word or two.
        let who = episode.modelPending ? "reader for now"
            : episode.needsFullModelRead ? "model, quick check"
            : episode.modelVersion > 0 ? "on-device model"
            : episode.finderNote.contains("isn't downloaded") ? "reader, model not downloaded yet" : ""
        return [what, who, when].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
