import SwiftUI
import SwiftData
import UIKit

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
        BackgroundWork.shared.register()
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
                    NetworkStatus.shared.start()
                    NowPlayingActivityController.shared.start()
                    // Counts and catalogue indexing, in their own background
                    // context — see `LibraryIndex`.
                    LibraryIndexStatus.shared.configure(container: container)

                    // Only does anything under the screenshot launch argument.
                    // Without it the workflow photographs an empty library and
                    // never reaches the screens worth reviewing.
                    DemoData.seed(into: context)

                    ProcessingPipeline.shared.configure(context: context, settings: settings)
                    FeedPublisher.shared.configure(context: context)
                    // So Siri and Shortcuts act on the same objects the
                    // screens are watching, not a detached second copy.
                    AppLibrary.use(context)
                    PlayerEngine.shared.configure(settings: settings)
                    PlayerEngine.shared.queueProvider = { current in
                        NextUpProvider.next(in: context, after: current)
                    }
                    PlayerEngine.shared.upcomingProvider = { current, limit in
                        NextUpProvider.upcoming(in: context, after: current, limit: limit)
                    }
                    // Autoplay moving on to an episode whose ads have not been
                    // found asks the same question a tap does — when someone
                    // can see it. In the background there is no sheet to show,
                    // and a countdown the app may be suspended half way
                    // through would stall playback between episodes, so it
                    // just plays.
                    PlayerEngine.shared.autoplayRouter = { next in
                        if UIApplication.shared.applicationState == .active {
                            PlayCoordinator.play(next, settings: settings,
                                                 pipeline: .shared, reason: .autoplay)
                        } else {
                            PlayerEngine.shared.load(next, autoplay: true)
                        }
                    }
                    // Quietly get the next episode or two ready in the
                    // background while this one plays. `enqueueBackground`
                    // never pre-empts a job someone is watching, so this cannot
                    // make a deliberate "Find Ads" wait behind a speculative
                    // one.
                    PlayerEngine.shared.preprocessProvider = { _ in
                        PrepareAhead.shared.refresh()
                    }
                    PrepareAhead.shared.configure(context: context, settings: settings)
                    PublishQueue.shared.configure(context: context)
                    // What the Lock Screen shows while a job carries on after
                    // you leave the app: the publish queue if it is working,
                    // otherwise whatever is finding ads.
                    BackgroundWork.shared.status = {
                        if let queued = PublishQueue.shared.snapshot { return queued }
                        let pipeline = ProcessingPipeline.shared
                        if pipeline.isRunning {
                            return .init(title: pipeline.currentEpisodeTitle ?? "Finding ads",
                                         subtitle: "Finding ads · \(pipeline.stage.label)",
                                         fraction: pipeline.overallFraction)
                        }
                        let publisher = FeedPublisher.shared
                        if publisher.isPublishing {
                            return .init(title: publisher.currentEpisodeTitle ?? "Publishing",
                                         subtitle: "Publishing · \(publisher.stage.label)",
                                         fraction: publisher.overallFraction)
                        }
                        return nil
                    }
                    PlayerEngine.shared.sessionRecorder = { session in
                        context.insert(session)
                        try? context.save()
                    }

                    // Put the mini player back where it was. After a crash or
                    // a force-quit this is the difference between tapping play
                    // and going to find the episode again.
                    PlayerEngine.shared.restoreLastSession(context: context)
                    PrepareAhead.shared.refresh()

                    SmartFilterSeeder.seedIfNeeded(context: context)
                    // Fill in back catalogues that are not in yet, one show at
                    // a time in the background — see `LibraryIndex`. Resumes
                    // where it stopped if the app was closed part-way.
                    LibraryIndexStatus.shared.indexCatalogues()
                    DownloadManager.tidy(context: context, settings: settings)
                    ProcessingPipeline.scheduleNext(requiresPower: settings.processOnlyWhileCharging)
                    await NotificationService.requestPermissionIfNeeded(settings: settings)
                }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                PlayerEngine.shared.isInBackground = true
                PlayerEngine.shared.handleAppWillResignActive()
                ProcessingPipeline.shared.applicationDidEnterBackground()
                try? container.mainContext.save()
            case .inactive:
                // Covers the app switcher and incoming calls, where a
                // termination can follow without another callback.
                PlayerEngine.shared.handleAppWillResignActive()
            case .active:
                PlayerEngine.shared.isInBackground = false
                ProcessingPipeline.shared.applicationWillEnterForeground()
                PrepareAhead.shared.refresh()
                LibraryIndexStatus.shared.indexCatalogues()
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
        // Demo runs keep an in-memory store, so the flag from an earlier run
        // must not stop this one having its stations.
        guard existing == 0, DemoData.isEnabled || !UserDefaults.standard.bool(forKey: "seededFilters") else { return }
        for filter in SmartFilter.defaults() { context.insert(filter) }
        try? context.save()
        UserDefaults.standard.set(true, forKey: "seededFilters")
    }
}

