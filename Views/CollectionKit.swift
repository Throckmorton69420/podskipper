import SwiftUI
import SwiftData

// Pass 39 (his 15 Oct request): every Library collection — Saved,
// Downloaded, Latest Episodes, Recently Played, a station, Bookmarks — is
// built from the same pieces, so they look and behave alike: a large title,
// the activity bar pinned under it, a ⋯ menu top right with what can be
// done to the whole page (including what was only in a long press), Select
// for choosing several, and one bar of actions for what is chosen. The show
// page's own selection (publishing included) stays as it is; these are its
// actions for pages that list episodes from many shows.

/// What can be done to several episodes at once, wherever they are listed.
@MainActor
enum EpisodeBatch {
    static func markPlayed(_ episodes: [Episode], _ played: Bool, context: ModelContext) {
        for episode in episodes {
            episode.isPlayed = played
            if played { episode.isNew = false; episode.isInQueue = false }
        }
        finish(context, episodes)
    }

    /// To the end of Up Next, in the order given.
    static func playLast(_ episodes: [Episode], context: ModelContext) {
        let queued = (try? context.fetch(FetchDescriptor<Episode>(predicate: #Predicate { $0.isInQueue }))) ?? []
        var order = (queued.map(\.queueOrder).max() ?? -1) + 1
        for episode in episodes where !episode.isInQueue {
            if episode.isPlayed { episode.playbackPosition = 0 }
            episode.isInQueue = true
            episode.queueOrder = order
            order += 1
        }
        PrepareAhead.shared.refresh()
        finish(context, episodes)
    }

    /// To the front of Up Next, keeping their order.
    static func playNext(_ episodes: [Episode], context: ModelContext) {
        for episode in episodes.reversed() { episode.addToUpNext(next: true, context: context) }
        PrepareAhead.shared.refresh()
        finish(context, episodes)
    }

    static func needingAds(_ episodes: [Episode], pipeline: ProcessingPipeline) -> [Episode] {
        episodes.filter { $0.processingState != .ready && !pipeline.isProcessing($0) }
    }

    static func findAds(_ episodes: [Episode], pipeline: ProcessingPipeline) {
        let targets = needingAds(episodes, pipeline: pipeline)
        guard !targets.isEmpty else { return }
        pipeline.cancelBackgroundWork()
        Task { await pipeline.process(targets) }
        Haptics.success()
    }

    static func download(_ episodes: [Episode], context: ModelContext) {
        let targets = episodes.filter { !$0.isDownloaded }
        Haptics.success()
        Task {
            for episode in targets { _ = await DownloadManager.fetchAudio(for: episode) }
            try? context.save()
            LibraryTotals.shared.invalidate()
        }
    }

    /// Never the one that is playing: its file is open.
    static func removeDownloads(_ episodes: [Episode], context: ModelContext) {
        let playing = PlayerEngine.shared.currentEpisode?.guid
        for episode in episodes where episode.isDownloaded && episode.guid != playing {
            DownloadManager.remove(episode)
        }
        finish(context, episodes)
    }

    static func setSaved(_ episodes: [Episode], _ saved: Bool, context: ModelContext) {
        for episode in episodes { episode.isStarred = saved }
        finish(context, episodes)
    }

    static func archive(_ episodes: [Episode], context: ModelContext) {
        for episode in episodes { episode.isArchived = true; episode.isInQueue = false }
        finish(context, episodes)
    }

    private static func finish(_ context: ModelContext, _ episodes: [Episode] = []) {
        try? context.save()
        // One count pass covers every show's numbers and the Library's.
        LibraryTotals.shared.invalidate()
        Haptics.success()
    }
}

/// A row with a tick beside it while choosing; the row's own buttons are off
/// so a tap anywhere ticks it (the show page's rule).
///
/// Pass 41: with `drag`, touching the tick and sliding up or down through
/// the ticks of the rows next to it chooses them all (`SelectionDrag`). A
/// drag that starts anywhere else on the row still scrolls.
struct SelectionRow<Content: View>: View {
    let isSelected: Bool
    var drag: SelectionDrag.Handle? = nil
    let toggle: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SelectionTick(isSelected: isSelected, drag: drag, toggle: toggle)
            content.allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .feel(.selection, trigger: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("SelectableRow")
        .selectionDragFrame(drag)
    }
}

/// The tick at the start of a row being chosen. With a drag handle, the
/// whole height of the row in this column is where a run starts: a tap
/// there ticks or unticks the row, a slide carries on through its
/// neighbours.
struct SelectionTick: View {
    let isSelected: Bool
    var drag: SelectionDrag.Handle?
    var toggle: () -> Void = {}
    @GestureState private var touching = false

    var body: some View {
        let tick = Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .foregroundStyle(isSelected ? Theme.accentHot : Color.secondary)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 28)
        if let drag {
            tick
                .frame(width: 44)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, -8)
                .contentShape(Rectangle())
                // Its own tap: a quick tap here was taken by the list's row
                // (which opened the episode) before a zero-distance drag
                // claimed it, in the simulator.
                .onTapGesture(perform: toggle)
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .updating($touching) { _, touching, _ in touching = true }
                    .onChanged { drag.move($0.location.y, from: $0.startLocation.y) }
                    .onEnded { _ in drag.end() })
                // Cancelled rather than ended (a call, the system taking the
                // touch): `onEnded` never comes, this does.
                .onChange(of: touching) { _, now in if !now { drag.end() } }
                .accessibilityIdentifier("SelectionTick")
        } else {
            tick
        }
    }
}

