import SwiftUI
import SwiftData
import UIKit

/// Publish, in two levels.
///
/// The first version dumped every episode you own into one flat list. With
/// 584 episodes that meant scrolling past hundreds of one show before
/// reaching the next. Shows first, episodes inside — the same shape Apple
/// Podcasts uses, and the only one that survives a real library.
struct PublishView: View {
    @Query private var podcasts: [Podcast]
    @Environment(ProcessingPipeline.self) private var pipeline
    @State private var publisher = FeedPublisher.shared
    @State private var search = ""
    @State private var sort: ShowSort = .mostReady

    enum ShowSort: String, CaseIterable, Identifiable {
        case mostReady = "Most ad-free"
        case published = "Published"
        case title = "Title"
        case recent = "Recently added"
        var id: String { rawValue }
    }

    private var visible: [Podcast] {
        var list = podcasts.filter { !$0.isArchived }
        if !search.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(search) }
        }
        switch sort {
        case .mostReady: return list.sorted { $0.readyCount > $1.readyCount }
        case .published: return list.sorted { $0.publishedCount > $1.publishedCount }
        case .title:     return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .recent:    return list.sorted { $0.dateAdded > $1.dateAdded }
        }
    }

    private var totals: (ready: Int, published: Int) {
        (podcasts.reduce(0) { $0 + $1.readyCount },
         podcasts.reduce(0) { $0 + $1.publishedCount })
    }

    var body: some View {
        List {
            if pipeline.isRunning || publisher.isPublishing {
                activityCard.plainRow(top: 6, bottom: 6)
            }

            HStack(spacing: 14) {
                summaryStat(value: totals.ready, label: "ad-free", tint: .green)
                summaryStat(value: totals.published, label: "published", tint: Theme.accentHot)
                Spacer()
            }
            .plainRow(top: 0, bottom: 8)

            ForEach(visible) { podcast in
                NavigationLink(destination: PublishShowView(podcast: podcast)) {
                    PublishShowRow(podcast: podcast)
                }
                .contentRow()
            }

            if visible.isEmpty {
                ContentUnavailableView("Nothing to publish",
                    systemImage: "dot.radiowaves.up.forward",
                    description: Text("Process an episode first, then come back."))
                    .plainRow(top: 40, bottom: 40)
            }

            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle("Publish")
        .amoledScreen()
        .processingBanner(pipeline, publisher: publisher)
        .searchable(text: $search, prompt: "Search shows")
        .toolbar {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(ShowSort.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
        }

    }

    private func summaryStat(value: Int, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)").font(.title3.bold().monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

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
        // A card inside a list is content, not navigation, so it gets the flat
        // surface rather than glass. Glass here had nothing behind it to
        // refract and rendered as a grey slab sitting on the page.
        .contentCard(cornerRadius: Metrics.panelCorner)
    }
}

