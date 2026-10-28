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
    /// Finding ads: the job running, the line, what's finished (pass 20).
    case activity
    /// What the Publish tab was: every show's ad-free feed, from the Library.
    case feeds
    case show(PersistentIdentifier)

    var title: String {
        switch self {
        case .playlists:  return "Stations"
        case .bookmarks:  return "Bookmarks"
        case .stats:      return "Statistics"
        case .downloaded: return "Downloaded"
        case .starred:    return "Saved"
        case .latest:     return "Latest Episodes"
        case .recent:     return "Recently Played"
        case .feeds:      return "Ad-Free Feeds"
        case .activity:   return "Activity"
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
        case .activity:   return "wand.and.sparkles"
        case .show:       return "mic.fill"
        }
    }

    /// Pass 35: a stable name for each collection, for the Library's
    /// show/hide and order setting.
    var key: String? {
        switch self {
        case .playlists: "stations"; case .bookmarks: "bookmarks"; case .stats: "stats"
        case .downloaded: "downloaded"; case .starred: "starred"; case .latest: "latest"
        case .recent: "recent"; case .feeds: "feeds"; case .activity: "activity"; case .show: nil
        }
    }

    static let collections: [LibraryRoute] = [.playlists, .latest, .recent, .downloaded, .starred,
                                              .bookmarks, .activity, .feeds, .stats]

    var tint: Color {
        switch self {
        case .playlists:  return Theme.accentHot
        case .bookmarks:  return Theme.accentWarm
        case .stats:      return .green
        case .downloaded: return .blue
        case .starred:    return Theme.accentHot
        case .latest:     return .purple
        case .recent:     return .teal
        case .feeds:      return .green
        case .activity:   return .orange
        case .show:       return .gray
        }
    }
}

// MARK: - Library