/// Pass 41 (his 16 Oct request): choosing a run of rows in one movement, as
/// in Mail and Files — touch a row's tick and slide up or down through the
/// ticks of the rows beside it. Starting on an unticked row ticks the run,
/// starting on a ticked one unticks it. Rows the finger comes back across
/// return to what they were before the drag, so nothing flickers. Holding
/// the finger near the top or bottom of the list scrolls it and carries on.
///
/// One per page (`@State`), not observed: rows report where they are (only
/// while choosing) and the page's selection binding is the only state that
/// changes. The list goes inside `.selectionDragArea(_:)`.
@MainActor
@Observable
final class SelectionDrag {

    /// A run is being chosen: the list holds still under the finger (read
    /// only by `selectionDragArea`). Without it the list's own pan took the
    /// touch over a row or two in and cancelled the run.
    private(set) var isDragging = false

    /// What a row hands its tick: the page's order and selection, at this
    /// render.
    struct Handle {
        let drag: SelectionDrag
        let id: AnyHashable
        let order: () -> [AnyHashable]
        let selection: () -> Set<AnyHashable>
        let set: (Set<AnyHashable>) -> Void

        @MainActor func move(_ y: CGFloat, from start: CGFloat) { drag.move(self, y: y, start: start) }
        @MainActor func end() { drag.end() }
    }

    func handle<ID: Hashable>(_ id: ID, order: [ID], selection: Binding<Set<ID>>) -> Handle {
        Handle(drag: self, id: AnyHashable(id),
               order: { order.map(AnyHashable.init) },
               selection: { Set(selection.wrappedValue.map(AnyHashable.init)) },
               set: { selection.wrappedValue = Set($0.compactMap { $0.base as? ID }) })
    }

    @ObservationIgnored fileprivate var frames: [AnyHashable: CGRect] = [:]
    /// The list's top and bottom on screen. Everything is in screen
    /// coordinates: inside a list's cells a named coordinate space reached
    /// row frames but not the tick's drag, which came back in the tick's own.
    @ObservationIgnored fileprivate var frame: CGRect = .zero
    private var bounds: ClosedRange<CGFloat> { frame.minY...frame.maxY }
    @ObservationIgnored fileprivate var scrollTo: ((AnyHashable, UnitPoint) -> Void)?