/// Picks what plays next: highest-priority show first, then queue order.
enum NextUpProvider {

    /// What plays when the current episode ends.
    ///
    /// The explicit queue wins — if someone has lined episodes up, that is an
    /// instruction. Only when the queue is empty does it continue through the
    /// show, and there it asks `NextEpisode` rather than taking the next row in
    /// the list: a show displayed newest-first puts the *earlier* episode at
    /// the following index, so walking the list played a back catalogue
    /// backwards. Following publication order in the direction the listener is
    /// travelling is what "the next one" actually means.
    @MainActor
    static func next(in context: ModelContext, after current: Episode? = nil) -> Episode? {
        upcoming(in: context, after: current, limit: 1).first
    }

    /// The next several, in the order autoplay would reach them.
    ///
    /// "Prepare 2 episodes ahead" used to ask `next` twice in a row, and `next`
    /// only knows how to exclude the one episode it is handed — so the second
    /// call came back with the first answer, was rejected as a duplicate, and
    /// the list was never longer than one. It also only ever considered
    /// downloaded episodes, which on a phone is usually none.
    @MainActor
    static func upcoming(in context: ModelContext, after current: Episode?, limit: Int) -> [Episode] {
        guard limit > 0 else { return [] }
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.isInQueue },
            sortBy: [SortDescriptor(\.queueOrder)]
        )
        let queued = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.guid != current?.guid && !$0.isArchived }
            .sorted { a, b in
                (a.podcast?.priority ?? 0, -a.queueOrder) > (b.podcast?.priority ?? 0, -b.queueOrder)
            }

        // Up Next first, always, then on through the show.
        //
        // This is Apple Podcasts' model: what you queued by hand plays before
        // anything chosen for you. An earlier version put the show's own run
        // first when the episode had been started from its show page, so the
        // "Getting the next 2 ready" card listed two older episodes of that
        // show and left out the two just added to Up Next — which read as
        // random. After the queue it continues through the current show in
        // that show's sort order, skipping anything already played.
        var found: [Episode] = Array(queued.prefix(limit))
        var cursor = current
        while found.count < limit, let from = cursor,
              let next = NextEpisode.following(from, in: context),
              next.guid != current?.guid,
              !found.contains(where: { $0.guid == next.guid }) {
            found.append(next)
            cursor = next
        }
        return found
    }

    /// Where autoplay goes once Up Next runs out: on through the playing
    /// episode's show, in that show's order, skipping what is played. Shown
    /// at the foot of Up Next so what plays next is never a surprise — the
    /// way Apple Podcasts lists the episodes it will continue with.
    @MainActor
    static func continuation(in context: ModelContext, after current: Episode?, limit: Int) -> [Episode] {
        guard let current, limit > 0 else { return [] }
        var found: [Episode] = []
        var cursor = current
        var seen: Set<String> = [current.guid]
        while found.count < limit, seen.count < 30, let next = NextEpisode.following(cursor, in: context),
              !seen.contains(next.guid) {
            seen.insert(next.guid)
            if !next.isInQueue { found.append(next) }
            cursor = next
        }
        return found
    }
}

// MARK: - Root

struct RootView: View {
    @State private var player = PlayerEngine.shared
    @State private var playbackRequest = PlaybackRequest.shared
    @State private var showOnboarding = !OnboardingView.hasBeenSeen
    @State private var activeSheet: ActiveSheet?
    @Environment(AppSettings.self) private var settings
    /// Held here, outside the view that is rebuilt when the interface size
    /// changes, so changing it in Settings leaves you in Settings.
    @State private var selectedTab = "library"

    var body: some View {
        let step = UIScale.steps.first { $0.id == settings.interfaceSize } ?? UIScale.steps[2]
        content
            // The Lock Screen card, and anything else that links to the player.
            .onOpenURL { url in
                guard url.scheme == "podskipper" else { return }
                if url.host() == "player", PlayerEngine.shared.currentEpisode != nil {
                    activeSheet = .player
                }
            }
            // Every point size is computed when a body runs, so a new size
            // needs the tree rebuilt — `id` does that. Text styles follow
            // `dynamicTypeSize`.
            .id(settings.interfaceSize)
            .dynamicTypeSize(step.typeSize)
    }

