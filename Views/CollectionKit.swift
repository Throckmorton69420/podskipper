import SwiftUI
import UIKit
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

    /// Pass 43 (his 19 Oct request): episodes already done, not running or
    /// waiting — for Find Ads Again on several at once. Cuts he confirmed,
    /// edited or rejected stay as he left them; the rest are found afresh.
    static func doneBefore(_ episodes: [Episode], pipeline: ProcessingPipeline) -> [Episode] {
        episodes.filter { $0.processingState == .ready && !pipeline.isProcessing($0) && !pipeline.isWaiting($0.guid) }
    }

    static func findAdsAgain(_ episodes: [Episode], pipeline: ProcessingPipeline) {
        let targets = doneBefore(episodes, pipeline: pipeline)
        guard !targets.isEmpty else { return }
        pipeline.cancelBackgroundWork()
        pipeline.processNow(targets)
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
/// there ticks or unticks the row; a slide is the list's (`SelectionPan`).
struct SelectionTick: View {
    let isSelected: Bool
    var drag: SelectionDrag.Handle?
    var toggle: () -> Void = {}

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
                // (which opened the episode), in the simulator.
                .onTapGesture(perform: toggle)
                // Where the column is, for the list's pan to know a touch
                // started in it.
                .onGeometryChange(for: ClosedRange<CGFloat>.self, of: {
                    let f = $0.frame(in: .global); return f.minX...f.maxX
                }) { drag.drag.column = $0 }
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
/// Pass 42 (his 18 Oct phone: the list didn't scroll along). Pass 41's drag
/// was a SwiftUI gesture on the first row's tick, and the edge stepped one
/// row every tenth of a second with `scrollTo`. A list recycles a row once
/// it scrolls out of sight, and the gesture went with it — the run ended
/// about a screen later; the stepping moved the selection by index rather
/// than by what was under the finger, in visible jumps. Now the touch is a
/// UIKit pan on the list's own scroll view (`SelectionPan`), which lives as
/// long as the list; the finger's position is kept while it rests, and a
/// display link scrolls the list every frame at a speed set by how far into
/// the edge the finger is, then chooses through the row under the finger.
/// The edges are the scroll view's own uncovered area (bars and the mini
/// player are in its insets).
///
/// One per page (`@State`): rows report where they are (only while
/// choosing) and the page's selection binding is the only state that
/// changes. The list goes inside `.selectionDragArea(_:)`.
@MainActor
final class SelectionDrag {

    /// What a row hands its tick: the page's order and selection, at this
    /// render.
    struct Handle {
        let drag: SelectionDrag
        let id: AnyHashable
        let order: () -> [AnyHashable]
        let selection: () -> Set<AnyHashable>
        let set: (Set<AnyHashable>) -> Void
    }

    func handle<ID: Hashable>(_ id: ID, order: [ID], selection: Binding<Set<ID>>) -> Handle {
        Handle(drag: self, id: AnyHashable(id),
               order: { order.map(AnyHashable.init) },
               selection: { Set(selection.wrappedValue.map(AnyHashable.init)) },
               set: { selection.wrappedValue = Set($0.compactMap { $0.base as? ID }) })
    }

    /// Rows on screen, in screen coordinates, with their latest handle.
    fileprivate var rows: [AnyHashable: (frame: CGRect, handle: Handle)] = [:]
    /// The tick column's left and right on screen.
    fileprivate var column: ClosedRange<CGFloat>?

    private var active: Handle?
    private var order: [AnyHashable] = []
    private var anchor = 0
    private var current = 0
    private var ticking = true
    private var before: Set<AnyHashable> = []
    private var applied: Set<AnyHashable> = []
    private var lastHaptic = Date.distantPast

    private weak var scrollView: UIScrollView?
    /// Where the finger is on screen, kept while it rests.
    private var finger: CGPoint = .zero
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var edgeSince: CFTimeInterval?

    /// The edge: how deep the band is, the slowest and fastest scroll, and
    /// how long the finger rests in it first (a finger on the last row on
    /// screen is choosing that row).
    static let edgeBand: CGFloat = 64
    static let slowest: CGFloat = 90
    static let fastest: CGFloat = 1_100
    static let edgeDelay: CFTimeInterval = 0.3

    /// A touch on the tick of a row that is being chosen.
    fileprivate func shouldBegin(at point: CGPoint) -> Bool {
        guard let column, column.contains(point.x) || abs(point.x - column.lowerBound) < 4 else { return false }
        return row(at: point.y) != nil
    }

    fileprivate func begin(at start: CGPoint, now point: CGPoint, in scrollView: UIScrollView?) {
        end()
        guard let (id, handle) = row(at: start.y) else { return }
        order = handle.order()
        guard let index = order.firstIndex(of: id) else { order = []; return }
        self.scrollView = scrollView
        active = handle
        anchor = index
        current = index
        before = handle.selection()
        applied = before
        ticking = !before.contains(id)
        apply()
        move(to: point)
        let link = CADisplayLink(target: LinkTarget(self), selector: #selector(LinkTarget.step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastFrame = 0
    }

    fileprivate func move(to point: CGPoint) {
        guard active != nil else { return }
        finger = point
        choose()
    }

    func end() {
        link?.invalidate(); link = nil
        edgeSince = nil
        active = nil
        order = []
    }

    /// The uncovered part of the list on screen.
    private var visible: ClosedRange<CGFloat>? {
        guard let scrollView, let window = scrollView.window else { return nil }
        let frame = scrollView.convert(scrollView.bounds, to: window)
        let insets = scrollView.adjustedContentInset
        let top = frame.minY + insets.top, bottom = frame.maxY - insets.bottom
        return top < bottom ? top...bottom : nil
    }

    /// Through the row under the finger (held inside the uncovered part, so
    /// a finger over a bar chooses the last row that can be seen).
    private func choose() {
        var y = finger.y
        if let visible { y = min(max(y, visible.lowerBound + 1), visible.upperBound - 1) }
        if let (id, _) = row(at: y), let index = order.firstIndex(of: id) { current = index }
        apply()
    }

    /// Every frame while choosing: scroll if the finger is in an edge band.
    fileprivate func step(_ link: CADisplayLink) {
        guard active != nil, let scrollView, let visible else { return }
        let now = link.timestamp
        let dt = lastFrame == 0 ? 0 : min(0.05, now - lastFrame)
        lastFrame = now
        let band = min(Self.edgeBand, (visible.upperBound - visible.lowerBound) / 4)
        let depth: CGFloat
        if finger.y > visible.upperBound - band {
            depth = min(1, (finger.y - (visible.upperBound - band)) / band)
        } else if finger.y < visible.lowerBound + band {
            depth = -min(1, ((visible.lowerBound + band) - finger.y) / band)
        } else {
            edgeSince = nil
            return
        }
        if edgeSince == nil { edgeSince = now }
        guard let since = edgeSince, now - since >= Self.edgeDelay, dt > 0 else { return }
        let speed = Self.slowest + (Self.fastest - Self.slowest) * depth.magnitude * depth.magnitude
        let insets = scrollView.adjustedContentInset
        let lowest = -insets.top
        let highest = max(lowest, scrollView.contentSize.height + insets.bottom - scrollView.bounds.height)
        let y = scrollView.contentOffset.y
        let next = min(max(lowest, y + (depth > 0 ? 1 : -1) * speed * dt), highest)
        guard abs(next - y) > 0.01 else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: next), animated: false)
        // The rows' frames follow the scroll a moment later; the row under
        // a resting finger is found again on the next frames too.
        choose()
    }

    /// The row under a screen height, from the frames the rows reported.
    private func row(at y: CGFloat) -> (AnyHashable, Handle)? {
        for (id, row) in rows where row.frame.minY <= y && y < row.frame.maxY {
            return (id, row.handle)
        }
        return nil
    }

    private func apply() {
        guard let active, order.indices.contains(anchor), order.indices.contains(current) else { return }
        var next = before
        for id in order[min(anchor, current)...max(anchor, current)] {
            if ticking { next.insert(id) } else { next.remove(id) }
        }
        guard next != applied else { return }
        applied = next
        active.set(next)
        // One tick a row, but not a buzz while the list runs past quickly.
        if Date().timeIntervalSince(lastHaptic) > 0.05 {
            lastHaptic = Date()
            Haptics.select()
        }
    }

    /// CADisplayLink keeps its target; this keeps the drag weakly.
    private final class LinkTarget: NSObject {
        weak var drag: SelectionDrag?
        init(_ drag: SelectionDrag) { self.drag = drag }
        @objc func step(_ link: CADisplayLink) {
            MainActor.assumeIsolated {
                guard let drag else { link.invalidate(); return }
                drag.step(link)
            }
        }
    }
}

/// Pass 42: the touch that chooses a run, as a UIKit pan on the list. It
/// only takes touches that start in the tick column of a row being chosen;
/// for those the list's own pan waits for it, so the list doesn't scroll
/// under the finger. Anywhere else it never sees the touch and the list
/// scrolls as always.
struct SelectionPan: UIGestureRecognizerRepresentable {
    let drag: SelectionDrag

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator(drag: drag) }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.drag = drag
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let drag = context.coordinator.drag
        let point = pan.location(in: nil)
        switch pan.state {
        case .began:
            // From where the finger came down, not where the pan was
            // recognised ten points later (which can be the next row).
            drag.begin(at: context.coordinator.touchDown ?? point, now: point,
                       in: context.coordinator.scrollView)
        case .changed:
            drag.move(to: point)
        default:
            drag.end()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var drag: SelectionDrag
        weak var scrollView: UIScrollView?
        var touchDown: CGPoint?
        init(drag: SelectionDrag) { self.drag = drag }

        func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            let point = touch.location(in: nil)
            let takes = MainActor.assumeIsolated { drag.shouldBegin(at: point) }
            touchDown = takes ? point : nil
            // The list is the nearest scroll view above the touched row.
            if takes {
                var view = touch.view
                while let v = view, !(v is UIScrollView) { view = v.superview }
                if let list = view as? UIScrollView { scrollView = list }
            }
            return takes
        }

        /// The list's pan (found here, the one scroll view under the touch)
        /// waits for this one.
        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard let list = other.view as? UIScrollView, other === list.panGestureRecognizer else { return false }
            scrollView = list
            return true
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            if let list = other.view as? UIScrollView, other === list.panGestureRecognizer { scrollView = list }
            return false
        }
    }
}