    @ObservationIgnored private var active: Handle?
    @ObservationIgnored private var started: CGFloat?
    @ObservationIgnored private var order: [AnyHashable] = []
    @ObservationIgnored private var anchor = 0
    @ObservationIgnored private var current = 0
    @ObservationIgnored private var ticking = true
    @ObservationIgnored private var before: Set<AnyHashable> = []
    @ObservationIgnored private var applied: Set<AnyHashable> = []
    @ObservationIgnored private var edge: Task<Void, Never>?
    @ObservationIgnored private var edgeStep = 0

    /// How close to the top or bottom of the list the finger scrolls it,
    /// and how long it must stay there first: a finger resting on the last
    /// row on screen is choosing that row, not asking for more.
    private let edgeBand: CGFloat = 36
    private let edgeDelay: Duration = .milliseconds(350)

    private func move(_ handle: Handle, y: CGFloat, start: CGFloat) {
        // A new touch while an old one never ended (cancelled by the
        // system): start over from this one.
        if active != nil, started != start { end() }
        if active == nil {
            started = start
            isDragging = true
            order = handle.order()
            guard let start = order.firstIndex(of: handle.id) else { return }
            active = handle
            anchor = start
            current = start
            before = handle.selection()
            applied = before
            ticking = !before.contains(handle.id)
            apply()
            return
        }
        if let index = row(at: y) { current = index }
        let step = y > bounds.upperBound - edgeBand ? 1 : y < bounds.lowerBound + edgeBand ? -1 : 0
        if step == 0 { apply() }
        follow(step)
    }

    func end() {
        edge?.cancel(); edge = nil; edgeStep = 0
        active = nil
        started = nil
        order = []
        if isDragging { isDragging = false }
    }

    /// The row under the finger, from the frames the rows reported.
    private func row(at y: CGFloat) -> Int? {
        for (id, frame) in frames where frame.minY <= y && y < frame.maxY {
            return order.firstIndex(of: id)
        }
        return nil
    }

    private func apply() {
        guard let active else { return }
        var next = before
        for id in order[min(anchor, current)...max(anchor, current)] {
            if ticking { next.insert(id) } else { next.remove(id) }
        }
        guard next != applied else { return }
        applied = next
        active.set(next)
        Haptics.select()
    }

