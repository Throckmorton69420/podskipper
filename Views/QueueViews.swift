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
        case all = "All", ready = "Ad-free", downloaded = "Downloaded", pending = "Needs AI"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .all:        return "list.bullet"
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

    private var base: [Episode] { queue.filter { !$0.isPlayed } }

    private var visible: [Episode] {
        var list = base
        switch filter {
        case .all:        break
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
            ($0.podcast?.priority ?? 0, -$1.queueOrder) > ($1.podcast?.priority ?? 0, -$0.queueOrder)
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
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
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
            if pipeline.isRunning {
                DetailedProgressView(
                    title: pipeline.currentEpisodeTitle ?? "Working",
                    stepName: pipeline.stage.label,
                    stepIndex: pipeline.stage.number,
                    stepCount: ProcessingPipeline.Stage.count,
                    fraction: pipeline.overallFraction,
                    etaSeconds: pipeline.etaSeconds,
                    queueRemaining: pipeline.queueRemaining
                )
                .padding(14)
                .glassControl(cornerRadius: 20)
                .plainRow(top: 8, bottom: 4)
            }

            FilterChips(options: Filter.allCases, label: { $0.rawValue },
                        selection: $filter, symbol: { $0.symbol })
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 0))

            HStack(spacing: 8) {
                Image(systemName: "clock")
                Text(formatMinutes(totalRemaining))
                Text("·")
                Text("\(visible.count) episode\(visible.count == 1 ? "" : "s")")
                Spacer()
                Button {
                    if let first = visible.first(where: { $0.isDownloaded }) ?? visible.first {
                        player.load(first)
                    }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .contentChip(tint: Theme.accentHot)
                }
                .buttonStyle(.plain)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .plainRow(top: 0, bottom: 6)

            ForEach(visible) { episode in
                EpisodeCompactRow(episode: episode)
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

            Color.clear.frame(height: 70).plainRow(top: 0, bottom: 0)
        }
        .listStyle(.plain)
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
