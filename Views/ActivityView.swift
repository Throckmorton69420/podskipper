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

/// The running job's step, bar, time spent and time left. Its own view: it
/// redraws every second.
private struct NowProgress: View {
    let pipeline: ProcessingPipeline

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: min(1, max(0, pipeline.overallFraction)))
                HStack {
                    Text((pipeline.batchLabel.map { $0 + " · " } ?? "") + pipeline.stage.label)
                    Spacer()
                    Text("\(Int(min(1, max(0, pipeline.overallFraction)) * 100))%").monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if let started = pipeline.jobStartedAt {
                        Text("Spent " + Self.minutes(context.date.timeIntervalSince(started)))
                    }
                    Spacer()
                    if let eta = pipeline.etaSeconds {
                        Text("About " + Self.minutes(eta) + " left")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    static func minutes(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        return m < 1 ? "under a minute" : m < 60 ? "\(m) min" : "\(m / 60) h \(m % 60) min"
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
        return [what, when].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
