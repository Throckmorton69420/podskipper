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
    @State private var recommendations: [PodcastSearchResult] = []
    @State private var recommendationSeed: String?

    private var subscribed: Set<String> { Set(podcasts.map(\.feedURL)) }
    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    private let grid = [GridItem(.adaptive(minimum: 158), spacing: 12)]

    var body: some View {
        List {
            errorLine
            if searching { resultsSection } else { browseSection }
            Color.clear.frame(height: 70).plainRow(top: 0, bottom: 0)
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
            Text(errorMessage).font(.caption).foregroundStyle(.orange).plainRow()
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

    /// Not a pretend recommendation engine. These are Apple's directory
    /// results for the categories and authors already in your library, which
    /// is the honest version of "more like this".
    @ViewBuilder
    private var recommendationsSection: some View {
        if !recommendations.isEmpty {
            SectionHeader(title: "Because You Listen") {
                if let seed = recommendationSeed {
                    Text(seed).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(recommendations) { show in
                        Button {
                            Task { await subscribe(show) }
                        } label: {
                            VStack(spacing: 6) {
                                ZStack(alignment: .topTrailing) {
                                    Artwork(url: show.artworkURL, size: 116, corner: 16)
                                    if subscribed.contains(show.feedURL) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .padding(6)
                                    }
                                }
                                Text(show.title).font(.caption2).lineLimit(2)
                                    .frame(width: 116)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(subscribed.contains(show.feedURL))
                    }
                }
                .padding(.horizontal, 20)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 10, trailing: 0))
        }
    }

    private func loadRecommendations() async {
        // Seed from whatever you've played most recently, falling back to
        // whatever you subscribed to last.
        let seed = podcasts
            .sorted { ($0.lastRefreshed ?? $0.dateAdded) > ($1.lastRefreshed ?? $1.dateAdded) }
            .first
        guard let seed else { return }
        recommendationSeed = seed.title
        let found = (try? await DiscoverService.related(to: seed, limit: 14)) ?? []
        recommendations = found.filter { !subscribed.contains($0.feedURL) }
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
