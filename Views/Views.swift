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
        // A screenshot run gets a throwaway store, so seeded demo shows can
        // never end up in a real library.
        let config = ModelConfiguration(schema: schema,
                                        isStoredInMemoryOnly: DemoData.isEnabled)
        return try! ModelContainer(for: schema, configurations: [config])
    }()

    init() {
        ProcessingPipeline.registerBackgroundTask {
            await ProcessingPipeline.shared.processPending()
        }
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(ProcessingPipeline.shared)
                .task {
                    let context = container.mainContext

                    // One directory listing, before anything can ask an
                    // episode whether it is downloaded.
                    FileIndex.loadIfNeeded()

                    // Only does anything under the screenshot launch argument.
                    // Without it the workflow photographs an empty library and
                    // never reaches the screens worth reviewing.
                    DemoData.seed(into: context)

                    ProcessingPipeline.shared.configure(context: context, settings: settings)
                    FeedPublisher.shared.configure(context: context)
                    PlayerEngine.shared.configure(settings: settings)
                    PlayerEngine.shared.queueProvider = { NextUpProvider.next(in: context) }
                    PlayerEngine.shared.sessionRecorder = { session in
                        context.insert(session)
                        try? context.save()
                    }

                    // Put the mini player back where it was. After a crash or
                    // a force-quit this is the difference between tapping play
                    // and going to find the episode again.
                    PlayerEngine.shared.restoreLastSession(context: context)

                    SmartFilterSeeder.seedIfNeeded(context: context)
                    DownloadManager.tidy(context: context, settings: settings)
                    LibraryTotals.shared.refresh(context: context, force: true)
                    ProcessingPipeline.scheduleNext(requiresPower: settings.processOnlyWhileCharging)
                    await NotificationService.requestPermissionIfNeeded(settings: settings)
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                PlayerEngine.shared.handleAppWillResignActive()
                ProcessingPipeline.shared.applicationDidEnterBackground()
                try? container.mainContext.save()
            case .inactive:
                // Covers the app switcher and incoming calls, where a
                // termination can follow without another callback.
                PlayerEngine.shared.handleAppWillResignActive()
            case .active:
                ProcessingPipeline.shared.applicationWillEnterForeground()
            @unknown default:
                break
            }
        }
    }
}

enum SmartFilterSeeder {
    @MainActor
    static func seedIfNeeded(context: ModelContext) {
        let existing = (try? context.fetchCount(FetchDescriptor<SmartFilter>())) ?? 0
        guard existing == 0, !UserDefaults.standard.bool(forKey: "seededFilters") else { return }
        for filter in SmartFilter.defaults() { context.insert(filter) }
        try? context.save()
        UserDefaults.standard.set(true, forKey: "seededFilters")
    }
}

/// Picks what plays next: highest-priority show first, then queue order.
enum NextUpProvider {
    @MainActor
    static func next(in context: ModelContext) -> Episode? {
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.isInQueue && !$0.isPlayed },
            sortBy: [SortDescriptor(\.queueOrder)]
        )
        let queued = (try? context.fetch(descriptor)) ?? []
        let playable = queued.filter { $0.isDownloaded }
        return playable.sorted {
            ($0.podcast?.priority ?? 0, -$1.queueOrder) > ($1.podcast?.priority ?? 0, -$0.queueOrder)
        }.first
    }
}

// MARK: - Root

struct RootView: View {
    @State private var player = PlayerEngine.shared
    @State private var showOnboarding = !OnboardingView.hasBeenSeen
    @State private var showFullPlayer = false

    var body: some View {
        TabView {
            Tab("Library", systemImage: "square.stack") {
                NavigationStack { LibraryView() }
            }
            Tab("Up Next", systemImage: "list.bullet") {
                NavigationStack { UpNextView() }
            }
            Tab("Publish", systemImage: "dot.radiowaves.up.forward") {
                NavigationStack { PublishView() }
            }
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack { SettingsView() }
            }
            Tab("Discover", systemImage: "magnifyingglass", role: .search) {
                NavigationStack { DiscoverView() }
            }
        }
        // On iPad this turns the tab bar into a collapsible sidebar that the
        // user can flip back to a top tab bar. It is the supported adaptive
        // path — hand-rolling a NavigationSplitView would fight the platform.
        .tabViewStyle(.sidebarAdaptable)
        .tint(Theme.accentHot)
        .preferredColorScheme(.dark)
        // The system places this above the tab bar and gives it glass for
        // free — which is why the old hand-rolled bar covered the tabs.
        .tabViewBottomAccessory {
            MiniPlayer(onTap: { showFullPlayer = true })
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(isPresented: $showFullPlayer) { PlayerView() }
        .sheet(isPresented: $showOnboarding) { OnboardingView() }
    }
}

// MARK: - Adding a show by RSS

struct AddPodcastView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [PodcastSearchResult] = []
    @State private var isSearching = false
    @State private var isAdding = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if results.isEmpty && !isSearching {
                    ContentUnavailableView("Find a show",
                        systemImage: "magnifyingglass",
                        description: Text("Type a name, or paste an RSS address."))
                } else {
                    List {
                        ForEach(results) { result in
                            Button {
                                Task { await add(feedURL: result.feedURL, art: result.artworkURL) }
                            } label: {
                                SearchResultRow(show: result, isSubscribed: false)
                            }
                            .buttonStyle(.plain)
                            .contentRow()
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .amoledScreen()
            .searchable(text: $query, prompt: "Show name or RSS address")
            .onChange(of: query) { _, value in
                searchTask?.cancel()
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("http") {
                    results = []
                    return
                }
                guard trimmed.count >= 2 else { results = []; return }
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(320))
                    guard !Task.isCancelled else { return }
                    await runSearch()
                }
            }
            .onSubmit(of: .search) {
                let trimmed = query.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("http") {
                    Task { await add(feedURL: trimmed, art: nil) }
                } else {
                    searchTask = Task { await runSearch() }
                }
            }
            .navigationTitle("Add Podcast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .overlay(alignment: .bottom) {
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .glassCapsule()
                        .padding()
                }
            }
            .overlay { if isAdding { ProgressView().controlSize(.large) } }
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
            results = []
            if case PodcastSearch.SearchError.noResults = error { errorMessage = nil }
            else { errorMessage = error.localizedDescription }
        }
    }

    private func add(feedURL: String, art: String?) async {
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
                                  summary: feed.summary, artworkURL: feed.artworkURL ?? art)
            context.insert(podcast)
            for item in feed.items.prefix(100) {
                let episode = Episode(item: item)
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

/// Shared between Add-by-RSS and Discover.
struct SearchResultRow: View {
    let show: PodcastSearchResult
    let isSubscribed: Bool
    var onAdd: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: show.artworkURL, size: Metrics.artRow)
            VStack(alignment: .leading, spacing: 3) {
                Text(show.title).font(.subheadline.weight(.semibold))
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                Text(show.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let genre = show.genre {
                    Text(genre).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if isSubscribed {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if let onAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.footnote.weight(.bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                        .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.8))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Shared pieces

extension Episode {
    var stateSummary: String {
        switch processingState {
        case .ready:        return "\(adSegments.count) ads · \(Int(adSecondsRemoved / 60))m cut"
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
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

func formatMinutes(_ seconds: Double) -> String {
    let minutes = Int(seconds / 60)
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h \(minutes % 60)m"
}
