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

    @State private var showingAdd = false
    @State private var search = ""
    @State private var sort: Sort = .recent
    @State private var showArchived = false
    @State private var useGrid = false
    @State private var refreshNote: String?

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
            Color.clear.frame(height: 70).plainRow(top: 0, bottom: 0)
        }
        .listStyle(.plain)
        .navigationTitle("Library")
        .amoledScreen()
        .processingBanner(pipeline)
        .searchable(text: $search, prompt: "Search your shows")
        .onChange(of: search) { _, value in runEpisodeSearch(value) }
        .refreshable { await refresh() }
        .navigationDestination(for: LibraryRoute.self) { destination(for: $0) }
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
                Toggle("Grid layout", isOn: $useGrid)
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
            Text(refreshNote).font(.caption)
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 14)], spacing: 16) {
            ForEach(shows) { podcast in
                NavigationLink(value: LibraryRoute.show(podcast.persistentModelID)) {
                    VStack(alignment: .leading, spacing: 6) {
                        ZStack(alignment: .topTrailing) {
                            Artwork(url: podcast.artworkURL, size: 104, corner: 14)
                            if podcast.unplayedCount > 0 {
                                Text("\(podcast.unplayedCount)")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Theme.accentGradient))
                                    .foregroundStyle(.black)
                                    .padding(5)
                            }
                        }
                        Text(podcast.title).font(.caption.weight(.medium))
                            .lineLimit(2).foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain)
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
            Text(route.title).font(.body)
            Spacer(minLength: 0)
            if count > 0 {
                Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

struct ShowRow: View {
    let podcast: Podcast

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: podcast.artworkURL, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(podcast.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(podcast.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    if podcast.unplayedCount > 0 {
                        Text("\(podcast.unplayedCount) new")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.accentHot)
                    }
                    if podcast.priority == 1 {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.caption2).foregroundStyle(Theme.accentWarm)
                    }
                    if podcast.publishedFeedURL != nil {
                        Image(systemName: "dot.radiowaves.up.forward")
                            .font(.caption2).foregroundStyle(.green)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Compact episode row used in collections and search results.
struct EpisodeCompactRow: View {
    let episode: Episode
    @State private var player = PlayerEngine.shared

    var body: some View {
        HStack(spacing: 11) {
            Artwork(url: episode.artworkURL ?? episode.podcast?.artworkURL, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(episode.podcast?.title ?? "")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(episode.title).font(.subheadline.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(formatMinutes(episode.remainingSeconds))
                    if episode.processingState == .ready {
                        Text("· Ad-free").foregroundStyle(.green)
                    }
                    if episode.isStarred {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { player.load(episode) } label: {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.8))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
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
                    Color.clear.frame(height: 70).plainRow(top: 0, bottom: 0)
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
    @State private var player = PlayerEngine.shared
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var showingSettings = false
    @State private var similar: [PodcastSearchResult] = []
    @State private var summaryExpanded = false

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", unplayed = "Unplayed", played = "Played"
        case downloaded = "Downloaded", ready = "Ad-free"
        var id: String { rawValue }
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
                .padding(.top, 6)
                .padding(.bottom, 10)
                .background(alignment: .top) { heroWash }
                .plainRow(top: 0, bottom: 2)

            FilterChips(options: Filter.allCases, label: { $0.rawValue }, selection: $filter)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))

            episodeList
            similarSection
            Color.clear.frame(height: 70).plainRow(top: 0, bottom: 0)
        }
        .listStyle(.plain)
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .processingBanner(pipeline)
        .searchable(text: $search, prompt: "Search episodes")
        .sheet(isPresented: $showingSettings) {
            NavigationStack { ShowSettingsView(podcast: podcast) }
        }
        .task {
            similar = (try? await DiscoverService.related(to: podcast, limit: 12)) ?? []
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 14) {
            Artwork(url: podcast.artworkURL, size: 168, corner: 22)
                .shadow(color: .black.opacity(0.55), radius: 22, y: 10)

            VStack(spacing: 4) {
                Text(podcast.title)
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Text(podcast.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                statsLine
            }
            .frame(maxWidth: .infinity)

            actionRow

            if !podcast.plainSummary.isEmpty {
                Text(podcast.plainSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(summaryExpanded ? nil : 3)
                    .multilineTextAlignment(.center)
                    .onTapGesture { withAnimation { summaryExpanded.toggle() } }
            }
        }
        .frame(maxWidth: .infinity)
        .readableWidth(520)
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
        .font(.caption)
        .foregroundStyle(.tertiary)
    }

    private var actionRow: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button { playLatest() } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(Theme.accentHot)

                NavigationLink {
                    PublishShowView(podcast: podcast)
                } label: {
                    Label(podcast.publishedFeedURL == nil ? "Publish" : "Feed",
                          systemImage: "dot.radiowaves.up.forward")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)

                Menu {
                    Button("Mark All Played", systemImage: "checkmark.circle") { markAllPlayed() }
                    Button("Queue Unplayed", systemImage: "text.append") { queueUnplayed() }
                    if let feed = podcast.publishedFeedURL {
                        Button("Copy Feed Address", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = feed
                            Haptics.success()
                        }
                    }
                    Divider()
                    Button("Show Settings", systemImage: "slider.horizontal.3") {
                        showingSettings = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
            }
        }
    }

    /// The show's own artwork, enlarged, blurred and faded out behind the
    /// header — so the glass controls above it have something to refract.
    private var heroWash: some View {
        Artwork(url: podcast.artworkURL, size: 420, corner: 0)
            .scaleEffect(1.6)
            .blur(radius: 60, opaque: false)
            .opacity(0.30)
            .frame(maxWidth: .infinity)
            .frame(height: 230, alignment: .top)
            .clipped()
            .mask(
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.45), location: 0.6),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            )
            .allowsHitTesting(false)
    }

    // MARK: Episodes

    private var episodeList: some View {
        ForEach(episodes) { episode in
            EpisodeRow(episode: episode)
                .contentRow()
                .swipeActions(edge: .trailing) { rowTrailing(episode) }
                .swipeActions(edge: .leading) { rowLeading(episode) }
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(similar) { show in
                    VStack(spacing: 6) {
                        Artwork(url: show.artworkURL, size: 104, corner: 16)
                        Text(show.title).font(.caption2).lineLimit(2)
                            .frame(width: 104).multilineTextAlignment(.center)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: Actions

    private func playLatest() {
        let next = episodes.first { !$0.isPlayed && $0.isDownloaded }
            ?? episodes.first { !$0.isPlayed }
            ?? episodes.first
        if let next { player.load(next) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            metaLine
            Text(episode.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(3)
                .foregroundStyle(episode.isPlayed ? .secondary : .primary)
            notes
            progressBar
            actionRow
            errorLine
        }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            if !episode.numberLabel.isEmpty {
                Text(episode.numberLabel).foregroundStyle(Theme.accentWarm)
                Text("·")
            }
            Text(episode.publishedAt, format: .dateTime.month(.abbreviated).day())
                .textCase(.uppercase)
            Spacer(minLength: 0)
            if episode.isDownloaded {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tertiary)
            }
            if episode.isStarred {
                Image(systemName: "star.fill").foregroundStyle(.yellow)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var notes: some View {
        if !episode.plainDescription.isEmpty {
            Text(episode.plainDescription)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 2)
                .onTapGesture { withAnimation { expanded.toggle() } }
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if episode.progressFraction > 0.01 && !episode.isPlayed {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(Theme.accentGradient)
                        .frame(width: max(3, geo.size.width * episode.progressFraction))
                }
            }
            .frame(height: 3)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            playButton
            if episode.processingState != .ready { findAdsButton }
            Spacer(minLength: 0)
            Text(trailingLabel)
                .font(.caption2)
                .foregroundStyle(episode.processingState == .ready ? .green : .secondary)
            overflowMenu
        }
    }

    private var trailingLabel: String {
        if episode.processingState == .ready { return episode.stateSummary }
        return episode.duration > 0 ? "\(Int(episode.duration / 60))m" : ""
    }

    private var playButton: some View {
        Button { player.load(episode) } label: {
            Label(episode.playbackPosition > 5 ? "Resume" : "Play", systemImage: "play.fill")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
    }

    private var findAdsButton: some View {
        Button {
            episode.isInQueue = true
            try? context.save()
            Task { await pipeline.process(episode) }
        } label: {
            Label("Find Ads", systemImage: "wand.and.sparkles")
                .contentChip()
        }
        .buttonStyle(.plain)
        .disabled(pipeline.isRunning)
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
            if !episode.timedTranscript.isEmpty {
                NavigationLink("Transcript") { TranscriptView(episode: episode) }
            }
            if !episode.chapters.isEmpty {
                NavigationLink("Chapters") { ChapterListView(episode: episode) }
            }
            if episode.processingState == .ready {
                Button("Re-process", systemImage: "arrow.clockwise") {
                    Task { await pipeline.process(episode) }
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.caption).padding(7)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var errorLine: some View {
        if let error = episode.processingError {
            Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
        }
    }
}

// MARK: - Per-show settings

struct ShowSettingsView: View {
    @Bindable var podcast: Podcast
    @Environment(\.dismiss) private var dismiss

    private let speeds: [Double] = [0.8, 1.0, 1.2, 1.5, 1.8, 2.0, 2.5]

    var body: some View {
        List {
            headerCard.plainRow(top: 10, bottom: 6)
            playbackSection
            newEpisodesSection
            episodesSection
            Color.clear.frame(height: 60).plainRow(top: 0, bottom: 0)
        }
        .listStyle(.plain)
        .navigationTitle("Show Settings")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .toolbar {
            Button("Done") { dismiss() }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
        }
    }

    private var headerCard: some View {
        HStack(spacing: 12) {
            Artwork(url: podcast.artworkURL, size: 54, corner: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(podcast.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(podcast.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .glassPanel(cornerRadius: 18)
    }

    @ViewBuilder
    private var playbackSection: some View {
        Group {
            SectionHeader("Playback")

            Picker("Speed", selection: Binding(
                get: { podcast.playbackSpeedOverride ?? 0 },
                set: { podcast.playbackSpeedOverride = $0 == 0 ? nil : $0 }
            )) {
                Text("Use Default").tag(0.0)
                ForEach(speeds, id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
            }
            .contentRow()

            Stepper("Skip intro: \(Int(podcast.skipIntroSeconds))s",
                    value: $podcast.skipIntroSeconds, in: 0...300, step: 5)
                .contentRow()

            Stepper("Skip outro: \(Int(podcast.skipOutroSeconds))s",
                    value: $podcast.skipOutroSeconds, in: 0...300, step: 5)
                .contentRow()

            Picker("Skip Ads", selection: Binding(
                get: { podcast.autoSkipEnabled ?? true },
                set: { podcast.autoSkipEnabled = $0 }
            )) {
                Text("On").tag(true)
                Text("Off").tag(false)
            }
            .contentRow()
        }
    }

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
                .font(.caption).foregroundStyle(.secondary)
                .contentRow()
        }
    }

    @ViewBuilder
    private var episodesSection: some View {
        Group {
            SectionHeader("Episodes")
            Toggle("Newest First", isOn: $podcast.newestFirst).contentRow()
            Toggle("Archived", isOn: $podcast.isArchived).contentRow()
        }
    }
}
