import SwiftUI
import SwiftData

/// Browsing, not just searching.
///
/// This is the gap the app had: you could only add a show if you already knew
/// its name. Charts and categories are how you find one you don't.
struct DiscoverView: View {
    @Environment(\.modelContext) private var context
    @Query private var podcasts: [Podcast]

    @State private var search = ""
    @State private var searchResults: [PodcastSearchResult] = []
    @State private var chart: [PodcastSearchResult] = []
    @State private var selectedCategory: DiscoverService.Category?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var addingFeed: String?

    private var subscribedFeeds: Set<String> { Set(podcasts.map(\.feedURL)) }
    private var showingSearch: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal, 16)
                }

                if showingSearch {
                    sectionHeader("Results")
                    resultsGrid(searchResults)
                } else {
                    categoryStrip

                    sectionHeader(selectedCategory.map { "Top in \($0.name)" } ?? "Top shows")
                    if chart.isEmpty && isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else {
                        chartList
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .navigationTitle("Discover")
        .background(Theme.background.ignoresSafeArea())
        .searchable(text: $search, prompt: "Shows, topics, hosts")
        .onChange(of: search) { _, value in
            searchTask?.cancel()
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2 else { searchResults = []; return }
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled else { return }
                await runSearch()
            }
        }
        .task { await loadChart(nil) }
        .refreshable { await loadChart(selectedCategory?.id) }
    }

    // MARK: - Pieces

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.title3.bold())
            .padding(.horizontal, 16)
    }

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                categoryChip(name: "All", symbol: "square.grid.2x2",
                             isOn: selectedCategory == nil) {
                    selectedCategory = nil
                    Task { await loadChart(nil) }
                }
                ForEach(DiscoverService.categories) { category in
                    categoryChip(name: category.name, symbol: category.symbol,
                                 isOn: selectedCategory?.id == category.id) {
                        selectedCategory = category
                        Task { await loadChart(category.id) }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func categoryChip(name: String, symbol: String,
                              isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(name, systemImage: symbol)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(Capsule().fill(isOn
                    ? AnyShapeStyle(Theme.accentGradient)
                    : AnyShapeStyle(Material.ultraThin)))
                .overlay(Capsule().strokeBorder(isOn ? Color.clear : Theme.hairline, lineWidth: 1))
                .foregroundStyle(isOn ? Color.black : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var chartList: some View {
        VStack(spacing: 8) {
            ForEach(Array(chart.enumerated()), id: \.element.id) { index, show in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, alignment: .trailing)
                    showRow(show)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.8))
                .padding(.horizontal, 14)
            }
        }
    }

    private func resultsGrid(_ items: [PodcastSearchResult]) -> some View {
        VStack(spacing: 8) {
            ForEach(items) { show in
                showRow(show)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.8))
                    .padding(.horizontal, 14)
            }
            if items.isEmpty && !isLoading {
                ContentUnavailableView("Nothing found", systemImage: "magnifyingglass")
                    .padding(.top, 40)
            }
        }
    }

    private func showRow(_ show: PodcastSearchResult) -> some View {
        HStack(spacing: 12) {
            Artwork(url: show.artworkURL, size: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(show.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(show.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let genre = show.genre {
                    StatusPill(text: genre, tint: Theme.accentWarm)
                }
            }
            Spacer(minLength: 0)

            if subscribedFeeds.contains(show.feedURL) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if addingFeed == show.feedURL {
                ProgressView()
            } else {
                Button {
                    Task { await subscribe(show) }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.accentHot)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Loading

    private func loadChart(_ genre: Int?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
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
            if case PodcastSearch.SearchError.noResults = error {
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
            }
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
                let episode = Episode(guid: item.guid, title: item.title,
                                      episodeDescription: item.description,
                                      audioURL: item.audioURL, publishedAt: item.publishedAt,
                                      duration: item.duration, artworkURL: item.artworkURL)
                episode.podcast = podcast
                context.insert(episode)
            }
            podcast.lastRefreshed = .now
            try context.save()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
