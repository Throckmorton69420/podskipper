import SwiftUI
import SwiftData

struct UpNextView: View {
    @Query(filter: #Predicate<Episode> { $0.isInQueue },
           sort: \Episode.queueOrder) private var queue: [Episode]
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @State private var player = PlayerEngine.shared

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
        // No banner here: every episode in this list draws its own progress,
        // so a floating one would be saying the same thing twice and pushing
        // the list down to do it.
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .toolbar {
            if pipeline.isRunning && !visible.contains(where: { pipeline.isProcessing($0) }) {
                ToolbarItem(placement: .topBarTrailing) {
                    ProcessingToolbarChip(pipeline: pipeline)
                }
            }
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
                EpisodeRow(episode: episode, showsShowName: true)
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

            BottomClearance()
        }
        .listStyle(.plain)
        .onChange(of: queue.map(\.queueOrder)) { PrepareAhead.shared.refresh() }
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

/// Which episodes "Prepare N ahead" is working on, and whether they are done.
///
/// Reported as looking random: it listed two older episodes of one show,
/// skipped one in between and left out what had just been added to Up Next.
/// The order was the cause (now Up Next first, then the show), and the card
/// never said how it chose. Now each line says why it is there — "Up Next"
/// or "Next in <show>" — with its date, the card says that played episodes
/// are skipped, and tapping a line opens that episode.
struct ReadyAheadCard: View {
    @State private var ahead = PrepareAhead.shared
    @Environment(ProcessingPipeline.self) private var pipeline
    @State private var expanded = false

    var body: some View {
        if ahead.limit > 0, !ahead.targets.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                    Haptics.select()
                } label: {
                    HStack {
                        Label("Getting the next \(ahead.limit) ready", systemImage: "sparkles")
                            .font(.subheadline.weight(.semibold))
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

                ForEach(ahead.targets) { episode in
                    NavigationLink {
                        EpisodeDetailView(episode: episode)
                    } label: {
                        line(for: episode)
                    }
                    .buttonStyle(.plain)
                }

                if expanded {
                    Text("Finds the ads in what will play next, before you get there, so it is ad-free when it starts. It takes what you've put in Up Next first, then carries on through the show that's playing, in that show's order, skipping anything you've already played. Change how many in Settings → Playback.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }

                if !ahead.pending.isEmpty {
                    Button {
                        Haptics.select()
                        ahead.prepareNow()
                    } label: {
                        Text(pipeline.isRunning ? "Working on another episode…" : "Prepare Now")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .disabled(pipeline.isRunning)
                }
            }
            .padding(12)
            .glassPanel(cornerRadius: 18)
        }
    }

    private func line(for episode: Episode) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Artwork(url: episode.artworkURL ?? episode.podcast?.artworkURL, size: UIScale.pt(40))
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(episode.publishedAt, format: .dateTime.month(.abbreviated).day().year())
                    Text("·")
                    Text(reason(for: episode))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                status(for: episode)
                Text(label(for: episode))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func reason(for episode: Episode) -> String {
        if episode.isInQueue { return "Up Next" }
        return "Next in \(episode.podcast?.title ?? "this show")"
    }

    @ViewBuilder
    private func status(for episode: Episode) -> some View {
        if episode.processingState == .ready {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if pipeline.isProcessing(episode) {
            ProgressView().controlSize(.mini)
        } else if episode.processingState == .failed {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            Image(systemName: "clock").foregroundStyle(.secondary)
        }
    }

    private func label(for episode: Episode) -> String {
        if episode.processingState == .ready { return "Ad-free" }
        if pipeline.isProcessing(episode) { return pipeline.stage.label }
        if episode.processingState == .failed { return "Failed" }
        return "Waiting"
    }
}
