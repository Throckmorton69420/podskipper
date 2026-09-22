import SwiftUI
import SwiftData
import UIKit

// MARK: - Routing
//
// Destinations are values, not embedded NavigationLinks. Three links inside a
// single List row is what caused tapping "Playlists" to push Playlists,
// Bookmarks and Stats all at once — which is why Back walked through all
// three on the way out.

enum LibraryRoute: Hashable {
    case playlists, bookmarks, stats, downloaded, starred, latest, recent
    /// What the Publish tab was: every show's ad-free feed, from the Library.
    case feeds
    case show(PersistentIdentifier)

    var title: String {
        switch self {
        case .playlists:  return "Stations"
        case .bookmarks:  return "Bookmarks"
        case .stats:      return "Statistics"
        case .downloaded: return "Downloaded"
        case .starred:    return "Starred"
        case .latest:     return "Latest Episodes"
        case .recent:     return "Recently Played"
        case .feeds:      return "Ad-Free Feeds"
        case .show:       return "Show"
        }
    }

    var symbol: String {
        switch self {
        case .playlists:  return "square.stack.3d.up"
        case .bookmarks:  return "bookmark.fill"
        case .stats:      return "chart.bar.fill"
        case .downloaded: return "arrow.down.circle.fill"
        case .starred:    return "star.fill"
        case .latest:     return "clock.fill"
        case .recent:     return "clock.arrow.circlepath"
        case .feeds:      return "dot.radiowaves.up.forward"
        case .show:       return "mic.fill"
        }
    }

    var tint: Color {
        switch self {
        case .playlists:  return Theme.accentHot
        case .bookmarks:  return Theme.accentWarm
        case .stats:      return .green
        case .downloaded: return .blue
        case .starred:    return .yellow
        case .latest:     return .purple
        case .recent:     return .teal
        case .feeds:      return .green
        case .show:       return .gray
        }
    }
}

// MARK: - Library

struct LibraryView: View {
    @Query(sort: \Podcast.dateAdded, order: .reverse) private var podcasts: [Podcast]
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(AppSettings.self) private var settings

    /// Counts used to come from `@Query private var allEpisodes: [Episode]`,
    /// which pulls every episode in the store into memory and recomputes the
    /// filters on every render of this screen.
    @State private var totals = LibraryTotals.shared
    @State private var indexStatus = LibraryIndexStatus.shared
    /// Episode search results, fetched on demand rather than by filtering the
    /// whole store in a computed property.
    @State private var episodeMatches: [Episode] = []
    @State private var searchTask: Task<Void, Never>?

    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var showingAdd = false
    @State private var search = ""
    /// Kept, rather than reset every time the Library is left.
    ///
    /// It was `@State`, so choosing "Title", going into a show and coming back
    /// put it silently on "Recently Added" again — the same complaint as the
    /// episode filter reverting to "All Episodes", which was fixed a while ago
    /// and this one was not.
    @AppStorage("librarySort") private var sortRaw: String = Sort.recent.rawValue
    private var sort: Sort { Sort(rawValue: sortRaw) ?? .recent }

    @AppStorage("libraryShowArchived") private var showArchived = false
    /// nil means "whatever suits this screen". An iPad has the width for a
    /// grid of covers and looks half-empty with a single column of rows, which
    /// is why Apple Podcasts shows a grid there and a list on a phone.
    @State private var gridPreference: Bool?
    @State private var refreshNote: String?
    /// Pushed by the cover grid, which uses buttons rather than links so the
    /// List does not decorate every tile with a disclosure chevron.
    @State private var pushedShow: LibraryRoute?

    private var isRegular: Bool { sizeClass == .regular }

    /// Covers of shows, in a grid, on every device.
    ///
    /// This used to default to `isRegular` — a grid on iPad and a list of rows
    /// on iPhone. Which meant the two-column phone grid that was asked for, and
    /// the column-counting that was written to produce it, were on a branch the
    /// phone never took. A list is still one tap away from the toolbar.
    private var useGrid: Bool { gridPreference ?? true }

    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Recently Added"
        case title = "Title"
        case author = "Author"
        case unplayed = "Unplayed"
        case priority = "Priority"
        var id: String { rawValue }
    }

    private var shows: [Podcast] {
        var list = podcasts.filter { showArchived || !$0.isArchived }
        if !search.isEmpty {
            let needle = search.lowercased()
            list = list.filter {
                $0.title.lowercased().contains(needle) || $0.author.lowercased().contains(needle)
            }
        }
        switch sort {
        case .recent:   return list.sorted { $0.dateAdded > $1.dateAdded }
        case .title:    return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .author:   return list.sorted { $0.author.localizedCaseInsensitiveCompare($1.author) == .orderedAscending }
        case .unplayed: return list.sorted { $0.unplayedCount > $1.unplayedCount }
        case .priority: return list.sorted { ($0.priority, $0.title) > ($1.priority, $1.title) }
        }
    }

    private var collections: [LibraryRoute] {
        [.playlists, .latest, .recent, .downloaded, .starred, .bookmarks, .feeds, .stats]
    }

    /// Runs against the store with a predicate and a fetch limit, so typing in
    /// the search field no longer walks every episode you have ever added.
    private func runEpisodeSearch(_ text: String) {
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            episodeMatches = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            var descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate { !$0.isArchived && $0.title.localizedStandardContains(trimmed) },
                sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
            )
            descriptor.fetchLimit = 20
            let found = (try? context.fetch(descriptor)) ?? []
            guard !Task.isCancelled else { return }
            episodeMatches = found
        }
    }

    var body: some View {
        List {
            collectionsSection
            episodeResultsSection
            showsSection
            emptyState
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle("Library")
        .amoledScreen()
        // Pinned, like the show page: the activity bar stays in view while
        // anything is being worked on, and goes when it's done.
        .processingBanner(pipeline, publisher: FeedPublisher.shared)
        .searchable(text: $search, prompt: "Search your shows")
        .onChange(of: search) { _, value in runEpisodeSearch(value) }
        .refreshable { await refresh() }
        .navigationDestination(for: LibraryRoute.self) { destination(for: $0) }
        .navigationDestination(item: $pushedShow) { destination(for: $0) }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingAdd) { AddPodcastView().glassSheet() }
        .overlay(alignment: .top) { refreshBanner }
    }

    // MARK: Sections

    @ViewBuilder
    private var collectionsSection: some View {
        if search.isEmpty {
            if indexStatus.isIndexing || indexStatus.pausedReason != nil {
                LibraryIndexBanner()
                    .plainRow(top: 4, bottom: 8)
            }
            ForEach(collections, id: \.self) { route in
                NavigationLink(value: route) {
                    CollectionRow(route: route, count: count(for: route))
                }
                .contentRow()
            }

            SectionHeader(title: "Shows") {
                Text("\(shows.count)").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var episodeResultsSection: some View {
        if !episodeMatches.isEmpty {
            SectionHeader("Episodes")
            ForEach(episodeMatches) { episode in
                EpisodeCompactRow(episode: episode).contentRow()
            }
            SectionHeader("Shows")
        }
    }

    @ViewBuilder
    private var showsSection: some View {
        if useGrid && search.isEmpty {
            gridSection
        } else {
            ForEach(shows) { podcast in
                NavigationLink(value: LibraryRoute.show(podcast.persistentModelID)) {
                    ShowRow(podcast: podcast)
                }
                .contentRow()
                .swipeActions(edge: .trailing) { trailingActions(podcast) }
                .swipeActions(edge: .leading) { leadingActions(podcast) }
            }
        }
    }

    @ViewBuilder
    private func trailingActions(_ podcast: Podcast) -> some View {
        Button(role: .destructive) {
            context.delete(podcast); try? context.save()
        } label: { Label("Delete", systemImage: "trash") }

        Button {
            podcast.isArchived.toggle(); try? context.save()
        } label: {
            Label(podcast.isArchived ? "Restore" : "Archive", systemImage: "archivebox")
        }
        .tint(.indigo)
    }

    @ViewBuilder
    private func leadingActions(_ podcast: Podcast) -> some View {
        Button {
            podcast.priority = podcast.priority == 1 ? 0 : 1
            try? context.save()
        } label: { Label("Priority", systemImage: "arrow.up.circle") }
        .tint(Theme.accentWarm)
    }

    @ViewBuilder
    private var emptyState: some View {
        if shows.isEmpty && search.isEmpty {
            ContentUnavailableView("No shows yet",
                systemImage: "antenna.radiowaves.left.and.right",
                description: Text("Tap + to search for a show, or look in New."))
                .plainRow(top: 40, bottom: 40)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort", selection: $sortRaw) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Divider()
                Toggle("Grid layout", isOn: Binding(
                    get: { useGrid },
                    set: { gridPreference = $0 }
                ))
                Toggle("Show archived", isOn: $showArchived)
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingAdd = true } label: { Image(systemName: "plus") }
        }
    }

    @ViewBuilder
    private var refreshBanner: some View {
        if let refreshNote {
            Text(refreshNote).font(.footnote)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .glassCapsule()
                .padding(.top, 6)
        }
    }

    @ViewBuilder
    private func destination(for route: LibraryRoute) -> some View {
        switch route {
        case .playlists:  FiltersView()
        case .bookmarks:  BookmarksView()
        case .stats:      StatsView()
        case .downloaded: EpisodeCollectionView(title: "Downloaded", kind: .downloaded)
        case .starred:    EpisodeCollectionView(title: "Starred", kind: .starred)
        case .latest:     EpisodeCollectionView(title: "Latest Episodes", kind: .latest)
        case .recent:     EpisodeCollectionView(title: "Recently Played", kind: .recent)
        case .feeds:      PublishView()
        case .show(let id):
            if let podcast = podcasts.first(where: { $0.persistentModelID == id }) {
                ShowDetailView(podcast: podcast)
            } else {
                ContentUnavailableView("Show not found", systemImage: "questionmark")
            }
        }
    }

    private func count(for route: LibraryRoute) -> Int {
        switch route {
        case .downloaded: return totals.downloaded
        case .starred:    return totals.starred
        case .latest:     return totals.unplayed
        case .feeds:      return totals.published
        default:          return 0
        }
    }

    private var gridSection: some View {
        // No GeometryReader.
        //
        // One inside a List row has no intrinsic height, so the row had to be
        // told a guessed one — which left a screenful of dead space under three
        // shows — and it measures during layout in a way that left ghost copies
        // of the previous screen painted over the top of this one after a
        // navigation transition. Both were visible in a simulator screenshot
        // and neither is visible in the code.
        //
        // The width is known without measuring: it is the screen minus the
        // gutters this row already applies.
        //
        // One list row per line of covers, not one row holding the whole grid.
        // A grid inside a single row is not lazy at all as far as the list is
        // concerned: every cover in the library was laid out, loaded and drawn
        // at once as one enormous cell, and a quick flick made the list push
        // that whole cell around — the stutter reported on a fast swipe up.
        // Split into lines, the list only builds the lines on screen.
        let columns = AdaptiveGrid.columnCount(forContentWidth: contentWidth, targetTile: targetTile)
        let side = AdaptiveGrid.tileSide(forContentWidth: contentWidth, targetTile: targetTile)
        let list = shows
        let lines = stride(from: 0, to: list.count, by: columns).map { start in
            Array(list[start..<min(start + columns, list.count)])
        }
        return ForEach(lines, id: \.first?.persistentModelID) { line in
            HStack(alignment: .top, spacing: AdaptiveGrid.spacing) {
                ForEach(line) { podcast in
                    // A Button, not a NavigationLink. A List draws its own
                    // disclosure chevron beside every link it can see,
                    // including ones nested in a row — so each cover had a
                    // stray ">" floating to the right of it.
                    Button {
                        pushedShow = LibraryRoute.show(podcast.persistentModelID)
                    } label: {
                        ShowTile(podcast: podcast, side: side)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(podcast.title)
                    .accessibilityValue(podcast.freshnessLine)
                }
                Spacer(minLength: 0)
            }
            .plainRow(top: 11, bottom: 11)
        }
    }

    private var targetTile: CGFloat {
        isRegular ? Metrics.artTileWide : Metrics.artTile
    }

    /// Width available to the grid: the screen, less this row's own gutters,
    /// and capped the way every other row in the app is capped.
    private var contentWidth: CGFloat {
        let gutter = isRegular ? Metrics.gutterWide : Metrics.gutter
        return max(200, min(Metrics.readableMax, screenWidth - gutter * 2))
    }

    private var screenWidth: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds.width }
            .first ?? 402
    }

    private func refresh() async {
        let added = await pipeline.refreshAllFeeds(queueNewEpisodes: settings.autoQueueNewEpisodes)
        totals.refresh(context: context, force: true)
        withAnimation {
            refreshNote = added == 0 ? "No new episodes" : "Added \(added) new episode\(added == 1 ? "" : "s")"
        }
        try? await Task.sleep(for: .seconds(3))
        withAnimation { refreshNote = nil }
    }
}