struct LibraryView: View {
    /// Pass 40: fetched when shows are added or removed, not on every save
    /// (`@Query` re-read every show on every save, even with this page
    /// hidden under another — see `StoreChanges`). Each show's own fields
    /// still update through observation.
    @State private var podcasts: [Podcast] = []
    @State private var podcastsLoaded = false
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(AppSettings.self) private var settings
    @Environment(\.pushLibraryRoute) private var pushLibraryRoute

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
    /// Pass 48: a station made from the Library's ⋯, open in its editor.
    @State private var newStation: SmartFilter?
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
        /// Apple's own wording (`SORT_BY_UPDATED`) — by the newest episode,
        /// not by when you followed the show.
        case updated = "Recently Updated"
        var id: String { rawValue }
    }

    private var shows: [Podcast] {
        var list = podcasts.filter { $0.isLive && (showArchived || !$0.isArchived) }
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
        case .updated:  return list.sorted { ($0.lastUpdatedAt ?? .distantPast) > ($1.lastUpdatedAt ?? .distantPast) }
        }
    }

    /// Pass 35 (his request, as Apple Podcasts' Library → Edit): which
    /// collections show, in his order. Stored as keys so a collection added
    /// in a later version appears (shown, at the end) without resetting his.
    @AppStorage("libraryCollectionOrder") private var orderRaw = ""
    @AppStorage("libraryCollectionHidden") private var hiddenRaw = ""
    @State private var editingCollections = false
    @State private var collectionsEditMode: EditMode = .inactive

    private var orderedCollections: [LibraryRoute] {
        let saved = orderRaw.split(separator: ",").compactMap { key in
            LibraryRoute.collections.first { $0.key == String(key) }
        }
        return saved + LibraryRoute.collections.filter { !saved.contains($0) }
    }
    private var hiddenKeys: Set<String> { Set(hiddenRaw.split(separator: ",").map(String.init)) }

    private var collections: [LibraryRoute] {
        orderedCollections.filter { !hiddenKeys.contains($0.key ?? "") }
    }

    private func toggleHidden(_ route: LibraryRoute) {
        guard let key = route.key else { return }
        var hidden = hiddenKeys
        if hidden.contains(key) { hidden.remove(key) } else { hidden.insert(key) }
        hiddenRaw = hidden.sorted().joined(separator: ",")
        Haptics.select()
    }

    private func moveCollections(_ from: IndexSet, _ to: Int) {
        var order = orderedCollections
        order.move(fromOffsets: from, toOffset: to)
        orderRaw = order.compactMap(\.key).joined(separator: ",")
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
        // Sorted and filtered once per render and handed down. It used to be a
        // computed property read three times per body (the count, the grid, the
        // empty state), each time sorting the whole library.
        let shows = self.shows
        return List {
            if editingCollections {
                editCollectionsSection
            } else {
                collectionsSection(shows)
                episodeResultsSection
                showsSection(shows)
                emptyState(shows)
            }
            BottomClearance()
        }
        .listStyle(.plain)
        .environment(\.editMode, $collectionsEditMode)
        .onChange(of: editingCollections) { _, editing in collectionsEditMode = editing ? .active : .inactive }
        .navigationTitle("Library")
        // Pass 48: as Apple's tab roots — the large title on the bar's line.
        .toolbarTitleDisplayMode(.inlineLarge)
        .amoledScreen()
        // Pinned, like the show page: the activity bar stays in view while
        // anything is being worked on, and goes when it's done.
        //
        // Pass 35 had made it the list's first row because, pinned, it sat
        // where the search field slides down from under the title: the two
        // overlapped and revealing the field moved the bar mid-scroll. Pass
        // 39 (his 15 Oct: it scrolled away): pinned again, and search is the
        // toolbar's search button as on the show page, so nothing slides in
        // above the bar and nothing under it jumps.
        .processingBanner(pipeline, publisher: FeedPublisher.shared)
        .searchable(text: $search, prompt: "Search your shows")
        .searchToolbarBehavior(.minimize)
        .onChange(of: search) { _, value in runEpisodeSearch(value) }
        .refreshable {
            await refresh()
            Feel.selection.play()
        }
        .navigationDestination(for: LibraryRoute.self) { destination(for: $0) }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingAdd) { AddPodcastView().glassSheet() }
        .sheet(item: $newStation) { station in
            NavigationStack { FilterEditor(filter: station) }.glassSheet()
        }
        .overlay(alignment: .top) { refreshBanner }
        .task { if !podcastsLoaded { loadPodcasts() } }
        // Not debounced, so a deleted show is gone by the next frame; until
        // then `shows` leaves out anything deleted.
        .onReceive(StoreChanges.saves(in: context.container)) { change in
            if change.changesShowList { loadPodcasts() }
        }
    }

    private func loadPodcasts() {
        podcasts = (try? context.fetch(FetchDescriptor<Podcast>(sortBy: [SortDescriptor(\.dateAdded, order: .reverse)]))) ?? []
        podcastsLoaded = true
    }

    // MARK: Sections

    @ViewBuilder
    private func collectionsSection(_ shows: [Podcast]) -> some View {
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
                EpisodeListRow(episode: episode)
            }
            SectionHeader("Shows")
        }
    }

    @ViewBuilder
    private func showsSection(_ shows: [Podcast]) -> some View {
        if useGrid && search.isEmpty {
            gridSection(shows)
        } else {
            ForEach(shows) { podcast in
                NavigationLink(value: LibraryRoute.show(podcast.persistentModelID)) {
                    ShowRow(podcast: podcast)
                }
                .rowScrollTransition()
                .contentRow()
                .swipeActions(edge: .trailing) { trailingActions(podcast) }
                .swipeActions(edge: .leading) { leadingActions(podcast) }
            }
        }
    }

    @ViewBuilder
    private func trailingActions(_ podcast: Podcast) -> some View {
        Button(role: .destructive) {
            Feel.warning.play()
            context.delete(podcast); try? context.save()
        } label: { Label("Delete", systemImage: "trash") }

        Button {
            Feel.confirm.play()
            podcast.isArchived.toggle(); try? context.save()
        } label: {
            Label(podcast.isArchived ? "Restore" : "Archive", systemImage: "archivebox")
        }
        .tint(.indigo)
    }

    @ViewBuilder
    private func leadingActions(_ podcast: Podcast) -> some View {
        Button {
            Feel.confirm.play()
            podcast.priority = podcast.priority == 1 ? 0 : 1
            try? context.save()
        } label: { Label("Priority", systemImage: "arrow.up.circle") }
        .tint(Theme.accentWarm)
    }

    @ViewBuilder
    private func emptyState(_ shows: [Podcast]) -> some View {
        if podcastsLoaded && shows.isEmpty && search.isEmpty {
            // Pass 37: Apple Podcasts' own empty Library wording.
            ContentUnavailableView("Start Your Library",
                systemImage: "square.stack",
                description: Text("Followed shows, saved episodes and stations will show up here. Tap + to search for a show, or look in New."))
                .plainRow(top: 40, bottom: 40)
        }
    }

    /// Every collection, ticked if shown, with a handle to reorder — Apple
    /// Podcasts' Library editor.
    @ViewBuilder
    private var editCollectionsSection: some View {
        ForEach(orderedCollections, id: \.self) { route in
            let shown = !hiddenKeys.contains(route.key ?? "")
            Button { toggleHidden(route) } label: {
                HStack(spacing: 14) {
                    Image(systemName: shown ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(shown ? Theme.accentHot : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                    Image(systemName: route.symbol)
                        .foregroundStyle(route.tint)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    Text(route.title).foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(shown ? [.isSelected] : [])
            .accessibilityHint(shown ? "Shown in Library. Tap to hide." : "Hidden. Tap to show.")
            .accessibilityIdentifier("library.edit.\(route.key ?? "")")
            .contentRow()
        }
        .onMove(perform: moveCollections)
        Text("Ticked collections appear in your Library. Drag to change the order.")
            .font(.footnote).foregroundStyle(.secondary)
            .plainRow(top: 8, bottom: 8)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if editingCollections {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done", systemImage: "checkmark", role: .confirm) {
                    withAnimation(.snappy) { editingCollections = false }
                }
                .accessibilityIdentifier("library.edit.done")
            }
        } else {
        // Pass 48: one ⋯ menu, as Apple's Library (iOS 27 guide: "Tap
        // Library, then tap More → New Station"; 27.2 strings Edit Library,
        // New Station, Follow a Show by URL…). It used to be a filter icon
        // and a bare "+" side by side in one capsule.
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Edit Library", systemImage: "checklist") {
                    search = ""
                    withAnimation(.snappy) { editingCollections = true }
                }
                .accessibilityIdentifier("library.edit")
                Button("New Station", systemImage: "square.stack.3d.up", action: createStation)
                    .accessibilityIdentifier("library.newStation")
                Button("Follow a Show…", systemImage: "plus") { showingAdd = true }
                    .accessibilityIdentifier("library.follow")
                Divider()
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
                PageMenuLabel(title: "Library Options")
            }
            .accessibilityIdentifier("library.menu")
            .feel(.selection, trigger: sortRaw)
            .feel(.toggle, trigger: showArchived)
            .feel(.toggle, trigger: useGrid)
            // Menu checkmarks, not the app's switch style.
            .toggleStyle(.automatic)
        }
        }
    }

    /// Pass 48: as the Stations page's Create Station — made, then edited.
    private func createStation() {
        let count = (try? context.fetchCount(FetchDescriptor<SmartFilter>())) ?? 0
        let station = SmartFilter(name: "New Station", order: count)
        context.insert(station)
        try? context.save()
        newStation = station
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
        case .starred:    EpisodeCollectionView(title: "Saved", kind: .starred)
        case .latest:     EpisodeCollectionView(title: "Latest Episodes", kind: .latest)
        case .recent:     EpisodeCollectionView(title: "Recently Played", kind: .recent)
        case .feeds:      PublishView()
        case .activity:   ActivityView()
        case .show(let id):
            if let podcast = podcasts.first(where: { $0.persistentModelID == id }) ?? (context.model(for: id) as? Podcast) {
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
        case .bookmarks:  return totals.bookmarks
        default:          return 0
        }
    }

    private func gridSection(_ shows: [Podcast]) -> some View {
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
                    // A link on the stack's own path. It was a Button setting
                    // a `navigationDestination(item:)`, to dodge the chevron
                    // a List draws beside every link — but a screen pushed
                    // that way is not on the path, and an episode tapped on
                    // it (pass 18: every row opens its episode) replaced the
                    // show page instead of stacking on it. The chevron is
                    // hidden directly now.
                    // A button that pushes onto the tab's path, not a
                    // NavigationLink: two links in one list row both fire on
                    // a tap, so tapping the left cover opened the right show
                    // on top of it (his report, pass 20). The page still goes
                    // on the stack's path, which is what its own links need.
                    Button {
                        pushLibraryRoute(.show(podcast.persistentModelID))
                    } label: {
                        ShowTile(podcast: podcast, side: side)
                    }
                    .buttonStyle(.borderless)
                    .tint(.primary)
                    .accessibilityLabel(podcast.title)
                    .accessibilityValue(podcast.freshnessLine)
                    .accessibilityIdentifier("ShowTile")
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
                .overlay(alignment: .topTrailing) { NewCountBadge(count: podcast.newCount).padding(6) }
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
                    .foregroundStyle(podcast.newCount > 0 ? Theme.accentHot : .secondary)
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
                                      weight: podcast.newCount > 0 ? .semibold : .regular))
                        .foregroundStyle(podcast.newCount > 0 ? Theme.accentHot : .secondary)
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
            NewCountBadge(count: podcast.newCount)
        }
    }
}

