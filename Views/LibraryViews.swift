import SwiftUI
import SwiftData
import UIKit

// MARK: - Library

struct LibraryView: View {
    @Query(sort: \Podcast.dateAdded, order: .reverse) private var podcasts: [Podcast]
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(AppSettings.self) private var settings

    @State private var showingAdd = false
    @State private var search = ""
    @State private var sort: Sort = .recent
    @State private var showArchived = false
    @State private var useGrid = false
    @State private var refreshNote: String?
    @Query private var allEpisodes: [Episode]

    /// When the search box has text, also show matching episodes from every
    /// show — not just shows whose title matches.
    private var matchingEpisodes: [Episode] {
        guard search.count >= 2 else { return [] }
        return allEpisodes
            .filter { !$0.isArchived && $0.title.localizedCaseInsensitiveContains(search) }
            .sorted { $0.publishedAt > $1.publishedAt }
            .prefix(25)
            .map { $0 }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Recently added"
        case title = "Title"
        case author = "Author"
        case unplayed = "Unplayed"
        case priority = "Priority"
        var id: String { rawValue }
    }

    private var visible: [Podcast] {
        var list = podcasts.filter { showArchived || !$0.isArchived }
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
        }
    }

    var body: some View {
        Group {
            if useGrid { grid } else { rows }
        }
        .navigationTitle("Library")
        .amoledScreen()
        .searchable(text: $search, prompt: "Search your shows")
        .refreshable { await refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Divider()
                    Toggle("Grid layout", isOn: $useGrid)
                    Toggle("Show archived", isOn: $showArchived)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showingAdd) { AddPodcastView() }
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView("No shows yet",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Tap + and search for a show by name."))
            }
        }
    }

    private var rows: some View {
        List {
            if search.isEmpty {
                HStack(spacing: 10) {
                    NavigationLink { FiltersView() } label: {
                        shortcut("Playlists", "line.3.horizontal.decrease.circle", Theme.accentHot)
                    }
                    NavigationLink { BookmarksView() } label: {
                        shortcut("Bookmarks", "bookmark.fill", Theme.accentWarm)
                    }
                    NavigationLink { StatsView() } label: {
                        shortcut("Stats", "chart.bar.fill", .green)
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 8, trailing: 14))
            }

            if !matchingEpisodes.isEmpty {
                Section {
                    ForEach(matchingEpisodes) { episode in
                        QueueRow(episode: episode).glassListRow()
                    }
                } header: {
                    Text("Episodes").glassSectionHeader()
                }
            }

            if let refreshNote {
                Text(refreshNote).font(.caption).foregroundStyle(.secondary)
                    .glassListRow()
            }
            ForEach(visible) { podcast in
                NavigationLink(destination: ShowDetailView(podcast: podcast)) {
                    ShowRow(podcast: podcast)
                }
                .glassListRow()
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        context.delete(podcast); try? context.save()
                    } label: { Label("Delete", systemImage: "trash") }

                    Button {
                        podcast.isArchived.toggle(); try? context.save()
                    } label: {
                        Label(podcast.isArchived ? "Restore" : "Archive", systemImage: "archivebox")
                    }
                    .tint(.indigo)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        podcast.priority = podcast.priority == 1 ? 0 : 1
                        try? context.save()
                    } label: {
                        Label("Priority", systemImage: "arrow.up.circle")
                    }
                    .tint(Theme.accentWarm)
                }
            }
        }
        .listStyle(.plain)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 14)], spacing: 16) {
                ForEach(visible) { podcast in
                    NavigationLink(destination: ShowDetailView(podcast: podcast)) {
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack(alignment: .topTrailing) {
                                Artwork(url: podcast.artworkURL, size: 104, corner: 14)
                                if podcast.unplayedCount > 0 {
                                    Text("\(podcast.unplayedCount)")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Theme.accentGradient))
                                        .foregroundStyle(.black)
                                        .padding(5)
                                }
                            }
                            Text(podcast.title).font(.caption.weight(.medium))
                                .lineLimit(2).foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    private func shortcut(_ title: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 0.8))
    }

    private func refresh() async {
        let added = await pipeline.refreshAllFeeds(queueNewEpisodes: settings.autoQueueNewEpisodes)
        refreshNote = added == 0 ? "No new episodes." : "Added \(added) new episode\(added == 1 ? "" : "s")."
        try? await Task.sleep(for: .seconds(4))
        refreshNote = nil
    }
}