// MARK: - Tiles

/// One cover in the library grid.
///
/// The badge over the corner is gone. It said "100" on a show you had followed
/// five minutes ago, because it counted unplayed episodes and a back catalogue
/// is entirely unplayed — a number that was true, prominent and told you
/// nothing. Underneath the title there is now a line that says when the show
/// last published, and adds a count only when something has actually arrived
/// since you last opened it.
struct ShowTile: View {
    let podcast: Podcast
    let side: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Artwork(url: podcast.artworkURL, size: side)
                // Which shows have an ad-free feed, at a glance — what the
                // Publish tab's list used to be for.
                .overlay(alignment: .bottomTrailing) {
                    if podcast.publishedFeedURL != nil {
                        Image(systemName: "dot.radiowaves.up.forward")
                            .font(.system(size: UIScale.pt(12), weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: UIScale.pt(26), height: UIScale.pt(26))
                            .glassEffect(.regular.tint(.green.opacity(0.7)), in: Circle())
                            .padding(6)
                            .accessibilityLabel("Has an ad-free feed")
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(podcast.title)
                    .font(.system(size: Metrics.bodySize, weight: .semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text(podcast.freshnessLine)
                    .font(.system(size: Metrics.metaSize))
                    .foregroundStyle(podcast.newSinceLastSeen > 0 ? Theme.accentHot : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: side, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Rows

struct CollectionRow: View {
    let route: LibraryRoute
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: route.symbol)
                .font(.system(size: UIScale.pt(17)))
                .foregroundStyle(route.tint)
                .frame(width: 28)
                // The accessibility dump from a device run showed VoiceOver
                // announcing this icon as "Hdr" — iOS auto-labelling the SF
                // Symbol. It is decoration next to a label that already says
                // the same thing, so it should not be spoken at all.
                .accessibilityHidden(true)
            Text(route.title).font(.body)
            Spacer(minLength: 0)
            if count > 0 {
                Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        // One element per row rather than icon, label and count read
        // separately.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(count > 0 ? "\(route.title), \(count)" : route.title)
    }
}

struct ShowRow: View {
    let podcast: Podcast

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: podcast.artworkURL, size: Metrics.artRow)
            VStack(alignment: .leading, spacing: 3) {
                Text(podcast.title).font(.system(size: Metrics.bodySize, weight: .semibold)).lineLimit(2)
                Text(podcast.author).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    // Was the unplayed count labelled "new", which on a show
                    // with a back catalogue read "100 new" the moment you
                    // followed it. Leads with when the feed last updated, and
                    // adds a count only when episodes have arrived since you
                    // last looked.
                    Text(podcast.freshnessLine)
                        .font(.system(size: Metrics.metaSize,
                                      weight: podcast.newSinceLastSeen > 0 ? .semibold : .regular))
                        .foregroundStyle(podcast.newSinceLastSeen > 0 ? Theme.accentHot : .secondary)
                        .lineLimit(1)
                    if podcast.priority == 1 {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.footnote).foregroundStyle(Theme.accentWarm)
                    }
                    if podcast.publishedFeedURL != nil {
                        Image(systemName: "dot.radiowaves.up.forward")
                            .font(.footnote).foregroundStyle(.green)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Compact episode row used in collections, Up Next and search results.
struct EpisodeCompactRow: View {
    let episode: Episode
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(AppSettings.self) private var rowSettings
    @State private var player = PlayerEngine.shared

    private var isCurrent: Bool { player.currentEpisode?.guid == episode.guid }
    private var isProcessing: Bool { pipeline.isProcessing(episode) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 11) {
                Artwork(url: episode.artworkURL ?? episode.podcast?.artworkURL, size: Metrics.artRow)
                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.podcast?.title ?? "")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    Text(episode.title).font(.system(size: Metrics.bodySize, weight: .medium)).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(formatMinutes(episode.remainingSeconds))
                        if episode.processingState == .ready {
                            Text("· Ad-free").foregroundStyle(.green)
                        }
                        if episode.isStarred {
                            Image(systemName: "star.fill").foregroundStyle(.yellow)
                        }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    if isCurrent { player.togglePlayPause() } else { PlayCoordinator.play(episode, settings: rowSettings, pipeline: pipeline) }
                } label: {
                    Image(systemName: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                        .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.8))
                        .contentShape(Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCurrent && player.isPlaying ? "Pause" : "Play")
            }

            // Same rule as the full row: progress belongs to the episode it is
            // about, not to a banner at the top of the screen.
            if isProcessing {
                InlineProcessingRow(pipeline: pipeline)
            }
        }
        .animation(.snappy(duration: 0.25), value: isProcessing)
        .contextMenu {
            EpisodeMenuItems(episode: episode)
        }
    }
}

/// Everything you can do to one episode, for its ⋯ menu and for touch-and-hold
/// on its row, so the two can never drift apart.
struct EpisodeMenuItems: View {
    let episode: Episode
    var onSelect: (() -> Void)? = nil
    /// On a show page: opens that page's publishing view with this episode
    /// ticked — the same view as the Publish button beside Play.
    var onPublish: (() -> Void)? = nil
    /// Off on the episode's own page.
    var offersDetails = true
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline

    var body: some View {
        Button(episode.isStarred ? "Unstar" : "Star",
               systemImage: episode.isStarred ? "star.slash" : "star") {
            episode.isStarred.toggle()
            try? context.save()
            LibraryTotals.shared.invalidate()
            Haptics.toggle(on: episode.isStarred)
        }
        Button(episode.isPlayed ? "Mark Unplayed" : "Mark Played",
               systemImage: episode.isPlayed ? "circle" : "checkmark.circle") {
            episode.isPlayed.toggle()
            if episode.isPlayed { episode.isInQueue = false }
            try? context.save()
            CountsCache.invalidate(episode.podcast)
            LibraryTotals.shared.invalidate()
        }
        if episode.isInQueue {
            Button("Remove from Up Next", systemImage: "minus.circle") {
                episode.removeFromUpNext(context: context)
            }
        } else {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                episode.addToUpNext(next: true, context: context)
                Haptics.success()
            }
            Button("Add to Up Next", systemImage: "text.append") {
                episode.addToUpNext(next: false, context: context)
                Haptics.success()
            }
        }
        if episode.isDownloaded {
            Button("Remove Download", systemImage: "trash") {
                guard PlayerEngine.shared.currentEpisode?.guid != episode.guid else { return }
                DownloadManager.remove(episode)
                try? context.save()
                LibraryTotals.shared.invalidate()
            }
        } else {
            Button("Download", systemImage: "arrow.down.circle") {
                Task {
                    _ = await DownloadManager.fetchAudio(for: episode)
                    try? context.save()
                    LibraryTotals.shared.invalidate()
                }
            }
        }
        // Whether there is a transcript, not the transcript: decoding it here
        // ran for every row of every list each time the row was drawn.
        if episode.transcriptData != nil || !episode.chapters.isEmpty {
            Divider()
        }
        if episode.transcriptData != nil {
            NavigationLink { TranscriptView(episode: episode) } label: {
                Label("Transcript", systemImage: "text.quote")
            }
        }
        if !episode.chapters.isEmpty {
            NavigationLink { ChapterListView(episode: episode) } label: {
                Label("Chapters", systemImage: "list.bullet.indent")
            }
        }
        Divider()
        if episode.processingState == .ready {
            Button("Find Ads Again", systemImage: "arrow.clockwise") {
                Task { await pipeline.process(episode) }
            }
        } else if !pipeline.isProcessing(episode) {
            Button("Find Ads", systemImage: "wand.and.sparkles") {
                Task { await pipeline.processNow(episode) }
            }
        }
        // The ad-free feed, from the episode itself — the Publish tab is gone.
        if episode.publishedURL != nil {
            Button("Remove from Feed", systemImage: "minus.circle") {
                guard let podcast = episode.podcast else { return }
                Task {
                    try? await FeedPublisher.shared.removeFromFeed([episode], of: podcast)
                    Haptics.success()
                }
            }
        }
        if let onPublish {
            Button("Publish…", systemImage: "dot.radiowaves.up.forward") { onPublish() }
        } else if episode.publishedURL == nil, R2Credentials.isConfigured {
            Button(episode.processingState == .ready ? "Publish to Feed" : "Find Ads and Publish",
                   systemImage: "dot.radiowaves.up.forward") {
                PublishQueue.shared.configure(context: context)
                PublishQueue.shared.enqueue([episode])
                Haptics.success()
            }
        }
        if offersDetails {
            NavigationLink { EpisodeDetailView(episode: episode) } label: {
                Label("Episode Details", systemImage: "info.circle")
            }
        }
        if let onSelect {
            Button("Select", systemImage: "checkmark.circle") { onSelect() }
        }
    }
}

// MARK: - Episode collections

struct EpisodeCollectionView: View {
    enum Kind { case downloaded, starred, latest, recent }

    let title: String
    let kind: Kind

    @Environment(\.modelContext) private var context
    /// Fetched once when the screen appears rather than by loading the whole
    /// store into a `@Query` and filtering it on every render.
    @State private var episodes: [Episode] = []
    /// Stops "Nothing here yet" flashing up for a frame before the first fetch
    /// lands.
    @State private var hasLoaded = false

    /// Each list asks the store for exactly its own episodes.
    ///
    /// All of these used to fetch every episode in the library — whole back
    /// catalogues, thousands of rows — and then filter in memory on the main
    /// thread, which is the pause before a collection opened.
    private func reload() {
        var descriptor: FetchDescriptor<Episode>
        switch kind {
        case .starred:
            descriptor = FetchDescriptor(predicate: #Predicate { !$0.isArchived && $0.isStarred },
                                         sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
        case .latest:
            descriptor = FetchDescriptor(predicate: #Predicate { !$0.isArchived && !$0.isPlayed },
                                         sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
            descriptor.fetchLimit = 300
        case .recent:
            // Apple's "Recently Played": what you listened to, newest first.
            descriptor = FetchDescriptor(predicate: #Predicate { $0.lastPlayedAt != nil },
                                         sortBy: [SortDescriptor(\.lastPlayedAt, order: .reverse)])
            descriptor.fetchLimit = 150
        case .downloaded:
            descriptor = FetchDescriptor(predicate: #Predicate { !$0.isArchived && $0.localFilename != nil },
                                         sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
        }
        let found = (try? context.fetch(descriptor)) ?? []
        episodes = kind == .downloaded ? found.filter(\.isDownloaded) : found
        hasLoaded = true
    }

    var body: some View {
        Group {
            if !hasLoaded {
                Color.clear
            } else if episodes.isEmpty {
                ContentUnavailableView(title, systemImage: "tray",
                    description: Text("Nothing here yet."))
            } else {
                List {
                    ForEach(episodes) { episode in
                        EpisodeCompactRow(episode: episode)
                            .contentRow()
                            .swipeActions(edge: .leading) {
                                Button {
                                    episode.addToUpNext(next: true, context: context)
                                } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                                .tint(Theme.accentHot)
                            }
                            .swipeActions(edge: .trailing) {
                                Button {
                                    episode.isStarred.toggle()
                                    try? context.save()
                                    LibraryTotals.shared.invalidate()
                                    reload()
                                } label: { Label("Star", systemImage: "star") }
                                .tint(.yellow)
                            }
                    }
                    BottomClearance()
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .task { reload() }
        .refreshable { reload() }
    }
}
// MARK: - One show

/// The show page's scroll position, observed only by what moves with it.
@MainActor
@Observable
final class ScrollTracker {
    var offset: CGFloat = 0
}

/// The artwork-tinted area behind the show header. Its own view so that it is
/// the only thing redrawn as the page scrolls.
private struct ShowBackdrop: View {
    let url: String?
    let headerBottom: CGFloat
    let collapsePoint: CGFloat
    let scroll: ScrollTracker

    var body: some View {
        // As tall as the header actually is, ending in a fade rather than a
        // cut. It was a fixed 554pt with a hard bottom edge, which lined up
        // with the end of the header only at one text size — at any other the
        // edge ran through the episode list as a sharp border.
        let height = max(200, headerBottom + 40)
        let offset = scroll.offset
        ArtworkBackdrop(url: url, variant: .header)
            .frame(height: height)
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: max(0, 1 - 110 / height)),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .offset(y: -min(offset, height))
            .opacity(1 - min(1, max(0, offset) / collapsePoint))
            .ignoresSafeArea(edges: .top)
    }
}

struct ShowDetailView: View {
    let podcast: Podcast
    /// Opened from the Publish tab: the same page, already in publish mode.
    var startPublishing = false
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(AppSettings.self) private var settings
    @State private var player = PlayerEngine.shared
    /// Held on the show, not in view state.
    ///
    /// It was `@State`, which SwiftUI throws away when the view leaves the
    /// navigation stack — so choosing "Unplayed", going back, and coming in
    /// again silently reset you to "All Episodes" every single time. The choice
    /// belongs to the show and is now stored on it.
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var showingSettings = false
    @State private var showingPublish = false
    @State private var similar: [PodcastSearchResult] = []
    @State private var summaryExpanded = false
    /// The scroll position, held outside this view's own state.
    ///
    /// It was `@State` read in this body, so every frame of scrolling
    /// re-evaluated the whole page — the header, the filter bar and the filter
    /// and sort over every episode of the show. With a full catalogue that is
    /// a thousand rows sorted sixty times a second, which is what made the
    /// show page stutter and the phone warm. Now only the backdrop reads it,
    /// and the page itself hears about scrolling only when the header crosses
    /// the point where the title moves into the bar.
    @State private var scroll = ScrollTracker()
    /// Where the header ends, in the page's own coordinates, so the tinted
    /// backdrop can end with it at every text size.
    @State private var headerBottom: CGFloat = 554

    /// Selection mode, the way the Podcasts app does it: the ⋯ menu's Select
    /// Episodes turns every row into a checkbox row, the bar says how many,
    /// and the actions sit along the bottom where the tab bar was.
    ///
    /// Acts on what is *visible*, so a filter narrows it — "Unplayed", Select
    /// All, Mark as Played is the filter-scoped mark-as-played the plan asked
    /// for, with no separate feature needed.
    @State private var selecting = false
    @State private var selection = Set<PersistentIdentifier>()

    /// Publishing is a mode of this page, not a separate one.
    ///
    /// The Publish page was its own screen with smaller rows, no covers and a
    /// different header, and was reported as inconsistent. Now the show page
    /// does both: Publish turns on selection with the feed link in the header,
    /// publish-oriented filters, and Find Ads / Publish along the bottom.
    @State private var publishing = false
    @State private var queue = PublishQueue.shared
    @State private var publishMessage: String?
    @State private var confirmProcessAndPublish = false

    /// How tall the tinted area is before it has been scrolled at all.
    private static let backdropHeight: CGFloat = 554
    /// Where the header is considered gone and the bar takes over.
    private static let collapsePoint: CGFloat = 260


    enum Filter: String, CaseIterable, Identifiable {
        case all = "All Episodes", unplayed = "Unplayed", played = "Played"
        case downloaded = "Downloaded", ready = "Ad-free"
        case notInFeed = "Not in Feed", inFeed = "In Feed", needsAds = "Needs Ads"
        case readyToPublish = "Ready to Publish"
        var id: String { rawValue }

        static let browsing: [Filter] = [.all, .unplayed, .played, .downloaded, .ready, .inFeed]
        static let publishing: [Filter] = [.all, .readyToPublish, .inFeed, .needsAds, .notInFeed]

        var symbol: String {
            switch self {
            case .all:        return "list.bullet"
            case .unplayed:   return "circle"
            case .played:     return "checkmark.circle"
            case .downloaded: return "arrow.down.circle"
            case .ready:      return "wand.and.sparkles"
            case .notInFeed:  return "arrow.up.circle"
            case .inFeed:     return "dot.radiowaves.up.forward"
            case .needsAds:   return "sparkle.magnifyingglass"
            case .readyToPublish: return "checkmark.seal"
            }
        }
    }

    /// Read the stored choice when the view appears, and write it back the
    /// moment it changes.
    private func restoreFilter() {
        filter = Filter(rawValue: podcast.episodeFilter) ?? .all
        if !Filter.browsing.contains(filter) { filter = .all }
    }

    private func persistFilter(_ new: Filter) {
        guard Filter.browsing.contains(new), podcast.episodeFilter != new.rawValue else { return }
        podcast.episodeFilter = new.rawValue
        try? context.save()
    }

    /// The visible episodes, worked out when something they depend on
    /// changes rather than on every evaluation of this page. A computed
    /// property here was sorted and filtered several times per evaluation —
    /// the toolbar, the list and the selection bar each asked — and for a
    /// show with a thousand episodes that is most of a frame each time.
    @State private var episodes: [Episode] = []
    @State private var markFiltered: MarkFiltered?
    /// 0 is every season.
    @State private var season = 0
    @State private var seasonList: [Int] = []
    /// The episodes that start a new year in the list, and which year.
    @State private var yearBreaks: [PersistentIdentifier: Int] = [:]

    private func refreshEpisodes() {
        episodes = computeEpisodes()
        yearBreaks = Self.yearBreaks(in: episodes)
    }

    /// Where a year heading goes: before the first episode of each run of
    /// the same year, except a run in the current year at the top of the
    /// list, which needs no heading.
    static func yearBreaks(in episodes: [Episode], now: Date = .now) -> [PersistentIdentifier: Int] {
        let calendar = Calendar.current
        let thisYear = calendar.component(.year, from: now)
        var breaks: [PersistentIdentifier: Int] = [:]
        var previous: Int?
        for episode in episodes {
            let year = calendar.component(.year, from: episode.publishedAt)
            if year != previous, !(previous == nil && year == thisYear) {
                breaks[episode.persistentModelID] = year
            }
            previous = year
        }
        return breaks
    }

    private func computeEpisodes() -> [Episode] {
        var list = podcast.sortedEpisodes.filter { !$0.isArchived }
        switch filter {
        case .all:        break
        case .unplayed:   list = list.filter { !$0.isPlayed }
        case .played:     list = list.filter { $0.isPlayed }
        case .downloaded: list = list.filter { $0.isDownloaded }
        case .ready:      list = list.filter { $0.processingState == .ready }
        case .notInFeed:  list = list.filter { $0.publishedURL == nil }
        case .inFeed:     list = list.filter { $0.publishedURL != nil }
        case .needsAds:   list = list.filter { $0.processingState != .ready }
        case .readyToPublish: list = list.filter { $0.processingState == .ready && $0.publishedURL == nil }
        }
        if podcast.hidePlayed && filter != .played && !publishing {
            list = list.filter { !$0.isPlayed }
        }
        if season > 0 {
            list = list.filter { $0.seasonNumber == season }
        }
        if !search.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(search) }
        }
        return list
    }

    /// The seasons this show numbers its episodes in, if any — Apple's
    /// season picker appears only for shows that use seasons.
    private var seasons: [Int] {
        Array(Set(podcast.episodes.lazy.map(\.seasonNumber).filter { $0 > 0 })).sorted()
    }

    var body: some View {
        List {
            header
            filterBar
            episodeList
            if !selecting { similarSection }
            BottomClearance()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // The backdrop is allowed through the top safe area, so the artwork
        // colour runs under the status bar and the navigation buttons. That is
        // what replaces the hard black header strip above the cover — and it
        // is what gives the glass controls something real to refract.
        //
        // It moves with the scroll. Pinned, it stayed painted over the episode
        // list no matter how far down you were, which is why the whole page
        // read as one colour instead of a tinted header above a black list.
        .background(alignment: .top) {
            ShowBackdrop(url: podcast.artworkURL, headerBottom: headerBottom,
                         collapsePoint: Self.collapsePoint, scroll: scroll)
        }
        .background(Theme.background.ignoresSafeArea())
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            scroll.offset = offset
        }
        // Soft, as the Podcasts app does it — no hard-edged band under the bar.
        .scrollEdgeEffectStyle(.soft, for: .all)
        .environment(\.defaultMinListRowHeight, 44)
        // No title in the bar, scrolled or not. It used to appear once the
        // header had scrolled away, and with the soft edge under the bar it
        // sat directly over the episode text passing beneath — reported as
        // messy (and not something Apple Podcasts' show page does, as he
        // remembers it). Only
        // selection puts words there ("3 Selected").
        .navigationTitle(selecting ? selectionTitle : "")
        .processingBanner(pipeline, publisher: FeedPublisher.shared)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(selecting)
        // A panel above the tab bar, not a bottom toolbar in place of it.
        //
        // The first version hid the tab bar and put the actions in a
        // `.bottomBar` toolbar. The now-playing bar does not hide with the tab
        // bar — it dropped down and sat squarely on top of Mark as Played and
        // Find Ads, so only the ⋯ at the far edge could be reached. Seen in a
        // screenshot, not guessed. The Publish page already uses this
        // pattern and it clears everything.
        // A safe-area *bar*, not an inset, so the list gets the same soft
        // edge effect under it that it gets under the system bars — rows
        // passing beneath the buttons blur away instead of reading through.
        .safeAreaBar(edge: .bottom) {
            if publishing { publishActionBar } else if selecting { selectionActionBar }
        }
        // No painted bar background: the soft edge effect is the material,
        // the way the Podcasts app's show page reads.
        .searchable(text: $search, prompt: "Search episodes")
        .searchToolbarBehavior(.minimize)
        // Pull down to check this show's feed now. Joins a library-wide check
        // if one is already running; never interrupts finding ads or
        // publishing — see `ProcessingPipeline.refreshFeed(of:)`.
        .refreshable {
            await pipeline.refreshFeed(of: podcast, queueNewEpisodes: settings.autoQueueNewEpisodes)
            refreshEpisodes()
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { ShowSettingsView(podcast: podcast) }
                .glassSheet()
        }
        .task {
            similar = (try? await DiscoverService.related(to: podcast, limit: 12)) ?? []
        }
        .onAppear {
            restoreFilter()
            refreshEpisodes()
            if startPublishing, !publishing { beginPublishing() }
            // Everything published before this moment has now been seen, which
            // is what stops the library saying "100 new" about a show you read
            // five minutes ago.
            podcast.markSeen()
            LibraryIndexStatus.shared.refreshCounts()
            try? context.save()
        }
        .onChange(of: filter) { _, new in persistFilter(new); refreshEpisodes() }
        .onChange(of: season) { refreshEpisodes() }
        .task(id: podcast.episodes.count) { seasonList = seasons }
        .onChange(of: search) { refreshEpisodes() }
        // The show's counts move whenever an episode is added, played,
        // processed or published — the things the filters depend on.
        .onChange(of: CountsCache.counts(for: podcast)) { refreshEpisodes() }
        .confirmationDialog(processAndPublishTitle, isPresented: $confirmProcessAndPublish,
                            titleVisibility: .visible) {
            Button("Find Ads and Publish") {
                queuePublish(selectedEpisodes.filter { $0.publishedURL == nil })
            }
            Button("Publish Only the Ad-Free Ones") {
                queuePublish(selectedEpisodes.filter { $0.publishedURL == nil && $0.processingState == .ready })
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Finding ads takes a few minutes an episode. Each one is published as soon as its ads are found.")
        }
    }

    private var processAndPublishTitle: String {
        let pending = selectedEpisodes.filter { $0.publishedURL == nil && $0.processingState != .ready }.count
        return "Find ads in \(pending) episode\(pending == 1 ? "" : "s") and publish?"
    }

    /// A single percentage in the navigation bar, for when the episode being
    /// processed isn't one of the rows on screen. It sits in the toolbar so
    /// nothing in the content moves when it appears or goes away.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(allVisibleSelected ? "Select None" : "Select All") {
                    if allVisibleSelected {
                        selection.removeAll()
                    } else {
                        selection = Set(episodes.map(\.persistentModelID))
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done", role: .confirm) { publishing ? endPublishing() : endSelection() }
            }
        } else if pipeline.isRunning && !episodes.contains(where: { pipeline.isProcessing($0) }) {
            ToolbarItem(placement: .topBarTrailing) {
                ProcessingToolbarChip(pipeline: pipeline)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 16) {
            Artwork(url: podcast.artworkURL, size: Metrics.artHero)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                .padding(.top, 4)

            VStack(spacing: 6) {
                Text(podcast.title)
                    .font(.system(size: Metrics.titleSize, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                // 17pt, not 15. The author line sits directly under a 22pt
                // title and was two steps down from it, which made the pair
                // read as a heading with a footnote rather than a show and
                // who makes it.
                Text(podcast.author)
                    .font(.system(size: Metrics.bodySize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                statsLine
            }
            .frame(maxWidth: .infinity)

            actionRow
            if publishing {
                publishHeader
            } else {
                summary
            }
        }
        .frame(maxWidth: .infinity)
        .readableWidth(520)
        .padding(.bottom, 6)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).maxY
        } action: { maxY in
            let bottom = maxY + scroll.offset
            if abs(bottom - headerBottom) > 1 { headerBottom = bottom }
        }
        .plainRow(top: 2, bottom: 4)
    }

    private var statsLine: some View {
        HStack(spacing: 6) {
            Text("\(CountsCache.counts(for: podcast).total) episodes")
            if podcast.readyCount > 0 {
                Text("·")
                Text("\(podcast.readyCount) ad-free").foregroundStyle(.green)
            }
            if podcast.priority == 1 {
                Text("·")
                Text("High priority").foregroundStyle(Theme.accentWarm)
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    /// Play, Publish and the overflow menu, sized so the two capsules share
    /// the width evenly and the menu is a circle of the same height.
    ///
    /// The old row put a `NavigationLink` in the middle of a `List` row, which
    /// made the list add its own chevron on the far right and stretch the gap
    /// between the Publish label and that arrow.
    private var actionRow: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ShowPlayButton(title: playTitle, isPlaying: isPlayingThisShow) {
                    togglePlayLatest()
                }

                ShowSecondaryButton(
                    title: publishing ? "Done" : (podcast.publishedFeedURL == nil ? "Publish" : "Feed"),
                    symbol: publishing ? "checkmark" : "dot.radiowaves.up.forward"
                ) {
                    publishing ? endPublishing() : beginPublishing()
                }

                Menu {
                    overflowMenuContent
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 38, height: 22)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("More")
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var overflowMenuContent: some View {
        Button("Show Settings", systemImage: "slider.horizontal.3") {
            showingSettings = true
        }
        Button("Select Episodes", systemImage: "checkmark.circle") {
            beginSelection()
        }
        Button("Queue Unplayed", systemImage: "text.append") { queueUnplayed() }
        Button("Mark All Played", systemImage: "checkmark.circle") { markAllPlayed() }
        if let feed = podcast.publishedFeedURL {
            Divider()
            Button("Copy Feed Address", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = feed
                Haptics.success()
            }
        }
        Divider()
        Button(podcast.isArchived ? "Unarchive Show" : "Archive Show",
               systemImage: "archivebox") {
            podcast.isArchived.toggle()
            try? context.save()
        }
    }

    /// Feed descriptions are HTML. This is `plainSummary`, not `summary`, which
    /// is why the text no longer opens with a literal `<p>`.
    @ViewBuilder
    private var summary: some View {
        let text = podcast.plainSummary
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: Metrics.bodySize))
                    .foregroundStyle(.secondary)
                    .lineLimit(summaryExpanded ? nil : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !summaryExpanded {
                    // Lowercase, and the same size as the text it continues.
                    // Bold small caps read as a section heading rather than as
                    // the end of a truncated sentence, which is not how the
                    // Podcasts app does it.
                    Text("more")
                        .font(.system(size: Metrics.bodySize, weight: .semibold))
                        .foregroundStyle(Theme.accentHot)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy(duration: 0.22)) { summaryExpanded.toggle() }
            }
            .padding(.top, 2)
        }
    }

    // MARK: Filter and sort

    /// Replaces the chip strip that ran off the right edge of the screen.
    private var filterBar: some View {
        SectionMenuBar(title: filter.rawValue) {
            Picker("Show", selection: $filter) {
                ForEach(publishing ? Filter.publishing : Filter.browsing) { option in
                    Label(option.rawValue, systemImage: option.symbol).tag(option)
                }
            }
            Divider()
            Picker("Episode Order", selection: Binding(
                get: { podcast.episodeOrder },
                set: { podcast.episodeOrder = $0; try? context.save() }
            )) {
                ForEach(EpisodeOrder.allCases) { Text($0.rawValue).tag($0) }
            }
            if seasonList.count > 1 {
                Picker("Season", selection: $season) {
                    Text("All Seasons").tag(0)
                    ForEach(seasonList, id: \.self) { Text("Season \($0)").tag($0) }
                }
            }
            if !publishing {
                Toggle("Hide Played Episodes", systemImage: "eye.slash", isOn: Binding(
                    get: { podcast.hidePlayed },
                    set: { podcast.hidePlayed = $0; try? context.save(); refreshEpisodes() }
                ))
            }
            // New in Podcasts 27.2: act on exactly what the filter shows.
            if (filter != .all || !search.isEmpty || season > 0) && !publishing && !episodes.isEmpty {
                Divider()
                Button("Mark Filtered as Played", systemImage: "checkmark.circle") {
                    markFiltered = .played
                }
                Button("Mark Filtered as Unplayed", systemImage: "circle") {
                    markFiltered = .unplayed
                }
            }
        } trailing: {
            if season > 0 {
                Text("Season \(season)").font(.subheadline).foregroundStyle(.secondary)
            }
            Text("\(episodes.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .plainRow(top: 14, bottom: 4)
        // Apple's wording for both confirmations.
        .confirmationDialog(markFiltered == .played
                                ? "This will mark all filtered episodes of this show as played."
                                : "This will mark all filtered episodes of this show as unplayed.",
                            isPresented: Binding(get: { markFiltered != nil },
                                                 set: { if !$0 { markFiltered = nil } }),
                            titleVisibility: .visible) {
            Button(markFiltered == .played ? "Mark as Played" : "Mark as Unplayed") {
                if let mark = markFiltered { markVisible(played: mark == .played) }
                markFiltered = nil
            }
            Button("Cancel", role: .cancel) { markFiltered = nil }
        }
    }

    private enum MarkFiltered { case played, unplayed }

    private func markVisible(played: Bool) {
        for episode in episodes where episode.isPlayed != played {
            episode.isPlayed = played
            if played {
                episode.isInQueue = false
            } else {
                episode.playbackPosition = 0
            }
        }
        try? context.save()
        CountsCache.invalidate(podcast)
        LibraryTotals.shared.invalidate()
        refreshEpisodes()
        Haptics.success()
    }

    // MARK: Episodes

    @ViewBuilder
    private var episodeList: some View {
        ForEach(episodes) { episode in
            // A year written between the rows where the list crosses into
            // another year, the way the Podcasts app does it — "Dec 26" under
            // "Jan 1" is otherwise read as the same year.
            if let year = yearBreaks[episode.persistentModelID] {
                Text(String(year))
                    .font(.system(size: Metrics.titleSize, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("YearHeading")
                    .plainRow(top: 18, bottom: 2)
            }
            if selecting {
                // The same full row — cover, notes and all — with a tick
                // beside it, on the same page.
                //
                // Selection used to swap every row for a compact text-only one
                // in list edit mode, and read as a different, smaller screen.
                // The row's own buttons are switched off while selecting, so a
                // tap anywhere on it ticks it.
                SelectingEpisodeRow(episode: episode,
                                    isSelected: selection.contains(episode.persistentModelID)) {
                    toggleSelection(episode)
                }
                .contentRow()
            } else {
                EpisodeRow(episode: episode, onSelect: {
                    beginSelection()
                    selection.insert(episode.persistentModelID)
                }, onPublish: {
                    beginPublishing(keeping: [episode.persistentModelID])
                }, yearInDate: false)
                .contentRow()
                .swipeActions(edge: .trailing) { rowTrailing(episode) }
                .swipeActions(edge: .leading) { rowLeading(episode) }
            }
        }

        if episodes.isEmpty {
            ContentUnavailableView("Nothing matches",
                systemImage: "line.3.horizontal.decrease",
                description: Text("Try a different filter."))
                .plainRow(top: 40, bottom: 40)
        }
    }

    @ViewBuilder
    private func rowTrailing(_ episode: Episode) -> some View {
        Button(role: .destructive) {
            episode.isArchived = true
            try? context.save()
            CountsCache.invalidate(podcast)
            LibraryTotals.shared.invalidate()
        } label: { Label("Archive", systemImage: "archivebox") }

        Button {
            episode.isPlayed.toggle()
            try? context.save()
            CountsCache.invalidate(podcast)
            LibraryTotals.shared.invalidate()
        } label: {
            Label(episode.isPlayed ? "Unplayed" : "Played",
                  systemImage: episode.isPlayed ? "circle" : "checkmark.circle")
        }
        .tint(.blue)
    }

    @ViewBuilder
    private func rowLeading(_ episode: Episode) -> some View {
        Button {
            episode.addToUpNext(next: true, context: context)
        } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        .tint(Theme.accentHot)
    }

    @ViewBuilder
    private var similarSection: some View {
        if !similar.isEmpty {
            SectionHeader("You Might Also Like")
            similarStrip.plainRow(top: 0, bottom: 8)
        }
    }

    private var similarStrip: some View {
        CoverStrip(items: similar, artwork: { $0.artworkURL }) { show in
            Text(show.title)
                .font(.footnote)
                .lineLimit(2)
                .foregroundStyle(.primary)
        }
    }

    // MARK: Selection

    private var selectionActionBar: some View {
        let chosen = selectedEpisodes
        let allPlayed = !chosen.isEmpty && chosen.allSatisfy(\.isPlayed)
        return GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    batchMarkPlayed(!allPlayed)
                } label: {
                    Label(allPlayed ? "Unplayed" : "Played",
                          systemImage: allPlayed ? "circle" : "checkmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                }
                .buttonStyle(.glass)
                .disabled(chosen.isEmpty)

                Button {
                    batchFindAds()
                } label: {
                    Label("Find Ads", systemImage: "wand.and.sparkles")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                }
                .buttonStyle(.glass)
                .disabled(selectedNeedingAds.isEmpty || pipeline.isRunning)

                // The same publishing view as the Publish button beside Play,
                // with what is ticked here still ticked.
                Button {
                    beginPublishing(keeping: selection)
                } label: {
                    Label("Publish", systemImage: "dot.radiowaves.up.forward")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                }
                .buttonStyle(.glass)
                .disabled(chosen.isEmpty)

                Menu {
                    batchMenuContent
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

    private var selectedEpisodes: [Episode] {
        episodes.filter { selection.contains($0.persistentModelID) }
    }

    private var selectedNeedingAds: [Episode] {
        selectedEpisodes.filter { $0.processingState != .ready && !pipeline.isProcessing($0) }
    }

    private var allVisibleSelected: Bool {
        !episodes.isEmpty && episodes.allSatisfy { selection.contains($0.persistentModelID) }
    }

    private var selectionTitle: String {
        let count = selectedEpisodes.count
        if publishing { return count == 0 ? "Publish" : "\(count) to Publish" }
        // "Select" rather than "Select Episodes": between Select All and Done
        // the longer one was truncated to "Select Episo…".
        return count == 0 ? "Select" : "\(count) Selected"
    }

    @ViewBuilder
    private var batchMenuContent: some View {
        let chosen = selectedEpisodes
        Button("Add to Up Next", systemImage: "text.append") { batchQueue() }
        if chosen.contains(where: { !$0.isDownloaded }) {
            Button("Download", systemImage: "arrow.down.circle") { batchDownload() }
        }
        if chosen.contains(where: \.isDownloaded) {
            Button("Remove Download", systemImage: "trash") { batchRemoveDownloads() }
        }
        Button(chosen.allSatisfy(\.isStarred) ? "Unstar" : "Star", systemImage: "star") {
            let star = !chosen.allSatisfy(\.isStarred)
            for episode in chosen { episode.isStarred = star }
            finishBatch()
        }
        Divider()
        Button("Archive", systemImage: "archivebox", role: .destructive) {
            for episode in chosen { episode.isArchived = true }
            finishBatch()
        }
    }

    private func toggleSelection(_ episode: Episode) {
        let id = episode.persistentModelID
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        Haptics.select()
    }

    /// Opens publishing, optionally with episodes already ticked — from the
    /// selection bar's Publish, or an episode's Publish… — in which case the
    /// filter shows everything, so nothing ticked is hidden by it.
    private func beginPublishing(keeping kept: Set<PersistentIdentifier> = []) {
        PublishQueue.shared.configure(context: context)
        FeedPublisher.shared.configure(context: context, pipeline: pipeline)
        selection = kept
        withAnimation(.snappy(duration: 0.28)) {
            publishing = true
            selecting = true
            filter = kept.isEmpty ? .notInFeed : .all
        }
    }

    private func endPublishing() {
        withAnimation(.snappy(duration: 0.28)) {
            publishing = false
            selecting = false
            filter = Filter(rawValue: podcast.episodeFilter) ?? .all
            if !Filter.browsing.contains(filter) { filter = .all }
        }
        selection.removeAll()
    }

    /// The feed link, where the show's description would be.
    @ViewBuilder
    private var publishHeader: some View {
        VStack(spacing: 10) {
            if let feed = podcast.publishedFeedURL {
                FeedLinkCard(feed: feed, lastPublished: podcast.lastPublished)
                // Also in the show's settings; here because this is where
                // publishing is being thought about.
                Toggle(isOn: Bindable(podcast).autoPublish) {
                    Text("Publish new episodes automatically")
                        .font(.subheadline)
                }
                .tint(Theme.accentHot)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("AutoPublishToggle")
            } else {
                Text("Publish one episode and this show gets a single private link. Add it to Apple Podcasts once — everything you publish afterwards appears there by itself.")
                    .font(.system(size: Metrics.subtitleSize))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let publishMessage {
                Text(publishMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 2)
    }

    private var publishActionBar: some View {
        let chosen = selectedEpisodes
        let needAds = chosen.filter { $0.processingState != .ready && !pipeline.isProcessing($0) }
        let unpublished = chosen.filter { $0.publishedURL == nil }
        return GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Task { for episode in needAds { await pipeline.processNow(episode) } }
                    selection.removeAll()
                    Haptics.success()
                } label: {
                    Label("Find Ads (\(needAds.count))", systemImage: "wand.and.sparkles")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                }
                .buttonStyle(.glass)
                .disabled(needAds.isEmpty)

                if !chosen.isEmpty && unpublished.isEmpty {
                    // Everything chosen is already in the feed: the same
                    // place offers taking it out.
                    Button(role: .destructive) {
                        let episodes = chosen
                        Task {
                            do {
                                try await FeedPublisher.shared.removeFromFeed(episodes, of: podcast)
                                publishMessage = "Took \(episodes.count) out of the feed."
                            } catch {
                                publishMessage = error.localizedDescription
                            }
                        }
                        selection.removeAll()
                        Haptics.success()
                    } label: {
                        Label("Remove from Feed (\(chosen.count))", systemImage: "minus.circle")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                } else {
                    Button {
                        // Unprocessed episodes are found first and then
                        // published — say so before starting something that
                        // long, rather than after.
                        if unpublished.contains(where: { $0.processingState != .ready }) {
                            confirmProcessAndPublish = true
                        } else {
                            queuePublish(unpublished)
                        }
                    } label: {
                        Label("Publish (\(unpublished.count))", systemImage: "arrow.up.circle")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(unpublished.isEmpty)
                }
            }
            .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 8)
    }

    private func queuePublish(_ episodes: [Episode]) {
        PublishQueue.shared.enqueue(episodes)
        publishMessage = "Queued \(episodes.count) episode\(episodes.count == 1 ? "" : "s"). Tap the bar at the top to follow along or change the order."
        selection.removeAll()
        Haptics.success()
    }

    private func beginSelection() {
        selection.removeAll()
        withAnimation(.snappy(duration: 0.25)) { selecting = true }
    }

    private func endSelection() {
        if publishing { endPublishing(); return }
        withAnimation(.snappy(duration: 0.25)) { selecting = false }
        selection.removeAll()
    }

    /// Save, refresh the counts everything else reads, and leave selection
    /// mode — the same thing the Podcasts app does after a batch action.
    private func finishBatch(stay: Bool = false) {
        try? context.save()
        CountsCache.invalidate(podcast)
        LibraryTotals.shared.invalidate()
        Haptics.success()
        if !stay { endSelection() }
    }

    private func batchMarkPlayed(_ played: Bool) {
        for episode in selectedEpisodes {
            episode.isPlayed = played
            if played { episode.isInQueue = false }
        }
        finishBatch()
    }

    /// To the end of Up Next, in the order they appear on this page.
    private func batchQueue() {
        let queued = (try? context.fetch(FetchDescriptor<Episode>(
            predicate: #Predicate { $0.isInQueue }))) ?? []
        var order = (queued.map(\.queueOrder).max() ?? -1) + 1
        for episode in selectedEpisodes where !episode.isInQueue {
            if episode.isPlayed { episode.playbackPosition = 0 }
            episode.isInQueue = true
            episode.queueOrder = order
            order += 1
        }
        PrepareAhead.shared.refresh()
        finishBatch()
    }

    private func batchFindAds() {
        let targets = selectedNeedingAds
        guard !targets.isEmpty else { return }
        pipeline.cancelBackgroundWork()
        Task { await pipeline.process(targets) }
        finishBatch()
    }

    private func batchDownload() {
        let targets = selectedEpisodes.filter { !$0.isDownloaded }
        finishBatch()
        Task {
            for episode in targets {
                _ = await DownloadManager.fetchAudio(for: episode)
            }
            try? context.save()
            LibraryTotals.shared.invalidate()
        }
    }

    /// Never the one that is playing: its file is open.
    private func batchRemoveDownloads() {
        let playing = player.currentEpisode?.guid
        for episode in selectedEpisodes where episode.isDownloaded && episode.guid != playing {
            DownloadManager.remove(episode)
        }
        finishBatch()
    }

    // MARK: Actions

    private var nextUpEpisode: Episode? {
        episodes.first { !$0.isPlayed && $0.isDownloaded }
            ?? episodes.first { !$0.isPlayed }
            ?? episodes.first
    }

    private var isPlayingThisShow: Bool {
        player.isPlaying && player.currentEpisode?.podcast?.feedURL == podcast.feedURL
    }

    private var playTitle: String {
        if isPlayingThisShow { return "Pause" }
        if let next = nextUpEpisode, next.playbackPosition > 5 { return "Resume" }
        return "Play"
    }

    private func togglePlayLatest() {
        if isPlayingThisShow {
            player.pause()
            return
        }
        if let current = player.currentEpisode,
           current.podcast?.feedURL == podcast.feedURL, !current.isPlayed {
            player.play()
            return
        }
        if let next = nextUpEpisode { PlayCoordinator.play(next, settings: settings, pipeline: pipeline) }
    }

    private func markAllPlayed() {
        for episode in podcast.episodes where !episode.isPlayed {
            episode.isPlayed = true
            episode.isInQueue = false
        }
        try? context.save()
        CountsCache.invalidate(podcast)
        LibraryTotals.shared.invalidate()
    }

    private func queueUnplayed() {
        var order = 0
        for episode in podcast.sortedEpisodes where !episode.isPlayed && !episode.isArchived {
            episode.isInQueue = true
            episode.queueOrder = order
            order += 1
        }
        try? context.save()
    }
}

// MARK: - Selecting row

/// A full episode row with a tick, for selection mode.
struct SelectingEpisodeRow: View {
    let episode: Episode
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(isSelected ? Theme.accentHot : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28)
            EpisodeRow(episode: episode)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("SelectableEpisode")
    }
}

// MARK: - Selectable row

/// The row used in selection mode: what the episode is, with nothing in it
/// that can take a tap.
struct SelectableEpisodeRow: View {
    let episode: Episode

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(RelativeDate.release(episode.publishedAt))
                if episode.duration > 0 {
                    Text("·")
                    Text(formatDuration(episode.duration))
                }
                if episode.processingState == .ready {
                    Text("·")
                    Label("Ad-free", systemImage: "wand.and.sparkles")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.green)
                }
                Spacer(minLength: 0)
                if episode.isDownloaded {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tertiary)
                }
                if episode.isInQueue {
                    Image(systemName: "text.append").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: Metrics.metaSize, weight: .medium))
            .foregroundStyle(.secondary)

            Text(episode.title)
                .font(.system(size: Metrics.bodySize, weight: .semibold))
                .lineLimit(2)
                .foregroundStyle(episode.isPlayed ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Episode row

struct EpisodeRow: View {
    let episode: Episode
    /// Starts selection mode with this episode ticked. Offered in the row's
    /// menu where the page supports selecting.
    var onSelect: (() -> Void)? = nil
    var onPublish: (() -> Void)? = nil
    /// In a list mixing shows — Up Next — the show's name leads the row,
    /// since it is not the page you are on.
    var showsShowName = false
    /// Up Next's "getting ready" state for this episode, when it is one of
    /// the next few being prepared and is not ready yet.
    var aheadNote: String? = nil
    /// Whether an episode from an earlier year says so in its date. The show
    /// page says it with a year heading between the rows instead.
    var yearInDate = true
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(AppSettings.self) private var settings
    @State private var player = PlayerEngine.shared
    @State private var expanded = false

    private var isCurrent: Bool { player.currentEpisode?.guid == episode.guid }
    private var isProcessing: Bool { pipeline.isProcessing(episode) }

    var body: some View {
        // Cover on the right, the way the Podcasts app does it on a show page.
        // In a cross-show list the artwork leads, because it identifies the
        // show; here the show is already the page you are on, so it trails and
        // the title gets the left edge.
        // The controls sit below the artwork, not beside it.
        //
        // They used to live in the text column, which meant the ⋯ lined up
        // with the left edge of the cover rather than the right edge of the
        // row — two thirds of the way across, floating, in a different place
        // on every screen width. It was reported as "the three dot menu isn't
        // all the way to the right", and it wasn't. Apple runs this row the
        // full width underneath for the same reason.
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: Metrics.rowTextGap) {
                VStack(alignment: .leading, spacing: 7) {
                    if showsShowName, let show = episode.podcast?.title, !show.isEmpty {
                        Text(show)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.bottom, -4)
                    }
                    metaLine
                    title
                    notes
                    if let aheadNote {
                        Label(aheadNote, systemImage: "sparkles")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.accentWarm)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Artwork(url: episode.artworkURL ?? episode.podcast?.artworkURL,
                        size: Metrics.artRow)
            }

            actionRow

            // Progress for this episode, in this episode's own row,
            // directly under its controls — rather than a banner floating
            // at the top of the screen that never said which episode it
            // meant.
            if isProcessing {
                InlineProcessingRow(pipeline: pipeline)
                    .padding(.top, 1)
            }
            errorLine
        }
        .animation(.snappy(duration: 0.25), value: isProcessing)
        // Touch and hold anywhere on the row for the same menu as ⋯.
        .contextMenu {
            EpisodeMenuItems(episode: episode, onSelect: onSelect, onPublish: onPublish)
        }
    }

    /// The line above the title, the way the Podcasts app writes it: the
    /// date, then an explicit badge, what kind of episode it is (Bonus,
    /// Trailer, or its number), a TV and "Video" for a video episode, and —
    /// PodSkipper's own — "Ad-free" once its ads are found.
    ///
    /// One `Text` rather than a row of separate ones, so a long line is cut
    /// off at the end with an ellipsis instead of squeezing every piece.
    private var metaText: Text {
        var parts: [Text] = []
        var date = Text(yearInDate
                        ? RelativeDate.release(episode.publishedAt)
                        : episode.publishedAt.formatted(.dateTime.month(.abbreviated).day()))
        if episode.isExplicit {
            let badge = Text(Image(systemName: "e.square.fill")).accessibilityLabel("Explicit")
            date = Text("\(date) \(badge)")
        }
        parts.append(date)
        if episode.isBonus {
            let number = episode.numberLabel
            parts.append(Text(number.isEmpty ? "Bonus" : "\(number) Bonus").foregroundStyle(Theme.accentWarm))
        } else if episode.isTrailer {
            parts.append(Text("Trailer").foregroundStyle(Theme.accentWarm))
        } else if !episode.numberLabel.isEmpty {
            parts.append(Text(episode.numberLabel).foregroundStyle(Theme.accentWarm))
        }
        if episode.isVideo || episode.videoURL != nil {
            // Worth flagging before you start it: a bigger download, and a
            // picture you may not want.
            parts.append(Text("\(Image(systemName: "tv")) Video"))
        }
        if episode.processingState == .ready {
            parts.append(Text("\(Image(systemName: "wand.and.sparkles")) Ad-free").foregroundStyle(.green))
        }
        // Interpolation rather than `+`, which iOS 26 deprecates for Text.
        return parts.dropFirst().reduce(parts[0]) { line, part in Text("\(line)  ·  \(part)") }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            metaText
                .lineLimit(1)
                .accessibilityIdentifier("EpisodeMeta")
            Spacer(minLength: 0)
            if episode.publishedURL != nil {
                Image(systemName: "dot.radiowaves.up.forward")
                    .foregroundStyle(Theme.accentHot)
                    .accessibilityLabel("In your ad-free feed")
            }
            if episode.isDownloaded {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tertiary)
            }
            if episode.isStarred {
                Image(systemName: "star.fill").foregroundStyle(.yellow)
            }
        }
        // 13pt is the floor. Apple has no 10 or 11pt tier anywhere in this
        // app except the tab bar label, and `.caption2` is 11.
        .font(.system(size: Metrics.metaSize, weight: .medium))
        .foregroundStyle(.secondary)
    }

    private var title: some View {
        // 22pt semibold over two lines. It was 15pt over three, which is the
        // single biggest reason the app read as cramped next to the real one:
        // the most important string on the screen was set smaller than
        // Apple's section headings.
        Text(episode.title)
            .font(.system(size: Metrics.titleSize, weight: .semibold))
            .lineSpacing(Metrics.titleLineSpacing)
            .lineLimit(2)
            .foregroundStyle(episode.isPlayed ? .secondary : .primary)
            .accessibilityIdentifier("EpisodeTitle")
    }

    @ViewBuilder
    private var notes: some View {
        if !episode.plainDescription.isEmpty {
            Text(episode.plainDescription)
                .font(.system(size: Metrics.subtitleSize))
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 2)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy(duration: 0.2)) { expanded.toggle() } }
        }
    }

    /// Play pill, Find Ads, and the overflow — one row, always full width.
    ///
    /// The previous attempt used `ViewThatFits`, and that was the wrong tool:
    /// it measures each candidate at its *ideal* size, and a `Spacer` has an
    /// ideal width of zero. So the first candidate always claimed to fit, the
    /// row shrank to its contents, and the result was the opposite of what was
    /// asked for — Find Ads stretched out and the three-dot floated in from the
    /// right edge instead of sitting on it.
    ///
    /// One plain `HStack` that fills the width, with the trailing control
    /// pinned. What gives, when something has to, is the play pill's time
    /// label: it is the only element carrying information that is also drawn as
    /// a progress bar an inch to its left.
    private var actionRow: some View {
        HStack(spacing: 8) {
            playPill
                .layoutPriority(1)

            // `fixedSize()`, both axes.
            //
            // It was `horizontal: true, vertical: false`, which reads as
            // "fix the width, leave the height alone" and is not what it
            // does here: the label's text kept wrapping, "Find Ads" became a
            // column of letters, and the capsule around it grew into a
            // three-hundred-point vertical pill with a wand floating in the
            // middle of it — sitting in the row where a small button should
            // be, shoving the ⋯ two thirds of the way across. One line, one
            // ideal size, no wrapping, in both directions.
            findAdsIfNeeded
                .fixedSize()
                .layoutPriority(2)

            // Takes every point nobody else claimed. This is what puts the
            // overflow on the trailing edge and keeps it in the same place on
            // every row, whatever the duration beside it reads.
            Spacer(minLength: 8)

            overflowMenu
                .frame(width: 44, height: 32)
                .contentShape(Rectangle())
                .fixedSize()
                .layoutPriority(2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 1)
    }

    private var playPill: some View {
        EpisodePlayPill(isPlaying: isCurrent && player.isPlaying,
                        progress: episode.progressFraction,
                        timeLabel: timeLabel) {
            if isCurrent {
                player.togglePlayPause()
            } else {
                // Goes through the coordinator rather than straight to the
                // player, so an episode whose ads have not been found yet gets
                // the choice instead of either refusing or silently starting a
                // transcription nobody asked for.
                PlayCoordinator.play(episode, settings: settings, pipeline: pipeline)
            }
        }
    }

    @ViewBuilder
    private var findAdsIfNeeded: some View {
        if episode.processingState != .ready && !isProcessing {
            findAdsButton
        }
    }

    /// Time remaining once you have started, total length before that — the
    /// same thing Apple shows in its own play pill.
    private var timeLabel: String {
        if episode.isPlayed { return "Played" }
        let remaining = episode.remainingSeconds
        let base = remaining > 0 ? remaining : episode.duration
        guard base > 0 else { return "—" }
        let minutes = Int(base / 60)
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private var findAdsButton: some View {
        Button {
            Task { await pipeline.processNow(episode) }
        } label: {
            Label(pipeline.waitingToProcess == episode.guid ? "Waiting…" : "Find Ads",
                  systemImage: "wand.and.sparkles")
                // Spelled out, not left to `.automatic`, which quietly drops
                // the words and leaves a wand on its own — a button whose
                // label is a magic wand tells you nothing about what pressing
                // it does.
                .labelStyle(.titleAndIcon)
                .font(.subheadline.weight(.semibold))
                // Two words that must stay two words on one line. Allowed to
                // wrap, they become the tall pill described above.
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.09)))
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.8))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var overflowMenu: some View {
        Menu {
            EpisodeMenuItems(episode: episode, onSelect: onSelect, onPublish: onPublish)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: UIScale.pt(17), weight: .semibold))
                .foregroundStyle(.secondary)
                // A fixed square with the highest priority in the row. This is
                // what pins it to the trailing edge: whatever else the row has
                // to give up, this does not move and does not shrink, so the
                // three-dot is always in the same place on every row of the
                // list regardless of how long the duration beside it reads.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .layoutPriority(2)
        .accessibilityLabel("More options")
    }

    @ViewBuilder
    private var errorLine: some View {
        if let error = episode.processingError, !isProcessing {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }
}

// MARK: - Per-show settings

struct ShowSettingsView: View {
    @Bindable var podcast: Podcast
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    private let speeds: [Double] = [0.8, 1.0, 1.2, 1.5, 1.75, 2.0, 2.5, 3.0]

    var body: some View {
        List {
            headerCard.plainRow(top: 10, bottom: 6)
            playbackSection
            audioSection
            adSection
            newEpisodesSection
            episodesSection
            YouTubeChannelSection(podcast: podcast)
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle("Show Settings")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .close) { dismiss() }
            }
        }
    }

    private var headerCard: some View {
        HStack(spacing: 12) {
            Artwork(url: podcast.artworkURL, size: Metrics.artRow)
            VStack(alignment: .leading, spacing: 2) {
                Text(podcast.title).font(.system(size: Metrics.bodySize, weight: .semibold)).lineLimit(2)
                Text(podcast.author).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassPanel(cornerRadius: 16)
    }

    // MARK: Playback

    /// Speed follows Apple's Default / custom split: leave it alone and the
    /// show uses whatever the app default is, or pin it and fine-tune from
    /// there.
    @ViewBuilder
    private var playbackSection: some View {
        Group {
            SectionHeader("Playback Speed")

            Picker("Speed", selection: Binding(
                get: { podcast.playbackSpeedOverride ?? 0 },
                set: { podcast.playbackSpeedOverride = $0 == 0 ? nil : $0 }
            )) {
                Text("Default (\(settings.defaultPlaybackSpeed, specifier: "%g")×)").tag(0.0)
                ForEach(speeds, id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
            }
            .contentRow()

            if let override = podcast.playbackSpeedOverride {
                fineTuneSpeed(override)
            }
        }
    }

    private func fineTuneSpeed(_ current: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Fine tune").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Text("\(current, specifier: "%.2f")×")
                    .font(.footnote.monospacedDigit().weight(.semibold))
            }
            Slider(value: Binding(
                get: { podcast.playbackSpeedOverride ?? 1 },
                set: { podcast.playbackSpeedOverride = $0.rounded(toPlaces: 2) }
            ), in: 0.5...3.0, step: 0.05)
            .tint(Theme.accentHot)
        }
        .contentRow()
    }

    // MARK: Audio

    /// Per-show audio, each switch three-way: follow the default, force on, or
    /// force off. A comedy show and a news show rarely want the same
    /// treatment.
    @ViewBuilder
    private var audioSection: some View {
        Group {
            SectionHeader("Audio")

            overridePicker(title: "Smart Speed",
                           value: $podcast.smartSpeedOverride,
                           fallback: settings.smartSpeedEnabled)

            if podcast.smartSpeedOverride == true {
                smartSpeedAmount
            }

            overridePicker(title: "Voice Boost",
                           value: $podcast.voiceBoostOverride,
                           fallback: settings.voiceBoostEnabled)

            overridePicker(title: "Volume Normalization",
                           value: $podcast.volumeNormalizationOverride,
                           fallback: settings.volumeNormalizationEnabled)

            Text("Anything left on Default follows Settings → Audio.")
                .font(.footnote).foregroundStyle(.secondary)
                .contentRow()
        }
    }

    private var smartSpeedAmount: some View {
        let amount = podcast.smartSpeedAmountOverride ?? settings.smartSpeedAggressiveness
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Shorten pauses by").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(amount * 100))%")
                    .font(.footnote.monospacedDigit().weight(.semibold))
            }
            Slider(value: Binding(
                get: { podcast.smartSpeedAmountOverride ?? settings.smartSpeedAggressiveness },
                set: { podcast.smartSpeedAmountOverride = $0 }
            ), in: 0.2...1.0)
            .tint(Theme.accentWarm)
        }
        .contentRow()
    }

    /// One control shape for every three-way override, so they all read the
    /// same way down the screen.
    private func overridePicker(title: String,
                                value: Binding<Bool?>,
                                fallback: Bool) -> some View {
        Picker(title, selection: Binding(
            get: { value.wrappedValue == nil ? 0 : (value.wrappedValue == true ? 1 : 2) },
            set: { value.wrappedValue = $0 == 0 ? nil : ($0 == 1) }
        )) {
            Text("Default (\(fallback ? "On" : "Off"))").tag(0)
            Text("On").tag(1)
            Text("Off").tag(2)
        }
        .contentRow()
    }

    // MARK: Ads

    @ViewBuilder
    private var adSection: some View {
        Group {
            SectionHeader("Ads and Sponsors")

            overridePicker(title: SegmentKind.ad.name,
                           value: $podcast.autoSkipEnabled,
                           fallback: settings.autoSkipEnabled)

            overridePicker(title: SegmentKind.selfPromo.name,
                           value: $podcast.skipSelfPromoOverride,
                           fallback: settings.skipSelfPromo)

            overridePicker(title: SegmentKind.crossPromo.name,
                           value: $podcast.skipCrossPromoOverride,
                           fallback: settings.skipCrossPromo)

            overridePicker(title: "Intros and Outros",
                           value: $podcast.skipIntroOutroOverride,
                           fallback: settings.skipIntroOutro)

            if !podcast.knownSponsors.isEmpty {
                // Worth showing: it is the app explaining why it is getting
                // faster and more certain on this show over time.
                Text("Recognises \(podcast.knownSponsors.count) sponsor\(podcast.knownSponsors.count == 1 ? "" : "s") from earlier episodes: \(podcast.knownSponsors.prefix(6).joined(separator: ", "))")
                    .font(.footnote).foregroundStyle(.secondary)
                    .contentRow()
            }

            Stepper("Fixed intro trim: \(Int(podcast.skipIntroSeconds))s",
                    value: $podcast.skipIntroSeconds, in: 0...300, step: 5)
                .contentRow()

            Stepper("Fixed outro trim: \(Int(podcast.skipOutroSeconds))s",
                    value: $podcast.skipOutroSeconds, in: 0...300, step: 5)
                .contentRow()

            Text("The fixed trims always cut that many seconds. Skip Intro and Outro instead finds the recurring open and close from the transcript, so it still works when an episode runs long.")
                .font(.footnote).foregroundStyle(.secondary)
                .contentRow()
        }
    }

    // MARK: New episodes

    @ViewBuilder
    private var newEpisodesSection: some View {
        Group {
            SectionHeader("New Episodes")
            Toggle("Add to Up Next", isOn: $podcast.autoQueueNew).contentRow()
            NavigationLink { ShowAutoDownloadView(podcast: podcast) } label: {
                HStack {
                    Text("Automatically Download")
                    Spacer()
                    Text(AutoDownload.summary(mode: podcast.effectiveAutoDownloadMode(settings),
                                              limit: podcast.effectiveAutoDownloadLimit(settings)))
                        .foregroundStyle(.secondary).font(.footnote).lineLimit(1)
                }
            }
            .contentRow()
            Toggle("Notify Me", isOn: $podcast.notifyOnNewEpisodes).contentRow()
            Picker("Priority", selection: $podcast.priority) {
                Text("Low").tag(-1)
                Text("Normal").tag(0)
                Text("High").tag(1)
            }
            .contentRow()
            Text("High-priority shows play first when Up Next advances.")
                .font(.footnote).foregroundStyle(.secondary)
                .contentRow()
        }
    }

    // MARK: Episodes

    @ViewBuilder
    private var episodesSection: some View {
        Group {
            SectionHeader("Episodes")

            Picker("Episode Order", selection: $podcast.episodeOrder) {
                ForEach(EpisodeOrder.allCases) { Text($0.rawValue).tag($0) }
            }
            .contentRow()

            overridePicker(title: "Remove Played Downloads",
                           value: $podcast.removePlayedDownloads,
                           fallback: settings.removePlayedDownloads)

            Toggle("Archived", isOn: $podcast.isArchived).contentRow()

            if podcast.publishedFeedURL != nil {
                SectionHeader("Ad-Free Feed")
                Toggle(isOn: $podcast.autoPublish) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Publish Automatically")
                        Text("Each new episode goes into this show's ad-free feed as soon as its ads are found.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .tint(Theme.accentHot)
                .contentRow()
            }
        }
    }
}


// MARK: - YouTube channel

/// Where "Watch on YouTube" looks for this show's episodes. Pasting the
/// channel's link (youtube.com/@name) is enough; it is turned into the
/// channel's ID once, here.
struct YouTubeChannelSection: View {
    @Bindable var podcast: Podcast
    @State private var draft = ""
    @State private var status: String?
    @State private var working = false

    var body: some View {
        Group {
            SectionHeader("Video on YouTube")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Channel link, e.g. youtube.com/@name", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .onSubmit { Task { await save() } }
                        .accessibilityIdentifier("YouTubeChannelField")
                    if working { ProgressView() }
                    else if !draft.isEmpty && draft != podcast.youtubeChannel {
                        Button("Save") { Task { await save() } }
                    }
                }
                Text(status ?? (podcast.youtubeChannel.isEmpty
                    ? "If the show puts full episodes on its own YouTube channel, the player offers Watch on YouTube for recent episodes. It plays in YouTube's own player, with YouTube's ads."
                    : "Channel set. Recent episodes that are on it show Watch on YouTube in the player."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !podcast.youtubeChannel.isEmpty {
                    Button("Remove Channel", role: .destructive) {
                        podcast.youtubeChannel = ""
                        draft = ""
                        status = nil
                    }
                    .font(.subheadline)
                }
            }
            .contentRow()
        }
        .onAppear { draft = podcast.youtubeChannel }
    }

    private func save() async {
        working = true
        defer { working = false }
        guard let id = await YouTubeLink.channelID(from: draft) else {
            status = "That doesn't look like a YouTube channel link."
            return
        }
        podcast.youtubeChannel = id
        draft = id
        let count = await YouTubeLink.recentVideos(channelID: id).count
        status = count > 0 ? "Channel set — \(count) recent uploads found." : "Channel set, but no uploads could be read yet."
    }
}
