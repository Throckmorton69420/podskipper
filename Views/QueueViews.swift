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
    }

    enum Sort: String, CaseIterable, Identifiable {
        case manual = "My order"
        case newest = "Newest"
        case oldest = "Oldest"
        case shortest = "Shortest"
        case priority = "Show priority"
        var id: String { rawValue }
    }

    private var base: [Episode] {
        queue.filter { !$0.isPlayed }
    }

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

    private var totalRemaining: Double {
        visible.reduce(0) { $0 + $1.remainingSeconds }
    }

    private var unprocessed: Int {
        base.filter { $0.processingState != .ready }.count
    }

    var body: some View {
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
                .glassCard()
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
            }

            Section {
                ChipRow(options: Filter.allCases, label: { $0.rawValue }, selection: $filter)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 4, trailing: 0))
                    .listRowSeparator(.hidden)
            }

            if !visible.isEmpty {
                HStack {
                    Label(formatMinutes(totalRemaining), systemImage: "clock")
                    Spacer()
                    Text("\(visible.count) episode\(visible.count == 1 ? "" : "s")")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 8, trailing: 20))
            }

            ForEach(visible) { episode in
                QueueRow(episode: episode)
                    .glassListRow()
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
                        Button {
                            moveToTop(episode)
                        } label: { Label("Top", systemImage: "arrow.up.to.line") }
                            .tint(Theme.accentHot)
                    }
            }
            .onMove { indices, destination in
                // Manual order is the only one that's meaningful to drag.
                guard sort == .manual else { return }
                move(from: indices, to: destination)
            }
        }
        .listStyle(.plain)
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
                        Button(isEditing ? "Done reordering" : "Reorder") {
                            withAnimation { isEditing.toggle() }
                        }
                    }
                    Button("Clear played", systemImage: "trash") { clearPlayed() }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if unprocessed > 0 {
                    Button {
                        Task { await pipeline.processPending(limit: unprocessed) }
                    } label: { Image(systemName: "wand.and.sparkles") }
                        .disabled(pipeline.isRunning)
                }
            }
        }
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView("Nothing up next",
                    systemImage: "list.bullet",
                    description: Text("Swipe an episode right in a show, or tap \"Find ads\" to queue it."))
            }
        }
    }

    // MARK: - Reordering

    private func move(from offsets: IndexSet, to destination: Int) {
        var ordered = visible
        ordered.move(fromOffsets: offsets, toOffset: destination)
        for (index, episode) in ordered.enumerated() {
            episode.queueOrder = index
        }
        try? context.save()
    }

    private func moveToTop(_ episode: Episode) {
        let lowest = visible.map(\.queueOrder).min() ?? 0
        episode.queueOrder = lowest - 1
        try? context.save()
    }

    private func clearPlayed() {
        for episode in queue where episode.isPlayed {
            episode.isInQueue = false
        }
        try? context.save()
    }
}

struct QueueRow: View {
    let episode: Episode
    @State private var player = PlayerEngine.shared

    var body: some View {
        HStack(spacing: 11) {
            Artwork(url: episode.artworkURL ?? episode.podcast?.artworkURL, size: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(episode.podcast?.title ?? "")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(episode.title)
                    .font(.subheadline.weight(.medium)).lineLimit(2)

                HStack(spacing: 6) {
                    Text(formatMinutes(episode.remainingSeconds))
                    if episode.processingState == .ready {
                        StatusPill(text: "Ad-free", tint: .green)
                    } else if episode.processingState == .notStarted {
                        StatusPill(text: "Needs AI", tint: .gray)
                    } else {
                        StatusPill(text: episode.stateSummary, tint: .orange)
                    }
                    if episode.podcast?.priority == 1 {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.caption2).foregroundStyle(Theme.accentWarm)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                player.load(episode)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accentHot)
            }
            .buttonStyle(.plain)
        }
    }
}