struct ShowRow: View {
    let podcast: Podcast

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: podcast.artworkURL, size: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(podcast.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(podcast.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    if podcast.unplayedCount > 0 {
                        StatusPill(text: "\(podcast.unplayedCount) new", tint: Theme.accentHot)
                    }
                    if podcast.priority == 1 {
                        StatusPill(text: "High", tint: Theme.accentWarm)
                    }
                    if podcast.publishedFeedURL != nil {
                        Image(systemName: "dot.radiowaves.up.forward")
                            .font(.caption2).foregroundStyle(.green)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - One show

struct ShowDetailView: View {
    let podcast: Podcast
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @State private var player = PlayerEngine.shared
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var showingSettings = false
    @State private var similar: [PodcastSearchResult] = []

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", unplayed = "Unplayed", played = "Played"
        case downloaded = "Downloaded", ready = "Ad-free"
        var id: String { rawValue }
    }

    private var episodes: [Episode] {
        var list = podcast.sortedEpisodes.filter { !$0.isArchived }
        switch filter {
        case .all:        break
        case .unplayed:   list = list.filter { !$0.isPlayed }
        case .played:     list = list.filter { $0.isPlayed }
        case .downloaded: list = list.filter { $0.isDownloaded }
        case .ready:      list = list.filter { $0.processingState == .ready }
        }
        if !search.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(search) }
        }
        return list
    }

    var body: some View {
        List {
            Section {
                header.glassListRow()
            }

            if !similar.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(similar) { show in
                                VStack(spacing: 5) {
                                    Artwork(url: show.artworkURL, size: 84, corner: 12)
                                    Text(show.title).font(.caption2).lineLimit(2)
                                        .frame(width: 84)
                                        .multilineTextAlignment(.center)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowSeparator(.hidden)
                } header: {
                    Text("You might also like").glassSectionHeader()
                }
            }

            Section {
                ChipRow(options: Filter.allCases, label: { $0.rawValue }, selection: $filter)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 6, trailing: 0))
                    .listRowSeparator(.hidden)
            }

            ForEach(episodes) { episode in
                EpisodeRow(episode: episode)
                    .glassListRow()
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            episode.isArchived = true; try? context.save()
                        } label: { Label("Archive", systemImage: "archivebox") }
                        Button {
                            episode.isPlayed.toggle(); try? context.save()
                        } label: {
                            Label(episode.isPlayed ? "Unplayed" : "Played",
                                  systemImage: episode.isPlayed ? "circle" : "checkmark.circle")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            episode.isInQueue = true
                            episode.queueOrder = 0
                            try? context.save()
                        } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                        .tint(Theme.accentHot)
                    }
            }
        }
        .listStyle(.plain)
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .searchable(text: $search, prompt: "Search episodes")
        .toolbar {
            Button { showingSettings = true } label: { Image(systemName: "slider.horizontal.3") }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { ShowSettingsView(podcast: podcast) }
        }
        .task {
            // Best effort. No recommendations engine here — this is Apple's
            // directory, searched by the show's own category.
            similar = (try? await DiscoverService.related(to: podcast, limit: 12)) ?? []
        }
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Artwork(url: podcast.artworkURL, size: 78, corner: 14)
                VStack(alignment: .leading, spacing: 4) {
                    Text(podcast.author).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        StatusPill(text: "\(podcast.episodes.count) episodes", tint: .gray)
                        if podcast.readyCount > 0 {
                            StatusPill(text: "\(podcast.readyCount) ad-free", tint: .green)
                        }
                    }
                    if podcast.priority != 0 {
                        StatusPill(text: "\(podcast.priorityLabel) priority", tint: Theme.accentWarm)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                NavigationLink {
                    PublishShowView(podcast: podcast)
                } label: {
                    Label(podcast.publishedFeedURL == nil ? "Publish" : "Manage feed",
                          systemImage: "dot.radiowaves.up.forward")
                }
                .buttonStyle(.bordered).controlSize(.small)

                if let feed = podcast.publishedFeedURL {
                    Button { UIPasteboard.general.string = feed } label: {
                        Label("Copy feed", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }

            if !podcast.summary.isEmpty {
                Text(podcast.summary).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }

            HStack(spacing: 8) {
                Button {
                    for episode in podcast.episodes where !episode.isPlayed {
                        episode.isPlayed = true
                        episode.isInQueue = false
                    }
                    try? context.save()
                } label: { Label("Mark all played", systemImage: "checkmark.circle") }

                Button {
                    queueUnplayed()
                } label: { Label("Queue unplayed", systemImage: "text.append") }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }
}

// MARK: - Episode row

struct EpisodeRow: View {
    let episode: Episode
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @State private var player = PlayerEngine.shared
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Text(episode.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(3)
                    .foregroundStyle(episode.isPlayed ? .secondary : .primary)
                Spacer(minLength: 0)
                if episode.isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 6) {
                if !episode.numberLabel.isEmpty {
                    Text(episode.numberLabel).foregroundStyle(Theme.accentWarm)
                    Text("·")
                }
                Text(episode.publishedAt, format: .dateTime.month().day())
                if episode.duration > 0 { Text("· \(Int(episode.duration / 60))m") }
                if !episode.stateSummary.isEmpty {
                    Text("· \(episode.stateSummary)").foregroundStyle(episode.stateColor)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if episode.progressFraction > 0.01 && !episode.isPlayed {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.10))
                        Capsule().fill(Theme.accentGradient)
                            .frame(width: max(3, geo.size.width * episode.progressFraction))
                    }
                }
                .frame(height: 3)
            }

            if !episode.plainDescription.isEmpty {
                Text(episode.plainDescription)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 2)
                    .onTapGesture { withAnimation { expanded.toggle() } }
            }

            HStack(spacing: 8) {
                Button {
                    player.load(episode)
                } label: {
                    Label(episode.playbackPosition > 5 ? "Resume" : "Play", systemImage: "play.fill")
                }

                if episode.processingState != .ready {
                    Button {
                        episode.isInQueue = true
                        try? context.save()
                        Task { await pipeline.process(episode) }
                    } label: { Label("Find ads", systemImage: "wand.and.sparkles") }
                        .disabled(pipeline.isRunning)
                } else {
                    NavigationLink {
                        TranscriptView(episode: episode)
                    } label: { Label("Transcript", systemImage: "text.alignleft") }

                    if !episode.chapters.isEmpty {
                        NavigationLink {
                            ChapterListView(episode: episode)
                        } label: { Label("\(episode.chapters.count)", systemImage: "list.bullet.indent") }
                    }
                }

                Button {
                    episode.isStarred.toggle(); try? context.save()
                } label: {
                    Image(systemName: episode.isStarred ? "star.fill" : "star")
                }
                .tint(episode.isStarred ? .yellow : .secondary)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let error = episode.processingError {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
    }
}

