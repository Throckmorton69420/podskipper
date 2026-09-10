import SwiftUI
import SwiftData

// MARK: - App entry

@main
struct PodSkipperApp: App {
    @State private var settings = AppSettings()

    var container: ModelContainer = {
        let schema = Schema([Podcast.self, Episode.self, AdSegment.self])
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
                    ProcessingPipeline.shared.configure(context: container.mainContext,
                                                        settings: settings)
                    ProcessingPipeline.scheduleNext(requiresPower: settings.processOnlyWhileCharging)
                }
        }
        .modelContainer(container)
    }
}

// MARK: - Root

struct RootView: View {
    @State private var player = PlayerEngine.shared

    var body: some View {
        TabView {
            NavigationStack { LibraryView() }
                .tabItem { Label("Library", systemImage: "square.stack") }
            NavigationStack { QueueView() }
                .tabItem { Label("Up Next", systemImage: "list.bullet") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .safeAreaInset(edge: .bottom) {
            if player.currentEpisode != nil { MiniPlayer() }
        }
    }
}

// MARK: - Library

struct LibraryView: View {
    @Query(sort: \Podcast.dateAdded, order: .reverse) private var podcasts: [Podcast]
    @State private var showingAdd = false

    var body: some View {
        List {
            ForEach(podcasts) { podcast in
                NavigationLink(destination: EpisodeListView(podcast: podcast)) {
                    HStack(spacing: 12) {
                        Artwork(url: podcast.artworkURL, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(podcast.title).font(.headline).lineLimit(2)
                            Text(podcast.author).font(.caption).foregroundStyle(.secondary)
                            if podcast.publishedFeedURL != nil {
                                Label("Feed published", systemImage: "dot.radiowaves.up.forward")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            Button { showingAdd = true } label: { Image(systemName: "plus") }
        }
        .sheet(isPresented: $showingAdd) { AddPodcastView() }
        .overlay {
            if podcasts.isEmpty {
                ContentUnavailableView("No shows yet",
                                       systemImage: "antenna.radiowaves.left.and.right",
                                       description: Text("Tap + and paste a podcast's RSS feed address."))
            }
        }
    }
}

struct AddPodcastView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("RSS feed address") {
                    TextField("https://â¦", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section {
                    Text("Search the web for \"<show name> RSS feed\" to find this.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.callout)
                }
            }
            .navigationTitle("Add Podcast")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }
                        .disabled(urlText.isEmpty || isLoading)
                }
            }
            .overlay { if isLoading { ProgressView() } }
        }
    }

    private func add() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let feed = try await FeedParser.fetch(urlText)
            let podcast = Podcast(feedURL: urlText, title: feed.title, author: feed.author,
                                  summary: feed.summary, artworkURL: feed.artworkURL)
            context.insert(podcast)
            for item in feed.items.prefix(50) {
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

// MARK: - Episodes

struct EpisodeListView: View {
    let podcast: Podcast
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @State private var player = PlayerEngine.shared
    @State private var publishMessage: String?
    @State private var isPublishing = false

    private var episodes: [Episode] {
        podcast.episodes.sorted { $0.publishedAt > $1.publishedAt }
    }

    var body: some View {
        List {
            Section {
                PublishRow(podcast: podcast,
                           isPublishing: $isPublishing,
                           message: $publishMessage)
            }

            Section("Episodes") {
                ForEach(episodes) { episode in
                    EpisodeRow(episode: episode)
                }
            }
        }
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct EpisodeRow: View {
    let episode: Episode
    @Environment(ProcessingPipeline.self) private var pipeline
    @State private var player = PlayerEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(episode.title).font(.subheadline.weight(.medium)).lineLimit(3)

            HStack(spacing: 6) {
                Text(episode.publishedAt, format: .dateTime.month().day())
                if episode.duration > 0 { Text("Â· \(Int(episode.duration / 60)) min") }
                Text(episode.stateSummary).foregroundStyle(episode.stateColor)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button {
                    player.load(episode)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if episode.processingState != .ready {
                    Button {
                        episode.isInQueue = true
                        Task { await pipeline.process(episode) }
                    } label: {
                        Label("Find ads", systemImage: "wand.and.sparkles")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(pipeline.isRunning)
                }
            }
            .buttonStyle(.bordered)

            if let error = episode.processingError {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

extension Episode {
    var stateSummary: String {
        switch processingState {
        case .ready:
            let saved = adSegments.reduce(0) { $0 + $1.duration }
            return "Â· \(adSegments.count) ads, \(Int(saved / 60)) min cut"
        case .failed:       return "Â· failed"
        case .notStarted:   return ""
        case .downloading:  return "Â· downloadingâ¦"
        case .transcribing: return "Â· transcribingâ¦"
        case .detecting:    return "Â· finding adsâ¦"
        }
    }

    var stateColor: Color {
        switch processingState {
        case .ready:      return .green
        case .failed:     return .red
        default:          return .secondary
        }
    }
}

struct QueueView: View {
    @Query(filter: #Predicate<Episode> { $0.isInQueue },
           sort: \Episode.queueOrder) private var queue: [Episode]
    @Environment(ProcessingPipeline.self) private var pipeline

    var body: some View {
        List(queue) { episode in
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title).lineLimit(2).font(.subheadline)
                Text(episode.stateSummary).font(.caption).foregroundStyle(episode.stateColor)
            }
        }
        .navigationTitle("Up Next")
        .overlay {
            if queue.isEmpty {
                ContentUnavailableView("Queue is empty", systemImage: "list.bullet",
                                       description: Text("Tap \"Find ads\" on an episode to add it here."))
            }
        }
        .safeAreaInset(edge: .top) {
            if pipeline.isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pipeline.currentEpisodeTitle ?? "").font(.caption).lineLimit(1)
                    ProgressView(value: pipeline.progress)
                    Text(pipeline.stageDescription ?? "").font(.caption2).foregroundStyle(.secondary)
                }
                .padding()
                .background(.thinMaterial)
            }
        }
    }
}

// MARK: - Player

struct MiniPlayer: View {
    @State private var player = PlayerEngine.shared
    @State private var showFull = false

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: player.currentEpisode?.artworkURL, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentEpisode?.title ?? "").font(.caption.weight(.medium)).lineLimit(1)
                if let skip = player.lastSkip {
                    Text("Skipped \(Int(skip.seconds))s\(skip.sponsor.isEmpty ? "" : " Â· \(skip.sponsor)")")
                        .font(.caption2).foregroundStyle(.green)
                }
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .contentShape(Rectangle())
        .onTapGesture { showFull = true }
        .sheet(isPresented: $showFull) { PlayerView() }
    }
}

struct PlayerView: View {
    @State private var player = PlayerEngine.shared

    var body: some View {
        VStack(spacing: 24) {
            Artwork(url: player.currentEpisode?.artworkURL, size: 240)
            Text(player.currentEpisode?.title ?? "").font(.headline)
                .multilineTextAlignment(.center)

            AdTimeline(episode: player.currentEpisode, current: player.currentTime,
                       duration: player.duration)

            HStack(spacing: 40) {
                Button { player.skipBackward() } label: {
                    Image(systemName: "gobackward.15").font(.title)
                }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                }
                Button { player.skipForward() } label: {
                    Image(systemName: "goforward.30").font(.title)
                }
            }

            if player.lastSkip != nil {
                Button("Undo skip") { player.rewindLastSkip() }
                    .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding()
    }
}

/// Shows where the ads are, so a bad cut is visible rather than a mystery jump.
struct AdTimeline: View {
    let episode: Episode?
    let current: Double
    let duration: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if let episode, duration > 0 {
                    ForEach(episode.adSegments) { segment in
                        Capsule()
                            .fill(.orange.opacity(0.6))
                            .frame(width: max(2, geo.size.width * (segment.duration / duration)))
                            .offset(x: geo.size.width * (segment.start / duration))
                    }
                }
                if duration > 0 {
                    Capsule().fill(.primary)
                        .frame(width: 3)
                        .offset(x: geo.size.width * (current / duration))
                }
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Small pieces

struct Artwork: View {
    let url: String?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
