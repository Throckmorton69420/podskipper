import SwiftUI
import SwiftData

struct UpNextView: View {
    @Query(filter: #Predicate<Episode> { $0.isInQueue },
           sort: \Episode.queueOrder) private var queue: [Episode]
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @State private var player = PlayerEngine.shared

    @State private var ahead = PrepareAhead.shared
    /// Where autoplay goes after the list — see `NextUpProvider.continuation`.
    @State private var continuation: [Episode] = []
    @State private var filter: Filter = .all
    @State private var sort: Sort = .manual
    @State private var isEditing = false

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", unplayed = "Unplayed", played = "Played"
        case ready = "Ad-free", downloaded = "Downloaded", pending = "Needs AI"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .all:        return "list.bullet"
            case .unplayed:   return "circle"
            case .played:     return "checkmark.circle"
            case .ready:      return "checkmark.seal.fill"
            case .downloaded: return "arrow.down.circle.fill"
            case .pending:    return "wand.and.sparkles"
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case manual = "My Order", newest = "Newest", oldest = "Oldest"
        case shortest = "Shortest", priority = "Show Priority"
        var id: String { rawValue }
    }

    /// Everything you queued, played or not. Hiding played episodes meant an
    /// episode added to hear again simply never appeared.
    private var base: [Episode] { queue }

    private var visible: [Episode] {
        var list = base
        switch filter {
        case .all:        break
        case .unplayed:   list = list.filter { !$0.isPlayed }
        case .played:     list = list.filter { $0.isPlayed }
        case .ready:      list = list.filter { $0.processingState == .ready }
        case .downloaded: list = list.filter { $0.isDownloaded }
        case .pending:    list = list.filter { $0.processingState != .ready }
        }
        switch sort {
        case .manual:   return list.sorted { $0.queueOrder < $1.queueOrder }
        case .newest:   return list.sorted { $0.publishedAt > $1.publishedAt }
        case .oldest:   return list.sorted { $0.publishedAt < $1.publishedAt }
        case .shortest: return list.sorted { $0.remainingSeconds < $1.remainingSeconds }
        case .priority: return list.sorted {
            ($0.podcast?.priority ?? 0, -$0.queueOrder) > ($1.podcast?.priority ?? 0, -$1.queueOrder)
        }
        }
    }

    private var totalRemaining: Double { visible.reduce(0) { $0 + $1.remainingSeconds } }
    private var unprocessed: Int { base.filter { $0.processingState != .ready }.count }

    var body: some View {
        Group {
            if base.isEmpty {
                ContentUnavailableView("Nothing up next",
                    systemImage: "list.bullet",
                    description: Text("Swipe an episode right in any show, or tap Find Ads to queue it."))
                    .amoledScreen()
            } else {
                list
            }
        }
        .navigationTitle("Up Next")
        .amoledScreen()
        // The same activity bar as the Library, which opens into the full
        // card. Up Next had only a percentage in the corner that could not be
        // opened — reported, with a Find Ads job running.
        .processingBanner(pipeline, publisher: FeedPublisher.shared)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .task(id: continuationKey) { refreshContinuation() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Divider()
                    if sort == .manual {
                        Button(isEditing ? "Done Reordering" : "Reorder", systemImage: "arrow.up.arrow.down") {
                            withAnimation { isEditing.toggle() }
                        }
                    }
                    if unprocessed > 0 {
                        Button("Process All (\(unprocessed))", systemImage: "wand.and.sparkles") {
                            Task { await pipeline.processPending(limit: unprocessed) }
                        }
                        .disabled(pipeline.isRunning)
                    }
                    Button("Clear Played", systemImage: "trash", role: .destructive) { clearPlayed() }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
    }

    private var list: some View {
        List {
            // One filter idiom across the app. This was a scrolling chip strip
            // that ran off the right edge of the screen.
            SectionMenuBar(title: filter.rawValue) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { option in
                        Label(option.rawValue, systemImage: option.symbol).tag(option)
                    }
                }
                Divider()
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
            } trailing: {
                Button {
                    if let first = visible.first(where: { $0.isDownloaded }) ?? visible.first {
                        player.load(first)
                    }
                } label: {
                    Label("Play All", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentHot)
                .disabled(visible.isEmpty)
            }
            .plainRow(top: 12, bottom: 2)

            HStack(spacing: 6) {
                Image(systemName: "clock")
                Text(formatMinutes(totalRemaining))
                Text("·")
                Text("\(visible.count) episode\(visible.count == 1 ? "" : "s")")
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .plainRow(top: 0, bottom: 6)

            ReadyAheadCard()
                .plainRow(top: 2, bottom: 8)

            // The same row as a show page — date, number, description, cover,
            // play and Find Ads — with the show named above, since Up Next
            // mixes shows. It was a compact row with no date or description,
            // and episodes added by hand looked like they had lost both.
            ForEach(visible) { episode in
                EpisodeRow(episode: episode, showsShowName: true,
                           aheadNote: ahead.status(of: episode))
                    .contentRow()
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            episode.isInQueue = false; try? context.save()
                        } label: { Label("Remove", systemImage: "minus.circle") }
                        Button {
                            episode.isPlayed = true
                            episode.isInQueue = false
                            try? context.save()
                        } label: { Label("Played", systemImage: "checkmark.circle") }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .leading) {
                        Button { moveToTop(episode) } label: {
                            Label("Top", systemImage: "arrow.up.to.line")
                        }
                        .tint(Theme.accentHot)
                    }
            }
            .onMove { indices, destination in
                guard sort == .manual else { return }
                move(from: indices, to: destination)
            }

            if visible.isEmpty {
                ContentUnavailableView("Nothing matches that filter", systemImage: "line.3.horizontal.decrease")
                    .plainRow(top: 40, bottom: 40)
            }

            continuationSection

            BottomClearance()
        }
        .listStyle(.plain)
        .onChange(of: queue.map(\.queueOrder)) { PrepareAhead.shared.refresh() }
    }

    /// After the list, autoplay carries on through the playing show. Those
    /// episodes are not in Up Next — nothing was added behind your back — but
    /// they are listed, and the next few are got ready like the rest.
    @ViewBuilder
    private var continuationSection: some View {
        if !continuation.isEmpty, filter == .all {
            SectionHeader(title: "Then from \(continuation.first?.podcast?.title ?? "this show")") {
                Text("Autoplay").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(continuation) { episode in
                EpisodeRow(episode: episode, aheadNote: ahead.status(of: episode))
                    .contentRow()
                    .swipeActions(edge: .leading) {
                        Button {
                            episode.addToUpNext(next: false, context: context)
                            refreshContinuation()
                        } label: { Label("Add", systemImage: "text.append") }
                        .tint(Theme.accentHot)
                    }
            }
        }
    }

    private var continuationKey: String {
        "\(player.currentEpisode?.guid ?? "")|\(queue.count)|\(ahead.targets.count)"
    }

    private func refreshContinuation() {
        continuation = NextUpProvider.continuation(in: context, after: player.currentEpisode, limit: 3)
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        var ordered = visible
        ordered.move(fromOffsets: offsets, toOffset: destination)
        for (index, episode) in ordered.enumerated() { episode.queueOrder = index }
        try? context.save()
    }

    private func moveToTop(_ episode: Episode) {
        episode.queueOrder = (visible.map(\.queueOrder).min() ?? 0) - 1
        try? context.save()
    }

    private func clearPlayed() {
        for episode in queue where episode.isPlayed { episode.isInQueue = false }
        try? context.save()
    }
}


