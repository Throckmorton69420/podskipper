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
    case playlists, bookmarks, stats, downloaded, starred, latest
    case show(PersistentIdentifier)

    var title: String {
        switch self {
        case .playlists:  return "Playlists"
        case .bookmarks:  return "Bookmarks"
        case .stats:      return "Statistics"
        case .downloaded: return "Downloaded"
        case .starred:    return "Starred"
        case .latest:     return "Latest Episodes"
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
    /// Episode search results, fetched on demand rather than by filtering the
    /// whole store in a computed property.
    @State private var episodeMatches: [Episode] = []
    @State private var searchTask: Task<Void, Never>?

    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var showingAdd = false
    @State private var search = ""
    @State private var sort: Sort = .recent
    @State private var showArchived = false
    /// nil means "whatever suits this screen". An iPad has the width for a
    /// grid of covers and looks half-empty with a single column of rows, which
    /// is why Apple Podcasts shows a grid there and a list on a phone.
    @State private var gridPreference: Bool?
    @State private var refreshNote: String?
    /// Pushed by the cover grid, which uses buttons rather than links so the
    /// List does not decorate every tile with a disclosure chevron.
    @State private var pushedShow: LibraryRoute?

    private var isRegular: Bool { sizeClass == .regular }
    private var useGrid: Bool { gridPreference ?? isRegular }

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
        [.playlists, .latest, .downloaded, .starred, .bookmarks, .stats]
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
        .processingBanner(pipeline)
        .searchable(text: $search, prompt: "Search your shows")
        .onChange(of: search) { _, value in runEpisodeSearch(value) }
        .refreshable { await refresh() }
        .navigationDestination(for: LibraryRoute.self) { destination(for: $0) }
        .navigationDestination(item: $pushedShow) { destination(for: $0) }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingAdd) { AddPodcastView() }
        .overlay(alignment: .top) { refreshBanner }
        .task { totals.refresh(context: context, force: true) }
        .onAppear { totals.refresh(context: context) }
    }

    // MARK: Sections

    @ViewBuilder
    private var collectionsSection: some View {
        if search.isEmpty {
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
                description: Text("Tap + to search for a show, or browse Discover."))
                .plainRow(top: 40, bottom: 40)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
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
        default:          return 0
        }
    }

    private var gridSection: some View {
        // The cover size and the column minimum are the same number on
        // purpose. They were 112 and 150, so on an iPad every cover sat in a
        // 200pt column with 90pt of dead space beside it and the shelf looked
        // half-built.
        LazyVGrid(columns: AdaptiveGrid.columns(compactMinimum: Metrics.artTile,
                                                regularMinimum: Metrics.artTileWide,
                                                isRegular: isRegular),
                  spacing: 16) {
            ForEach(shows) { podcast in
                // A Button, not a NavigationLink. A List draws its own
                // disclosure chevron beside every link it can see, including
                // ones nested in a grid inside a row — so on iPad each cover
                // had a stray ">" floating to the right of it. buttonStyle
                // does not suppress that; not being a link does.
                Button {
                    pushedShow = LibraryRoute.show(podcast.persistentModelID)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        ZStack(alignment: .topTrailing) {
                            Artwork(url: podcast.artworkURL,
                                    size: isRegular ? Metrics.artTileWide : Metrics.artTile)
                            if podcast.unplayedCount > 0 {
                                Text("\(podcast.unplayedCount)")
                                    .font(.footnote.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Theme.accentGradient))
                                    .foregroundStyle(.black)
                                    .padding(5)
                            }
                        }
                        Text(podcast.title).font(.system(size: Metrics.bodySize, weight: .medium))
                            .lineLimit(2).foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(podcast.title)
            }
        }
        .plainRow(top: 4, bottom: 4)
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

// MARK: - Rows

struct CollectionRow: View {
    let route: LibraryRoute
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: route.symbol)
                .font(.system(size: 17))
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
                    if podcast.unplayedCount > 0 {
                        Text("\(podcast.unplayedCount) new")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.accentHot)
                    }
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
                    if isCurrent { player.togglePlayPause() } else { player.load(episode) }
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
    }
}

// MARK: - Episode collections

struct EpisodeCollectionView: View {
    enum Kind { case downloaded, starred, latest }

    let title: String
    let kind: Kind

    @Environment(\.modelContext) private var context
    /// Fetched once when the screen appears rather than by loading the whole
    /// store into a `@Query` and filtering it on every render.
    @State private var episodes: [Episode] = []
    /// Stops "Nothing here yet" flashing up for a frame before the first fetch
    /// lands.
    @State private var hasLoaded = false