/// Everything you can do to one episode — the one list behind its row ⋯,
/// touch-and-hold on its row, the episode page ⋯ and the player ⋯ (his rule,
/// 15–23 Sep: one set of episode actions, offered the same way everywhere).
///
/// The player is a sheet with no navigation of its own, so there pages open
/// through `PlayerHooks` (its own sheets) or, for the show and the episode
/// page, by closing the player and opening them in the tab behind it.
struct EpisodeMenuItems: View {
    let episode: Episode
    var onSelect: (() -> Void)? = nil
    /// On a show page: opens that page's publishing view with this episode
    /// ticked — the same view as the Publish button beside Play.
    var onPublish: (() -> Void)? = nil
    /// Off on the episode's own page.
    var offersDetails = true
    /// Set by the player's ⋯ menu.
    var player: PlayerHooks? = nil

    struct PlayerHooks {
        var shareFromHere: () -> Void
        var whatWasSkipped: () -> Void
        var chapters: () -> Void
    }

    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(AppSettings.self) private var settings
    /// Apple's link to this exact episode, looked up once the menu is
    /// actually built rather than for every row in a list — `Menu` and
    /// `contextMenu` only build their content on demand. `nil` until it
    /// resolves, or forever when the directory doesn't list the show.
    @State private var appleLink: URL?

    private var shareURL: URL? { appleLink ?? URL(string: episode.audioURL) }
    private var isCurrent: Bool { PlayerEngine.shared.currentEpisode?.guid == episode.guid }

    var body: some View {
        Group { menuItems }
            .task(id: episode.guid) { appleLink = await EpisodeLink.apple(for: episode, at: 0) }
    }

    @ViewBuilder
    private var menuItems: some View {
        // Play — everywhere but the player, which is the play button.
        if player == nil {
            // Not the saved position: it changes while the episode plays, and a
            // menu that reads a changing value is rebuilt under the finger.
            let playing = isCurrent && PlayerEngine.shared.isPlaying
            Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") {
                if isCurrent { PlayerEngine.shared.togglePlayPause() }
                else { PlayCoordinator.play(episode, settings: settings, pipeline: pipeline) }
            }
        }
        // Pass 43 (his 19 Oct request): Select near the top, not last.
        if let onSelect {
            Button("Select", systemImage: "checkmark.circle") { onSelect() }
        }

        // Finding ads, and what was found.
        Section {
            findAdsItem
            if episode.processingState == .ready || !episode.adSegments.isEmpty {
                if let player {
                    Button("What Was Skipped", systemImage: "list.bullet.rectangle") { player.whatWasSkipped() }
                } else {
                    NavigationLink { SkipReportView(episode: episode) } label: {
                        Label("What Was Skipped", systemImage: "list.bullet.rectangle")
                    }
                }
            }
        }

        // Up Next — not for the episode that is playing.
        if !(player != nil && isCurrent) {
            if episode.isInQueue {
                Button("Remove from Up Next", systemImage: "minus.circle") {
                    episode.removeFromUpNext(context: context)
                }
            } else {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    episode.addToUpNext(next: true, context: context)
                    Haptics.success()
                }
                Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    episode.addToUpNext(next: false, context: context)
                    Haptics.success()
                }
            }
        }

        Section {
            // Pass 37 (Apple Podcasts parity): "Save Episode" / "Unsave",
            // shown in Library → Saved, as Apple's app names it. Same flag.
            Button(episode.isStarred ? "Unsave" : "Save Episode",
                   systemImage: episode.isStarred ? "star.slash" : "star") {
                episode.isStarred.toggle()
                try? context.save()
                LibraryTotals.shared.invalidate()
                Haptics.toggle(on: episode.isStarred)
            }
            Button(episode.isPlayed ? "Mark as Unplayed" : "Mark as Played",
                   systemImage: episode.isPlayed ? "circle" : "checkmark.circle") {
                episode.isPlayed.toggle()
                if episode.isPlayed { episode.isInQueue = false }
                try? context.save()
                CountsCache.invalidate(episode.podcast)
                LibraryTotals.shared.invalidate()
            }
            if episode.isDownloaded {
                // The file playing now stays.
                if !isCurrent {
                    Button("Remove Download", systemImage: "trash") {
                        Feel.warning.play()
                        DownloadManager.remove(episode)
                        try? context.save()
                        LibraryTotals.shared.invalidate()
                    }
                }
            } else {
                Button("Download", systemImage: "arrow.down.circle") {
                    Feel.confirm.play()
                    Task {
                        _ = await DownloadManager.fetchAudio(for: episode)
                        try? context.save()
                        LibraryTotals.shared.invalidate()
                    }
                }
            }
        }

        // Transcript and chapters. The player shows its transcript itself.
        // Whether there is a transcript, not the transcript: decoding it here
        // ran for every row of every list each time the row was drawn.
        Section {
            if player == nil, episode.hasTranscript {
                NavigationLink { TranscriptView(episode: episode) } label: {
                    Label("Transcript", systemImage: "text.quote")
                }
            }
            if !episode.chapters.isEmpty {
                if let player {
                    Button("Chapters", systemImage: "list.bullet.indent") { player.chapters() }
                } else {
                    NavigationLink { ChapterListView(episode: episode) } label: {
                        Label("Chapters", systemImage: "list.bullet.indent")
                    }
                }
            }
        }

        // The ad-free feed, from the episode itself — the Publish tab is gone.
        Section {
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
        }

        Section {
            if let podcast = episode.podcast {
                if player != nil {
                    Button("Go to Show", systemImage: "list.bullet") {
                        AppRouter.shared.open(ShowRoute(podcast))
                    }
                } else {
                    NavigationLink(value: ShowRoute(podcast)) {
                        Label("Go to Show", systemImage: "list.bullet")
                    }
                }
            }
            if let shareURL {
                ShareLink(item: shareURL, subject: Text(episode.title)) {
                    Label("Share Episode…", systemImage: "square.and.arrow.up")
                }
            }
            if let player {
                Button("Share from Here…", systemImage: "clock.arrow.circlepath") { player.shareFromHere() }
            }
            if let shareURL {
                Button("Copy Link", systemImage: "link") {
                    UIPasteboard.general.string = shareURL.absoluteString
                    Haptics.select()
                }
            }
            if offersDetails {
                if player != nil {
                    Button("Episode Details", systemImage: "info.circle") {
                        AppRouter.shared.open(EpisodeRoute(episode))
                    }
                } else {
                    NavigationLink(value: EpisodeRoute(episode)) {
                        Label("Episode Details", systemImage: "info.circle")
                    }
                }
            }
        }
    }

    /// Find Ads, Find Ads Again, Resume or Restart — whichever applies now.
    @ViewBuilder
    private var findAdsItem: some View {
        if pipeline.isProcessing(episode) {
            if pipeline.stalledSince != nil {
                Button("Restart Finding Ads", systemImage: "arrow.clockwise") {
                    Task { await pipeline.restart(episode) }
                }
            }
            Button("Stop Finding Ads", systemImage: "stop.circle", role: .destructive) {
                pipeline.stopJob(episode)
            }
        } else if pipeline.isWaiting(episode.guid) {
            Button("Remove from Line", systemImage: "xmark.circle", role: .destructive) {
                pipeline.cancelWaiting(episode.guid)
            }
        } else if pipeline.isPaused(episode) {
            Button("Resume Finding Ads", systemImage: "play.circle") {
                Task { await pipeline.processNow(episode) }
            }
        } else if episode.processingState == .ready {
            Button("Find Ads Again", systemImage: "arrow.clockwise") {
                Task { await pipeline.processNow(episode) }
            }
        } else if !pipeline.isWaiting(episode.guid) {
            Button("Find Ads", systemImage: "wand.and.sparkles") {
                Task { await pipeline.processNow(episode) }
            }
        }
    }
}