struct PublishShowRow: View {
    let podcast: Podcast

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: podcast.artworkURL, size: Metrics.artRow)
            VStack(alignment: .leading, spacing: 4) {
                Text(podcast.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    if podcast.readyCount > 0 {
                        StatusPill(text: "\(podcast.readyCount) ad-free", tint: .green)
                    }
                    if podcast.publishedCount > 0 {
                        StatusPill(text: "\(podcast.publishedCount) published",
                                   tint: Theme.accentHot, filled: true)
                    }
                    if podcast.readyCount == 0 && podcast.publishedCount == 0 {
                        StatusPill(text: "\(podcast.episodes.count) episodes", tint: .gray)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - One show's episodes

struct PublishShowView: View {
    let podcast: Podcast
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @State private var publisher = FeedPublisher.shared

    @State private var selection = Set<PersistentIdentifier>()
    @State private var filter: Filter = .ready
    @State private var sort: Sort = .newest
    @State private var message: String?
    @State private var isWorking = false

    enum Filter: String, CaseIterable, Identifiable {
        case ready = "Ready", needsAI = "Needs AI", published = "Published", all = "All"
        var id: String { rawValue }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case newest = "Newest", oldest = "Oldest", mostAds = "Most ads"
        var id: String { rawValue }
    }

    private var episodes: [Episode] {
        var list = podcast.episodes.filter { !$0.isArchived }
        switch filter {
        case .ready:     list = list.filter { $0.processingState == .ready && $0.publishedURL == nil }
        case .needsAI:   list = list.filter { $0.processingState != .ready }
        case .published: list = list.filter { $0.publishedURL != nil }
        case .all:       break
        }
        switch sort {
        case .newest:  return list.sorted { $0.publishedAt > $1.publishedAt }
        case .oldest:  return list.sorted { $0.publishedAt < $1.publishedAt }
        case .mostAds: return list.sorted { $0.adSecondsRemoved > $1.adSecondsRemoved }
        }
    }

    private var selected: [Episode] {
        episodes.filter { selection.contains($0.persistentModelID) }
    }
    private var selectedNeedingAI: [Episode] { selected.filter { $0.processingState != .ready } }
    private var selectedReady: [Episode] { selected.filter { $0.processingState == .ready } }

    var body: some View {
        List {
            feedBanner

            // Same filter idiom as every other list in the app. The scrolling
            // chip strip this replaces ran off the right edge of the screen
            // with no indication there was more.
            SectionMenuBar(title: filter.rawValue) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
            } trailing: {
                Text("\(episodes.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .plainRow(top: 12, bottom: 4)

            selectionBar
            messageLine
            episodeRows
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .processingBanner(pipeline, publisher: publisher)
        .toolbar { menu }
        .safeAreaInset(edge: .bottom) { actionBar }
    }

    @ViewBuilder
    private var feedBanner: some View {
        if let feed = podcast.publishedFeedURL {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ad-free feed").font(.caption2).foregroundStyle(.secondary)
                Text(feed).font(.caption2.monospaced()).textSelection(.enabled).lineLimit(2)
                HStack(spacing: 8) {
                    Button { UIPasteboard.general.string = feed } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: feed) { Label("Share", systemImage: "square.and.arrow.up") }
                }
                .buttonStyle(.bordered).controlSize(.mini)
                Text("Apple Podcasts → Library → ••• → Follow a Show by URL")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .contentRow()
        }
    }

    private var selectionBar: some View {
        HStack {
            Button(allSelected ? "Deselect All" : "Select All") { toggleAll() }
                .font(.subheadline.weight(.medium))
            Spacer()
            Text("\(episodes.count) episode\(episodes.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .plainRow(top: 0, bottom: 6)
    }

    @ViewBuilder
    private var messageLine: some View {
        if let message {
            Text(message).font(.caption).foregroundStyle(.secondary).contentRow()
        }
    }

    private var episodeRows: some View {
        ForEach(episodes) { episode in
            EpisodeSelectRow(episode: episode,
                             isSelected: selection.contains(episode.persistentModelID)) {
                toggle(episode)
            }
            .contentRow()
        }
    }

    private var menu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
            }
            Divider()
            Button("Publish Everything Ready", systemImage: "arrow.up.circle") {
                Task { await publishAll() }
            }
            .disabled(podcast.readyCount == 0 || isWorking)
        } label: {
            Image(systemName: "ellipsis")
        }
    }

    private var allSelected: Bool {
        !episodes.isEmpty && episodes.allSatisfy { selection.contains($0.persistentModelID) }
    }

    private var actionBar: some View {
        Group {
            if !selection.isEmpty {
                VStack(spacing: 10) {
                    HStack {
                        Text("\(selection.count) selected").font(.caption.weight(.medium))
                        Spacer()
                        Button("Clear") { selection.removeAll() }.font(.caption)
                    }
                    HStack(spacing: 10) {
                        Button {
                            Task { await processSelected() }
                        } label: {
                            Label("Find ads (\(selectedNeedingAI.count))", systemImage: "wand.and.sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(selectedNeedingAI.isEmpty || isWorking || pipeline.isRunning)

                        Button {
                            Task { await publishSelected() }
                        } label: {
                            Label("Publish (\(selectedReady.count))", systemImage: "arrow.up.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(selectedReady.isEmpty || isWorking || publisher.isPublishing)
                    }
                    .buttonStyle(.borderedProminent)
                }
                // Glass is right here: this bar floats above the list rather
                // than sitting in it, which is exactly the navigation layer
                // the material is meant for.
                .padding(14)
                .glassPanel(cornerRadius: 24)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
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

    private func toggleAll() {
        if allSelected {
            selection.removeAll()
        } else {
            for episode in episodes { selection.insert(episode.persistentModelID) }
        }
    }

    private func processSelected() async {
        isWorking = true; message = nil
        defer { isWorking = false }
        let targets = selectedNeedingAI
        for episode in targets { episode.isInQueue = true }
        try? context.save()
        await pipeline.process(targets)
        message = "Processed \(targets.count) episode\(targets.count == 1 ? "" : "s")."
    }

    private func publishSelected() async {
        await runPublish(only: selectedReady)
    }

    private func publishAll() async {
        await runPublish(only: nil)
    }

    private func runPublish(only: [Episode]?) async {
        isWorking = true; message = nil
        defer { isWorking = false }
        publisher.configure(context: context, pipeline: pipeline)
        do {
            let result = try await publisher.publish(podcast, only: only)
            message = "Published \(result.episodesPublished) episode\(result.episodesPublished == 1 ? "" : "s")."
            selection.removeAll()
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: - Selectable row

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
                        if episode.duration > 0 { Text("· \(Int(episode.duration / 60))m") }
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
                Spacer(minLength: 0)
            }
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
