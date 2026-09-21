import SwiftUI
import SwiftData

// MARK: - New and Search tabs
//
// Two tabs, the way the Podcasts app splits them (checked against the iOS
// 27.2 beta 2 build: `TITLE_CATALOG` "New" and `TITLE_SEARCH` "Search").
//
// New is the shelves you take in at a glance — what you might like, favourite
// categories, "Because You Listen to", the top shows and top episodes.
//
// Search, before you type, is only the categories, as big colour tiles that
// each open their own page. Typing shows your own library first, then shows,
// then episodes. Nothing subscribes on a tap: a show opens a preview of itself
// with its episodes, and following it is a deliberate button on that page.
//
// This used to be one "Discover" tab doing both, with the categories at the
// bottom of the shelves.

struct DiscoverView: View {
    enum Mode { case new, search }
    var mode: Mode = .new

    @Environment(\.modelContext) private var context
    @Query private var podcasts: [Podcast]

    @State private var search = ""
    @State private var showResults: [PodcastSearchResult] = []
    @State private var episodeResults: [DiscoverService.EpisodeResult] = []
    @State private var chart: [PodcastSearchResult] = []
    @State private var topEpisodes: [DiscoverService.ChartEpisode] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var recommendations: [TasteProfile.Suggestion] = []
    @State private var recommendationNote: String?
    @AppStorage("recentSearches") private var recentRaw = ""
    /// Categories pinned from a category tile, each shown as its own shelf.
    @AppStorage("favoriteCategories") private var favoriteRaw = ""
    @State private var favoriteShelves: [Int: [PodcastSearchResult]] = [:]
    /// "Because You Listen to …", one shelf for each of the shows you
    /// listen to most — the kind of hand-built row Apple's editors make,
    /// built here from what you actually play.
    @State private var becauseShelves: [(show: String, results: [PodcastSearchResult])] = []
    /// Your own episodes whose titles match, and what was said in them.
    @State private var myEpisodes: [Episode] = []
    @State private var transcriptHits: [LibraryIndex.TranscriptHit] = []
    /// Shows by a host of that name, and your episodes that name them as a
    /// host or guest (from the feed's `podcast:person` tags).
    @State private var peopleShows: [PodcastSearchResult] = []
    @State private var episodesWithPerson: [Episode] = []
    @Environment(AppSettings.self) private var settings
    @Environment(ProcessingPipeline.self) private var pipeline
    /// Where a tap goes. Buttons set this and one `navigationDestination`
    /// follows it: a `NavigationLink` inside a list row makes the list draw a
    /// disclosure chevron beside it, and the first screenshot of this page had
    /// a column of stray chevrons down the middle of the category grid.
    @State private var route: DiscoverRoute?
    /// Apple's own page for this tab — New, or Search's categories — when it
    /// can be read. PodSkipper's own shelves stand in when it can't.
    @State private var applePage: StorePage?
    @State private var appleLoading = true
    @State private var storeLink: StoreLink?

