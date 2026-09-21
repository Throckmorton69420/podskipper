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
            HStack(spacing: 14) {
                summaryStat(value: totals.ready, label: "ad-free", tint: .green)
                summaryStat(value: totals.published, label: "published", tint: Theme.accentHot)
                Spacer()
            }
            .plainRow(top: 0, bottom: 8)

            ForEach(visible) { podcast in
                NavigationLink(destination: ShowDetailView(podcast: podcast, startPublishing: true)) {
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
        .navigationTitle("Ad-Free Feeds")
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
            Text(label).font(.footnote).foregroundStyle(.secondary)
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
                    stepIndex: publisher.stepNumber,
                    stepCount: publisher.stepCount,
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
                Text(podcast.title).font(.system(size: Metrics.bodySize, weight: .semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    if podcast.readyCount > 0 {
                        StatusPill(text: "\(podcast.readyCount) ad-free", tint: .green)
                    }
                    if podcast.publishedCount > 0 {
                        StatusPill(text: "\(podcast.publishedCount) in feed",
                                   tint: Theme.accentHot, filled: true)
                    }
                    if podcast.readyCount == 0 && podcast.publishedCount == 0 {
                        StatusPill(text: "\(CountsCache.counts(for: podcast).total) episodes", tint: .gray)
                    }
                }
            }
            Spacer(minLength: 0)
            // One show, one link: say so on the row, so which shows already
            // have a feed can be seen without opening each one.
            if podcast.publishedFeedURL != nil {
                Image(systemName: "dot.radiowaves.up.forward")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .accessibilityLabel("Has an ad-free feed")
            }
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
    // Starts on All, not Ready.
    //
    // "Ready" means processed *and not yet published*, so the moment you
    // publish something the tab you are looking at empties — the screen opens
    // blank and looks broken. All is the honest default; Ready is a filter you
    // choose when you want it.
    @State private var filter: Filter = .all
    @State private var sort: Sort = .newest
    @State private var message: String?
    @State private var isWorking = false
    @State private var showActivity = false
    @Namespace private var transition

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
    /// Processed, and not already up.
    ///
    /// The `publishedURL` half was missing, so selecting an episode on the
    /// Published tab lit the Publish button as though there were something to
    /// do — and pressing it cut and uploaded the same audio again.
    private var selectedReady: [Episode] {
        selected.filter { $0.processingState == .ready && $0.publishedURL == nil }
    }

    /// Not yet up, whatever state it is in.
    private var selectedUnpublished: [Episode] {
        selected.filter { $0.publishedURL == nil }
    }

    /// Already up, and selected. Republishing one is a deliberate act, not the
    /// same button.
    private var selectedPublished: [Episode] {
        selected.filter { $0.publishedURL != nil }
    }

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
        // The show's name is the header's now; the bar says where you are.
        .navigationTitle("Publish")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .processingBanner(pipeline, publisher: publisher)
        .toolbar { menu }
        .safeAreaInset(edge: .bottom) { actionBar }
        .sheet(isPresented: $showActivity) {
            WorkDetailView(pipeline: pipeline)
                .navigationTransition(.zoom(sourceID: "activity-link", in: transition))
        }
    }

    /// The show, the way its own page draws it, and its one feed link.
    ///
    /// This was a grey footnote of raw URL above a list of episodes, which
    /// made publishing read as a per-episode chore. A published show has
    /// exactly one address — every episode you publish goes into it, and Apple
    /// Podcasts picks them up on its own — so that address is the headline of
    /// the page, under the show's own artwork, with the one action that
    /// matters beside it: add it to Podcasts.
    private var feedBanner: some View {
        VStack(spacing: 14) {
            Artwork(url: podcast.artworkURL, size: UIScale.pt(150))
                .shadow(color: .black.opacity(0.45), radius: 18, y: 9)
                .padding(.top, 6)

            VStack(spacing: 4) {
                Text(podcast.title)
                    .font(.system(size: Metrics.titleSize, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("Ad-free feed")
                    .font(.system(size: Metrics.subtitleSize, weight: .semibold))
                    .foregroundStyle(.green)
                Text(feedCounts)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let feed = podcast.publishedFeedURL {
                FeedLinkCard(feed: feed, lastPublished: podcast.lastPublished)
            } else {
                Text("Publish one episode and this show gets a single private link. Add it to Apple Podcasts once — everything you publish afterwards appears there by itself.")
                    .font(.system(size: Metrics.subtitleSize))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .readableWidth(520)
        .plainRow(top: 4, bottom: 10)
    }

    private var feedCounts: String {
        let up = podcast.episodes.filter { $0.publishedURL != nil }.count
        let waiting = podcast.episodes.filter {
            $0.processingState == .ready && $0.publishedURL == nil && !$0.isArchived
        }.count
        var parts = ["\(up) in the feed"]
        if waiting > 0 { parts.append("\(waiting) ready to add") }
        return parts.joined(separator: " · ")
    }

    private var selectionBar: some View {
        HStack {
            Button(allSelected ? "Deselect All" : "Select All") { toggleAll() }
                .font(.subheadline.weight(.medium))
            Spacer()
            Text("\(episodes.count) episode\(episodes.count == 1 ? "" : "s")")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .plainRow(top: 0, bottom: 6)
    }

    @ViewBuilder
    private var messageLine: some View {
        if let message {
            Text(message).font(.footnote).foregroundStyle(.secondary).contentRow()
        }
        // The queue can finish — or fail — between two looks at the screen,
        // and with nothing running the banner is gone. This keeps what
        // happened one tap away.
        if !PublishQueue.shared.jobs.isEmpty {
            Button {
                showActivity = true
            } label: {
                Label(activitySummary, systemImage: "list.bullet.rectangle")
                    .font(.footnote.weight(.medium))
            }
            .accessibilityIdentifier("ShowActivity")
            .matchedTransitionSource(id: "activity-link", in: transition)
            .contentRow()
        }
    }

    private var activitySummary: String {
        let queue = PublishQueue.shared
        let failed = queue.jobs.filter { if case .failed = $0.state { return true } else { return false } }.count
        let waiting = queue.waiting.count
        var parts: [String] = []
        if queue.current != nil { parts.append("1 publishing") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if failed > 0 { parts.append("\(failed) failed") }
        let done = queue.finished.count - failed
        if done > 0 { parts.append("\(done) done") }
        return "Activity · " + parts.joined(separator: ", ")
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
                        Text("\(selection.count) selected").font(.subheadline.weight(.medium))
                        Spacer()
                        Button("Clear") { selection.removeAll() }.font(.footnote)
                    }
                    HStack(spacing: 10) {
                        Button {
                            Task { await processSelected() }
                        } label: {
                            Label("Find ads (\(selectedNeedingAI.count))", systemImage: "wand.and.sparkles")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(selectedNeedingAI.isEmpty || isWorking || pipeline.isRunning)

                        // Every unpublished episode in the selection, not only
                        // the ones already through Find Ads: the queue finds
                        // ads first for the rest. And never disabled while
                        // something is running — a second press adds to the
                        // queue instead of being refused.
                        Button {
                            publishSelected()
                        } label: {
                            Label("Publish (\(selectedUnpublished.count))", systemImage: "arrow.up.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(selectedUnpublished.isEmpty)
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

    /// What happened, in the order someone would ask about it. "Published 3
    /// episodes" said nothing about whether the other twelve were still there.
    static func summary(of result: FeedPublisher.PublishResult) -> String {
        func count(_ n: Int) -> String { "\(n) episode\(n == 1 ? "" : "s")" }
        var parts: [String] = []
        if result.episodesPublished > 0 { parts.append("Added \(count(result.episodesPublished)).") }
        if result.episodesAlreadyUp > 0 { parts.append("\(count(result.episodesAlreadyUp)) already up, left alone.") }
        parts.append("The feed lists \(count(result.episodesInFeed)).")
        return parts.joined(separator: " ")
    }

    private func publishSelected() {
        let targets = episodes.filter { selection.contains($0.persistentModelID) && $0.publishedURL == nil }
        PublishQueue.shared.configure(context: context)
        publisher.configure(context: context, pipeline: pipeline)
        PublishQueue.shared.enqueue(targets)
        message = "Queued \(targets.count) episode\(targets.count == 1 ? "" : "s"). Tap the progress bar at the top to see the order or change it."
        selection.removeAll()
        Haptics.success()
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
            message = Self.summary(of: result)
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
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        statusPill
                        if episode.processingState == .ready && !episode.adSegments.isEmpty {
                            StatusPill(text: "\(episode.adSegments.count) ads · \(Int(episode.adSecondsRemoved / 60))m",
                                       tint: Theme.adTint)
                        }
                        if episode.isDownloaded {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.footnote).foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("SelectableEpisode")
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

// MARK: - Feed link

/// One show's feed address and what to do with it.
struct FeedLinkCard: View {
    let feed: String
    let lastPublished: Date?
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    /// Apple Podcasts registers the `podcast:` scheme and treats
    /// `podcast://host/path` as "follow this feed". Unverified on a device —
    /// if Podcasts does not open, Copy and Follow a Show by URL still work.
    private var subscribeURL: URL? {
        guard var components = URLComponents(string: feed) else { return nil }
        components.scheme = "podcast"
        return components.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.up.forward")
                    .foregroundStyle(.green)
                Text(feed)
                    .font(.footnote.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        if let subscribeURL { openURL(subscribeURL) }
                    } label: {
                        Label("Add to Podcasts", systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 22)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accentHot)

                    Button {
                        UIPasteboard.general.string = feed
                        Haptics.success()
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 30, height: 22)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Copy feed address")

                    ShareLink(item: feed) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 30, height: 22)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Share feed address")
                }
                .buttonBorderShape(.capsule)
            }

            Group {
                if let lastPublished {
                    Text("Updated \(lastPublished, format: .relative(presentation: .named)). If Add to Podcasts does nothing, copy the link and use Library → ⋯ → Follow a Show by URL.")
                } else {
                    Text("If Add to Podcasts does nothing, copy the link and use Library → ⋯ → Follow a Show by URL.")
                }
            }
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .contentCard(cornerRadius: Metrics.cardCorner)
    }
}