// MARK: - Per-show settings

struct ShowSettingsView: View {
    @Bindable var podcast: Podcast
    @Environment(\.dismiss) private var dismiss

    private let speeds: [Double] = [0.8, 1.0, 1.2, 1.5, 1.8, 2.0, 2.5]

    var body: some View {
        Form {
            Section("Playback") {
                Picker("Speed", selection: Binding(
                    get: { podcast.playbackSpeedOverride ?? 0 },
                    set: { podcast.playbackSpeedOverride = $0 == 0 ? nil : $0 }
                )) {
                    Text("Use default").tag(0.0)
                    ForEach(speeds, id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
                }
                Stepper("Skip intro: \(Int(podcast.skipIntroSeconds))s",
                        value: $podcast.skipIntroSeconds, in: 0...300, step: 5)
                Stepper("Skip outro: \(Int(podcast.skipOutroSeconds))s",
                        value: $podcast.skipOutroSeconds, in: 0...300, step: 5)
            }

            Section("New episodes") {
                Toggle("Add to Up Next", isOn: $podcast.autoQueueNew)
                Toggle("Download automatically", isOn: $podcast.autoDownloadNew)
                Toggle("Notify me", isOn: $podcast.notifyOnNewEpisodes)
                Picker("Priority", selection: $podcast.priority) {
                    Text("Low").tag(-1)
                    Text("Normal").tag(0)
                    Text("High").tag(1)
                }
                Text("High-priority shows play first when Up Next advances.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Ads") {
                Picker("Skip ads", selection: Binding(
                    get: { podcast.autoSkipEnabled ?? true },
                    set: { podcast.autoSkipEnabled = $0 }
                )) {
                    Text("On").tag(true)
                    Text("Off").tag(false)
                }
            }

            Section("Episodes") {
                Toggle("Newest first", isOn: $podcast.newestFirst)
                Toggle("Archived", isOn: $podcast.isArchived)
            }
        }
        .navigationTitle("Show settings")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .toolbar { Button("Done") { dismiss() } }
    }
}
