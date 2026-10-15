import SwiftUI
import SwiftData

// Pass 39 (his 15 Oct request): every Library collection — Saved,
// Downloaded, Latest Episodes, Recently Played, a station, Bookmarks — is
// built from the same pieces, so they look and behave alike: a large title,
// the activity bar pinned under it, a ⋯ menu top right with what can be
// done to the whole page (including what was only in a long press), Select
// for choosing several, and one bar of actions for what is chosen. The show
// page's own selection (publishing included) stays as it is; these are its
// actions for pages that list episodes from many shows.

/// What can be done to several episodes at once, wherever they are listed.
@MainActor
enum EpisodeBatch {
    static func markPlayed(_ episodes: [Episode], _ played: Bool, context: ModelContext) {
        for episode in episodes {
            episode.isPlayed = played
            if played { episode.isNew = false; episode.isInQueue = false }
        }
        finish(context, episodes)
    }

    /// To the end of Up Next, in the order given.
    static func playLast(_ episodes: [Episode], context: ModelContext) {
        let queued = (try? context.fetch(FetchDescriptor<Episode>(predicate: #Predicate { $0.isInQueue }))) ?? []
        var order = (queued.map(\.queueOrder).max() ?? -1) + 1
        for episode in episodes where !episode.isInQueue {
            if episode.isPlayed { episode.playbackPosition = 0 }
            episode.isInQueue = true
            episode.queueOrder = order
            order += 1
        }
        PrepareAhead.shared.refresh()
        finish(context, episodes)
    }

    /// To the front of Up Next, keeping their order.
    static func playNext(_ episodes: [Episode], context: ModelContext) {
        for episode in episodes.reversed() { episode.addToUpNext(next: true, context: context) }
        PrepareAhead.shared.refresh()
        finish(context, episodes)
    }

    static func needingAds(_ episodes: [Episode], pipeline: ProcessingPipeline) -> [Episode] {
        episodes.filter { $0.processingState != .ready && !pipeline.isProcessing($0) }
    }

    static func findAds(_ episodes: [Episode], pipeline: ProcessingPipeline) {
        let targets = needingAds(episodes, pipeline: pipeline)
        guard !targets.isEmpty else { return }
        pipeline.cancelBackgroundWork()
        Task { await pipeline.process(targets) }
        Haptics.success()
    }

    static func download(_ episodes: [Episode], context: ModelContext) {
        let targets = episodes.filter { !$0.isDownloaded }
        Haptics.success()
        Task {
            for episode in targets { _ = await DownloadManager.fetchAudio(for: episode) }
            try? context.save()
            LibraryTotals.shared.invalidate()
        }
    }

    /// Never the one that is playing: its file is open.
    static func removeDownloads(_ episodes: [Episode], context: ModelContext) {
        let playing = PlayerEngine.shared.currentEpisode?.guid
        for episode in episodes where episode.isDownloaded && episode.guid != playing {
            DownloadManager.remove(episode)
        }
        finish(context, episodes)
    }

    static func setSaved(_ episodes: [Episode], _ saved: Bool, context: ModelContext) {
        for episode in episodes { episode.isStarred = saved }
        finish(context, episodes)
    }

    static func archive(_ episodes: [Episode], context: ModelContext) {
        for episode in episodes { episode.isArchived = true; episode.isInQueue = false }
        finish(context, episodes)
    }

    private static func finish(_ context: ModelContext, _ episodes: [Episode] = []) {
        try? context.save()
        // One count pass covers every show's numbers and the Library's.
        LibraryTotals.shared.invalidate()
        Haptics.success()
    }
}

/// A row with a tick beside it while choosing; the row's own buttons are off
/// so a tap anywhere ticks it (the show page's rule).
struct SelectionRow<Content: View>: View {
    let isSelected: Bool
    let toggle: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(isSelected ? Theme.accentHot : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28)
            content.allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .feel(.selection, trigger: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("SelectableRow")
    }
}

/// Select All / Done in the navigation bar while choosing.
struct SelectionToolbar: ToolbarContent {
    let allSelected: Bool
    let selectAll: () -> Void
    let selectNone: () -> Void
    let done: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(allSelected ? "Select None" : "Select All") {
                Haptics.select()
                allSelected ? selectNone() : selectAll()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Done", role: .confirm, action: done)
                .accessibilityIdentifier("selection.done")
        }
    }
}

/// "3 Selected", or "Select" before anything is chosen.
func selectionTitle(_ count: Int) -> String { count == 0 ? "Select" : "\(count) Selected" }

/// The bar of actions for chosen episodes, above the tab bar and the
/// now-playing bar (the show page's panel, without publishing).
struct EpisodeSelectionBar<More: View>: View {
    let chosen: [Episode]
    let pipeline: ProcessingPipeline
    let done: () -> Void
    /// Page-specific items at the top of the bar's ⋯ menu (Unsave on Saved…).
    @ViewBuilder var more: More
    @Environment(\.modelContext) private var context

    var body: some View {
        let allPlayed = !chosen.isEmpty && chosen.allSatisfy(\.isPlayed)
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    EpisodeBatch.markPlayed(chosen, !allPlayed, context: context); done()
                } label: {
                    BarLabel(title: allPlayed ? "Unplayed" : "Played",
                                     systemImage: allPlayed ? "circle" : "checkmark.circle")
                }
                .buttonStyle(.glass)
                .disabled(chosen.isEmpty)

                Button {
                    EpisodeBatch.findAds(chosen, pipeline: pipeline); done()
                } label: {
                    BarLabel(title: "Find Ads", systemImage: "wand.and.sparkles")
                }
                .buttonStyle(.glass)
                .disabled(EpisodeBatch.needingAds(chosen, pipeline: pipeline).isEmpty)

                Button {
                    EpisodeBatch.playLast(chosen, context: context); done()
                } label: {
                    BarLabel(title: "Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
                .buttonStyle(.glass)
                .disabled(chosen.isEmpty)

                Menu {
                    more
                    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        EpisodeBatch.playNext(chosen, context: context); done()
                    }
                    if chosen.contains(where: { !$0.isDownloaded }) {
                        Button("Download", systemImage: "arrow.down.circle") {
                            EpisodeBatch.download(chosen, context: context); done()
                        }
                    }
                    if chosen.contains(where: \.isDownloaded) {
                        Button("Remove Download", systemImage: "trash") {
                            EpisodeBatch.removeDownloads(chosen, context: context); done()
                        }
                    }
                    let allSaved = chosen.allSatisfy(\.isStarred)
                    Button(allSaved ? "Unsave" : "Save", systemImage: allSaved ? "star.slash" : "star") {
                        EpisodeBatch.setSaved(chosen, !allSaved, context: context); done()
                    }
                    Divider()
                    Button("Archive", systemImage: "archivebox", role: .destructive) {
                        EpisodeBatch.archive(chosen, context: context); done()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 24)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Selection Actions")
                .accessibilityIdentifier("Selection Actions")
                .disabled(chosen.isEmpty)
            }
            .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 8)
    }
}

/// One line, as the show page's Publish button: two-line labels made the
/// bar's capsules uneven (Pass 39 simulator check).
private struct BarLabel: View {
    let title: String
    let systemImage: String
    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
    }
}

extension EpisodeSelectionBar where More == EmptyView {
    init(chosen: [Episode], pipeline: ProcessingPipeline, done: @escaping () -> Void) {
        self.init(chosen: chosen, pipeline: pipeline, done: done) { EmptyView() }
    }
}

/// The ⋯ label every collection's page menu uses.
struct PageMenuLabel: View {
    var title = "More"
    var body: some View {
        Label(title, systemImage: "ellipsis")
    }
}
