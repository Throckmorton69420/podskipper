import SwiftUI
import SwiftData

// MARK: - Search tab
//
// Rebuilt in the shape of the Podcasts app's Search tab, which is where this
// tab sits (the search role). Browsing is shelves you can take in at a glance —
// what you might like, the top shows, the top episodes, and categories as big
// colour tiles that open their own page. Searching shows your own library
// first, then shows, then episodes. Nothing subscribes on a tap any more: a
// show opens a preview of itself with its episodes, and following it is a
// deliberate button on that page.

struct DiscoverView: View {
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
    /// Where a tap goes. Buttons set this and one `navigationDestination`
    /// follows it: a `NavigationLink` inside a list row makes the list draw a
    /// disclosure chevron beside it, and the first screenshot of this page had
    /// a column of stray chevrons down the middle of the category grid.
    @State private var route: DiscoverRoute?

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var subscribed: Set<String> { Set(podcasts.map(\.feedURL)) }
    private var trimmed: String { search.trimmingCharacters(in: .whitespaces) }
    private var searching: Bool { !trimmed.isEmpty }
    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }

    private var categoryGrid: [GridItem] {
        AdaptiveGrid.columns(compactMinimum: 158, regularMinimum: 210,
                             spacing: 12, isRegular: sizeClass == .regular)
    }

    var body: some View {
        List {
            errorLine
            if searching { results } else { browse }
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle(searching ? "Search" : "Discover")
        .amoledScreen()
        .searchable(text: $search, prompt: "Shows, episodes, hosts")
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
        .task {
            async let shows: Void = loadChart()
            async let episodes: Void = loadTopEpisodes()
            _ = await (shows, episodes)
            if recommendations.isEmpty { await loadRecommendations() }
        }
        .refreshable {
            await loadChart()
            await loadTopEpisodes()
        }
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

        SectionHeader("Browse by Category")
        LazyVGrid(columns: categoryGrid, spacing: 12) {
            ForEach(Array(DiscoverService.categories.enumerated()), id: \.element.id) { index, item in
                Button { route = .category(item) } label: {
                    CategoryTile(category: item, index: index)
                }
                .buttonStyle(.plain)
            }
        }
        .plainRow(top: 2, bottom: 10)
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

        if showResults.isEmpty && episodeResults.isEmpty && mine.isEmpty {
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
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            async let shows = try? PodcastSearch.search(term, limit: 30)
            async let episodes = try? DiscoverService.searchEpisodes(term, limit: 25)
            let (foundShows, foundEpisodes) = await (shows, episodes)
            guard !Task.isCancelled else { return }
            showResults = foundShows ?? []
            episodeResults = foundEpisodes ?? []
            isSearching = false
        }
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
                secondsListened: show.episodes.reduce(0.0) { $0 + $1.secondsListened }
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
            .sorted { left, right in
                left.episodes.reduce(0.0) { $0 + $1.secondsListened }
                    > right.episodes.reduce(0.0) { $0 + $1.secondsListened }
            }
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

private extension View {
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
                ForEach(Array(feed.items.prefix(40).enumerated()), id: \.offset) { _, item in
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
        for item in feed.items.prefix(100) {
            let episode = Episode(item: item)
            episode.podcast = podcast
            context.insert(episode)
        }
        podcast.lastRefreshed = .now
        try? context.save()
        CountsCache.invalidate()
        LibraryTotals.shared.invalidate()
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
