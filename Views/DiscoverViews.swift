import SwiftUI
import SwiftData

/// Discover, laid out the way Apple Podcasts lays out Browse: a chart you can
/// actually read, then categories as a grid you can see all at once — not a
/// mile-long horizontal strip.
struct DiscoverView: View {
    @Environment(\.modelContext) private var context
    @Query private var podcasts: [Podcast]

    @State private var search = ""
    @State private var searchResults: [PodcastSearchResult] = []
    @State private var chart: [PodcastSearchResult] = []
    @State private var category: DiscoverService.Category?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var addingFeed: String?
    @State private var chartLimit = 20
    @State private var recommendations: [TasteProfile.Suggestion] = []
    @State private var recommendationNote: String?

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var subscribed: Set<String> { Set(podcasts.map(\.feedURL)) }
    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Fixed at 158 before, which fills an iPad with a wall of small tiles.
    private var grid: [GridItem] {
        AdaptiveGrid.columns(compactMinimum: 158, regularMinimum: 210,
                             spacing: 12, isRegular: sizeClass == .regular)
    }

    var body: some View {
        List {
            errorLine
            if searching { resultsSection } else { browseSection }
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle(searching ? "Search" : "Discover")
        .amoledScreen()
        .searchable(text: $search, prompt: "Shows, topics, hosts")
        .onChange(of: search) { _, value in scheduleSearch(value) }
        .task {
            if chart.isEmpty { await loadChart(nil) }
            if recommendations.isEmpty { await loadRecommendations() }
        }
        .refreshable { await loadChart(category?.id) }
    }

    @ViewBuilder
    private var errorLine: some View {
        if let errorMessage {
            Text(errorMessage).font(.footnote).foregroundStyle(.orange).plainRow()
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        SectionHeader("Results")
        ForEach(searchResults) { show in
            SearchResultRow(show: show, isSubscribed: subscribed.contains(show.feedURL)) {
                Task { await subscribe(show) }
            }
            .contentRow()
        }
        if searchResults.isEmpty && !isLoading {
            ContentUnavailableView("Nothing found", systemImage: "magnifyingglass")
                .plainRow(top: 40, bottom: 40)
        }
    }

    @ViewBuilder
    private var browseSection: some View {
        recommendationsSection

        SectionHeader("Browse")
        LazyVGrid(columns: grid, spacing: 12) {
            ForEach(DiscoverService.categories) { categoryTile($0) }
        }
        .plainRow(top: 2, bottom: 10)

        SectionHeader(title: category.map { "Top in \($0.name)" } ?? "Top Shows") {
            if category != nil {
                Button("Clear") {
                    category = nil
                    Task { await loadChart(nil) }
                }
                .font(.subheadline)
            }
        }

        if chart.isEmpty && isLoading {
            ProgressView().frame(maxWidth: .infinity).plainRow(top: 40, bottom: 40)
        } else {
            ForEach(visibleChart.indices, id: \.self) { index in
                chartRow(index: index, show: visibleChart[index]).contentRow()
            }
            if chart.count > chartLimit {
                Button {
                    withAnimation { chartLimit = chart.count }
                } label: {
                    Label("Show all \(chart.count)", systemImage: "chevron.down")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentHot)
                .plainRow(top: 10, bottom: 10)
            }
        }
    }

    private var visibleChart: [PodcastSearchResult] {
        Array(chart.prefix(chartLimit))
    }

    /// Ranked on the device, against what you actually listen to.
    ///
    /// Each tile says which of your shows it came from, because a
    /// recommendation you can't interrogate is just an advert — and this app
    /// exists to remove those.
    @ViewBuilder
    private var recommendationsSection: some View {
        if !recommendations.isEmpty {
            SectionHeader(title: "For You") {
                if let note = recommendationNote {
                    Text(note).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            CoverStrip(items: recommendations, artwork: { $0.show.artworkURL }) { suggestion in
                VStack(spacing: 2) {
                    Text(suggestion.show.title)
                        .font(.footnote)
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                    if subscribed.contains(suggestion.show.feedURL) {
                        Label("Following", systemImage: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.green)
                    } else if !suggestion.becauseOf.isEmpty {
                        Text("like \(suggestion.becauseOf)")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            } onTap: { suggestion in
                guard !subscribed.contains(suggestion.show.feedURL) else { return }
                Task { await subscribe(suggestion.show) }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 10, trailing: 0))
        }
    }

    /// Builds the taste profile, gathers candidates, and ranks them here.
    ///
    /// The ranking is local and needs no network. The candidates do — they are
    /// Apple's public directory, which is the only catalogue available — but
    /// what is asked for is a handful of genres, and what comes back is
    /// scored against a profile that never leaves the phone.
    private func loadRecommendations() async {
        let seeds = podcasts.filter { !$0.isArchived }.map { show in
            TasteProfile.ShowSeed(
                title: show.title,
                author: show.author,
                category: show.category,
                summary: show.plainSummary,
                // Time actually spent, not episodes downloaded.
                secondsListened: show.episodes.reduce(0.0) { $0 + $1.secondsListened }
            )
        }
        guard !seeds.isEmpty else { return }

        // Off the main actor. Embedding a hundred shows is a hundred Core
        // ML calls, and this screen has to keep scrolling while it happens.
        let profile = await Task.detached(priority: .utility) {
            TasteProfile.build(shows: seeds)
        }.value
        guard profile.isUsable else { return }

        // Candidates from two directions: what is popular in the genres you
        // listen to, and what sits near your three biggest shows. Neither
        // alone is enough — charts give breadth, neighbours give specificity.
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
        recommendationNote = profile.usedFallback
            ? "matched on your library"
            : "ranked on this device"
    }

    private func scheduleSearch(_ value: String) {

        searchTask?.cancel()
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { searchResults = []; return }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            await runSearch()
        }
    }

    // MARK: Rows

    private func chartRow(index: Int, show: PodcastSearchResult) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 24, alignment: .trailing)
            SearchResultRow(show: show, isSubscribed: subscribed.contains(show.feedURL)) {
                Task { await subscribe(show) }
            }
        }
        .opacity(addingFeed == show.feedURL ? 0.4 : 1)
    }

    /// A tinted tile, the way the Podcasts app presents categories — visible
    /// all at once rather than scrolled past.
    private func categoryTile(_ item: DiscoverService.Category) -> some View {
        Button {
            category = item
            Task { await loadChart(item.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accentGradient)
                    // Decoration beside a label that already names the
                    // category. Left visible to VoiceOver, iOS reads out an
                    // auto-derived name for the symbol instead.
                    .accessibilityHidden(true)
                Text(item.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(category?.id == item.id
                                          ? Theme.accentHot : Theme.hairline,
                                          lineWidth: category?.id == item.id ? 1.5 : 0.8)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Loading

    private func loadChart(_ genre: Int?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        chartLimit = 20
        do {
            chart = try await DiscoverService.topShows(genre: genre)
        } catch {
            chart = []
            errorMessage = error.localizedDescription
        }
    }

    private func runSearch() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            searchResults = try await PodcastSearch.search(search, limit: 40)
        } catch is CancellationError {
            return
        } catch {
            searchResults = []
            if case PodcastSearch.SearchError.noResults = error { errorMessage = nil }
            else { errorMessage = error.localizedDescription }
        }
    }

    private func subscribe(_ show: PodcastSearchResult) async {
        addingFeed = show.feedURL
        defer { addingFeed = nil }
        do {
            let feed = try await FeedParser.fetch(show.feedURL)
            let podcast = Podcast(feedURL: show.feedURL,
                                  title: feed.title.isEmpty ? show.title : feed.title,
                                  author: feed.author.isEmpty ? show.author : feed.author,
                                  summary: feed.summary,
                                  artworkURL: feed.artworkURL ?? show.artworkURL,
                                  category: show.genre ?? "")
            context.insert(podcast)
            for item in feed.items.prefix(100) {
                let episode = Episode(item: item)
                episode.podcast = podcast
                context.insert(episode)
            }
            podcast.lastRefreshed = .now
            try context.save()
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
