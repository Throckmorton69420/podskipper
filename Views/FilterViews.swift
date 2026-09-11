import SwiftUI
import SwiftData

// MARK: - List of filters

struct FiltersView: View {
    @Query(sort: \SmartFilter.order) private var filters: [SmartFilter]
    @Query private var episodes: [Episode]
    @Environment(\.modelContext) private var context
    @State private var editing: SmartFilter?

    var body: some View {
        Group {
            if filters.isEmpty {
                ContentUnavailableView("No playlists",
                    systemImage: "square.stack.3d.up",
                    description: Text("A playlist is a set of rules — unplayed, under 45 minutes, downloaded — that fills itself."))
            } else {
                list
            }
        }
        .navigationTitle("Playlists")
        .amoledScreen()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let filter = SmartFilter(name: "New playlist", order: filters.count)
                    context.insert(filter)
                    try? context.save()
                    editing = filter
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editing) { filter in
            NavigationStack { FilterEditor(filter: filter) }
        }
    }

    private var list: some View {
        List {
            ForEach(filters) { filter in
                NavigationLink {
                    FilterResultsView(filter: filter)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: filter.iconName)
                            .font(.title3)
                            .foregroundStyle(filter.tint)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(filter.name).font(.subheadline.weight(.semibold))
                            Text(filter.summary).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text("\(filter.apply(to: episodes).count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentRow()
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        context.delete(filter); try? context.save()
                    } label: { Label("Delete", systemImage: "trash") }
                    Button {
                        editing = filter
                    } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                        .tint(.indigo)
                }
            }
            .onMove { indices, destination in
                var ordered = filters
                ordered.move(fromOffsets: indices, toOffset: destination)
                for (index, filter) in ordered.enumerated() { filter.order = index }
                try? context.save()
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Editing rules

struct FilterEditor: View {
    @Bindable var filter: SmartFilter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \Podcast.title) private var podcasts: [Podcast]

    private let icons = ["line.3.horizontal.decrease.circle", "car.fill", "sparkles",
                         "star.fill", "wand.and.sparkles", "bolt.fill", "moon.stars.fill",
                         "figure.run", "cup.and.saucer.fill", "airplane"]
    private let colors = ["FF3080", "FF9A3D", "3DD68C", "FFD23D", "4DA3FF", "B36BFF"]

    var body: some View {
        Form {
            Section("Name") {
                TextField("Playlist name", text: $filter.name)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(icons, id: \.self) { icon in
                            Button {
                                filter.iconName = icon
                            } label: {
                                Image(systemName: icon)
                                    .font(.title3)
                                    .frame(width: 40, height: 40)
                                    .background(Circle().fill(filter.iconName == icon
                                        ? filter.tint.opacity(0.25) : Color.white.opacity(0.06)))
                                    .foregroundStyle(filter.iconName == icon ? filter.tint : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                HStack(spacing: 12) {
                    ForEach(colors, id: \.self) { hex in
                        Button {
                            filter.colorHex = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().strokeBorder(.white,
                                    lineWidth: filter.colorHex == hex ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Include only") {
                Toggle("Unplayed", isOn: $filter.onlyUnplayed)
                Toggle("Downloaded", isOn: $filter.onlyDownloaded)
                Toggle("Ad-free (processed)", isOn: $filter.onlyAdFree)
                Toggle("Starred", isOn: $filter.onlyStarred)
            }

            Section("Released") {
                Picker("Within", selection: $filter.withinDays) {
                    Text("Any time").tag(0)
                    Text("Last 24 hours").tag(1)
                    Text("Last 3 days").tag(3)
                    Text("Last week").tag(7)
                    Text("Last month").tag(30)
                }
            }

            Section("Length") {
                Picker("Shorter than", selection: $filter.maxMinutes) {
                    Text("Any").tag(0)
                    ForEach([15, 30, 45, 60, 90, 120], id: \.self) { Text("\($0) min").tag($0) }
                }
                Picker("Longer than", selection: $filter.minMinutes) {
                    Text("Any").tag(0)
                    ForEach([5, 15, 30, 45, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
            }

            Section("Shows") {
                if filter.showFeedURLs.isEmpty {
                    Text("All shows").foregroundStyle(.secondary).font(.caption)
                }
                ForEach(podcasts) { podcast in
                    Button {
                        toggle(podcast)
                    } label: {
                        HStack {
                            Text(podcast.title).lineLimit(1).foregroundStyle(.primary)
                            Spacer()
                            if filter.showFeedURLs.contains(podcast.feedURL) {
                                Image(systemName: "checkmark").foregroundStyle(filter.tint)
                            }
                        }
                    }
                }
            }

            Section("Order") {
                Picker("Sort", selection: Binding(
                    get: { filter.sort },
                    set: { filter.sort = $0 }
                )) {
                    ForEach(FilterSort.allCases) { Text($0.rawValue).tag($0) }
                }
            }
        }
        .navigationTitle("Playlist rules")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .toolbar {
            Button("Done") {
                try? context.save()
                dismiss()
            }
        }
    }

    private func toggle(_ podcast: Podcast) {
        if let index = filter.showFeedURLs.firstIndex(of: podcast.feedURL) {
            filter.showFeedURLs.remove(at: index)
        } else {
            filter.showFeedURLs.append(podcast.feedURL)
        }
    }
}

// MARK: - What a filter matches

struct FilterResultsView: View {
    let filter: SmartFilter
    @Query private var allEpisodes: [Episode]
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @State private var player = PlayerEngine.shared

    private var episodes: [Episode] { filter.apply(to: allEpisodes) }

    private var totalTime: Double {
        episodes.reduce(0) { $0 + $1.remainingSeconds }
    }

    var body: some View {
        List {
            HStack(spacing: 14) {
                Label(formatMinutes(totalTime), systemImage: "clock")
                Text("\(episodes.count) episode\(episodes.count == 1 ? "" : "s")")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))

            HStack(spacing: 10) {
                Button {
                    playAll()
                } label: {
                    Label("Play all", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    queueAll()
                } label: {
                    Label("Queue all", systemImage: "text.append").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
            .disabled(episodes.isEmpty)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))

            if episodes.isEmpty {
                ContentUnavailableView("Nothing matches",
                    systemImage: filter.iconName,
                    description: Text("Loosen the rules, or process a few more episodes."))
                    .plainRow(top: 40, bottom: 40)
            }

            ForEach(episodes) { episode in
                EpisodeCompactRow(episode: episode)
                    .contentRow()
                    .swipeActions(edge: .leading) {
                        Button {
                            episode.isInQueue = true
                            episode.queueOrder = 0
                            try? context.save()
                        } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                            .tint(Theme.accentHot)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            episode.isStarred.toggle(); try? context.save()
                        } label: {
                            Label("Star", systemImage: episode.isStarred ? "star.slash" : "star")
                        }
                        .tint(.yellow)
                    }
            }
        }
        .listStyle(.plain)
        .navigationTitle(filter.name)
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()

    }

    private func queueAll() {
        for (index, episode) in episodes.enumerated() {
            episode.isInQueue = true
            episode.queueOrder = index
        }
        try? context.save()
    }

    private func playAll() {
        queueAll()
        if let first = episodes.first(where: { $0.isDownloaded }) ?? episodes.first {
            player.load(first)
        }
    }
}
