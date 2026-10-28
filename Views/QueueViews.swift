import SwiftUI
import SwiftData

struct UpNextView: View {
    /// Pass 40: whether the Up Next tab is the one showing. Its `@Query`
    /// redrew this whole page on every library save — 89 times in 40 s of
    /// back-catalogue-style saves in the simulator, hidden behind another
    /// tab or not. Now the queue arrives through `LiveQuery` (present only
    /// while this tab shows), and the page redraws only when the queue's
    /// episodes or their order change.
    private let active: Bool
    @State private var queue: [Episode] = []
    @State private var queueLoaded = false

    init(active: Bool = true) { self.active = active }

    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline
    @State private var player = PlayerEngine.shared

    @State private var ahead = PrepareAhead.shared
    /// Where autoplay goes after the list — see `NextUpProvider.continuation`.
    @State private var continuation: [Episode] = []
    @State private var filter: Filter = .all
    @State private var sort: Sort = .manual
    @State private var isEditing = false
    /// Pass 43 (his 19 Oct request): choosing several, as on Saved,
    /// Downloaded, Latest Episodes, Recently Played and the stations.
    @State private var selecting = false
    @State private var selection: Set<PersistentIdentifier> = []
    @State private var drag = SelectionDrag()

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", unplayed = "Unplayed", played = "Played"
        case ready = "Ad-free", downloaded = "Downloaded", pending = "Needs AI"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .all:        return "list.bullet"
            case .unplayed:   return "circle"
            case .played:     return "checkmark.circle"
            case .ready:      return "checkmark.seal.fill"
            case .downloaded: return "arrow.down.circle.fill"
            case .pending:    return "wand.and.sparkles"
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case manual = "My Order", newest = "Newest", oldest = "Oldest"
        case shortest = "Shortest", priority = "Show Priority"
        var id: String { rawValue }
    }

    /// Everything you queued, played or not. Hiding played episodes meant an
    /// episode added to hear again simply never appeared.
    private var base: [Episode] { queue.filter(\.isLive) }

    private var visible: [Episode] {
        var list = base
        switch filter {
        case .all:        break
        case .unplayed:   list = list.filter { !$0.isPlayed }
        case .played:     list = list.filter { $0.isPlayed }
        case .ready:      list = list.filter { $0.processingState == .ready }
        case .downloaded: list = list.filter { $0.isDownloaded }
        case .pending:    list = list.filter { $0.processingState != .ready }
        }
        switch sort {
        case .manual:   return list.sorted { $0.queueOrder < $1.queueOrder }
        case .newest:   return list.sorted { $0.publishedAt > $1.publishedAt }
        case .oldest:   return list.sorted { $0.publishedAt < $1.publishedAt }
        case .shortest: return list.sorted { $0.remainingSeconds < $1.remainingSeconds }
        case .priority: return list.sorted {
            ($0.podcast?.priority ?? 0, -$0.queueOrder) > ($1.podcast?.priority ?? 0, -$1.queueOrder)
        }
        }
    }

    var body: some View {
        Group {
            if queueLoaded && base.isEmpty {
                // Pass 37: Apple Podcasts' wording for an empty queue.
                ContentUnavailableView("See Your Queue",
                    systemImage: "list.bullet",
                    description: Text("Find out what's playing next. Episodes you add with Play Next or Play Last will appear here; you can also swipe an episode right in any show."))
                    .amoledScreen()
            } else {
                list
            }
        }
        .navigationTitle(selecting ? selectionTitle(selection.count) : "Up Next")
        // Pass 48: as Apple's tab roots — the large title on the bar's line.
        .toolbarTitleDisplayMode(.inlineLarge)
        .navigationBarTitleDisplayMode(selecting ? .inline : .large)
        .amoledScreen()
        // Pinned under the title while anything is being worked on.
        .processingBanner(pipeline, publisher: FeedPublisher.shared)
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .safeAreaBar(edge: .bottom) {
            if selecting {
                EpisodeSelectionBar(chosen: chosen, pipeline: pipeline, done: endSelection) {
                    Button("Remove from Up Next", systemImage: "minus.circle") {
                        for episode in chosen { episode.removeFromUpNext(context: context) }
                        try? context.save()
                        Haptics.success()
                        endSelection()
                    }
                }
            }
        }
        .task(id: continuationKey) { refreshContinuation() }
        .background {
            if active {
                LiveQuery(FetchDescriptor<Episode>(predicate: #Predicate { $0.isInQueue },
                                                   sortBy: [SortDescriptor(\.queueOrder)])) { found in
                    queue = found
                    queueLoaded = true
                }
            }
        }
        .toolbar {
            if selecting {
                SelectionToolbar(allSelected: !visible.isEmpty && selection.count == visible.count,
                                 selectAll: { selection = Set(visible.map(\.persistentModelID)) },
                                 selectNone: { selection.removeAll() },
                                 done: endSelection)
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        // Pass 43: Select first, and the words every other
                        // page uses ("Process All" was the only one).
                        Button("Select", systemImage: "checkmark.circle") { beginSelection(with: nil) }
                            .disabled(base.isEmpty)
                        Divider()
                        Picker("Sort", selection: $sort) {
                            ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Divider()
                        if sort == .manual {
                            Button(isEditing ? "Done Reordering" : "Reorder", systemImage: "arrow.up.arrow.down") {
                                withAnimation { isEditing.toggle() }
                            }
                        }
                        let needAds = EpisodeBatch.needingAds(base, pipeline: pipeline)
                        if !needAds.isEmpty {
                            Button("Find Ads in All (\(needAds.count))", systemImage: "wand.and.sparkles") {
                                EpisodeBatch.findAds(needAds, pipeline: pipeline)
                            }
                        }
                        Button("Clear Played", systemImage: "trash", role: .destructive) { clearPlayed() }
                    } label: { PageMenuLabel(title: "Up Next Options") }
                    .feel(.selection, trigger: sort)
                    .accessibilityIdentifier("upNext.menu")
                }
            }
        }
    }

    private var chosen: [Episode] { visible.filter { selection.contains($0.persistentModelID) } }

    private func beginSelection(with episode: Episode?) {
        isEditing = false
        selection = episode.map { [$0.persistentModelID] } ?? []
        withAnimation(.snappy(duration: 0.25)) { selecting = true }
    }

    private func endSelection() {
        withAnimation(.snappy(duration: 0.25)) { selecting = false }
        selection.removeAll()
    }

    private var list: some View {
        // Filtered and sorted once per render. `visible` used to be read six
        // times in this body, each time sorting the whole queue.
        let rows = visible
        let remaining = rows.reduce(0) { $0 + $1.remainingSeconds }
        return List {
            // One filter idiom across the app. This was a scrolling chip strip
            // that ran off the right edge of the screen.
            SectionMenuBar(title: filter.rawValue) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { option in
                        Label(option.rawValue, systemImage: option.symbol).tag(option)
                    }
                }
                Divider()
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
            } trailing: {
                Button {
                    if let first = rows.first(where: { $0.isDownloaded }) ?? rows.first {
                        player.load(first)
                    }
                } label: {
                    Label("Play All", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentHot)
                .disabled(rows.isEmpty)
            }
            .feel(.selection, trigger: filter)
            .feel(.selection, trigger: sort)
            .plainRow(top: 12, bottom: 2)

            HStack(spacing: 6) {
                Image(systemName: "clock")
                Text(formatMinutes(remaining))
                Text("·")
                Text("\(rows.count) episode\(rows.count == 1 ? "" : "s")")
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .plainRow(top: 0, bottom: 6)

            ReadyAheadCard()
                .plainRow(top: 2, bottom: 8)

            // The same row as a show page — date, number, description, cover,
            // play and Find Ads — with the show named above, since Up Next
            // mixes shows. It was a compact row with no date or description,
            // and episodes added by hand looked like they had lost both.
            let order = selecting ? rows.map(\.persistentModelID) : []
            ForEach(rows) { episode in
                // Pass 44: the shared row; Remove is this page's own swipe.
                EpisodeListRow(episode: episode,
                               status: ahead.status(of: episode).map(EpisodeRowStatus.gettingReady),
                               removal: EpisodeRemoval(title: "Remove", systemImage: "minus.circle") {
                                   episode.isInQueue = false; try? context.save()
                               },
                               choosing: EpisodeChoosing(isActive: selecting,
                                                         isSelected: selection.contains(episode.persistentModelID),
                                                         drag: drag.handle(episode.persistentModelID, order: order,
                                                                           selection: $selection),
                                                         toggle: {
                                                             let id = episode.persistentModelID
                                                             if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
                                                             Haptics.select()
                                                         },
                                                         begin: { beginSelection(with: episode) }))
            }
            .onMove { indices, destination in
                guard sort == .manual, !selecting else { return }
                move(from: indices, to: destination)
            }

            if rows.isEmpty {
                ContentUnavailableView("Nothing matches that filter", systemImage: "line.3.horizontal.decrease")
                    .plainRow(top: 40, bottom: 40)
            }

            if !selecting { continuationSection }

            BottomClearance()
        }
        .listStyle(.plain)
        .selectionDragArea(drag)
        .onChange(of: queue.map(\.persistentModelID)) { PrepareAhead.shared.refresh() }
    }

    /// After the list, autoplay carries on through the playing show. Those
    /// episodes are not in Up Next — nothing was added behind your back — but
    /// they are listed, and the next few are got ready like the rest.
    @ViewBuilder
    private var continuationSection: some View {
        if !continuation.isEmpty, filter == .all {
            // Pass 46: Apple Podcasts 27.2's name for it ("Continue
            // Playing" before), the show said beside it.
            SectionHeader(title: "Coming Up") {
                Text("From \(continuation.first?.podcast?.title ?? "this show")")
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            ForEach(continuation) { episode in
                EpisodeListRow(episode: episode, showsShowName: false,
                               status: ahead.status(of: episode).map(EpisodeRowStatus.gettingReady),
                               changed: refreshContinuation)
            }
        }
    }

    private var continuationKey: String {
        "\(player.currentEpisode?.guid ?? "")|\(base.count)|\(ahead.targets.count)"
    }

    private func refreshContinuation() {
        continuation = NextUpProvider.continuation(in: context, after: player.currentEpisode, limit: 3)
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        var ordered = visible
        ordered.move(fromOffsets: offsets, toOffset: destination)
        for (index, episode) in ordered.enumerated() { episode.queueOrder = index }
        try? context.save()
    }

    private func clearPlayed() {
        for episode in base where episode.isPlayed { episode.isInQueue = false }
        try? context.save()
    }
}