    /// Held near an edge: after a moment, a row further every tenth of a
    /// second, scrolled into view, until the finger moves away or lifts.
    private func follow(_ step: Int) {
        guard step != edgeStep else { return }
        edgeStep = step
        edge?.cancel(); edge = nil
        guard step != 0 else { return }
        let delay = edgeDelay
        edge = Task { [weak self] in
            try? await Task.sleep(for: delay)
            while !Task.isCancelled {
                guard let self, self.active != nil else { return }
                let next = self.current + step
                guard self.order.indices.contains(next) else { return }
                self.current = next
                self.apply()
                withAnimation(.linear(duration: 0.1)) {
                    self.scrollTo?(self.order[next], step > 0 ? .bottom : .top)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

extension View {
    /// The list a `SelectionDrag` works in: where it is, a way to scroll it,
    /// and holding it still during a run.
    func selectionDragArea(_ drag: SelectionDrag) -> some View {
        ScrollViewReader { proxy in
            self
                .scrollDisabled(drag.isDragging)
                // Its layout frame is the part no bar covers (the scroll
                // view runs on under the bars, inset), on collections and the
                // show page alike (logged in the simulator).
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { drag.frame = $0 }
                .onAppear { drag.scrollTo = { id, anchor in proxy.scrollTo(id, anchor: anchor) } }
        }
    }

    /// Where this row is in the list, while it can be dragged through.
    @ViewBuilder
    func selectionDragFrame(_ handle: SelectionDrag.Handle?) -> some View {
        if let handle {
            self
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
                    handle.drag.frames[handle.id] = $0
                }
                .onDisappear { handle.drag.frames[handle.id] = nil }
        } else {
            self
        }
    }
}

/// Select All / Done in the navigation bar while choosing.
struct SelectionToolbar: ToolbarContent {
    let allSelected: Bool
    let selectAll: () -> Void
    let selectNone: () -> Void
    let done: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(allSelected ? "Select None" : "Select All") {
                Haptics.select()
                allSelected ? selectNone() : selectAll()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Done", role: .confirm, action: done)
                .accessibilityIdentifier("selection.done")
        }
    }
}

/// "3 Selected", or "Select" before anything is chosen.
func selectionTitle(_ count: Int) -> String { count == 0 ? "Select" : "\(count) Selected" }

/// The bar of actions for chosen episodes, above the tab bar and the
/// now-playing bar (the show page's panel, without publishing).
struct EpisodeSelectionBar<More: View>: View {
    let chosen: [Episode]
    let pipeline: ProcessingPipeline
    let done: () -> Void
    /// Page-specific items at the top of the bar's ⋯ menu (Unsave on Saved…).
    @ViewBuilder var more: More
    @Environment(\.modelContext) private var context

    var body: some View {
        let allPlayed = !chosen.isEmpty && chosen.allSatisfy(\.isPlayed)
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    EpisodeBatch.markPlayed(chosen, !allPlayed, context: context); done()
                } label: {
                    BarLabel(title: allPlayed ? "Unplayed" : "Played",
                                     systemImage: allPlayed ? "circle" : "checkmark.circle")
                }
                .buttonStyle(.glass)
                .disabled(chosen.isEmpty)

                Button {
                    EpisodeBatch.findAds(chosen, pipeline: pipeline); done()
                } label: {
                    BarLabel(title: "Find Ads", systemImage: "wand.and.sparkles")
                }
                .buttonStyle(.glass)
                .disabled(EpisodeBatch.needingAds(chosen, pipeline: pipeline).isEmpty)

                Button {
                    EpisodeBatch.playLast(chosen, context: context); done()
                } label: {
                    BarLabel(title: "Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
                .buttonStyle(.glass)
                .disabled(chosen.isEmpty)

                Menu {
                    more
                    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        EpisodeBatch.playNext(chosen, context: context); done()
                    }
                    if chosen.contains(where: { !$0.isDownloaded }) {
                        Button("Download", systemImage: "arrow.down.circle") {
                            EpisodeBatch.download(chosen, context: context); done()
                        }
                    }
                    if chosen.contains(where: \.isDownloaded) {
                        Button("Remove Download", systemImage: "trash") {
                            EpisodeBatch.removeDownloads(chosen, context: context); done()
                        }
                    }
                    let allSaved = chosen.allSatisfy(\.isStarred)
                    Button(allSaved ? "Unsave" : "Save", systemImage: allSaved ? "star.slash" : "star") {
                        EpisodeBatch.setSaved(chosen, !allSaved, context: context); done()
                    }
                    Divider()
                    Button("Archive", systemImage: "archivebox", role: .destructive) {
                        EpisodeBatch.archive(chosen, context: context); done()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 34, height: 24)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Selection Actions")
                .accessibilityIdentifier("Selection Actions")
                .disabled(chosen.isEmpty)
            }
            .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.bottom, 8)
    }
}

/// One line, as the show page's Publish button: two-line labels made the
/// bar's capsules uneven (Pass 39 simulator check).
private struct BarLabel: View {
    let title: String
    let systemImage: String
    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
    }
}

extension EpisodeSelectionBar where More == EmptyView {
    init(chosen: [Episode], pipeline: ProcessingPipeline, done: @escaping () -> Void) {
        self.init(chosen: chosen, pipeline: pipeline, done: done) { EmptyView() }
    }
}

/// The ⋯ label every collection's page menu uses.
struct PageMenuLabel: View {
    var title = "More"
    var body: some View {
        Label(title, systemImage: "ellipsis")
    }
}