    private var content: some View {
        TabView(selection: $selectedTab) {
            Tab("Library", systemImage: "square.stack", value: "library") {
                NavigationStack { LibraryView() }
            }
            Tab("Up Next", systemImage: "list.bullet", value: "upnext") {
                NavigationStack { UpNextView() }
            }
            Tab("Settings", systemImage: "gearshape", value: "settings") {
                NavigationStack { SettingsView() }
            }
            Tab("Discover", systemImage: "magnifyingglass", value: "discover", role: .search) {
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
        //
        // Unconditional on purpose. Returning nothing from inside the
        // accessory does not remove it: the container reserves the capsule
        // regardless, so the app carried an empty glass bar across the bottom
        // of every screen. `MiniPlayer` always has something to say instead —
        // what is playing, or what would play next.
        .tabViewBottomAccessory {
            MiniPlayer(onTap: { activeSheet = .player })
        }
        // Never, not on scroll down.
        //
        // Collapsing is what made both reports from the phone: scrolled, the
        // tab bar shrank to a button and the now-playing bar was squeezed into
        // a pill beside it with room for about twenty characters of title
        // (B16); and every scroll up and down animated the whole bottom stack
        // — and the translucent band behind it — between two heights (B17).
        // A screen recording of the simulator shows the pill clearly. With
        // this the bottom of the screen is one size, always, and the
        // now-playing bar is always the full-width one with cover and controls.
        .tabBarMinimizeBehavior(.onScrollDown)
        // One sheet modifier, not three.
        //
        // SwiftUI honours a single `.sheet` per view: stack two more on the
        // same one and the extras silently never present — no warning, no
        // crash, the sheet simply does not appear. This view had three, and the
        // play-without-processing prompt was the last of them. That is why
        // pressing play on an unprocessed episode did nothing at all: the
        // request was raised, the sheet was never shown, and playback waited
        // forever for an answer nobody could give. It was never an audio bug.
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .player:
                PlayerView()
            case .onboarding:
                OnboardingView()
            case .playPrompt(let episode):
                PlaybackPromptView(request: playbackRequest, episode: episode)
            }
        }
        // The prompt is raised from the model layer — autoplay can raise it
        // with no screen involved — so it is mirrored into the sheet here
        // rather than being presented by whoever happened to tap play.
        .onChange(of: playbackRequest.pending?.guid) { _, guid in
            if let episode = playbackRequest.pending, guid != nil {
                activeSheet = .playPrompt(episode)
            } else if case .playPrompt = activeSheet {
                activeSheet = nil
            }
        }
        .onChange(of: activeSheet) { old, new in
            // Swiped away without choosing. Treated as "play it", the same as
            // letting the countdown run out.
            if case .playPrompt = old, new == nil, playbackRequest.pending != nil {
                playbackRequest.dismiss()
            }
        }
        .onAppear {
            if showOnboarding { activeSheet = .onboarding }
        }
    }

    /// Everything this screen can present, as one value.
    enum ActiveSheet: Identifiable, Equatable {
        case player
        case onboarding
        case playPrompt(Episode)

        var id: String {
            switch self {
            case .player:                return "player"
            case .onboarding:            return "onboarding"
            case .playPrompt(let episode): return "prompt-\(episode.guid)"
            }
        }

        static func == (a: ActiveSheet, b: ActiveSheet) -> Bool { a.id == b.id }
    }
}

/// `sheet(item:)` needs something `Identifiable`, and an `Episode` identified by
/// its model ID would re-present the sheet whenever SwiftData touched the row.
/// Keyed on the guid, which does not change.
struct PendingPlay: Identifiable {
    let episode: Episode
    var id: String { episode.guid }
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
                    Text(errorMessage).font(.footnote).foregroundStyle(.orange)
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
            await EpisodeCatalogue.fill(podcast, from: feed, context: context)
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
                Text(show.title).font(.system(size: Metrics.bodySize, weight: .semibold))
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                Text(show.author)
                    .font(.system(size: Metrics.subtitleSize))
                    .foregroundStyle(.secondary).lineLimit(1)
                if let genre = show.genre {
                    Text(genre).font(.footnote).foregroundStyle(.tertiary)
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
        case .ready:        return foundSummary
        case .failed:       return "failed"
        case .notStarted:   return ""
        case .downloading:  return "downloading…"
        case .transcribing: return "transcribing…"
        case .detecting:    return "finding ads…"
        case .analyzing:    return "analysing…"
        }
    }

    /// "3 ads, 1 promo · 4m cut".
    ///
    /// It used to say "4 ads" whatever it had found, which was wrong the
    /// moment self-promotion became its own kind — and the breakdown is the
    /// quickest way to see that the detector caught the tour-dates segment.
    private var foundSummary: String {
        let live = adSegments.filter { $0.userVerdict != .notAnAd }
        guard !live.isEmpty else { return "nothing found" }

        let counts = Dictionary(grouping: live, by: \.kind).mapValues(\.count)
        let parts = SegmentKind.allCases.compactMap { kind -> String? in
            guard let n = counts[kind], n > 0 else { return nil }
            let word = kind.label.lowercased()
            return "\(n) \(word)\(n == 1 ? "" : "s")"
        }
        let minutes = Int(adSecondsRemoved / 60)
        let cut = minutes > 0 ? " · \(minutes)m cut" : ""
        return parts.joined(separator: ", ") + cut
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