    private func loadApplePage(force: Bool) async {
        guard let url = StoreClient.url(forPath: mode == .new ? "new" : "search") else {
            appleLoading = false; return
        }
        if applePage == nil { applePage = StoreClient.cached(url) }
        if let applePage, !force, StoreClient.isFresh(applePage) { appleLoading = false; return }
        if let fresh = try? await StoreClient.load(url, force: force) { applePage = fresh }
        appleLoading = false
    }

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var subscribed: Set<String> { Set(podcasts.map(\.feedURL)) }
    private var trimmed: String { search.trimmingCharacters(in: .whitespaces) }
    private var searching: Bool { !trimmed.isEmpty }
    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }
    private var favorites: [DiscoverService.Category] {
        let ids = favoriteRaw.split(separator: ",").compactMap { Int($0) }
        return ids.compactMap { id in DiscoverService.categories.first { $0.id == id } }
    }

    private func toggleFavorite(_ category: DiscoverService.Category) {
        var ids = favoriteRaw.split(separator: ",").compactMap { Int($0) }
        if let at = ids.firstIndex(of: category.id) { ids.remove(at: at) } else { ids.append(category.id) }
        favoriteRaw = ids.map(String.init).joined(separator: ",")
        Haptics.select()
        Task { await loadFavoriteShelves() }
    }

    private var categoryGrid: [GridItem] {
        AdaptiveGrid.columns(compactMinimum: 158, regularMinimum: 210,
                             spacing: 12, isRegular: sizeClass == .regular)
    }

    var body: some View {
        switch mode {
        case .new:
            page
                .navigationTitle("New")
                .task {
                    // The directory's charts only feed the fallback page.
                    await loadApplePage(force: false)
                    if applePage == nil {
                        async let shows: Void = loadChart()
                        async let episodes: Void = loadTopEpisodes()
                        _ = await (shows, episodes)
                    }
                    if recommendations.isEmpty { await loadRecommendations() }
                    await loadFavoriteShelves()
                    if becauseShelves.isEmpty { await loadBecauseShelves() }
                }
                .refreshable {
                    await loadApplePage(force: true)
                    if applePage == nil {
                        await loadChart()
                        await loadTopEpisodes()
                    }
                }
        case .search:
            page
                .navigationTitle("Search")
                .searchable(text: $search, prompt: "Shows, Episodes, and More")
                .searchSuggestions {
                    if trimmed.isEmpty {
                        ForEach(recent, id: \.self) { term in
                            Label(term, systemImage: "clock.arrow.circlepath")
                                .searchCompletion(term)
                        }
                    }
                }
                .onSubmit(of: .search) { remember(trimmed) }
                .onChange(of: search) { _, value in scheduleSearch(value) }
        }
    }

    private var page: some View {
        List {
            switch mode {
            case .new:
                if let applePage {
                    // Apple's New page itself — see `StoreClient`.
                    StoreShelves(page: applePage) { storeLink = $0 }
                    // PodSkipper's own, built from what you play, after
                    // Apple's.
                    recommendationsShelf
                    favoriteShelvesSection
                    becauseShelvesSection
                } else if appleLoading {
                    ProgressView().frame(maxWidth: .infinity).plainRow(top: 80, bottom: 40)
                } else {
                    errorLine
                    browse
                }
            case .search:
                if searching {
                    errorLine
                    results
                } else if let applePage {
                    StoreShelves(page: applePage) { storeLink = $0 }
                } else if appleLoading {
                    ProgressView().frame(maxWidth: .infinity).plainRow(top: 80, bottom: 40)
                } else {
                    categories
                }
            }
            BottomClearance()
        }
        .listStyle(.plain)
        .amoledScreen()
        .task { if mode == .search { await loadApplePage(force: false) } }
        .navigationDestination(item: $storeLink) { StoreDestination(link: $0) }
        .navigationDestination(item: $route) { route in
            switch route {
            case .show(let show):            ShowPreviewView(show: show)
            case .chartEpisode(let episode): ShowPreviewView(chartEpisode: episode)
            case .episode(let episode):      ShowPreviewView(episodeResult: episode)
            case .category(let category):    CategoryView(category: category)
            case .chart:                     ChartListView(title: "Top Shows", shows: chart)
            case .library(let podcast):      ShowDetailView(podcast: podcast)
            }
        }
    }

    @ViewBuilder
    private var errorLine: some View {
        if let errorMessage {
            Text(errorMessage).font(.footnote).foregroundStyle(.orange).plainRow()
        }
    }

    // MARK: Browse

    @ViewBuilder
    private var browse: some View {
        recommendationsShelf
        favoriteShelvesSection
        becauseShelvesSection

        if !chart.isEmpty {
            SectionHeader(title: "Top Shows") {
                Button("See All") { route = .chart }
                    .font(.subheadline)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accentHot)
            }
            NavigationShelf(items: Array(chart.prefix(15).enumerated().map { RankedShow(rank: $0.offset + 1, show: $0.element) }),
                       artwork: { $0.show.artworkURL },
                       size: Metrics.artStrip) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.rank)")
                        .font(.system(size: Metrics.metaSize, weight: .bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(item.show.title)
                        .font(.footnote.weight(.medium))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    Text(item.show.author)
                        .font(.system(size: UIScale.pt(12)))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            } onTap: { item in
                route = .show(item.show)
            }
            .fullWidthRow()
        } else if errorMessage == nil {
            ProgressView().frame(maxWidth: .infinity).plainRow(top: 40, bottom: 40)
        }

        if !topEpisodes.isEmpty {
            SectionHeader("Top Episodes")
            ForEach(Array(topEpisodes.prefix(6).enumerated()), id: \.element.id) { index, episode in
                Button { route = .chartEpisode(episode) } label: {
                    ChartEpisodeRow(rank: index + 1, episode: episode)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentRow(top: 10, bottom: 10)
            }
        }

    }

    /// The Search tab before anything is typed: the categories and nothing
    /// else, as the Podcasts app has it.
    @ViewBuilder
    private var categories: some View {
        SectionHeader("Categories")
        LazyVGrid(columns: categoryGrid, spacing: 12) {
            ForEach(Array(DiscoverService.categories.enumerated()), id: \.element.id) { index, item in
                Button { route = .category(item) } label: {
                    CategoryTile(category: item, index: index,
                                 isFavorite: favorites.contains(item))
                }
                .buttonStyle(.plain)
                // Pin a category and its chart becomes a shelf at the top of
                // New — Apple's "favourite categories", kept on this phone.
                .contextMenu {
                    Button(favorites.contains(item) ? "Remove from Favourites" : "Add to Favourites",
                           systemImage: favorites.contains(item) ? "star.slash" : "star") {
                        toggleFavorite(item)
                    }
                }
            }
        }
        .plainRow(top: 2, bottom: 10)
    }

    @ViewBuilder
    private var favoriteShelvesSection: some View {
        ForEach(favorites) { category in
            if let shows = favoriteShelves[category.id], !shows.isEmpty {
                SectionHeader(title: "Top in \(category.name)") {
                    Button("See All") { route = .category(category) }
                        .font(.subheadline)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accentHot)
                }
                NavigationShelf(items: Array(shows.prefix(15)), artwork: { $0.artworkURL },
                                size: Metrics.artStrip) { show in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(show.title)
                            .font(.footnote.weight(.medium))
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                        Text(subscribed.contains(show.feedURL) ? "Following" : show.author)
                            .font(.system(size: UIScale.pt(12)))
                            .lineLimit(1)
                            .foregroundStyle(subscribed.contains(show.feedURL) ? .green : .secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
                } onTap: { show in
                    route = .show(show)
                }
                .fullWidthRow()
            }
        }
    }

    @ViewBuilder
    private var becauseShelvesSection: some View {
        ForEach(becauseShelves, id: \.show) { shelf in
            SectionHeader("Because You Listen to \(shelf.show)")
            NavigationShelf(items: shelf.results, artwork: { $0.artworkURL }, size: Metrics.artStrip) { show in
                VStack(alignment: .leading, spacing: 2) {
                    Text(show.title)
                        .font(.footnote.weight(.medium))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    Text(show.author)
                        .font(.system(size: UIScale.pt(12)))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            } onTap: { show in
                route = .show(show)
            }
            .fullWidthRow()
        }
    }

    private func loadBecauseShelves() async {
        let top = podcasts.filter { !$0.isArchived }
            .sorted { CountsCache.counts(for: $0).listened > CountsCache.counts(for: $1).listened }
            .prefix(2)
        var shelves: [(show: String, results: [PodcastSearchResult])] = []
        for show in top where CountsCache.counts(for: show).listened > 0 {
            if let found = try? await DiscoverService.related(to: show, limit: 16) {
                let fresh = found.filter { !subscribed.contains($0.feedURL) }
                if fresh.count >= 3 { shelves.append((show.title, Array(fresh.prefix(12)))) }
            }
        }
        becauseShelves = shelves
    }

    private func loadFavoriteShelves() async {
        for category in favorites where favoriteShelves[category.id] == nil {
            if let shows = try? await DiscoverService.topShows(genre: category.id, limit: 25) {
                favoriteShelves[category.id] = shows
            }
        }
    }

    /// Ranked on the device, against what you actually listen to.
    @ViewBuilder
    private var recommendationsShelf: some View {
        if !recommendations.isEmpty {
            SectionHeader(title: "For You") {
                if let note = recommendationNote {
                    Text(note).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            NavigationShelf(items: recommendations, artwork: { $0.show.artworkURL },
                       size: Metrics.artStrip) { suggestion in
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.show.title)
                        .font(.footnote.weight(.medium))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    if subscribed.contains(suggestion.show.feedURL) {
                        Label("Following", systemImage: "checkmark")
                            .font(.system(size: UIScale.pt(12), weight: .semibold))
                            .foregroundStyle(.green)
                    } else if !suggestion.becauseOf.isEmpty {
                        Text("Because you like \(suggestion.becauseOf)")
                            .font(.system(size: UIScale.pt(12)))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            } onTap: { suggestion in
                route = .show(suggestion.show)
            }
            .fullWidthRow()
        }
    }

    // MARK: Results

    private var libraryMatches: [Podcast] {
        podcasts.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.author.localizedCaseInsensitiveContains(trimmed)
        }
        .prefix(5).map { $0 }
    }

    @ViewBuilder
    private var results: some View {
        let mine = libraryMatches
        if !mine.isEmpty {
            SectionHeader("In Your Library")
            ForEach(mine) { podcast in
                Button { route = .library(podcast) } label: {
                    ShowRow(podcast: podcast).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentRow(top: 10, bottom: 10)
            }
        }

        if !peopleShows.isEmpty {
            SectionHeader("Hosted by \(trimmed)")
            NavigationShelf(items: peopleShows, artwork: { $0.artworkURL }, size: Metrics.artStrip) { show in
                VStack(alignment: .leading, spacing: 2) {
                    Text(show.title)
                        .font(.footnote.weight(.medium))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    Text(show.author)
                        .font(.system(size: UIScale.pt(12)))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            } onTap: { show in
                route = .show(show)
            }
            .fullWidthRow()
        }

        if !episodesWithPerson.isEmpty {
            SectionHeader("With \(trimmed)")
            ForEach(episodesWithPerson) { episode in
                EpisodeCompactRow(episode: episode).contentRow()
            }
        }

        if !myEpisodes.isEmpty {
            SectionHeader("Your Episodes")
            ForEach(myEpisodes) { episode in
                EpisodeCompactRow(episode: episode).contentRow()
            }
        }

        // Words said in episodes PodSkipper has transcribed — something only
        // an app that keeps the transcripts can offer. Tapping plays from
        // that moment.
        if !transcriptHits.isEmpty {
            SectionHeader("Said in Your Episodes")
            ForEach(transcriptHits) { hit in
                Button { playHit(hit) } label: {
                    TranscriptHitRow(hit: hit, term: trimmed).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentRow(top: 10, bottom: 10)
            }
        }

        if !showResults.isEmpty {
            SectionHeader("Shows")
            NavigationShelf(items: showResults, artwork: { $0.artworkURL }, size: Metrics.artStrip) { show in
                VStack(alignment: .leading, spacing: 2) {
                    Text(show.title)
                        .font(.footnote.weight(.medium))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    Text(subscribed.contains(show.feedURL) ? "Following" : show.author)
                        .font(.system(size: UIScale.pt(12)))
                        .lineLimit(1)
                        .foregroundStyle(subscribed.contains(show.feedURL) ? .green : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            } onTap: { show in
                route = .show(show)
            }
            .fullWidthRow()
        }

        if !episodeResults.isEmpty {
            SectionHeader("Episodes")
            ForEach(episodeResults) { episode in
                Button { route = .episode(episode) } label: {
                    EpisodeResultRow(episode: episode).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentRow(top: 10, bottom: 10)
            }
        }

        if showResults.isEmpty && episodeResults.isEmpty && mine.isEmpty
            && myEpisodes.isEmpty && transcriptHits.isEmpty && peopleShows.isEmpty
            && episodesWithPerson.isEmpty {
            if isSearching {
                ProgressView().frame(maxWidth: .infinity).plainRow(top: 40, bottom: 40)
            } else {
                ContentUnavailableView.search(text: trimmed)
                    .plainRow(top: 40, bottom: 40)
            }
        }
    }

    // MARK: Loading

    private func scheduleSearch(_ value: String) {
        searchTask?.cancel()
        let term = value.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2 else {
            showResults = []; episodeResults = []; isSearching = false
            myEpisodes = []; transcriptHits = []; peopleShows = []; episodesWithPerson = []
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            // Your own library first — it answers instantly and offline.
            var mineDescriptor = FetchDescriptor<Episode>(
                predicate: #Predicate { !$0.isArchived && $0.title.localizedStandardContains(term) },
                sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
            mineDescriptor.fetchLimit = 8
            myEpisodes = (try? context.fetch(mineDescriptor)) ?? []
            // Episodes that name this person as a host or guest. Many feeds
            // don't tag people, so titles are searched too ("… feat. Sam
            // Tallent") — and those already show under Your Episodes.
            var peopleDescriptor = FetchDescriptor<Episode>(
                predicate: #Predicate { $0.people.localizedStandardContains(term) },
                sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
            peopleDescriptor.fetchLimit = 12
            let mineIDs = Set(myEpisodes.map(\.guid))
            episodesWithPerson = ((try? context.fetch(peopleDescriptor)) ?? []).filter { !mineIDs.contains($0.guid) }
            async let said = LibraryIndexStatus.shared.searchTranscripts(term)
            async let shows = try? PodcastSearch.search(term, limit: 30)
            async let episodes = try? DiscoverService.searchEpisodes(term, limit: 25)
            async let hosts = try? PodcastSearch.searchPeople(term, limit: 12)
            let (foundShows, foundEpisodes, foundSaid, foundHosts) = await (shows, episodes, said, hosts)
            guard !Task.isCancelled else { return }
            // Only when the name reads as a person's — two words or more — and
            // only shows whose listed author actually carries that name: the
            // directory's author search also returns shows that merely
            // mention it (a guest on The Joe Rogan Experience).
            let words = term.lowercased().split(separator: " ").map(String.init)
            let byPerson = (foundHosts ?? []).filter { show in
                let author = show.author.lowercased()
                return words.allSatisfy { author.contains($0) }
            }
            peopleShows = words.count >= 2 ? byPerson : []
            transcriptHits = foundSaid
            showResults = foundShows ?? []
            episodeResults = foundEpisodes ?? []
            isSearching = false
        }
    }

    private func playHit(_ hit: LibraryIndex.TranscriptHit) {
        guard let episode = context.model(for: hit.id) as? Episode else { return }
        // A couple of seconds early, so the sentence is heard from its start.
        let start = max(0, hit.at - 2)
        if PlayerEngine.shared.currentEpisode?.guid == episode.guid {
            PlayerEngine.shared.jump(to: start)
            if !PlayerEngine.shared.isPlaying { PlayerEngine.shared.togglePlayPause() }
        } else {
            episode.playbackPosition = start
            PlayCoordinator.play(episode, settings: settings, pipeline: pipeline)
        }
        Haptics.select()
    }

    private func remember(_ term: String) {
        guard term.count >= 2 else { return }
        var list = recent.filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        list.insert(term, at: 0)
        recentRaw = list.prefix(8).joined(separator: "\n")
    }

    private func loadChart() async {
        do {
            chart = try await DiscoverService.topShows(genre: nil)
            errorMessage = nil
        } catch {
            if chart.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    private func loadTopEpisodes() async {
        if let found = try? await DiscoverService.topEpisodes(limit: 25) {
            topEpisodes = found
        }
    }

    /// Builds the taste profile, gathers candidates, and ranks them here.
    private func loadRecommendations() async {
        let seeds = podcasts.filter { !$0.isArchived }.map { show in
            TasteProfile.ShowSeed(
                title: show.title,
                author: show.author,
                category: show.category,
                summary: show.plainSummary,
                // From the background count: summing every episode of every
                // show here walked the whole library on the main thread.
                secondsListened: CountsCache.counts(for: show).listened
            )
        }
        guard !seeds.isEmpty else { return }

        let profile = await Task.detached(priority: .utility) {
            TasteProfile.build(shows: seeds)
        }.value
        guard profile.isUsable else { return }

        var candidates: [PodcastSearchResult] = []
        for genre in profile.genres.prefix(2) {
            if let found = try? await PodcastSearch.search(genre, limit: 25) {
                candidates.append(contentsOf: found)
            }
        }
        let biggest = podcasts
            .filter { !$0.isArchived }
            .sorted { CountsCache.counts(for: $0).listened > CountsCache.counts(for: $1).listened }
            .prefix(3)
        for show in biggest {
            if let found = try? await DiscoverService.related(to: show, limit: 20) {
                candidates.append(contentsOf: found)
            }
        }
        guard !candidates.isEmpty else { return }

        let pool = candidates
        let following = subscribed
        recommendations = await Task.detached(priority: .utility) {
            TasteProfile.rank(pool, against: profile, excluding: following, limit: 14)
        }.value
        recommendationNote = profile.usedFallback ? "matched on your library" : "ranked on this device"
    }
}

private struct RankedShow: Identifiable {
    let rank: Int
    let show: PodcastSearchResult
    var id: Int { show.id }
}

extension View {
    /// A horizontal shelf runs edge to edge; its own padding does the gutter.
    func fullWidthRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 10, trailing: 0))
    }
}

// MARK: - Shelf

/// A horizontal row of covers with captions that line up on the left.
struct NavigationShelf<Item: Identifiable, Caption: View>: View {
    let items: [Item]
    let artwork: (Item) -> String?
    var size: CGFloat = Metrics.artStrip
    @ViewBuilder var caption: (Item) -> Caption
    var onTap: (Item) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(items) { item in
                    Button { onTap(item) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Artwork(url: artwork(item), size: size)
                            caption(item).frame(width: size, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
        .scrollClipDisabled()
    }
}

enum DiscoverRoute: Hashable {
    case show(PodcastSearchResult)
    case chartEpisode(DiscoverService.ChartEpisode)
    case episode(DiscoverService.EpisodeResult)
    case category(DiscoverService.Category)
    case chart
    case library(Podcast)
}

// MARK: - Rows and tiles

struct ChartEpisodeRow: View {
    let rank: Int
    let episode: DiscoverService.ChartEpisode

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: episode.artworkURL, size: UIScale.pt(64))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(rank) · \(episode.showName)")
                    .font(.system(size: Metrics.metaSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(episode.title)
                    .font(.system(size: Metrics.subtitleSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
    }
}

struct EpisodeResultRow: View {
    let episode: DiscoverService.EpisodeResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Artwork(url: episode.artworkURL, size: UIScale.pt(64))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let date = episode.releaseDate {
                        Text(date, format: .dateTime.month(.abbreviated).day().year())
                    }
                    if episode.duration > 0 {
                        Text("·")
                        Text(formatDuration(episode.duration))
                    }
                }
                .font(.system(size: Metrics.metaSize, weight: .medium))
                .foregroundStyle(.secondary)
                Text(episode.title)
                    .font(.system(size: Metrics.subtitleSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(episode.showTitle)
                    .font(.system(size: Metrics.metaSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A category as a big colour tile, the way the Podcasts app browses them.
struct CategoryTile: View {
    let category: DiscoverService.Category
    let index: Int
    var isFavorite = false

    private var tint: Color {
        Color(hue: Double((index * 37) % 360) / 360, saturation: 0.62, brightness: 0.52)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous)
                .fill(LinearGradient(colors: [tint, tint.opacity(0.65)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: category.symbol)
                .font(.system(size: UIScale.pt(44), weight: .semibold))
                .foregroundStyle(.white.opacity(0.22))
                .rotationEffect(.degrees(-12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(10)
                .accessibilityHidden(true)
            Text(category.name)
                .font(.system(size: Metrics.bodySize, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(12)
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .accessibilityLabel("Favourite")
            }
        }
        .frame(height: 96)
        .contentShape(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
    }
}

// MARK: - Category page

struct CategoryView: View {
    let category: DiscoverService.Category
    @State private var shows: [PodcastSearchResult] = []
    @State private var failed: String?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var grid: [GridItem] {
        AdaptiveGrid.columns(compactMinimum: 158, regularMinimum: 200,
                             spacing: 14, isRegular: sizeClass == .regular)
    }

    var body: some View {
        ScrollView {
            if shows.isEmpty {
                if let failed {
                    ContentUnavailableView("Couldn't load \(category.name)",
                                           systemImage: "wifi.exclamationmark",
                                           description: Text(failed))
                        .padding(.top, 60)
                } else {
                    ProgressView().padding(.top, 80)
                }
            } else {
                LazyVGrid(columns: grid, alignment: .leading, spacing: 18) {
                    ForEach(Array(shows.enumerated()), id: \.element.id) { index, show in
                        NavigationLink {
                            ShowPreviewView(show: show)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Artwork(url: show.artworkURL, size: Metrics.artTile)
                                    .frame(maxWidth: .infinity)
                                Text("\(index + 1)")
                                    .font(.system(size: Metrics.metaSize, weight: .bold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(show.title)
                                    .font(.footnote.weight(.semibold))
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)
                                Text(show.author)
                                    .font(.system(size: UIScale.pt(12)))
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                            .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 8)
                BottomClearance()
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.large)
        .background(Theme.background.ignoresSafeArea())
        .task {
            guard shows.isEmpty else { return }
            do { shows = try await DiscoverService.topShows(genre: category.id) }
            catch { failed = error.localizedDescription }
        }
    }
}

/// The whole chart as a list.
struct ChartListView: View {
    let title: String
    let shows: [PodcastSearchResult]
    @Query private var podcasts: [Podcast]

    var body: some View {
        let subscribed = Set(podcasts.map(\.feedURL))
        List {
            ForEach(Array(shows.enumerated()), id: \.element.id) { index, show in
                NavigationLink {
                    ShowPreviewView(show: show)
                } label: {
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 26, alignment: .trailing)
                        SearchResultRow(show: show, isSubscribed: subscribed.contains(show.feedURL))
                    }
                }
                .contentRow(top: 10, bottom: 10)
            }
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .amoledScreen()
    }
}

// MARK: - Show preview

/// A show you have not followed, the way its own page would look.
///
/// Before this, tapping a search result or a chart entry subscribed to it on
/// the spot. There was no way to look at a show — its description, what its
/// episodes are like, how often it comes out — before it was in your library.
struct ShowPreviewView: View {
    private let seed: Seed

    struct Seed {
        var feedURL: String?
        var showID: Int?
        var title: String
        var author: String
        var artworkURL: String?
        var genre: String?
        var highlightTitle: String?
    }

    init(show: PodcastSearchResult) {
        seed = Seed(feedURL: show.feedURL, showID: show.id, title: show.title,
                    author: show.author, artworkURL: show.artworkURL, genre: show.genre)
    }

    /// Anything tapped on one of Apple's pages: a show, a hero card, an
    /// episode (which opens its show with that episode picked out).
    init(storeItem item: StoreItem) {
        let showID = Int(item.showAdamID ?? "") ?? (item.kind == .episode ? nil : Int(item.adamID ?? ""))
            ?? StoreClient.showID(in: item.destination)
        let isEpisode = item.kind == .episode || (item.destination?.contains("?i=") ?? false)
        seed = Seed(feedURL: item.feedURL, showID: showID,
                    title: item.showTitle ?? item.title, author: "",
                    artworkURL: (item.icon ?? item.artwork)?.squareURL(600),
                    genre: item.genre,
                    highlightTitle: isEpisode && item.kind == .episode ? item.title : nil)
    }

    init(episodeResult: DiscoverService.EpisodeResult) {
        seed = Seed(feedURL: episodeResult.feedURL, showID: episodeResult.showID,
                    title: episodeResult.showTitle, author: "",
                    artworkURL: episodeResult.artworkURL, genre: nil,
                    highlightTitle: episodeResult.title)
    }

    init(chartEpisode: DiscoverService.ChartEpisode) {
        seed = Seed(feedURL: nil, showID: chartEpisode.showID, title: chartEpisode.showName,
                    author: chartEpisode.showName, artworkURL: chartEpisode.artworkURL,
                    genre: nil, highlightTitle: chartEpisode.title)
    }

    @Environment(\.modelContext) private var context
    @Query private var podcasts: [Podcast]
    @State private var feed: ParsedFeed?
    @State private var feedURL: String?
    @State private var failed: String?
    @State private var following = false
    @State private var summaryExpanded = false
    @State private var openingLibraryShow = false

    private var existing: Podcast? {
        guard let feedURL else { return nil }
        return podcasts.first { $0.feedURL == feedURL }
    }

    private var title: String { feed?.title.isEmpty == false ? feed!.title : seed.title }
    private var author: String { feed?.author.isEmpty == false ? feed!.author : seed.author }
    private var artwork: String? { feed?.artworkURL ?? seed.artworkURL }

    var body: some View {
        List {
            header
            if let highlighted {
                SectionHeader("Episode")
                PreviewEpisodeRow(item: highlighted).contentRow()
            }
            if let feed {
                SectionHeader(title: "Episodes") {
                    Text("\(feed.items.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(feed.items.enumerated()), id: \.offset) { _, item in
                    PreviewEpisodeRow(item: item).contentRow()
                }
            } else if let failed {
                ContentUnavailableView("Couldn't load this show",
                                       systemImage: "wifi.exclamationmark",
                                       description: Text(failed))
                    .plainRow(top: 30, bottom: 30)
            } else {
                ProgressView().frame(maxWidth: .infinity).plainRow(top: 30, bottom: 30)
            }
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .background(alignment: .top) {
            ArtworkBackdrop(url: artwork, variant: .header)
                .frame(height: 460)
                .ignoresSafeArea(edges: .top)
        }
        .task { await load() }
        .navigationDestination(isPresented: $openingLibraryShow) {
            if let existing { ShowDetailView(podcast: existing) }
        }
    }

    private var highlighted: ParsedItem? {
        guard let wanted = seed.highlightTitle?.lowercased(), let feed else { return nil }
        return feed.items.first { $0.title.lowercased() == wanted }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Artwork(url: artwork, size: Metrics.artHero)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                .padding(.top, 4)
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: Metrics.titleSize, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if !author.isEmpty {
                    Text(author)
                        .font(.system(size: Metrics.bodySize))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let genre = seed.genre {
                    Text(genre).font(.footnote).foregroundStyle(.secondary)
                }
            }

            followButton

            if let summary = feed?.summary, !summary.isEmpty {
                let plain = HTMLText.strip(summary)
                Text(plain)
                    .font(.system(size: Metrics.subtitleSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(summaryExpanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy) { summaryExpanded.toggle() } }
            }
        }
        .frame(maxWidth: .infinity)
        .readableWidth(520)
        .plainRow(top: 2, bottom: 8)
    }

    @ViewBuilder
    private var followButton: some View {
        if existing != nil {
            Button { openingLibraryShow = true } label: {
                Label("Following · Open", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: 240)
                    .frame(height: 24)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
        } else {
            Button {
                Task { await follow() }
            } label: {
                HStack(spacing: 7) {
                    if following { ProgressView().controlSize(.small) }
                    else { Image(systemName: "plus") }
                    Text("Follow")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: 240)
                .frame(height: 24)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .tint(Theme.accentHot)
            .disabled(feed == nil || following)
        }
    }

    private func load() async {
        guard feed == nil else { return }
        var url = seed.feedURL
        if url == nil, let id = seed.showID,
           let found = try? await DiscoverService.lookup(ids: [id]).first {
            url = found.feedURL
        }
        guard let url else {
            failed = "This show's feed isn't listed in the directory."
            return
        }
        feedURL = url
        do { feed = try await FeedParser.fetch(url) }
        catch { failed = error.localizedDescription }
    }

    private func follow() async {
        guard let feed, let feedURL, existing == nil else { return }
        following = true
        defer { following = false }
        let podcast = Podcast(feedURL: feedURL,
                              title: feed.title.isEmpty ? seed.title : feed.title,
                              author: feed.author.isEmpty ? seed.author : feed.author,
                              summary: feed.summary,
                              artworkURL: feed.artworkURL ?? seed.artworkURL,
                              category: seed.genre ?? "")
        context.insert(podcast)
        await EpisodeCatalogue.fill(podcast, from: feed, context: context)
        Haptics.success()
    }
}

private struct PreviewEpisodeRow: View {
    let item: ParsedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(item.publishedAt, format: .dateTime.month(.abbreviated).day().year())
                if item.duration > 0 {
                    Text("·")
                    Text(formatDuration(item.duration))
                }
            }
            .font(.system(size: Metrics.metaSize, weight: .medium))
            .foregroundStyle(.secondary)
            Text(item.title)
                .font(.system(size: Metrics.bodySize, weight: .semibold))
                .lineLimit(2)
            let plain = HTMLText.strip(item.description)
            if !plain.isEmpty {
                Text(plain)
                    .font(.system(size: Metrics.subtitleSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// One place a word was said, in an episode PodSkipper has transcribed.
struct TranscriptHitRow: View {
    let hit: LibraryIndex.TranscriptHit
    let term: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Artwork(url: hit.artwork, size: UIScale.pt(56))
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.show).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                Text(hit.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(highlighted)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Label("Play from \(formatDuration(hit.at))", systemImage: "play.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accentHot)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    /// The snippet with the searched words in bold.
    private var highlighted: AttributedString {
        var text = AttributedString("“" + hit.snippet + "”")
        if let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].font = .footnote.weight(.bold)
            text[range].foregroundColor = .primary
        }
        return text
    }
}
