import SwiftUI
import SwiftData

// MARK: - List of filters

struct FiltersView: View {
    @Query(sort: \SmartFilter.order) private var filters: [SmartFilter]
    @Environment(\.modelContext) private var context
    @State private var editing: SmartFilter?

    /// One pass over the store fills in every row's count.
    ///
    /// Each row used to call `filter.apply(to: episodes)` on every render — so
    /// four playlists over a library of five hundred episodes meant two
    /// thousand rule evaluations every time this screen redrew.
    @State private var counts: [PersistentIdentifier: Int] = [:]

    private func reloadCounts() {
        let all = (try? context.fetch(FetchDescriptor<Episode>())) ?? []
        var result: [PersistentIdentifier: Int] = [:]
        for filter in filters {
            result[filter.persistentModelID] = all.reduce(0) { $0 + (filter.matches($1) ? 1 : 0) }
        }
        counts = result
    }

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
        .task { reloadCounts() }
        .onChange(of: filters.count) { _, _ in reloadCounts() }
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
                            Text(filter.summary).font(.footnote).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text("\(counts[filter.persistentModelID] ?? 0)")
                            .font(.footnote.monospacedDigit())
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
    private let maxLengths = [15, 30, 45, 60, 90, 120]
    private let minLengths = [5, 15, 30, 45, 60]

    var body: some View {
        Form {
            nameSection
            includeSection
            releasedSection
            lengthSection
            showsSection
            orderSection
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

    private var nameSection: some View {
        Section("Name") {
            TextField("Playlist name", text: $filter.name)
            iconPicker
            colorPicker
        }
    }

    private var iconPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(icons, id: \.self) { icon in
                    let selected = filter.iconName == icon
                    Button {
                        filter.iconName = icon
                    } label: {
                        Image(systemName: icon)
                            .font(.title3)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(selected
                                ? filter.tint.opacity(0.25) : Color.white.opacity(0.06)))
                            .foregroundStyle(selected ? filter.tint : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var colorPicker: some View {
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

    private var includeSection: some View {
        Section("Include only") {
            Toggle("Unplayed", isOn: $filter.onlyUnplayed)
            Toggle("Downloaded", isOn: $filter.onlyDownloaded)
            Toggle("Ad-free (processed)", isOn: $filter.onlyAdFree)
            Toggle("Starred", isOn: $filter.onlyStarred)
        }
    }

    private var releasedSection: some View {
        Section("Released") {
            Picker("Within", selection: $filter.withinDays) {
                Text("Any time").tag(0)
                Text("Last 24 hours").tag(1)
                Text("Last 3 days").tag(3)
                Text("Last week").tag(7)
                Text("Last month").tag(30)
            }
        }
    }

    private var lengthSection: some View {
        Section("Length") {
            Picker("Shorter than", selection: $filter.maxMinutes) {
                Text("Any").tag(0)
                ForEach(maxLengths, id: \.self) { Text("\($0) min").tag($0) }
            }
            Picker("Longer than", selection: $filter.minMinutes) {
                Text("Any").tag(0)
                ForEach(minLengths, id: \.self) { Text("\($0) min").tag($0) }
            }
        }
    }

    @ViewBuilder
    private var showsSection: some View {
        Section("Shows") {
            if filter.showFeedURLs.isEmpty {
                Text("All shows").foregroundStyle(.secondary).font(.footnote)
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
    }

    private var orderSection: some View {
        Section("Order") {
            Picker("Sort", selection: Binding(
                get: { filter.sort },
                set: { filter.sort = $0 }
            )) {
                ForEach(FilterSort.allCases) { Text($0.rawValue).tag($0) }
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
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @State private var player = PlayerEngine.shared

    /// Resolved once per appearance. Previously this was a `@Query` over every
    /// episode in the store, re-filtered and re-sorted on every render of a
    /// scrolling list.
    @State private var episodes: [Episode] = []
    @State private var totalTime: Double = 0

    private func reload() {
        let all = (try? context.fetch(FetchDescriptor<Episode>())) ?? []
        let matched = filter.apply(to: all)
        episodes = matched
        totalTime = matched.reduce(0) { $0 + $1.remainingSeconds }
    }

    var body: some View {
        List {
            summaryLine
            actionButtons
            emptyState
            episodeRows
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle(filter.name)
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .task { reload() }
        .refreshable { reload() }
    }

    private var summaryLine: some View {
        HStack(spacing: 14) {
            Label(formatMinutes(totalTime), systemImage: "clock")
            Text("\(episodes.count) episode\(episodes.count == 1 ? "" : "s")")
            Spacer()
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .plainRow(top: 4, bottom: 4)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Button { playAll() } label: {
                Label("Play All", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button { queueAll() } label: {
                Label("Queue All", systemImage: "text.append").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.small)
        .disabled(episodes.isEmpty)
        .plainRow(top: 0, bottom: 8)
    }

    @ViewBuilder
    private var emptyState: some View {
        if episodes.isEmpty {
            ContentUnavailableView("Nothing matches",
                systemImage: filter.iconName,
                description: Text("Loosen the rules, or process a few more episodes."))
                .plainRow(top: 40, bottom: 40)
        }
    }

    private var episodeRows: some View {
        ForEach(episodes) { episode in
            EpisodeCompactRow(episode: episode)
                .contentRow()
                .swipeActions(edge: .leading) {
                    Button {
                        episode.isInQueue = true
                        episode.queueOrder = 0
                        try? context.save()
                    } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
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
