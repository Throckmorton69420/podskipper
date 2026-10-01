import SwiftUI
import SwiftData

/// The job running now, as one view: the Activity page's Now section and the
/// activity card that opens from the bar both draw this (task 10 — he asked
/// for the pop-up to look the same as the page and show the same details).
///
/// Cover, show and episode; who asked for it and how many more are waiting;
/// the overall bar with time spent and left; every step done, under way or
/// still to come, with what the finder is doing; and the same actions — Open,
/// Pause, Stop, and Restart when it has stopped moving; while paused, Resume
/// and Stop.
struct ActivityNowContent: View {
    let pipeline: ProcessingPipeline
    /// False where there is no navigation stack to open the episode on (the
    /// publisher's sheet).
    var canOpen = true
    /// Called when Open is tapped, so the card can fold itself away first.
    var onOpen: () -> Void = {}

    @Environment(\.modelContext) private var context
    @State private var episode: Episode?

    var body: some View {
        Group {
            if pipeline.isRunning, pipeline.currentEpisodeGUID != nil {
                running
            } else if pipeline.pausedLine.isPaused {
                paused
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
        .task(id: "\(pipeline.currentEpisodeGUID ?? "")|\(pipeline.pausedLine.guids.first ?? "")") { load() }
    }

    /// Task 14: his line held, with everything done so far kept. The same
    /// view on the page and in the card, like the running one.
    private var paused: some View {
        let held = pipeline.pausedLine.guids
        return VStack(alignment: .leading, spacing: 10) {
            ActivityEpisodeLine(episode: episode, fallbackTitle: "Episode",
                                detail: "Paused" + (held.count > 1 ? " · \(held.count - 1) more held" : "")
                                    + " · everything done so far is kept")
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button {
                    Feel.confirm.play()
                    pipeline.resumeLine()
                } label: {
                    Label("Resume", systemImage: "play.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("activity.resume")
                Button(role: .destructive) {
                    Feel.warning.play()
                    if let first = held.first { pipeline.forgetPaused(first) }
                } label: {
                    Label("Stop Finding Ads", systemImage: "stop.circle")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("activity.stop")
            }
        }
        .padding(.vertical, 4)
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 10) {
            ActivityEpisodeLine(episode: episode, fallbackTitle: pipeline.currentEpisodeTitle ?? "",
                                detail: detail)
            NowProgress(pipeline: pipeline)
            if let minutes = pipeline.stalledMinutes {
                StalledLine(pipeline: pipeline, minutes: minutes)
            }
            if let episode {
                actions(episode)
            }
        }
        .padding(.vertical, 4)
    }

    private var detail: String {
        let waiting = pipeline.waitingQueue.count
        let more = waiting == 0 ? "" : " · \(waiting) more waiting"
        return pipeline.currentOrigin == .user
            ? "You asked for this" + more
            : "Getting Up Next ready by itself" + more + " · steps aside when you ask for one"
    }

    private func actions(_ episode: Episode) -> some View {
        HStack(spacing: 8) {
            if canOpen {
                NavigationLink(value: EpisodeRoute(episode)) {
                    GlassButtonLabel(title: "Open", systemImage: "arrow.up.forward.app", fills: false)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .simultaneousGesture(TapGesture().onEnded { onOpen() })
                .accessibilityIdentifier("activity.open")
            }
            Spacer(minLength: 0)
            Button {
                Feel.selection.play()
                pipeline.pauseJob(episode)
            } label: {
                GlassButtonLabel(title: pipeline.pausing ? "Pausing…" : "Pause",
                                 systemImage: "pause.circle", fills: false)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .disabled(pipeline.pausing || pipeline.stopping)
            .accessibilityIdentifier("activity.pause")
            Button(role: .destructive) {
                Feel.warning.play()
                pipeline.stopJob(episode)
            } label: {
                GlassButtonLabel(title: pipeline.stopping ? "Stopping…" : "Stop Finding Ads",
                                 systemImage: "stop.circle", fills: false)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .disabled(pipeline.stopping || pipeline.pausing)
            .accessibilityIdentifier("activity.stop")
        }
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func load() {
        guard let guid = pipeline.currentEpisodeGUID ?? pipeline.pausedLine.guids.first else { episode = nil; return }
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        descriptor.fetchLimit = 1
        episode = try? context.fetch(descriptor).first
    }
}

/// Cover, show and title of one episode, for the Activity screen.
struct ActivityEpisodeLine: View {
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
struct NowProgress: View {
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

