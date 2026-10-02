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
            failedSection
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
            Feel.selection.play()
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
        for guid in pipeline.waitingQueue + pipeline.unfinishedJobs + pipeline.pausedLine.guids + pipeline.failedJobs.map(\.guid) + [pipeline.currentEpisodeGUID].compactMap({ $0 }) {
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

    /// The same view the activity card shows (task 10), so the two can't
    /// drift apart.
    private var nowSection: some View {
        Section("Now") {
            ActivityNowContent(pipeline: pipeline)
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
                                    Feel.warning.play()
                                    pipeline.cancelWaiting(guid)
                                }
                            }
                    }
                    .onMove { pipeline.moveInLine(from: $0, to: $1) }
                }
            } header: {
                Button {
                    Feel.toggle.play()
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
        let held = pipeline.pausedLine.guids
        let interrupted = pipeline.unfinishedJobs.filter {
            !held.contains($0) && !pipeline.waitingQueue.contains($0) && $0 != pipeline.currentEpisodeGUID
        }
        let paused = held + interrupted
        if !paused.isEmpty {
            Section {
                ForEach(paused, id: \.self) { guid in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            ActivityEpisodeLine(episode: lookup[guid], fallbackTitle: pipeline.jobRecord(guid)?.title ?? "Episode")
                            if let reason = pipeline.jobRecord(guid)?.reason {
                                Text(reason).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let episode = lookup[guid] {
                            Button("Resume") {
                                Feel.confirm.play()
                                Task { await pipeline.processNow(episode) }
                            }
                                .buttonStyle(.glass)
                        }
                    }
                    .swipeActions {
                        Button("Forget", role: .destructive) {
                            Feel.warning.play()
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
                            Feel.confirm.play()
                            pipeline.resumeLine()
                            pipeline.processNow(interrupted.compactMap { lookup[$0] })
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
            } footer: {
                Text("Paused by you, interrupted by iOS, or left unfinished when the app closed. Everything done so far is kept; Resume carries on from there.")
            }
        }
    }

    @ViewBuilder
    private var failedSection: some View {
        if !pipeline.failedJobs.isEmpty {
            Section("Needs Attention") {
                ForEach(Array(pipeline.failedJobs.prefix(40))) { job in
                    VStack(alignment: .leading, spacing: 8) {
                        ActivityEpisodeLine(episode: lookup[job.guid], fallbackTitle: job.title)
                        Text(job.reason ?? "This task did not finish.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let episode = lookup[job.guid] {
                            Button("Retry") { Task { await pipeline.processNow(episode) } }
                                .buttonStyle(.glass)
                        }
                    }
                }
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
