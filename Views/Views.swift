import SwiftUI
import SwiftData

// MARK: - App entry

@main
struct PodSkipperApp: App {
    @State private var settings = AppSettings()

    var container: ModelContainer = {
        let schema = Schema([Podcast.self, Episode.self, AdSegment.self,
                             Bookmark.self, Chapter.self, ListeningSession.self,
                             SmartFilter.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try! ModelContainer(for: schema, configurations: [config])
    }()

    init() {
        ProcessingPipeline.registerBackgroundTask {
            await ProcessingPipeline.shared.processPending()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(ProcessingPipeline.shared)
                .task {
                    let context = container.mainContext
                    ProcessingPipeline.shared.configure(context: context, settings: settings)
                    FeedPublisher.shared.configure(context: context)
                    PlayerEngine.shared.configure(settings: settings)
                    PlayerEngine.shared.queueProvider = {
                        NextUpProvider.next(in: context)
                    }
                    PlayerEngine.shared.sessionRecorder = { session in
                        context.insert(session)
                        try? context.save()
                    }
                    DownloadManager.tidy(context: context, settings: settings)
                    SmartFilterSeeder.seedIfNeeded(context: context)
                    ProcessingPipeline.scheduleNext(requiresPower: settings.processOnlyWhileCharging)
                    await NotificationService.requestPermissionIfNeeded(settings: settings)
                }
        }
        .modelContainer(container)
    }
}

enum SmartFilterSeeder {
    @MainActor
    static func seedIfNeeded(context: ModelContext) {
        let existing = (try? context.fetchCount(FetchDescriptor<SmartFilter>())) ?? 0
        guard existing == 0,
              !UserDefaults.standard.bool(forKey: "seededFilters") else { return }
        for filter in SmartFilter.defaults() { context.insert(filter) }
        try? context.save()
        UserDefaults.standard.set(true, forKey: "seededFilters")
    }
}

/// Picks what plays after the current episode: highest-priority show first,
/// then queue order.
enum NextUpProvider {
    @MainActor
    static func next(in context: ModelContext) -> Episode? {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.isInQueue },
            sortBy: [SortDescriptor(\.queueOrder)]
        )
        let queued = (try? context.fetch(descriptor)) ?? []
        let playable = queued.filter { !$0.isPlayed && $0.isDownloaded }
        return playable.sorted {
            ($0.podcast?.priority ?? 0, -$1.queueOrder) > ($1.podcast?.priority ?? 0, -$0.queueOrder)
        }.first
    }
}

// MARK: - Root

struct RootView: View {
    @State private var player = PlayerEngine.shared

    var body: some View {
        TabView {
            NavigationStack { LibraryView() }
                .tabItem { Label("Library", systemImage: "square.stack") }
            NavigationStack { DiscoverView() }
                .tabItem { Label("Discover", systemImage: "sparkle.magnifyingglass") }
            NavigationStack { UpNextView() }
                .tabItem { Label("Up Next", systemImage: "list.bullet") }
            NavigationStack { PublishView() }
                .tabItem { Label("Publish", systemImage: "dot.radiowaves.up.forward") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .tint(Theme.accentHot)
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom) {
            if player.currentEpisode != nil { MiniPlayer() }
        }
    }
}

// MARK: - Adding a show

struct AddPodcastView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [PodcastSearchResult] = []
    @State private var isSearching = false
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var showManualEntry = false
    @State private var manualURL = ""
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.callout)
                        .glassListRow()
                }

                if showManualEntry {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("RSS feed address").font(.caption).foregroundStyle(.secondary)
                        TextField("https://…", text: $manualURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Button("Add this feed") {
                            Task { await add(feedURL: manualURL, fallbackArtwork: nil) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(manualURL.isEmpty || isAdding)
                    }
                    .glassListRow()
                }

                ForEach(results) { result in
                    Button {
                        Task { await add(feedURL: result.feedURL, fallbackArtwork: result.artworkURL) }
                    } label: {
                        HStack(spacing: 12) {
                            Artwork(url: result.artworkURL, size: 56)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.title).font(.subheadline.weight(.medium))
                                    .lineLimit(2).foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Text(result.author).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    if let genre = result.genre {
                                        StatusPill(text: genre, tint: Theme.accentWarm)
                                    }
                                    if let count = result.episodeCount {
                                        Text("\(count) episodes").font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isAdding)
                    .glassListRow()
                }

                if !results.isEmpty || showManualEntry {
                    Button(showManualEntry ? "Search by name instead" : "Paste an RSS address instead") {
                        showManualEntry.toggle()
                    }
                    .font(.caption)
                    .glassListRow()
                }
            }
            .listStyle(.plain)
            .amoledScreen()
            .searchable(text: $query, prompt: "Search for a podcast")
            .onChange(of: query) { _, newValue in
                searchTask?.cancel()
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= 2 else { results = []; return }
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(320))
                    guard !Task.isCancelled else { return }
                    await runSearch()
                }
            }
            .onSubmit(of: .search) {
                searchTask?.cancel()
                searchTask = Task { await runSearch() }
            }
            .navigationTitle("Add Podcast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if isAdding || (isSearching && results.isEmpty) {
                    ProgressView().controlSize(.large)
                } else if results.isEmpty && !showManualEntry && !isSearching {
                    ContentUnavailableView("Find a show",
                        systemImage: "magnifyingglass",
                        description: Text("Start typing — results appear as you go."))
                }
            }
        }
    }

    private func runSearch() async {
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            let found = try await PodcastSearch.search(query)
            guard !Task.isCancelled else { return }
            results = found
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            if case PodcastSearch.SearchError.noResults = error {
                errorMessage = nil
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func add(feedURL: String, fallbackArtwork: String?) async {
        isAdding = true
        errorMessage = nil
        defer { isAdding = false }

        let existing = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []
        if existing.contains(where: { $0.feedURL == feedURL }) {
            errorMessage = "You're already subscribed to that show."
            return
        }

        do {
            let feed = try await FeedParser.fetch(feedURL)
            let podcast = Podcast(feedURL: feedURL, title: feed.title, author: feed.author,
                                  summary: feed.summary,
                                  artworkURL: feed.artworkURL ?? fallbackArtwork)
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
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Shared pieces

struct Artwork: View {
    let url: String?
    var size: CGFloat = 52
    var corner: CGFloat = 10

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: corner)
                .fill(LinearGradient(colors: [Theme.surface, Color.black],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Image(systemName: "waveform").foregroundStyle(.tertiary))
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 0.6))
    }
}

extension Episode {
    var stateSummary: String {
        switch processingState {
        case .ready:
            return "\(adSegments.count) ads · \(Int(adSecondsRemoved / 60))m cut"
        case .failed:       return "failed"
        case .notStarted:   return ""
        case .downloading:  return "downloading…"
        case .transcribing: return "transcribing…"
        case .detecting:    return "finding ads…"
        case .analyzing:    return "analysing…"
        }
    }

    var stateColor: Color {
        switch processingState {
        case .ready:  return .green
        case .failed: return .red
        default:      return .orange
        }
    }
}

func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                 : String(format: "%d:%02d", m, s)
}

func formatMinutes(_ seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h \(minutes % 60)m"
}