// MARK: - Episode collections

struct EpisodeCollectionView: View {
    enum Kind {
        case downloaded, starred, latest, recent

        /// Each list asks the store for exactly its own episodes.
        ///
        /// All of these used to fetch every episode in the library — whole
        /// back catalogues, thousands of rows — and then filter in memory on
        /// the main thread, which is the pause before a collection opened.
        ///
        /// Pass 41: only the columns a row draws, with every row's cuts in
        /// one read (`EpisodeRowFetch`). Downloaded is where his found-ads
        /// episodes all are; a full read brought each one's transcript text.
        func descriptor() -> FetchDescriptor<Episode> {
            var descriptor: FetchDescriptor<Episode>
            switch self {
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
            descriptor.propertiesToFetch = EpisodeRowFetch.properties
            descriptor.relationshipKeyPathsForPrefetching = [\.adSegments, \.podcast]
            return descriptor
        }

        /// The fetch's own rule, for one episode already in memory.
        func belongs(_ episode: Episode) -> Bool {
            switch self {
            case .starred: return !episode.isArchived && episode.isStarred
            case .latest: return !episode.isArchived && !episode.isPlayed
            case .recent: return episode.lastPlayedAt != nil
            case .downloaded: return !episode.isArchived && episode.localFilename != nil && episode.isDownloaded
            }
        }

        /// Whether any of these episodes — changed by another context and
        /// not loaded on this one — now belongs on the page: one query for
        /// identifiers, not a re-read of the list. Until Pass 41 any such
        /// change re-read the whole page, and a back catalogue being merged
        /// changes existing episodes all the time (Pass 40's lab only added
        /// new ones). True when the store can't say.
        func anyBelong(_ ids: Set<PersistentIdentifier>, in context: ModelContext) -> Bool {
            guard !ids.isEmpty else { return false }
            let list = Array(ids)
            var descriptor: FetchDescriptor<Episode>
            switch self {
            case .starred:
                descriptor = FetchDescriptor(predicate: #Predicate { list.contains($0.persistentModelID) && !$0.isArchived && $0.isStarred })
            case .latest:
                descriptor = FetchDescriptor(predicate: #Predicate { list.contains($0.persistentModelID) && !$0.isArchived && !$0.isPlayed })
            case .recent:
                descriptor = FetchDescriptor(predicate: #Predicate { list.contains($0.persistentModelID) && $0.lastPlayedAt != nil })
            case .downloaded:
                descriptor = FetchDescriptor(predicate: #Predicate { list.contains($0.persistentModelID) && !$0.isArchived && $0.localFilename != nil })
            }
            descriptor.fetchLimit = 1
            guard let found = try? context.fetchIdentifiers(descriptor) else { return true }
            return !found.isEmpty
        }
    }

    let title: String
    let kind: Kind

    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(AppSettings.self) private var settings
    /// Fetched once when the screen appears rather than by loading the whole
    /// store into a `@Query` and filtering it on every render.
    @State private var episodes: [Episode] = []
    /// Stops the empty page flashing up for a frame before the first fetch
    /// lands.
    @State private var hasLoaded = false
    @State private var selecting = false
    @State private var selection: Set<PersistentIdentifier> = []
    @State private var confirmRemoveAll = false
    /// Pass 40: on screen (not under a page pushed on top of it); a save
    /// that matters while hidden marks it stale for when it shows again.
    @State private var onScreen = false
    @State private var stale = false
    @State private var pendingReload: Task<Void, Never>?
    @State private var drag = SelectionDrag()

    /// Pass 40 (his 15 Oct report: Downloaded slow to answer touches): since
    /// Pass 39 this page re-read the store after every save anywhere — with
    /// a back catalogue being indexed, several times a second, on the main
    /// thread, even under a page pushed on top. Now only a save that can
    /// change this list counts: one of its episodes changed or deleted; an
    /// episode changed that now belongs here; for Latest Episodes, any new
    /// episode. Pass 41: changes to episodes not loaded here are checked
    /// with one identifier query (`Kind.anyBelong`).
    private func matters(_ change: StoreChanges) -> Bool {
        if change.unknown { return true }
        let shown = Set(episodes.map(\.persistentModelID))
        let updated = change.of(Episode.self, change.updated)
        let deleted = change.of(Episode.self, change.deleted)
        if !shown.isDisjoint(with: updated) || !shown.isDisjoint(with: deleted) { return true }
        if kind == .latest, !change.of(Episode.self, change.inserted).isEmpty { return true }
        var unloaded: Set<PersistentIdentifier> = []
        for id in updated.subtracting(shown) {
            if let episode: Episode = context.registeredModel(for: id) {
                if kind.belongs(episode) { return true }
            } else {
                unloaded.insert(id)
            }
        }
        return kind.anyBelong(unloaded, in: context)
    }

    private func reload() {
        let started = Date()
        let found = (try? context.fetch(kind.descriptor())) ?? []
        episodes = kind == .downloaded ? found.filter(\.isDownloaded) : found
        selection.formIntersection(Set(episodes.map(\.persistentModelID)))
        hasLoaded = true
        SlowWork.note("\(title): read \(episodes.count) episodes", since: started)
    }

    /// Apple's own empty pages (27.2 b2 strings).
    private var empty: (title: String, image: String, message: String) {
        switch kind {
        case .starred: ("No Saved Episodes", "star", "Save episodes you want to listen to later, and they’ll show up here.")
        case .downloaded: ("No Downloaded Episodes", "arrow.down.circle", "Download episodes to listen offline, and they’ll show up here.")
        case .latest: ("No Latest Episodes", "clock", "The latest episodes from the shows you follow will appear here.")
        case .recent: ("Nothing Played Yet", "clock.arrow.circlepath", "Episodes you have listened to.")
        }
    }

    private var chosen: [Episode] { episodes.filter { selection.contains($0.persistentModelID) } }

    var body: some View {
        Group {
            if !hasLoaded {
                Color.clear
            } else if episodes.isEmpty {
                ContentUnavailableView(empty.title, systemImage: empty.image, description: Text(empty.message))
            } else {
                let shown = episodes.filter(\.isLive)
                let order = selecting ? shown.map(\.persistentModelID) : []
                List {
                    ForEach(shown) { episode in row(episode, order: order) }
                    BottomClearance()
                }
                .listStyle(.plain)
                .selectionDragArea(drag)
                .accessibilityIdentifier("collection.\(title)")
            }
        }
        .navigationTitle(selecting ? selectionTitle(selection.count) : title)
        .navigationBarTitleDisplayMode(selecting ? .inline : .large)
        .navigationBarBackButtonHidden(selecting)
        .amoledScreen()
        .processingBanner(pipeline, publisher: FeedPublisher.shared)
        .safeAreaBar(edge: .bottom) {
            if selecting {
                EpisodeSelectionBar(chosen: chosen, pipeline: pipeline, done: endSelection) {
                    if kind == .starred {
                        Button("Unsave", systemImage: "star.slash") {
                            EpisodeBatch.setSaved(chosen, false, context: context); endSelection()
                        }
                    }
                }
            }
        }
        .toolbar {
            if selecting {
                SelectionToolbar(allSelected: !episodes.isEmpty && selection.count == episodes.count,
                                 selectAll: { selection = Set(episodes.map(\.persistentModelID)) },
                                 selectNone: { selection.removeAll() },
                                 done: endSelection)
            } else {
                ToolbarItem(placement: .topBarTrailing) { pageMenu }
            }
        }
        .confirmationDialog("Remove all downloads from your Library?", isPresented: $confirmRemoveAll,
                            titleVisibility: .visible) {
            Button("Remove All Downloads", role: .destructive) {
                EpisodeBatch.removeDownloads(episodes, context: context); reload()
            }
        }
        .task { reload() }
        .onAppear {
            onScreen = true
            if stale, !selecting { stale = false; reload() }
        }
        .onDisappear { onScreen = false }
        // Every save is looked at (identifiers only, no fetch); the reads
        // that follow are coalesced into one.
        .onReceive(StoreChanges.saves(in: context.container)) { change in
                guard hasLoaded, matters(change) else { return }
                guard onScreen, !selecting else { stale = true; return }
                pendingReload?.cancel()
                pendingReload = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    if !Task.isCancelled { reload() }
                }
            }
        .refreshable {
            reload()
            Feel.selection.play()
        }
    }

    /// Pass 44: the same row as a show page and Up Next (it was a compact
    /// row with a round play button and no date or notes here, and the full
    /// row only while choosing).
    private func row(_ episode: Episode, order: [PersistentIdentifier]) -> some View {
        EpisodeListRow(episode: episode, removal: removal(episode),
                       choosing: EpisodeChoosing(isActive: selecting,
                                                 isSelected: selection.contains(episode.persistentModelID),
                                                 drag: drag.handle(episode.persistentModelID, order: order,
                                                                   selection: $selection),
                                                 toggle: { toggle(episode) },
                                                 begin: { beginSelection(with: episode) }),
                       changed: reload)
    }

    /// This page's own swipe: what takes the episode off it.
    private func removal(_ episode: Episode) -> EpisodeRemoval? {
        switch kind {
        case .downloaded:
            EpisodeRemoval(title: "Delete", systemImage: "trash") {
                EpisodeBatch.removeDownloads([episode], context: context)
            }
        case .starred:
            EpisodeRemoval(title: "Unsave", systemImage: "star.slash") {
                EpisodeBatch.setSaved([episode], false, context: context)
            }
        case .latest, .recent:
            nil
        }
    }

    /// What can be done to the whole page, including what was only in each
    /// row's long press.
    private var pageMenu: some View {
        Menu {
            Button("Select", systemImage: "checkmark.circle") { beginSelection(with: nil) }
                .disabled(episodes.isEmpty)
            Divider()
            Button("Play All", systemImage: "play.fill") { playAll() }
                .disabled(episodes.isEmpty)
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                EpisodeBatch.playLast(episodes, context: context)
            }
            .disabled(episodes.isEmpty)
            if episodes.contains(where: { !$0.isPlayed }) {
                Button("Mark All As Played", systemImage: "checkmark.circle") {
                    EpisodeBatch.markPlayed(episodes, true, context: context); reload()
                }
            }
            let needAds = EpisodeBatch.needingAds(episodes, pipeline: pipeline)
            if !needAds.isEmpty {
                Button("Find Ads in All (\(needAds.count))", systemImage: "wand.and.sparkles") {
                    EpisodeBatch.findAds(needAds, pipeline: pipeline)
                }
            }
            if kind != .downloaded, episodes.contains(where: { !$0.isDownloaded }) {
                Button("Download All", systemImage: "arrow.down.circle") {
                    EpisodeBatch.download(episodes, context: context)
                }
            }
            if kind == .downloaded, !episodes.isEmpty {
                Divider()
                Button("Remove All Downloads", systemImage: "trash", role: .destructive) { confirmRemoveAll = true }
            }
            if kind == .starred, !episodes.isEmpty {
                Divider()
                Button("Unsave All", systemImage: "star.slash", role: .destructive) {
                    EpisodeBatch.setSaved(episodes, false, context: context); reload()
                }
            }
        } label: { PageMenuLabel(title: "\(title) Options") }
            .accessibilityIdentifier("collection.menu")
    }

    private func playAll() {
        guard let first = episodes.first else { return }
        EpisodeBatch.playNext(Array(episodes.dropFirst()), context: context)
        PlayCoordinator.play(first, settings: settings, pipeline: pipeline)
    }

    private func toggle(_ episode: Episode) {
        let id = episode.persistentModelID
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        Haptics.select()
    }

    private func beginSelection(with episode: Episode?) {
        if let episode { selection = [episode.persistentModelID] }
        withAnimation(.snappy(duration: 0.25)) { selecting = true }
    }

    private func endSelection() {
        withAnimation(.snappy(duration: 0.25)) { selecting = false }
        selection.removeAll()
        reload()
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            // Parallax (task 10): the backdrop drifts up slower than the page,
            // so the cover's colour seems to sit behind it. Plain 1:1 under
            // Reduce Motion. Only an offset — nothing is filtered per frame.
            .offset(y: -min(offset, height) * (reduceMotion ? 1 : 0.6))
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
    /// So Unfollow can leave the page it just deleted the subject of.
    @Environment(\.dismiss) private var dismiss
    @State private var player = PlayerEngine.shared
    /// Apple's link to this show, resolved once and reused by both Share and
    /// Copy Link. Falls back to the feed address when the directory doesn't
    /// list it.
    @State private var appleShowLink: URL?
    @State private var confirmUnfollow = false
    @State private var hostsAndGuests: [String] = []
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
    @State private var drag = SelectionDrag()

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
            hostsSection
            filterBar
            episodeList
            if !selecting { similarSection }
            BottomClearance()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .selectionDragArea(drag)
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
            Feel.selection.play()
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
        .task(id: podcast.episodes.count) {
            seasonList = seasons
            hostsAndGuests = computeHostsAndGuests()
        }
        .task(id: podcast.feedURL) { appleShowLink = await resolveShowLink() }
        .onChange(of: search) { refreshEpisodes() }
        // The show's counts move whenever an episode is added, played,
        // processed or published — the things the filters depend on.
        .onChange(of: CountsCache.counts(for: podcast)) { refreshEpisodes() }
        .alert(processAndPublishTitle, isPresented: $confirmProcessAndPublish) {
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
        // Apple's own wording (`UNSUBSCRIBE_CONFIRMATION_TITLE`/`_BUTTON`).
        .alert("Unfollow?", isPresented: $confirmUnfollow) {
            Button("Unfollow", role: .destructive) { unfollowShow() }
            Button("Cancel", role: .cancel) {}
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
            // Its own capsule, not squeezed into the search button's (his 6
            // Oct screenshot). The search button comes from `.searchable`, so
            // a spacer can't part them; the chip leaves the shared glass and
            // wears its own.
            ToolbarItem(placement: .topBarTrailing) {
                ProcessingToolbarChip(pipeline: pipeline)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 44)
                    .glassEffect(.regular, in: .capsule)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
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
            if podcast.newCount > 0 {
                Text("\(podcast.newCount) New").fontWeight(.semibold).foregroundStyle(Theme.accentHot)
                Text("·")
            }
            Text("\(CountsCache.counts(for: podcast).total) episodes")
            if podcast.readyCount > 0 {
                Text("·")
                Text("\(podcast.readyCount) ad-free").foregroundStyle(.green)
            }
            if podcast.priority == 1 {
                Text("·")
                Text("High priority").foregroundStyle(Theme.accentWarm)
            }
            // Apple's "Updated %@" (27.2 b2 `SHOW_UPDATED_AT_FORMAT`).
            if let latest = episodes.map(\.publishedAt).max() {
                Text("·")
                Text("Updated " + RelativeDate.release(latest))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    /// Play, Publish and the overflow menu, sized so the two capsules share
    /// the width evenly and the menu is a circle of the same height.
    ///
    /// The old row put a `NavigationLink` in the middle of a `List` row, which
    /// made the list add its own chevron on the far right and stretch the gap
    /// between the Publish label and that arrow.
    ///
    /// Pass 47: the play capsule takes the row's room and the others their
    /// labels' (Apple's show page); the labels stay on one line. When the
    /// text is too large for one row, play gets a row of its own above the
    /// others rather than wrapping (his 27 Oct screenshot: "Latest Episode"
    /// in two lines, twice Publish's height).
    private var actionRow: some View {
        GlassEffectContainer(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    showPlayButton
                    publishButton(fills: false)
                    moreMenu
                }
                // A narrow phone: Publish as its symbol, still one row.
                HStack(spacing: 10) {
                    showPlayButton
                    publishButton(fills: false, iconOnly: true)
                    moreMenu
                }
                VStack(spacing: 10) {
                    showPlayButton
                    HStack(spacing: 10) {
                        publishButton(fills: true)
                        moreMenu
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private var showPlayButton: some View {
        ShowPlayButton(title: playTitle, isPlaying: isPlayingThisShow) {
            togglePlayLatest()
        }
        .accessibilityIdentifier("show.play")
    }

    private func publishButton(fills: Bool, iconOnly: Bool = false) -> some View {
        ShowSecondaryButton(
            title: publishing ? "Done" : (podcast.publishedFeedURL == nil ? "Publish" : "Feed"),
            symbol: publishing ? "checkmark" : "dot.radiowaves.up.forward",
            fills: fills, iconOnly: iconOnly
        ) {
            publishing ? endPublishing() : beginPublishing()
        }
        .accessibilityIdentifier("show.publish")
    }

    @ScaledMetric(relativeTo: .subheadline) private var actionHeight: CGFloat = 22

    private var moreMenu: some View {
        Menu {
            overflowMenuContent
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 38, minHeight: actionHeight)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .fixedSize()
        .accessibilityLabel("More")
    }

    @ViewBuilder
    private var overflowMenuContent: some View {
        // Pass 43: Select first, as on every other page's ⋯ menu.
        Button("Select Episodes", systemImage: "checkmark.circle") {
            beginSelection()
        }
        Button("Show Settings", systemImage: "slider.horizontal.3") {
            showingSettings = true
        }
        Button("Queue Unplayed", systemImage: "text.append") { queueUnplayed() }
        Button("Mark All As Played", systemImage: "checkmark.circle") { markAllPlayed() }
        if let feed = podcast.publishedFeedURL {
            Divider()
            Button("Copy Feed Address", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = feed
                Haptics.success()
            }
        }
        Divider()
        // The show itself, not the app's own ad-free republish of it above.
        if let link = appleShowLink ?? URL(string: podcast.feedURL) {
            ShareLink(item: link, subject: Text(podcast.title)) {
                Label("Share Show…", systemImage: "square.and.arrow.up")
            }
            Button("Copy Link", systemImage: "link") {
                UIPasteboard.general.string = link.absoluteString
                Haptics.success()
            }
        }
        if podcast.episodes.contains(where: \.isDownloaded) {
            Button("Remove Downloads", systemImage: "trash", role: .destructive) {
                removeDownloads()
            }
        }
        Divider()
        Button(podcast.isArchived ? "Unarchive Show" : "Archive Show",
               systemImage: "archivebox") {
            podcast.isArchived.toggle()
            try? context.save()
        }
        Button("Unfollow Show", systemImage: "minus.circle", role: .destructive) {
            confirmUnfollow = true
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

    /// The people the feed names, across the show and every episode of it —
    /// Apple's own section title (`EPISODE_HOSTS_AND_GUESTS_TITLE`). The same
    /// chip styling as `EpisodeDetailView`'s "People".
    @ViewBuilder
    private var hostsSection: some View {
        if !hostsAndGuests.isEmpty {
            SectionHeader("Hosts & Guests")
            HostsAndGuestsShelf(people: PersonEntry.list([hostsAndGuests.joined(separator: "|")]))
                .fullWidthRow()
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
                // Pass 46: Podcasts 27.2 (RC) names a season on its own.
                Button(onlySeason ? "Mark Season as Played" : "Mark Filtered as Played", systemImage: "checkmark.circle") {
                    markFiltered = .played
                }
                Button(onlySeason ? "Mark Season as Unplayed" : "Mark Filtered as Unplayed", systemImage: "circle") {
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
        .feel(.selection, trigger: filter)
        .feel(.selection, trigger: podcast.episodeOrder)
        .feel(.selection, trigger: season)
        .plainRow(top: 14, bottom: 4)
        // Apple's wording for both confirmations.
        .alert(onlySeason
                   ? (markFiltered == .played ? "This will mark every episode of this season as played."
                                              : "This will mark every episode of this season as unplayed.")
                   : (markFiltered == .played ? "This will mark all filtered episodes of this show as played."
                                              : "This will mark all filtered episodes of this show as unplayed."),
               isPresented: Binding(get: { markFiltered != nil },
                                    set: { if !$0 { markFiltered = nil } })) {
            Button(markFiltered == .played ? "Mark as Played" : "Mark as Unplayed") {
                if let mark = markFiltered { markVisible(played: mark == .played) }
                markFiltered = nil
            }
            Button("Cancel", role: .cancel) { markFiltered = nil }
        }
    }

    private enum MarkFiltered { case played, unplayed }

    /// A season chosen and nothing else narrowing the list.
    private var onlySeason: Bool { season > 0 && filter == .all && search.isEmpty }

    private func markVisible(played: Bool) {
        for episode in episodes where episode.isPlayed != played {
            episode.isPlayed = played; if played { episode.isNew = false }
            if played {
                episode.isInQueue = false
            } else {
                episode.setPosition(0)
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
        let order = selecting ? episodes.map(\.persistentModelID) : []
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
            // Pass 44: the shared row (`EpisodeListRow`) — the same swipes,
            // ticks and menu as every other list; Archive is this page's own.
            EpisodeListRow(episode: episode, showsShowName: false, yearInDate: false,
                           removal: EpisodeRemoval(title: "Archive", systemImage: "archivebox") {
                               EpisodeBatch.archive([episode], context: context)
                               CountsCache.invalidate(podcast)
                           },
                           onPublish: { beginPublishing(keeping: [episode.persistentModelID]) },
                           choosing: EpisodeChoosing(isActive: selecting,
                                                     isSelected: selection.contains(episode.persistentModelID),
                                                     drag: drag.handle(episode.persistentModelID, order: order,
                                                                       selection: $selection),
                                                     toggle: { toggleSelection(episode) },
                                                     begin: {
                                                         beginSelection()
                                                         selection.insert(episode.persistentModelID)
                                                     }))
        }

        if episodes.isEmpty {
            ContentUnavailableView("Nothing matches",
                systemImage: "line.3.horizontal.decrease",
                description: Text("Try a different filter."))
                .plainRow(top: 40, bottom: 40)
        }
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
                    GlassButtonLabel(title: allPlayed ? "Unplayed" : "Played",
                                     systemImage: allPlayed ? "circle" : "checkmark.circle")
                }
                .buttonStyle(.glass)
                .disabled(chosen.isEmpty)

                // Pass 43: Find Ads Again when everything ticked is done (and,
                // as on every other page, while another job runs: they join
                // the line).
                let again = selectedNeedingAds.isEmpty && !EpisodeBatch.doneBefore(chosen, pipeline: pipeline).isEmpty
                Button {
                    if again { EpisodeBatch.findAdsAgain(chosen, pipeline: pipeline); finishBatch() }
                    else { batchFindAds() }
                } label: {
                    GlassButtonLabel(title: again ? "Find Again" : "Find Ads",
                                     systemImage: again ? "arrow.clockwise" : "wand.and.sparkles")
                }
                .buttonStyle(.glass)
                .disabled(selectedNeedingAds.isEmpty && !again)
                .accessibilityLabel(again ? "Find Ads Again" : "Find Ads")
                .accessibilityIdentifier("selection.findAds")

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
        let doneOnes = EpisodeBatch.doneBefore(chosen, pipeline: pipeline)
        if !doneOnes.isEmpty, !selectedNeedingAds.isEmpty {
            Button("Find Ads Again (\(doneOnes.count))", systemImage: "arrow.clockwise") {
                EpisodeBatch.findAdsAgain(doneOnes, pipeline: pipeline); finishBatch()
            }
        }
        Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") { batchQueue() }
        if chosen.contains(where: { !$0.isDownloaded }) {
            Button("Download", systemImage: "arrow.down.circle") { batchDownload() }
        }
        if chosen.contains(where: \.isDownloaded) {
            Button("Remove Download", systemImage: "trash") { batchRemoveDownloads() }
        }
        Button(chosen.allSatisfy(\.isStarred) ? "Unsave" : "Save", systemImage: "star") {
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
                    pipeline.processNow(needAds)
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
                        GlassButtonLabel(title: "Remove from Feed (\(chosen.count))", systemImage: "minus.circle")
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
                        GlassButtonLabel(title: "Publish (\(unpublished.count))", systemImage: "arrow.up.circle")
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
            episode.isPlayed = played; if played { episode.isNew = false }
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
            if episode.isPlayed { episode.setPosition(0) }
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
        // Pass 45: Apple's words when it is the newest (27.2 b2
        // `PLAY_ACTION_LATEST_EPISODE`); plain Play when it's an older one.
        if let next = nextUpEpisode, next.publishedAt >= (episodes.map(\.publishedAt).max() ?? .distantFuture) {
            return "Latest Episode"
        }
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
            episode.isPlayed = true; episode.isNew = false
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

    /// Deletes this show's downloaded audio only — the same per-episode path
    /// `ProcessingPipeline.clearDownloads()` uses for the whole library.
    /// Transcripts and found ads are kept.
    private func removeDownloads() {
        for episode in podcast.episodes where episode.isDownloaded {
            DownloadManager.remove(episode)
        }
        try? context.save()
        LibraryTotals.shared.invalidate()
        CountsCache.invalidate(podcast)
        Haptics.success()
    }

    private func unfollowShow() {
        // Pass 47: so your other devices don't add it back.
        CloudSync.shared.noteUnfollowed(feed: podcast.feedURL)
        context.delete(podcast)
        try? context.save()
        dismiss()
    }

    private func resolveShowLink() async -> URL? {
        guard let id = await EpisodeLink.appleShowID(title: podcast.title, feedURL: podcast.feedURL)
        else { return nil }
        return URL(string: "https://podcasts.apple.com/podcast/id\(id)")
    }

    /// Every host or guest named on the show itself, then on any of its
    /// episodes — "role:Name", first mention wins on a repeat.
    private func computeHostsAndGuests() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in podcast.people.split(separator: "|").map(String.init) where !entry.isEmpty {
            if seen.insert(entry).inserted { result.append(entry) }
        }
        for episode in podcast.episodes {
            for entry in episode.people.split(separator: "|").map(String.init) where !entry.isEmpty {
                if seen.insert(entry).inserted { result.append(entry) }
            }
        }
        return result
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
    /// Pass 44: what the page this row is on has to say about the episode —
    /// Up Next's "getting ready", Activity's place in the line, why it
    /// paused, what was found and by which model. One line under the notes,
    /// the same on every page (it replaces Activity's own smaller rows).
    var status: EpisodeRowStatus? = nil
    /// The Find Ads button's words where the page means something more
    /// particular by it (Activity: "Resume", "Try Again").
    var findAdsTitle: String? = nil
    /// Whether an episode from an earlier year says so in its date. The show
    /// page says it with a year heading between the rows instead.
    var yearInDate = true
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(AppSettings.self) private var settings
    @State private var player = PlayerEngine.shared

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
            // The informational part — meta line, title, notes, artwork — is
            // one NavigationLink to the episode page, the way a row anywhere
            // in Apple Podcasts opens it. The controls below stay their own
            // buttons, outside the link, so tapping Play or Find Ads doesn't
            // also push a screen.
            NavigationLink(value: EpisodeRoute(episode)) {
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
                        if let status {
                            EpisodeRowStatusLine(status: status)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Artwork(url: episode.artworkURL ?? episode.podcast?.artworkURL,
                            size: Metrics.artRow)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // A link in a list row gets a disclosure chevron; Apple's rows
            // have none (the first screenshot of this showed one beside
            // every cover).
            .navigationLinkIndicatorVisibility(.hidden)

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
                        : RelativeDate.monthDay(episode.publishedAt))
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
        if episode.hasKnownVideo {
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
            if episode.showsAsNew {
                Text("New").font(.system(size: Metrics.metaSize, weight: .bold))
                    .foregroundStyle(Theme.accentHot)
                    .accessibilityIdentifier("EpisodeNewMarker")
            }
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
                Image(systemName: "star.fill").foregroundStyle(Theme.accentHot).accessibilityLabel("Saved")
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
        // No more tap-to-expand here: the row is a link to the episode page
        // now, and that page shows the notes in full.
        if !episode.plainDescription.isEmpty {
            Text(episode.plainDescription)
                .font(.system(size: Metrics.subtitleSize))
                .foregroundStyle(.secondary)
                .lineLimit(2)
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
        // A page's own words for it (Activity's Resume, Try Again) show it
        // even on an episode found before.
        if (episode.processingState != .ready || findAdsTitle != nil) && !isProcessing {
            findAdsButton
        }
    }

    /// Time remaining once you have started ("23m left", Apple's own pill
    /// in 27.2 b2), total length before that.
    private var timeLabel: String {
        if episode.isPlayed { return "Played" }
        let remaining = episode.rowRemainingSeconds
        let base = remaining > 0 ? remaining : episode.duration
        guard base > 0 else { return "—" }
        let minutes = Int(base / 60)
        let time = minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
        return episode.playbackPosition >= 1 && remaining > 0 ? time + " left" : time
    }

    private var findAdsButton: some View {
        Button {
            Task { await pipeline.processNow(episode) }
        } label: {
            Label(pipeline.isWaiting(episode.guid) ? "Waiting…" : findAdsTitle ?? "Find Ads",
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
        .accessibilityLabel("More")
    }

    @ViewBuilder
    private var errorLine: some View {
        // A page's own line (Activity's "Needs Attention") already says it.
        if status == nil, let error = episode.processingError, !isProcessing {
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
        .navigationDestination(for: ShowSoundRoute.self) { _ in ShowSoundView(podcast: podcast) }
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
        .glassPanel(cornerRadius: Metrics.cardCorner)
    }

    // MARK: Playback

    /// Speed follows Apple's Default / custom split: leave it alone and the
    /// show uses whatever the app default is, or pin it and fine-tune from
    /// there.
    @ViewBuilder
    private var playbackSection: some View {
        Group {
            SectionHeader("Playback")

            Picker("Speed", selection: Binding(
                get: { podcast.playbackSpeedOverride ?? 0 },
                set: { podcast.playbackSpeedOverride = $0 == 0 ? nil : $0 }
            )) {
                Text("Default (\(settings.defaultPlaybackSpeed, specifier: "%g")×)").tag(0.0)
                ForEach(speeds, id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
            }
            .feel(.selection, trigger: podcast.playbackSpeedOverride)
            .contentRow()

            if let override = podcast.playbackSpeedOverride {
                fineTuneSpeed(override)
            }

            // When one of this show's episodes ends: go on to the next, or
            // stop. The order and the "play without ads?" question are the
            // same either way.
            overridePicker(title: "Continue Playing",
                           value: $podcast.continuousPlaybackOverride,
                           fallback: settings.continuousPlayback)

            // For shows with video: open in video every time, or never.
            overridePicker(title: "Start in Video",
                           value: $podcast.startInVideoOverride,
                           fallback: settings.alwaysStartInVideo)
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
            .feelSteps(podcast.playbackSpeedOverride ?? 1, step: 0.1)
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

            // Preset and fixes for this show. Replaces the single Voice
            // Boost switch that used to be here; a show that had it set is
            // moved over when this screen opens.
            NavigationLink(value: ShowSoundRoute()) {
                HStack {
                    Text("Audio for This Show")
                    Spacer()
                    Text(podcast.customSoundData != nil || podcast.voiceBoostOverride != nil
                         ? "Custom" : "My Default")
                        .foregroundStyle(.secondary)
                }
            }
            .contentRow()

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
            .feelSteps(podcast.smartSpeedAmountOverride ?? settings.smartSpeedAggressiveness, step: 0.1)
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
        .feel(.selection, trigger: value.wrappedValue)
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
                .feel(.selection, trigger: podcast.skipIntroSeconds)
                .contentRow()

            Stepper("Fixed outro trim: \(Int(podcast.skipOutroSeconds))s",
                    value: $podcast.skipOutroSeconds, in: 0...300, step: 5)
                .feel(.selection, trigger: podcast.skipOutroSeconds)
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
            .feel(.selection, trigger: podcast.priority)
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
            .feel(.selection, trigger: podcast.episodeOrder)
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

/// The number of New episodes on a show, drawn on its cover or row.
/// Draws nothing at zero.
struct NewCountBadge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .frame(minWidth: 22)
                .background(Theme.accentHot, in: Capsule())
                .accessibilityLabel("\(count) new")
        }
    }
}
