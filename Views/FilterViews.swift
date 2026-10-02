import SwiftUI
import SwiftData
import Combine

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

    @State private var nextUp: [PersistentIdentifier: String] = [:]

    /// Each station asked of the store with its own rules, rather than every
    /// episode in the library loaded and tested against every station.
    private func reloadCounts() {
        var result: [PersistentIdentifier: Int] = [:]
        var next: [PersistentIdentifier: String] = [:]
        for filter in filters {
            let found = filter.episodes(in: context)
            result[filter.persistentModelID] = found.count
            if let first = found.first {
                next[filter.persistentModelID] = found.count > 1
                    ? "Next: \(first.title) and \(found.count - 1) more"
                    : "Next: \(first.title)"
            }
        }
        counts = result
        nextUp = next
    }

    var body: some View {
        Group {
            if filters.isEmpty {
                ContentUnavailableView("No Stations",
                    systemImage: "square.stack.3d.up",
                    description: Text("A station fills itself from the shows and rules you choose — unplayed, newest three from each show, under 45 minutes."))
            } else {
                list
            }
        }
        .navigationTitle("Stations")
        .amoledScreen()
        .task { reloadCounts() }
        .onChange(of: filters.count) { _, _ in reloadCounts() }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { notification in
                if StationStoreChanges.affectsStations(notification, context: context) { reloadCounts() }
            }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let filter = SmartFilter(name: "New Station", order: filters.count)
                    context.insert(filter)
                    try? context.save()
                    editing = filter
                } label: {
                    // Apple renamed this "Create Station" in 27.2.
                    Label("Create Station", systemImage: "plus").labelStyle(.iconOnly)
                }
            }
        }
        .sheet(item: $editing) { filter in
            NavigationStack { FilterEditor(filter: filter) }
                .glassSheet()
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
                            Text(nextUp[filter.persistentModelID] ?? filter.summary)
                                .font(.footnote).foregroundStyle(.secondary)
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
                        Feel.warning.play()
                        context.delete(filter); try? context.save()
                    } label: { Label("Delete", systemImage: "trash") }
                    Button {
                        Feel.confirm.play()
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
    @State private var saveFailure: String?

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
        .navigationTitle("Station Settings")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .toolbar {
            Button("Done") {
                do { try context.save(); dismiss() }
                catch { saveFailure = error.localizedDescription }
            }
            .accessibilityIdentifier("station.settings.save")
        }
        .alert("Couldn't Save Station", isPresented: Binding(
            get: { saveFailure != nil }, set: { if !$0 { saveFailure = nil } })) {
                Button("OK", role: .cancel) { saveFailure = nil }
            } message: { Text(saveFailure ?? "") }
    }

    private var nameSection: some View {
        Section("Name") {
            TextField("Station name", text: $filter.name)
                .accessibilityIdentifier("station.settings.name")
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
            .feel(.selection, trigger: filter.withinDays)
        }
    }

    private var lengthSection: some View {
        Section("Length") {
            Picker("Shorter than", selection: $filter.maxMinutes) {
                Text("Any").tag(0)
                ForEach(maxLengths, id: \.self) { Text("\($0) min").tag($0) }
            }
            .feel(.selection, trigger: filter.maxMinutes)
            Picker("Longer than", selection: $filter.minMinutes) {
                Text("Any").tag(0)
                ForEach(minLengths, id: \.self) { Text("\($0) min").tag($0) }
            }
            .feel(.selection, trigger: filter.minMinutes)
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
            Picker("Episodes to Include", selection: Binding(
                get: { filter.perShow },
                set: { filter.perShow = $0 }
            )) {
                Text("All Matching").tag(0)
                Text("Newest 1 per Show").tag(1)
                Text("Newest 3 per Show").tag(3)
                Text("Newest 5 per Show").tag(5)
                Text("Newest 10 per Show").tag(10)
            }
            .feel(.selection, trigger: filter.perShow)
            Picker("Sort", selection: Binding(
                get: { filter.sort },
                set: { selected in
                    if selected == .manual && filter.manualEpisodeGUIDs.isEmpty {
                        filter.manualEpisodeGUIDs = StationEpisodeOrder.replacingVisibleOrder(
                            existing: filter.manualEpisodeGUIDs, with: filter.episodes(in: context).map(\.guid))
                    }
                    filter.sort = selected
                }
            )) {
                ForEach(FilterSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .feel(.selection, trigger: filter.sort)
            .accessibilityIdentifier("station.settings.sort")
            Toggle("Group by Show", isOn: $filter.groupByShow)
                .accessibilityIdentifier("station.settings.groupByShow")
            if filter.sort == .manual {
                Text("Use Episode Order in the station's menu to arrange matching episodes.")
                    .font(.footnote).foregroundStyle(.secondary)
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

@MainActor
enum StationQueue {
    enum Placement: Equatable { case append, playFirst }

    /// Append preserves the existing queue; Play All puts the station's
    /// visible order first, followed by unrelated queued episodes.
    static func plan(ordered: [Episode], existing: [Episode], placement: Placement) -> [Episode] {
        var seen = Set<String>()
        let candidates = placement == .playFirst ? ordered + existing : existing + ordered
        return candidates.filter { seen.insert($0.guid).inserted }
    }

    @discardableResult
    static func enqueue(_ ordered: [Episode], in context: ModelContext, placement: Placement,
                        refreshDerivedState: Bool = true) throws -> [Episode] {
        let existing = try context.fetch(FetchDescriptor<Episode>(predicate: #Predicate { $0.isInQueue }))
            .sorted { $0.queueOrder == $1.queueOrder ? $0.guid < $1.guid : $0.queueOrder < $1.queueOrder }
        let planned = plan(ordered: ordered, existing: existing, placement: placement)
        var seen = Set<ObjectIdentifier>()
        let affected = (existing + ordered).filter { seen.insert(ObjectIdentifier($0)).inserted }
        let previous = affected.map { ($0, $0.isInQueue, $0.queueOrder) }
        let positions = Dictionary(uniqueKeysWithValues: planned.enumerated().map { (ObjectIdentifier($0.element), $0.offset) })
        for episode in affected {
            if let position = positions[ObjectIdentifier(episode)] {
                episode.isInQueue = true
                episode.queueOrder = position
            } else {
                episode.isInQueue = false
            }
        }
        do { try context.save() }
        catch {
            for (episode, queued, order) in previous { episode.isInQueue = queued; episode.queueOrder = order }
            throw error
        }
        if refreshDerivedState {
            CountsCache.invalidate()
            LibraryTotals.shared.invalidate()
            PrepareAhead.shared.refresh()
        }
        return planned
    }
}

struct FilterResultsView: View {
    let filter: SmartFilter
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(AppSettings.self) private var settings
    @State private var queueFailure: String?
    @State private var editing: Editor?
    private enum Editor: String, Identifiable {
        case settings, order
        var id: String { rawValue }
    }

    /// Resolved once per appearance. Previously this was a `@Query` over every
    /// episode in the store, re-filtered and re-sorted on every render of a
    /// scrolling list.
    @State private var episodes: [Episode] = []
    @State private var totalTime: Double = 0

    private func reload() {
        let matched = filter.episodes(in: context)
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
        .accessibilityIdentifier("station.results")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .alert("Couldn't Update Up Next", isPresented: Binding(
            get: { queueFailure != nil }, set: { if !$0 { queueFailure = nil } })) {
                Button("OK", role: .cancel) { queueFailure = nil }
            } message: { Text(queueFailure ?? "") }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { notification in
                if StationStoreChanges.affectsStations(notification, context: context) { reload() }
            }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Station Settings", systemImage: "slider.horizontal.3") { editing = .settings }
                        .accessibilityIdentifier("station.settings.open")
                    Button("Episode Order", systemImage: "arrow.up.arrow.down") { editing = .order }
                        .disabled(episodes.isEmpty)
                        .accessibilityIdentifier("station.order.open")
                } label: { Label("Station Options", systemImage: "ellipsis") }
                .accessibilityIdentifier("station.options")
            }
        }
        .sheet(item: $editing, onDismiss: reload) { editor in
            NavigationStack {
                switch editor {
                case .settings: FilterEditor(filter: filter)
                case .order: StationOrderView(filter: filter)
                }
            }
            .glassSheet(detents: [.large])
        }
        .refreshable {
            reload()
            Feel.selection.play()
        }
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
                GlassButtonLabel(title: "Play All", systemImage: "play.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accentHot)
            .accessibilityIdentifier("station.playAll")

            Button { queueAll() } label: {
                GlassButtonLabel(title: "Queue All", systemImage: "text.append")
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("station.queueAll")
        }
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

    @ViewBuilder
    private var episodeRows: some View {
        if filter.groupByShow {
            ForEach(StationEpisodeOrder.groups(in: episodes)) { group in
                Section {
                    ForEach(group.episodes) { episode in episodeRow(episode) }
                } header: {
                    Text(group.title).font(.headline)
                        .accessibilityIdentifier("station.group.\(group.id)")
                }
            }
        } else {
            ForEach(episodes) { episode in episodeRow(episode) }
        }
    }

    private func episodeRow(_ episode: Episode) -> some View {
        EpisodeCompactRow(episode: episode)
                .accessibilityIdentifier("station.episode.\(episode.guid)")
                .contentRow()
                .swipeActions(edge: .leading) {
                    Button {
                        Feel.confirm.play()
                        episode.addToUpNext(next: true, context: context)
                    } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                    .tint(Theme.accentHot)
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        Feel.confirm.play()
                        episode.isStarred.toggle(); try? context.save()
                    } label: {
                        Label("Star", systemImage: episode.isStarred ? "star.slash" : "star")
                    }
                    .tint(.yellow)
                }
    }

    private func queueAll() {
        do { try StationQueue.enqueue(episodes, in: context, placement: .append) }
        catch { queueFailure = error.localizedDescription }
    }

    private func playAll() {
        guard let first = episodes.first else { return }
        do {
            try StationQueue.enqueue(episodes, in: context, placement: .playFirst)
            PlayCoordinator.play(first, settings: settings, pipeline: pipeline)
        } catch { queueFailure = error.localizedDescription }
    }
}