// MARK: - Ready ahead

/// How "Prepare N ahead" is doing, in one line.
///
/// It used to list its episodes, and they were the same episodes listed right
/// below it in Up Next — reported as duplicated. Now the card says how many
/// are ready and what it is doing; each episode's own row says whether it is
/// ready or waiting, in Up Next or in the "Then from" list under it.
struct ReadyAheadCard: View {
    @State private var ahead = PrepareAhead.shared
    @Environment(ProcessingPipeline.self) private var pipeline
    @State private var expanded = false

    var body: some View {
        if ahead.limit > 0, !ahead.targets.isEmpty {
            let ready = ahead.targets.count - ahead.pending.count
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                    Haptics.select()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: ready == ahead.targets.count ? "checkmark.seal.fill" : "sparkles")
                            .foregroundStyle(ready == ahead.targets.count ? .green : Theme.accentHot)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Next \(ahead.targets.count): \(ready) ad-free")
                                .font(.subheadline.weight(.semibold))
                            Text(statusLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ReadyAheadHeader")

                if expanded {
                    Text("PodSkipper finds the ads in what will play next, before you get there. It takes Up Next first — episodes you haven't heard before ones you're replaying — then carries on through the show that's playing, in that show's order, skipping what you've played. It waits in Low Power Mode or when the phone is hot. Change how many in Settings → Playback.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }

                if !ahead.pending.isEmpty, !pipeline.isRunning {
                    Button {
                        Haptics.select()
                        ahead.prepareNow()
                    } label: {
                        Text("Prepare Now")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(12)
            .glassPanel(cornerRadius: 18)
        }
    }

    private var statusLine: String {
        if ahead.pending.isEmpty { return "Ready to play without ads." }
        if let current = ahead.targets.first(where: { pipeline.isProcessing($0) }) {
            return "Working on “\(current.title)”"
        }
        if let reason = pipeline.speculativePausedReason { return reason }
        if pipeline.isRunning { return "Starts when the current job finishes" }
        return "Starting shortly"
    }
}
