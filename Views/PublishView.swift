import SwiftUI
import SwiftData

/// The Publish screen.
///
/// Modelled on Castro's inbox: everything you own in one triage list, with
/// filters and multi-select, rather than making you walk into each show one
/// at a time. Selecting episodes and acting on the batch is the whole point.
struct PublishView: View {
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @Query private var allEpisodes: [Episode]

    @State private var publisher = FeedPublisher.shared
    @State private var selection = Set<PersistentIdentifier>()
    @State private var filter: Filter = .all
    @State private var sort: SortOrder = .newest
    @State private var message: String?
    @State private var isWorking = false

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case needsProcessing = "Needs AI"
        case readyToPublish = "Ready"
        case published = "Published"
        var id: String { rawValue }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case oldest = "Oldest"
        case show = "Show"
        case longestAds = "Most ads"
        var id: String { rawValue }
    }

    // MARK: - Derived data

    private var visible: [Episode] {
        let filtered = allEpisodes.filter { episode in
            switch filter {
            case .all:             return true
            case .needsProcessing: return episode.processingState != .ready
            case .readyToPublish:  return episode.processingState == .ready && episode.publishedURL == nil
            case .published:       return episode.publishedURL != nil
            }
        }
        switch sort {
        case .newest:     return filtered.sorted { $0.publishedAt > $1.publishedAt }
        case .oldest:     return filtered.sorted { $0.publishedAt < $1.publishedAt }
        case .show:       return filtered.sorted {
            ($0.podcast?.title ?? "", $1.publishedAt) < ($1.podcast?.title ?? "", $0.publishedAt)
        }
        case .longestAds: return filtered.sorted { $0.adSecondsRemoved > $1.adSecondsRemoved }
        }
    }

    private var grouped: [(show: String, episodes: [Episode])] {
        let buckets = Dictionary(grouping: visible) { $0.podcast?.title ?? "Unknown show" }
        return buckets.keys.sorted().map { ($0, buckets[$0] ?? []) }
    }

    private var selectedEpisodes: [Episode] {
        visible.filter { selection.contains($0.persistentModelID) }
    }

    private var selectedNeedingAI: [Episode] {
        selectedEpisodes.filter { $0.processingState != .ready }
    }

    private var selectedReady: [Episode] {
        selectedEpisodes.filter { $0.processingState == .ready }
    }

    // MARK: - Body

    var body: some View {
        List {
            if pipeline.isRunning || publisher.isPublishing {
                Section { activityCard }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }

            Section { controls }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 6, trailing: 12))

            if let message {
                Section {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }

            ForEach(grouped, id: \.show) { group in
                Section {
                    ForEach(group.episodes) { episode in
                        EpisodeSelectRow(
                            episode: episode,
                            isSelected: selection.contains(episode.persistentModelID)
                        ) {
                            toggle(episode)
                        }
                    }
                } header: {
                    HStack {
                        Text(group.show).textCase(nil)
                        Spacer()
                        Button(allSelected(in: group.episodes) ? "None" : "All") {
                            selectAll(in: group.episodes)
                        }
                        .font(.caption.weight(.medium))
                        .textCase(nil)
                    }
                }
            }
        }
        .navigationTitle("Publish")
        .amoledScreen()
        .safeAreaInset(edge: .bottom) { actionBar }
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView("Nothing here",
                                       systemImage: "tray",
                                       description: Text("Add a show and process an episode first."))
            }
        }
    }

    // MARK: - Pieces

    private var activityCard: some View {
        Group {
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
            } else {
                DetailedProgressView(
                    title: publisher.currentEpisodeTitle ?? "Publishing",
                    stepName: publisher.stage.label,
                    stepIndex: publisher.stage.number,
                    stepCount: FeedPublisher.Stage.count,
                    fraction: publisher.overallFraction,
                    etaSeconds: publisher.etaSeconds,
                    queueRemaining: publisher.itemsRemaining
                )
            }
        }
        .glassCard()
    }

    private var controls: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Filter.allCases) { option in
                        Button {
                            filter = option
                            selection.removeAll()
                        } label: {
                            Text(option.rawValue)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(filter == option
                                                   ? AnyShapeStyle(Theme.accentGradient)
                                                   : AnyShapeStyle(Color.white.opacity(0.10)))
                                )
                                .foregroundStyle(filter == option ? Color.black : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Picker("Sort", selection: $sort) {
                    ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)

                Spacer()

                Text("\(visible.count) episode\(visible.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var actionBar: some View {
        Group {
            if !selection.isEmpty {
                VStack(spacing: 10) {
                    HStack {
                        Text("\(selection.count) selected")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Button("Clear") { selection.removeAll() }
                            .font(.caption)
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task { await processSelected() }
                        } label: {
                            Label("Find ads (\(selectedNeedingAI.count))",
                                  systemImage: "wand.and.sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(selectedNeedingAI.isEmpty || isWorking || pipeline.isRunning)

                        Button {
                            Task { await publishSelected() }
                        } label: {
                            Label("Publish (\(selectedReady.count))",
                                  systemImage: "arrow.up.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(selectedReady.isEmpty || isWorking || publisher.isPublishing)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .glassCard(cornerRadius: 22)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Actions

    private func toggle(_ episode: Episode) {
        if selection.contains(episode.persistentModelID) {
            selection.remove(episode.persistentModelID)
        } else {
            selection.insert(episode.persistentModelID)
        }
    }

    private func allSelected(in episodes: [Episode]) -> Bool {
        !episodes.isEmpty && episodes.allSatisfy { selection.contains($0.persistentModelID) }
    }

    private func selectAll(in episodes: [Episode]) {
        if allSelected(in: episodes) {
            for episode in episodes { selection.remove(episode.persistentModelID) }
        } else {
            for episode in episodes { selection.insert(episode.persistentModelID) }
        }
    }

    private func processSelected() async {
        isWorking = true
        message = nil
        defer { isWorking = false }
        let targets = selectedNeedingAI
        for episode in targets { episode.isInQueue = true }
        try? context.save()
        await pipeline.process(targets)
        message = "Processed \(targets.count) episode\(targets.count == 1 ? "" : "s")."
    }

    private func publishSelected() async {
        isWorking = true
        message = nil
        defer { isWorking = false }

        publisher.configure(context: context, pipeline: pipeline)

        // Group the selection by show — one feed rewrite per show, not per episode.
        let byShow = Dictionary(grouping: selectedReady) { $0.podcast }
        var total = 0
        var failures: [String] = []

        for (podcast, episodes) in byShow {
            guard let podcast else { continue }
            do {
                let result = try await publisher.publish(podcast, only: episodes)
                total += result.episodesPublished
            } catch {
                failures.append("\(podcast.title): \(error.localizedDescription)")
            }
        }

        if failures.isEmpty {
            message = "Published \(total) episode\(total == 1 ? "" : "s"). Feed addresses are on each show's page."
            selection.removeAll()
        } else {
            message = failures.joined(separator: "\n")
        }
    }
}

// MARK: - Row

struct EpisodeSelectRow: View {
    let episode: Episode
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Theme.accentHot : Color.secondary)

                VStack(alignment: .leading, spacing: 5) {
                    Text(episode.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Text(episode.publishedAt, format: .dateTime.month().day().year())
                        if episode.duration > 0 {
                            Text("· \(Int(episode.duration / 60))m")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        statusPill
                        if episode.processingState == .ready && !episode.adSegments.isEmpty {
                            StatusPill(text: "\(episode.adSegments.count) ads · \(Int(episode.adSecondsRemoved / 60))m",
                                       tint: Theme.adTint)
                        }
                        if episode.isDownloaded {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }

    private var statusPill: some View {
        switch episode.processingState {
        case .ready:
            return episode.publishedURL != nil
                ? StatusPill(text: "Published", tint: .green, filled: true)
                : StatusPill(text: "Ready", tint: .green)
        case .failed:
            return StatusPill(text: "Failed", tint: .red)
        case .notStarted:
            return StatusPill(text: "Not processed", tint: .gray)
        default:
            return StatusPill(text: "Working", tint: .orange)
        }
    }
}