extension View {
    /// The list a `SelectionDrag` works in.
    func selectionDragArea(_ drag: SelectionDrag) -> some View {
        gesture(SelectionPan(drag: drag))
    }

    /// Where this row is in the list, while it can be dragged through.
    @ViewBuilder
    func selectionDragFrame(_ handle: SelectionDrag.Handle?) -> some View {
        if let handle {
            self
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) {
                    handle.drag.rows[handle.id] = ($0, handle)
                }
                .onDisappear { handle.drag.rows[handle.id] = nil }
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

                // Pass 43: Find Ads Again when everything chosen is done.
                let needAds = EpisodeBatch.needingAds(chosen, pipeline: pipeline)
                let again = needAds.isEmpty && !EpisodeBatch.doneBefore(chosen, pipeline: pipeline).isEmpty
                Button {
                    if again { EpisodeBatch.findAdsAgain(chosen, pipeline: pipeline) }
                    else { EpisodeBatch.findAds(chosen, pipeline: pipeline) }
                    done()
                } label: {
                    // "Find Ads Again" didn't fit beside Played and Play Last.
                    BarLabel(title: again ? "Find Again" : "Find Ads",
                             systemImage: again ? "arrow.clockwise" : "wand.and.sparkles")
                }
                .buttonStyle(.glass)
                .disabled(needAds.isEmpty && !again)
                .accessibilityLabel(again ? "Find Ads Again" : "Find Ads")
                .accessibilityIdentifier("selection.findAds")

                Button {
                    EpisodeBatch.playLast(chosen, context: context); done()
                } label: {
                    BarLabel(title: "Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
                .buttonStyle(.glass)
                .disabled(chosen.isEmpty)

                Menu {
                    more
                    // Some chosen still need finding and some are done: the
                    // done ones can be found again from here.
                    let doneOnes = EpisodeBatch.doneBefore(chosen, pipeline: pipeline)
                    if !doneOnes.isEmpty, !EpisodeBatch.needingAds(chosen, pipeline: pipeline).isEmpty {
                        Button("Find Ads Again (\(doneOnes.count))", systemImage: "arrow.clockwise") {
                            EpisodeBatch.findAdsAgain(doneOnes, pipeline: pipeline); done()
                        }
                    }
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