    private func reload() {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        )
        let base = (try? context.fetch(descriptor)) ?? []
        switch kind {
        case .downloaded: episodes = base.filter(\.isDownloaded)
        case .starred:    episodes = base.filter(\.isStarred)
        case .latest:     episodes = base.filter { !$0.isPlayed }
        }
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
                                    episode.isInQueue = true
                                    episode.queueOrder = 0
                                    try? context.save()
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

struct ShowDetailView: View {
    let podcast: Podcast
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(AppSettings.self) private var settings
    @State private var player = PlayerEngine.shared
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var showingSettings = false
    @State private var showingPublish = false
    @State private var similar: [PodcastSearchResult] = []
    @State private var summaryExpanded = false
    @State private var scrollOffset: CGFloat = 0

    /// How tall the tinted area is before it has been scrolled at all.
    private static let backdropHeight: CGFloat = 554
    /// Where the header is considered gone and the bar takes over.
    private static let collapsePoint: CGFloat = 260

    private var headerCollapsed: Bool { scrollOffset > Self.collapsePoint }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All Episodes", unplayed = "Unplayed", played = "Played"
        case downloaded = "Downloaded", ready = "Ad-free"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .all:        return "list.bullet"
            case .unplayed:   return "circle"
            case .played:     return "checkmark.circle"
            case .downloaded: return "arrow.down.circle"
            case .ready:      return "wand.and.sparkles"
            }
        }
    }

    private var episodes: [Episode] {
        var list = podcast.sortedEpisodes.filter { !$0.isArchived }
        switch filter {
        case .all:        break
        case .unplayed:   list = list.filter { !$0.isPlayed }
        case .played:     list = list.filter { $0.isPlayed }
        case .downloaded: list = list.filter { $0.isDownloaded }
        case .ready:      list = list.filter { $0.processingState == .ready }
        }
        if !search.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(search) }
        }
        return list
    }

    var body: some View {
        List {
            header
            filterBar
            episodeList
            similarSection
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
            ArtworkBackdrop(url: podcast.artworkURL, variant: .header)
                .frame(height: Self.backdropHeight)
                .offset(y: -min(scrollOffset, Self.backdropHeight))
                .opacity(1 - min(1, max(0, scrollOffset) / Self.collapsePoint))
                .ignoresSafeArea(edges: .top)
        }
        .background(Theme.background.ignoresSafeArea())
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            scrollOffset = offset
        }
        // Hard at the top, always. Soft turned out to be no barrier at all:
        // episode rows slid up behind the bar and were legible across the
        // back button, and the description bled over the status bar. Hard is
        // a real material, and over the artwork it reads the way the Podcasts
        // app's own header does.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .environment(\.defaultMinListRowHeight, 44)
        // The title belongs to the header until the header is gone, the way
        // the Podcasts app does it. Leaving it in the bar the whole time meant
        // the show name was on screen twice.
        .navigationTitle(headerCollapsed ? podcast.title : "")
        .navigationBarTitleDisplayMode(.inline)
        // Without this the bar is transparent at every scroll position and the
        // episode rows slide up behind it as unreadable ghosts. Visible once
        // the artwork is gone gives them a material to disappear into.
        .toolbarBackgroundVisibility(headerCollapsed ? .visible : .hidden,
                                     for: .navigationBar)
        .animation(.easeOut(duration: 0.2), value: headerCollapsed)
        .searchable(text: $search, prompt: "Search episodes")
        .searchToolbarBehavior(.minimize)
        .toolbar { toolbarContent }
        .navigationDestination(isPresented: $showingPublish) {
            PublishShowView(podcast: podcast)
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { ShowSettingsView(podcast: podcast) }
        }
        .task {
            similar = (try? await DiscoverService.related(to: podcast, limit: 12)) ?? []
        }
    }

    /// A single percentage in the navigation bar, for when the episode being
    /// processed isn't one of the rows on screen. It sits in the toolbar so
    /// nothing in the content moves when it appears or goes away.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if pipeline.isRunning && !episodes.contains(where: { pipeline.isProcessing($0) }) {
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
            summary
        }
        .frame(maxWidth: .infinity)
        .readableWidth(520)
        .padding(.bottom, 6)
        .plainRow(top: 2, bottom: 4)
    }

    private var statsLine: some View {
        HStack(spacing: 6) {
            Text("\(podcast.episodes.count) episodes")
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
                    title: podcast.publishedFeedURL == nil ? "Publish" : "Feed",
                    symbol: "dot.radiowaves.up.forward"
                ) {
                    showingPublish = true
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
                ForEach(Filter.allCases) { option in
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
        } trailing: {
            Text("\(episodes.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .plainRow(top: 14, bottom: 4)
    }

    // MARK: Episodes

    @ViewBuilder
    private var episodeList: some View {
        ForEach(episodes) { episode in
            EpisodeRow(episode: episode)
                .contentRow()
                .swipeActions(edge: .trailing) { rowTrailing(episode) }
                .swipeActions(edge: .leading) { rowLeading(episode) }
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
            episode.isInQueue = true
            episode.queueOrder = 0
            try? context.save()
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
        if let next = nextUpEpisode { player.load(next) }
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

// MARK: - Episode row

struct EpisodeRow: View {
    let episode: Episode
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @State private var player = PlayerEngine.shared
    @State private var expanded = false

    private var isCurrent: Bool { player.currentEpisode?.guid == episode.guid }
    private var isProcessing: Bool { pipeline.isProcessing(episode) }

    var body: some View {
        // Cover on the right, the way the Podcasts app does it on a show page.
        // In a cross-show list the artwork leads, because it identifies the
        // show; here the show is already the page you are on, so it trails and
        // the title gets the left edge.
        HStack(alignment: .top, spacing: Metrics.rowTextGap) {
            VStack(alignment: .leading, spacing: 7) {
                metaLine
                title
                notes
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
            .frame(maxWidth: .infinity, alignment: .leading)

            Artwork(url: episode.artworkURL ?? episode.podcast?.artworkURL,
                    size: Metrics.artRow)
        }
        .animation(.snappy(duration: 0.25), value: isProcessing)
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            Text(episode.publishedAt, format: .dateTime.month(.abbreviated).day())
            if !episode.numberLabel.isEmpty {
                Text("·")
                Text(episode.numberLabel).foregroundStyle(Theme.accentWarm)
            }
            if episode.isVideo {
                // Worth flagging before you start it. A video episode is a
                // much bigger download, and it behaves differently: no Smart
                // Speed, no equaliser, and a picture you may not want.
                Text("·")
                Label("Video", systemImage: "play.rectangle")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Theme.accentWarm)
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

    private var actionRow: some View {
        HStack(spacing: 8) {
            EpisodePlayPill(isPlaying: isCurrent && player.isPlaying,
                            progress: episode.progressFraction,
                            timeLabel: timeLabel) {
                if isCurrent {
                    player.togglePlayPause()
                } else {
                    player.load(episode)
                }
            }

            if episode.processingState != .ready && !isProcessing {
                findAdsButton
            }

            Spacer(minLength: 0)
            overflowMenu
        }
        .padding(.top, 1)
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
            episode.isInQueue = true
            try? context.save()
            Task { await pipeline.process(episode) }
        } label: {
            Label("Find Ads", systemImage: "wand.and.sparkles")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.09)))
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.8))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(pipeline.isRunning)
        .opacity(pipeline.isRunning ? 0.45 : 1)
    }

    private var overflowMenu: some View {
        Menu {
            Button(episode.isStarred ? "Unstar" : "Star", systemImage: "star") {
                episode.isStarred.toggle()
                try? context.save()
                LibraryTotals.shared.invalidate()
            }
            Button(episode.isPlayed ? "Mark Unplayed" : "Mark Played",
                   systemImage: "checkmark.circle") {
                episode.isPlayed.toggle()
                try? context.save()
                CountsCache.invalidate(episode.podcast)
                LibraryTotals.shared.invalidate()
            }
            Button(episode.isInQueue ? "Remove from Up Next" : "Play Next",
                   systemImage: "text.append") {
                episode.isInQueue.toggle()
                episode.queueOrder = 0
                try? context.save()
            }
            if !episode.timedTranscript.isEmpty {
                Divider()
                NavigationLink("Transcript") { TranscriptView(episode: episode) }
            }
            if !episode.chapters.isEmpty {
                NavigationLink("Chapters") { ChapterListView(episode: episode) }
            }
            if episode.processingState == .ready {
                Divider()
                Button("Find Ads Again", systemImage: "arrow.clockwise") {
                    Task { await pipeline.process(episode) }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            Toggle("Download Automatically", isOn: $podcast.autoDownloadNew).contentRow()
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
        }
    }
}