// MARK: - Ready ahead

/// How "Prepare N ahead" is doing, in one line.
///
/// It used to list its episodes, and they were the same episodes listed right
/// below it in Up Next — reported as duplicated. Now the card says how many
/// are ready and what it is doing; each episode's own row says whether it is
/// ready or waiting, in Up Next or in the "Then from" list under it.
struct ReadyAheadCard: View {
    @State private var ahead = PrepareAhead.shared
    @Environment(ProcessingPipeline.self) private var pipeline
    @State private var expanded = false

    var body: some View {
        if ahead.limit > 0, !ahead.targets.isEmpty {
            let ready = ahead.targets.count - ahead.pending.count
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                    Haptics.select()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: ready == ahead.targets.count ? "checkmark.seal.fill" : "sparkles")
                            .foregroundStyle(ready == ahead.targets.count ? .green : Theme.accentHot)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Next \(ahead.targets.count): \(ready) ad-free")
                                .font(.subheadline.weight(.semibold))
                            Text(statusLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ReadyAheadHeader")

                if expanded {
                    Text("PodSkipper finds the ads in what will play next, before you get there. It takes Up Next first — episodes you haven't heard before ones you're replaying — then carries on through the show that's playing, in that show's order, skipping what you've played. It waits in Low Power Mode or when the phone is hot. Change how many in Settings → Playback.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }

                if !ahead.pending.isEmpty, !pipeline.isRunning {
                    Button {
                        Haptics.select()
                        ahead.prepareNow()
                    } label: {
                        Text("Prepare Now")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(12)
            .glassPanel(cornerRadius: Metrics.cardCorner)
        }
    }

    private var statusLine: String {
        if ahead.pending.isEmpty { return "Ready to play without ads." }
        if let current = ahead.targets.first(where: { pipeline.isProcessing($0) }) {
            return "Working on “\(current.title)”"
        }
        if let reason = pipeline.speculativePausedReason { return reason }
        if pipeline.isRunning { return "Starts when the current job finishes" }
        return "Starting shortly"
    }
}

// MARK: - Playing Next (pass 46)

/// Apple Podcasts 27.2's Playing Next, opened from the player's bottom row
/// (its iOS 27 guide: the button shows or hides the queue; the current
/// chapter's arrow lists the chapters). Now Playing with its chapters, then
/// Up Next — PodSkipper's name for the queue, as its tab — which reorders,
/// swipes to Remove and clears, then Coming Up (27.2's name for what plays
/// on from the show, "Then from …" before), as autoplay will play it.
struct PlayingNextView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var player = PlayerEngine.shared
    @State private var queue: [Episode] = []
    @State private var comingUp: [Episode] = []
    @State private var chaptersOpen = false
    @State private var confirmClear = false

    /// The queue without the episode playing.
    private var upNext: [Episode] {
        queue.filter { $0.isLive && $0.guid != player.currentEpisode?.guid }
    }

    var body: some View {
        List {
            if let episode = player.currentEpisode {
                Section("Now Playing") {
                    row(episode, playing: true)
                    let chapters = episode.chapters.sorted { $0.start < $1.start }
                    if !chapters.isEmpty {
                        DisclosureGroup(isExpanded: $chaptersOpen) {
                            ForEach(chapters, id: \.start) { chapter in
                                Button {
                                    player.seek(to: chapter.start)
                                    Haptics.select()
                                } label: {
                                    HStack {
                                        Text(chapter.title).lineLimit(2)
                                        Spacer(minLength: 8)
                                        Text(formatDuration(chapter.start)).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                    .font(.subheadline)
                                    .foregroundStyle(chapter.start == player.currentChapter?.start ? Theme.accentHot : .primary)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } label: {
                            Label(player.currentChapter?.title ?? "Chapters", systemImage: "list.bullet.indent")
                                .font(.subheadline)
                                .lineLimit(1)
                        }
                        .accessibilityIdentifier("playingNext.chapters")
                    }
                }
            }
            Section {
                if upNext.isEmpty {
                    Text("Episodes you add with Play Next or Play Last appear here.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(upNext) { episode in
                    row(episode, playing: false)
                        .swipeActions(edge: .trailing) {
                            Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                episode.removeFromUpNext(context: context)
                                try? context.save()
                            }
                        }
                }
                .onMove(perform: move)
            } header: {
                HStack {
                    Text("Up Next")
                    Spacer()
                    if !upNext.isEmpty {
                        Button("Clear") { confirmClear = true }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accentHot)
                            .textCase(nil)
                            .accessibilityIdentifier("playingNext.clear")
                    }
                }
            }
            if !comingUp.isEmpty {
                Section {
                    ForEach(comingUp) { row($0, playing: false) }
                } header: {
                    Text("Coming Up")
                } footer: {
                    Text("Autoplay goes on with \(comingUp.first?.podcast?.title ?? "this show") after Up Next.")
                }
            }
        }
        .environment(\.editMode, .constant(upNext.count > 1 ? .active : .inactive))
        .navigationTitle("Playing Next")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Done") { dismiss() } }
        .task(id: player.currentEpisode?.guid) { reload() }
        .background {
            LiveQuery(FetchDescriptor<Episode>(predicate: #Predicate { $0.isInQueue },
                                               sortBy: [SortDescriptor(\.queueOrder)])) { found in
                queue = found
                reload()
            }
        }
        .alert("Clear Up Next?", isPresented: $confirmClear) {
            Button("Clear Episodes", role: .destructive) {
                for episode in upNext { episode.removeFromUpNext(context: context) }
                try? context.save()
            }
            Button("Keep Listening", role: .cancel) {}
        } message: {
            Text("The episodes stay in your library.")
        }
        .accessibilityIdentifier("PlayingNext")
    }

    private func row(_ episode: Episode, playing: Bool) -> some View {
        Button {
            guard !playing else { return }
            player.load(episode)
            Haptics.select()
        } label: {
            HStack(spacing: 12) {
                Artwork(url: episode.artworkURL ?? episode.podcast?.artworkURL, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(episode.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text([episode.podcast?.title ?? "", formatMinutes(episode.remainingSeconds)]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if playing {
                    Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                        .foregroundStyle(Theme.accentHot)
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(playing ? "" : "Plays this episode")
    }

    private func reload() {
        comingUp = NextUpProvider.continuation(in: context, after: player.currentEpisode, limit: 3)
            .filter { candidate in !queue.contains { $0.guid == candidate.guid } }
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        var ordered = upNext
        ordered.move(fromOffsets: offsets, toOffset: destination)
        for (index, episode) in ordered.enumerated() { episode.queueOrder = index }
        try? context.save()
    }
}
