import SwiftUI
import UIKit
import ImageIO
import CoreGraphics
import CoreImage

/// The app's visual language.
///
/// Two rules from Apple's guidance drive everything here:
///
/// 1. Liquid Glass belongs to the **navigation layer** that floats above
///    content. Never on list rows, cells or media. Glass in the content layer
///    is what made this app read as flat grey slabs.
/// 2. Glass **refracts what is behind it**. Over a pure black background there
///    is nothing to refract, so it renders as grey. Screens that want glass
///    need something behind it — artwork, a colour wash, content scrolling
///    underneath.
enum Theme {

    static let background = Color.black
    static let surface = Color(red: 0.07, green: 0.07, blue: 0.085)

    static let accentWarm = Color(red: 1.0, green: 0.72, blue: 0.34)
    static let accentHot  = Color(red: 1.0, green: 0.19, blue: 0.50)
    static let adTint     = Color(red: 1.0, green: 0.55, blue: 0.20)

    /// One colour per kind of detected segment, so the timeline says what
    /// each block is rather than just that something is there.
    static func tint(for kind: SegmentKind) -> Color {
        switch kind {
        case .ad:         return adTint
        case .selfPromo:  return Color(red: 0.98, green: 0.35, blue: 0.62)
        case .crossPromo: return Color(red: 0.55, green: 0.62, blue: 1.0)
        case .intro:      return Color(red: 0.42, green: 0.82, blue: 0.72)
        case .outro:      return Color(red: 0.42, green: 0.72, blue: 0.86)
        }
    }

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accentWarm, accentHot],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Measured off the real app: rgb(42,42,42) on black, one pixel.
    /// 9% white was noticeably fainter and made lists look unstructured.
    static let hairline = Color(red: 42.0 / 255, green: 42.0 / 255, blue: 42.0 / 255)

    /// Minimum comfortable touch target. Apple asks for 44; transport
    /// controls get used without looking, so they get more.
    static var tapTarget: CGFloat { UIScale.pt(56) }
}

// MARK: - Interface size

/// The app-wide size setting: Settings → Display → Text and Icon Size.
///
/// Two halves, because SwiftUI sizes things two ways. Text set in a text style
/// (`.subheadline`) and the symbols beside it follow Dynamic Type, which the
/// root view overrides with `dynamicTypeSize`. Everything set in points — every
/// `Metrics` value, every `.system(size:)`, the player's buttons — goes through
/// `pt(_:)`. Both read the same step, so the whole interface scales together.
///
/// "Default" is one step smaller than the app used to be: the text was
/// reported as a tad too large. The old size is "Large".
enum UIScale {
    struct Step: Identifiable, Equatable {
        let id: Int
        let name: String
        let factor: CGFloat
        let typeSize: DynamicTypeSize
    }

    static let steps: [Step] = [
        Step(id: -2, name: "Smallest", factor: 0.82, typeSize: .xSmall),
        Step(id: -1, name: "Smaller", factor: 0.88, typeSize: .small),
        Step(id: 0, name: "Default", factor: 0.94, typeSize: .medium),
        Step(id: 1, name: "Large", factor: 1.0, typeSize: .large),
        Step(id: 2, name: "Larger", factor: 1.08, typeSize: .xLarge),
        Step(id: 3, name: "Largest", factor: 1.16, typeSize: .xxLarge)
    ]

    static let key = "interfaceSize"

    nonisolated static var current: Step {
        let id = UserDefaults.standard.integer(forKey: key)
        return steps.first { $0.id == id } ?? steps[2]
    }

    nonisolated static var factor: CGFloat { current.factor }

    /// A point size, scaled to the chosen interface size.
    nonisolated static func pt(_ value: CGFloat) -> CGFloat {
        (value * factor).rounded(.toNearestOrAwayFromZero)
    }
}

// MARK: - Metrics
//
// One scale for the whole app.
//
// Before this existed, artwork was rounded at 8, 10, 12, 14 and 16 points in
// different files with nothing deciding which, list gutters were hardcoded as
// 20 everywhere including on a 13-inch iPad, and each screen invented its own
// bottom padding to clear the mini player. Every number below replaces a
// literal that was chosen once and copied.

/// Measured off Apple Podcasts on iOS 26, on a 402pt-wide screen.
///
/// Almost every number here went up. The app was built to a compact,
/// information-dense scale — 52pt thumbnails, 17pt titles, 10pt capitalised
/// section headers — and next to the real thing it read as cramped. Apple's
/// episode row is 132pt tall with a 22pt title and a 90pt cover; the version
/// here was roughly two thirds of that in every dimension.
enum Metrics {

    // Artwork, named by role rather than by number.
    static var artMini: CGFloat { UIScale.pt(30) }
    /// The bottom bar's cover. 30 made the whole bar read as a strip; Apple's
    /// is closer to half the bar's height and is what gives it presence.
    static var artMiniLarge: CGFloat { UIScale.pt(38) }      // mini player
    static var artRow: CGFloat { UIScale.pt(90) }       // list rows — was 52
    static var artTile: CGFloat { UIScale.pt(175) }     // library grid — was 112
    static var artTileWide: CGFloat { UIScale.pt(175) } // the same grid on a regular width
    static var artStrip: CGFloat { UIScale.pt(161) }    // horizontal carousels
    static var artHero: CGFloat { UIScale.pt(200) }     // show header — was 190
    static var artPlayer: CGFloat { UIScale.pt(258) }   // full player — was 296

    /// A cover's corner, proportional to its size.
    ///
    /// Six per cent, not thirteen. Podcast artwork in the Podcasts app is
    /// nearly square-cornered — a 90pt thumbnail gets about 5pt and a 258pt
    /// cover about 14. Apple's own drawn icon tiles are the round ones, and
    /// copying their radius onto artwork was what made every cover here look
    /// like an app icon.
    static func artCorner(_ size: CGFloat) -> CGFloat {
        min(UIScale.pt(16), max(4, size * 0.058))
    }

    // MARK: Type
    //
    // Named by role. Apple's episode title is 22pt semibold — the same size
    // as a section header — and its smallest text anywhere except the tab
    // label is 12pt. There is no 10 or 11pt tier.

    /// Row titles and section headers. 22pt.
    static var titleSize: CGFloat { UIScale.pt(22) }
    /// Show names, descriptions, settings rows. 17pt.
    static var bodySize: CGFloat { UIScale.pt(17) }
    /// Subtitles under a row title. 15pt.
    static var subtitleSize: CGFloat { UIScale.pt(15) }
    /// Dates, durations, badges. The floor.
    static var metaSize: CGFloat { UIScale.pt(13) }

    /// Deliberately loose, the way Apple sets a two-line episode title.
    static var titleLineSpacing: CGFloat { UIScale.pt(4) }

    // Surfaces.
    static var cardCorner: CGFloat { UIScale.pt(16) }
    static var panelCorner: CGFloat { UIScale.pt(20) }

    // Spacing.
    static var gutter: CGFloat { UIScale.pt(20) }          // screen side padding, compact
    static var gutterWide: CGFloat { UIScale.pt(56) }      // screen side padding, regular
    static var rowGap: CGFloat { UIScale.pt(12) }
    static var tight: CGFloat { UIScale.pt(6) }
    /// Gap between the cover and the text beside it in a row.
    static var rowTextGap: CGFloat { UIScale.pt(12) }
    /// Above a section header. Apple leaves a lot of air here — 50pt from the
    /// end of one section to the top of the next heading.
    static var sectionTop: CGFloat { UIScale.pt(34) }
    /// Between a section header and its first row.
    static var sectionBottom: CGFloat { UIScale.pt(10) }

    /// Line length stops being readable long before a 13-inch iPad runs out of
    /// width, so content is capped and centred rather than stretched.
    static let readableMax: CGFloat = 760

    /// Clearance for the floating mini player and tab bar. Every screen used
    /// to pick its own number between 60 and 90.
    static var bottomInset: CGFloat { UIScale.pt(84) }
}

// MARK: - Content layer

/// List rows that know what size of screen they are on.
///
/// The old versions hardcoded a 20pt gutter, which is right on a phone and
/// absurd on an iPad — a show title stretched across thirteen inches. These
/// widen the gutter on a regular size class and cap the content itself, so a
/// row reads the same on both and the separators stay aligned with it.
private struct AdaptiveRow: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var top: CGFloat
    var bottom: CGFloat
    var showsSeparator: Bool

    private var gutter: CGFloat {
        sizeClass == .regular ? Metrics.gutterWide : Metrics.gutter
    }

    func body(content: Content) -> some View {
        // Written as one chain with no branching. An if/else here would give
        // the two paths different concrete types, which only compiles while
        // the builder cooperates — not worth the risk in something every row
        // in the app passes through.
        content
            .frame(maxWidth: Metrics.readableMax)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: top, leading: gutter,
                                      bottom: bottom, trailing: gutter))
            .listRowSeparator(showsSeparator ? .automatic : .hidden)
            .listRowSeparatorTint(Theme.hairline)
            // A List extends separators to its own trailing edge, ignoring the
            // row's trailing inset. Measured on an iPad mini: content stopped
            // 56pt from the edge while the separator ran on to 20pt, so every
            // rule stuck out past the chevron above it. This pins the
            // separator to where the content actually ends.
            .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
            // And the leading edge is worse, because List derives it from the
            // row's content rather than its insets. On the show page the rows
            // with two buttons got a separator starting 270pt in while the
            // rows with one started at the gutter, so the episode list had
            // rules of four different lengths. This pins it to the gutter.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
}

extension View {

    func contentRow(top: CGFloat = 15, bottom: CGFloat = 15) -> some View {
        modifier(AdaptiveRow(top: top, bottom: bottom, showsSeparator: true))
    }

    func plainRow(top: CGFloat = 6, bottom: CGFloat = 6) -> some View {
        modifier(AdaptiveRow(top: top, bottom: bottom, showsSeparator: false))
    }

    /// True black page, with a real material where content passes under the
    /// bars.
    ///
    /// Soft was the setting everywhere, and soft is barely a material at all:
    /// on any list long enough to scroll, rows stayed legible through the tab
    /// bar and the mini player as ghost text. Hard at both ends gives them
    /// something to disappear into.
    /// A sheet opened over the player: Liquid Glass, like every other sheet
    /// the system draws, instead of a black page.
    ///
    /// Reported as the audio settings and what-was-skipped pages not matching
    /// the rest. Both painted their own black background over the sheet's
    /// material, and both opened straight to full height, which is the one
    /// detent where iOS makes a sheet opaque. Half height first, with the
    /// list see-through, lets the glass show; dragging up still gives the
    /// whole screen.
    func glassSheet() -> some View {
        self
            .environment(\.inGlassSheet, true)
            // Not `.large`. A sheet at the large detent is, by Apple's design,
            // "a more opaque appearance to help maintain focus" — the dull grey
            // it turned when dragged up. A tall partial detent keeps the
            // Liquid Glass and still shows almost all of the page.
            .presentationDetents([.medium, .fraction(0.93)])
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
    }

    /// A black page — or, inside a glass sheet, a see-through one, so the
    /// sheet's material shows. The same screen can be pushed in Settings and
    /// presented over the player; this lets it look right in both.
    func amoledScreen() -> some View {
        modifier(AmoledScreen())
    }

    /// Caps content width on wide screens so lines stay readable, while
    /// staying edge-to-edge on a phone.
    func readableWidth(_ maximum: CGFloat = Metrics.readableMax) -> some View {
        frame(maxWidth: maximum)
            .frame(maxWidth: .infinity)
    }

    /// A content-layer panel. Flat, not glass.
    ///
    /// Glass belongs to the navigation layer that floats above content; this
    /// file's own rules say so, and a few screens were breaking them by
    /// wrapping in-list cards in `glassControl`, which is what made those
    /// cards read as grey slabs sitting on top of the page.
    func contentCard(cornerRadius: CGFloat = Metrics.cardCorner,
                     padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.8)
            )
    }

    /// A quiet bordered control for use *inside* content rows, where glass
    /// isn't allowed. Cheap to render, which matters in a long list.
    func contentChip(tint: Color = .primary) -> some View {
        self
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            // Was a flat 10%-white capsule with a hairline border — a
            // hand-rolled imitation of glass with no lensing, no specular
            // edge and no press response. The real effect costs one modifier.
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(Capsule())
    }
}

// MARK: - Glass layer

extension View {
    /// Floating panel — progress cards, action bars, overlays.
    /// Non-interactive by design: `.interactive()` on a non-capsule shape has
    /// a known hit-testing bug where taps are matched against a capsule, which
    /// is why some buttons needed pressing two or three times.
    func glassPanel(cornerRadius: CGFloat = 22) -> some View {
        self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }

    func glassCapsule(tinted: Bool = false) -> some View {
        self.glassEffect(tinted ? .regular.tint(Theme.accentHot) : .regular, in: .capsule)
    }

    /// Kept so older call sites still build.
    func glassCard(cornerRadius: CGFloat = 22, padding: CGFloat = 14) -> some View {
        self.padding(padding).glassPanel(cornerRadius: cornerRadius)
    }

    func glassControl(cornerRadius: CGFloat = 22, tinted: Bool = false) -> some View {
        self.glassPanel(cornerRadius: cornerRadius)
    }
}

// MARK: - Buttons
//
// Every tappable glass thing goes through these. They use `.buttonStyle(.glass)`
// rather than `.glassEffect(.interactive())`, which is Apple's own workaround
// for the hit-testing mismatch.

/// Circular icon button with a generous target.
struct GlassIconButton: View {
    let symbol: String
    var size: CGFloat = Theme.tapTarget
    var label: String = ""
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(tint ?? .primary)
                .frame(width: size, height: size)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .clipShape(Circle())
        .accessibilityLabel(label.isEmpty ? symbol : label)
    }
}

/// Pill button with a text label.
struct GlassPillButton: View {
    let title: String
    var symbol: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
    }
}

/// A slim status bar that appears wherever you are while an episode is being
/// processed. You tapped "Find ads" and nothing visibly happened — this is
/// that missing feedback, and it follows you between screens.
struct ProcessingBanner: View {
    let pipeline: ProcessingPipeline
    var publisher: FeedPublisher? = nil

    @State private var expanded = false
    @State private var queue = PublishQueue.shared
    @Namespace private var glass

    private var active: Bool {
        pipeline.isRunning || (publisher?.isPublishing ?? false) || queue.isRunning
    }

    /// Stays after the queue finishes, so what happened — including a failure —
    /// is still one tap away, until dismissed.
    private var visible: Bool { active || !queue.finished.isEmpty }

    // The bar opens *in place*.
    //
    // Tapping it used to present a sheet: half-height glass from the bottom
    // edge — far from the bar that was tapped at the top — which went opaque
    // grey when dragged up. Now the bar itself grows into the full activity
    // card, one Liquid Glass shape morphing between the two sizes, and
    // collapses back into the bar.
    var body: some View {
        GlassEffectContainer(spacing: 12) {
            if visible {
                if expanded {
                    card
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .glassEffectID("activity", in: glass)
                } else {
                    Button {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) { expanded = true }
                        Haptics.select()
                    } label: { bar }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .glassEffectID("activity", in: glass)
                        .accessibilityHint("Shows every step and what is queued")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .animation(.snappy(duration: 0.28), value: visible)
        .onChange(of: visible) { _, now in if !now { expanded = false } }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                if !queue.finished.isEmpty {
                    Button("Clear Finished") {
                        withAnimation(.snappy) { queue.clearFinished() }
                    }
                    .font(.subheadline)
                }
                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { expanded = false }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Collapse")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            WorkDetailView(pipeline: pipeline)
                .frame(height: 380)
        }
        // Dragging the card up closes it, like pushing a notification away.
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.height < -40 {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { expanded = false }
                }
            }
        )
    }

    /// The latest sentence from the publisher, so the small box reads as work
    /// happening rather than a static label.
    private var latestLine: String? {
        guard !pipeline.isRunning || queue.isRunning else { return nil }
        return FeedPublisher.shared.log.last?.text
    }

    private var bar: some View {
                HStack(spacing: 11) {
                    if !active {
                        Image(systemName: outcome.symbol)
                            .font(.title3)
                            .foregroundStyle(outcome.tint)
                            .frame(width: 26, height: 26)
                    } else if queue.isWaitingForConnection && !pipeline.isRunning {
                        Image(systemName: "wifi.slash")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.orange)
                            .frame(width: 26, height: 26)
                    } else {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.15), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: max(0.02, fraction))
                            .stroke(Theme.accentGradient,
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.3), value: fraction)
                    }
                    .frame(width: 26, height: 26)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                        if let latestLine {
                            Text(latestLine)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .id(latestLine)
                                .transition(.push(from: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.snappy(duration: 0.3), value: latestLine)

                    Spacer(minLength: 0)

                    if active && !queue.isWaitingForConnection {
                        Text("\(Int(fraction * 100))%")
                            .font(.footnote.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
    }

    private var fraction: Double {
        if !active { return 1 }
        return pipeline.isRunning ? pipeline.overallFraction : (publisher?.overallFraction ?? 0)
    }

    /// Finished, and how it went. "Publishing finished" with "1 failed"
    /// underneath read as two contradictory answers.
    private var outcome: (title: String, symbol: String, tint: Color) {
        let failed = queue.failedCount
        let done = queue.finished.count - failed
        if failed > 0 && done == 0 {
            return (failed == 1 ? "Couldn't publish" : "Couldn't publish \(failed) episodes",
                    "exclamationmark.triangle.fill", .orange)
        }
        if failed > 0 { return ("Finished with problems", "exclamationmark.triangle.fill", .orange) }
        return (done == 1 ? "Published" : "Published \(done) episodes", "checkmark.circle.fill", .green)
    }

    private var title: String {
        if !active { return outcome.title }
        if queue.isWaitingForConnection && !pipeline.isRunning && !(publisher?.isPublishing ?? false) {
            return "Waiting for a connection"
        }
        if pipeline.isRunning { return pipeline.currentEpisodeTitle ?? "Processing" }
        return publisher?.currentEpisodeTitle ?? queue.current?.title ?? "Publishing"
    }

    private var detail: String {
        if !active {
            let failed = queue.finished.filter { if case .failed = $0.state { return true } else { return false } }.count
            let done = queue.finished.count - failed
            var parts: [String] = []
            if done > 0 { parts.append("\(done) published") }
            if failed > 0 { parts.append("\(failed) didn't") }
            return parts.joined(separator: " · ") + " — tap for details"
        }
        if queue.isWaitingForConnection && !pipeline.isRunning && !(publisher?.isPublishing ?? false) {
            return "No internet. It carries on by itself when you're back online."
        }
        let stage: String
        let step: Int
        let total: Int
        let eta: Double?
        let queued: Int
        if pipeline.isRunning {
            stage = pipeline.stage.label
            step = pipeline.stage.number
            total = ProcessingPipeline.Stage.count
            eta = pipeline.etaSeconds
            queued = pipeline.queueRemaining
        } else {
            stage = publisher?.stage.label ?? ""
            step = publisher?.stepNumber ?? 1
            total = publisher?.stepCount ?? 1
            eta = publisher?.etaSeconds
            queued = publisher?.itemsRemaining ?? 0
        }
        let waiting = queue.waiting.count
        // Say which job this is. Publishing and finding ads both showed
        // "Step n/m" in the same banner, and one was mistaken for the other.
        if pipeline.isRunning && pipeline.waitingForConnection {
            return "Waiting for a connection — carries on by itself"
        }
        let job = pipeline.isRunning ? "Finding ads" : "Publishing"
        var parts = ["\(job) \(step)/\(total)", stage]
        if let eta, eta.isFinite, eta > 1 {
            parts.append(DetailedProgressView.timeLeft(eta))
        }
        if queued + waiting > 0 { parts.append("+\(queued + waiting) queued") }
        return parts.joined(separator: " · ")
    }
}

/// Progress for the episode you are looking at, drawn inside that episode's
/// own row.
///
/// This replaces a floating banner pinned under the navigation bar. That
/// banner had two problems: it was attached with `safeAreaInset`, so it pushed
/// the whole page down and then sat still while the artwork scrolled up behind
/// it — which is why it appeared to jump above the cover — and it told you an
/// episode was being processed without ever saying which row it belonged to.
struct InlineProcessingRow: View {
    let pipeline: ProcessingPipeline

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // No `GeometryReader` here any more. This row lives inside a List
            // row, and a GeometryReader there is one of this project's
            // standing traps — it has no intrinsic height and leaves ghost
            // frames behind after a navigation transition. Scaling a capsule
            // from its leading edge needs no measurement at all, and at four
            // points tall the distortion to the end caps cannot be seen.
            Capsule()
                .fill(Color.white.opacity(0.13))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Theme.accentGradient)
                        .scaleEffect(x: max(0.004, clampedFraction), y: 1, anchor: .leading)
                        .animation(.easeOut(duration: 0.35), value: clampedFraction)
                }
                .frame(height: 4)

            HStack(spacing: 5) {
                Text(pipeline.stage.label)
                Spacer(minLength: 6)
                if let eta = pipeline.etaSeconds, eta.isFinite, eta > 1 {
                    Text(DetailedProgressView.timeLeft(eta)).monospacedDigit()
                }
                Text("\(Int(clampedFraction * 100))%")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.footnote)
            .foregroundStyle(Theme.accentWarm)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var clampedFraction: Double {
        min(1, max(0, pipeline.overallFraction))
    }
}

/// A single line that says something is being processed somewhere else.
///
/// Used on screens that don't show the episode in question. It goes in the
/// toolbar rather than the content, so nothing moves when it appears.
struct ProcessingToolbarChip: View {
    let pipeline: ProcessingPipeline

    var body: some View {
        if pipeline.isRunning {
            HStack(spacing: 6) {
                Circle()
                    .trim(from: 0, to: max(0.05, pipeline.overallFraction))
                    .stroke(Theme.accentGradient,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 14, height: 14)
                Text("\(Int(pipeline.overallFraction * 100))%")
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Processing, \(Int(pipeline.overallFraction * 100)) percent")
        }
    }
}

extension View {
    /// Drops the banner under the navigation bar on any screen.
    ///
    /// Kept for screens with no episode rows of their own. `safeAreaBar` is
    /// the iOS 26 replacement for `safeAreaInset` here: it carries the scroll
    /// blur itself, so content passing underneath stays legible instead of
    /// colliding with the bar.
    func processingBanner(_ pipeline: ProcessingPipeline,
                          publisher: FeedPublisher? = nil) -> some View {
        safeAreaBar(edge: .top) {
            ProcessingBanner(pipeline: pipeline, publisher: publisher)
        }
    }

    /// A soft press highlight for content rows. Liquid Glass gives floating
    /// controls this for free; plain rows need it drawn.
    func pressGlow() -> some View {
        buttonStyle(PressGlowStyle())
    }
}

struct PressGlowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.08 : 0))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -4)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

// MARK: - Section headers

struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: Metrics.titleSize, weight: .bold))
            Spacer()
            trailing
        }
        // Title case, never capitals. iOS 26 renders list section headers in
        // title case regardless of what you pass, so an all-caps string now
        // just reads as shouting.
        .textCase(nil)
        // Uses the same adaptive gutter as the rows underneath it. With a
        // hardcoded 20 here, every heading sat flush left on an iPad while its
        // own rows were indented — a visible misalignment down every screen.
        .plainRow(top: Metrics.sectionTop, bottom: Metrics.sectionBottom)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title, trailing: { EmptyView() }) }
}

/// The blank row at the bottom of every list, so the last item clears the
/// floating mini player and tab bar.
///
/// A real view rather than a `View` extension: as an extension it would have
/// to be called on something, and every call site here wants it standalone.
/// Each screen used to pick its own height between 60 and 90.
struct BottomClearance: View {
    var body: some View {
        Color.clear
            .frame(height: Metrics.bottomInset)
            .plainRow(top: 0, bottom: 0)
    }
}

// MARK: - Adaptive layout

/// Grid columns that actually use an iPad.
///
/// `GridItem(.adaptive(minimum:))` alone packs a 13-inch screen with tiny
/// tiles. Raising the minimum on a regular size class gives fewer, larger
/// tiles — which is what the Podcasts app does when you rotate an iPad.
/// Column layout for the artwork grids.
///
/// The library rendered a single column on every iPhone, and the cause was four
/// points of arithmetic. `GridItem(.adaptive(minimum:))` fits as many columns as
/// it can at *at least* the minimum width, so two 175pt tiles at 16pt spacing
/// need 366pt — and a 402pt phone with 20pt gutters offers 362. Four points
/// short, so it fell back to one column and drew a 362pt-wide cover.
///
/// `.adaptive` is the wrong tool for this anyway. It is sized by a minimum,
/// which means the answer depends on a constant matching the device rather than
/// on the space actually available. Counting the columns from the measured
/// width and then letting them flex fills the row exactly, on any width, and
/// cannot be wrong by four points.
enum AdaptiveGrid {

    /// Inter-column spacing. Apple's own library grid resolves to
    /// 20 + 175 + 12 + 175 + 20 = 402 on a 402pt screen, so the gap between
    /// covers is 12, not the 16 this was using.
    static let spacing: CGFloat = 12

    /// How many columns fit, given the width left after the screen gutters.
    ///
    /// Never fewer than two: one column of artwork is a list with delusions of
    /// grandeur, and it is what the bug above produced.
    static func columnCount(forContentWidth width: CGFloat,
                            targetTile: CGFloat,
                            spacing: CGFloat = spacing) -> Int {
        guard width > 0, targetTile > 0 else { return 2 }
        let fit = Int(((width + spacing) / (targetTile + spacing)).rounded(.down))
        return max(2, min(8, fit))
    }

    /// Flexible columns that divide the available width exactly.
    static func columns(forContentWidth width: CGFloat,
                        targetTile: CGFloat,
                        spacing: CGFloat = spacing) -> [GridItem] {
        let count = columnCount(forContentWidth: width, targetTile: targetTile, spacing: spacing)
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
    }

    /// What one tile will actually measure once the row is divided.
    static func tileSide(forContentWidth width: CGFloat,
                         targetTile: CGFloat,
                         spacing: CGFloat = spacing) -> CGFloat {
        let count = CGFloat(columnCount(forContentWidth: width, targetTile: targetTile, spacing: spacing))
        guard count > 0 else { return targetTile }
        return max(60, (width - spacing * (count - 1)) / count)
    }

    /// The old shape, kept so callers that have not moved over still compile.
    /// Prefer the width-driven versions: this one can be four points wrong.
    static func columns(compactMinimum: CGFloat,
                        regularMinimum: CGFloat,
                        spacing: CGFloat = spacing,
                        isRegular: Bool) -> [GridItem] {
        [GridItem(.adaptive(minimum: isRegular ? regularMinimum : compactMinimum),
                  spacing: spacing)]
    }
}

/// Horizontal strip of covers, used by Discover and "You Might Also Like".
///
/// Was written out longhand in two places with different tile sizes and
/// different corner radii.
struct CoverStrip<Item: Identifiable, Label: View>: View {
    let items: [Item]
    let artwork: (Item) -> String?
    var size: CGFloat = Metrics.artTile
    @ViewBuilder var label: (Item) -> Label
    var onTap: ((Item) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(items) { item in
                    Button {
                        onTap?(item)
                    } label: {
                        VStack(spacing: 6) {
                            Artwork(url: artwork(item), size: size)
                            label(item)
                                .frame(width: size)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(onTap == nil)
                }
            }
            .padding(.horizontal, Metrics.gutter)
        }
        .scrollClipDisabled()
    }
}

// MARK: - Play controls

/// The play control Apple Podcasts puts on every episode: a triangle, a
/// progress track once you have started, and the time left.
///
/// The old version was a bare `Label("Play", systemImage: "play.fill")` with
/// `.buttonStyle(.plain)`, which is why it read as loose text rather than a
/// control, and why the glyph kept failing to appear next to it.
struct EpisodePlayPill: View {
    let isPlaying: Bool
    let progress: Double
    let timeLabel: String
    var tint: Color = Theme.accentHot
    let action: () -> Void

    private var started: Bool { progress > 0.005 && progress < 0.995 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    // A fixed frame is what keeps the glyph from shifting the
                    // label sideways when it swaps between play and pause.
                    .font(.system(size: UIScale.pt(11), weight: .bold))
                    .frame(width: 12, height: 12)
                    .contentTransition(.symbolEffect(.replace))

                if started {
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 42, height: 3)
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint)
                                .frame(width: max(2, 42 * progress), height: 3)
                        }
                }

                Text(timeLabel)
                    .font(.system(size: Metrics.metaSize, weight: .semibold).monospacedDigit())
                    // Monospaced digits already stop the label twitching as the
                    // time counts down. This stops a long one — `1h 54m` rather
                    // than `54m` — from being the reason the button beside it
                    // gets clipped: the pill gives up its own width first, and
                    // the progress bar carries the meaning while it does.
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(-1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            // Interactive glass, not a flat tinted capsule. This is what
            // gives the press response — the material deforms and lights
            // under a finger, which is the whole selection feedback in iOS 26
            // and is not something worth hand-rolling with a scale effect.
            .glassEffect(isPlaying
                         ? .regular.tint(tint.opacity(0.55)).interactive()
                         : .regular.interactive(),
                         in: .capsule)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .accessibilityValue(timeLabel)
    }
}

/// The wide primary action at the top of a show, matching the single Play
/// capsule Apple puts under the cover.
struct ShowPlayButton: View {
    let title: String
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // Built as an explicit HStack rather than a `Label`. Inside a
            // prominent glass button a Label's icon was being dropped
            // entirely, which left the text sitting off-centre in the capsule
            // with no visible glyph.
            HStack(spacing: 7) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: UIScale.pt(13), weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 22)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(Theme.accentHot)
        .accessibilityLabel(title)
    }
}

/// Secondary capsule beside it — Publish, and anything else that belongs on
/// that line.
///
/// A plain `Button`, deliberately. The previous version was a
/// `NavigationLink { } label: { }` sitting inside a `List` row, so the list
/// drew its own disclosure chevron off to the right and left a wide dead gap
/// between the label and that arrow.
struct ShowSecondaryButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: UIScale.pt(12), weight: .semibold))
                    .frame(width: 14, height: 14)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
    }
}

// MARK: - Section bar

/// The "Unplayed ⌄ … See All" line Apple puts above an episode list.
///
/// Replaces a horizontally scrolling chip strip that ran off the right edge of
/// the screen with no sign it could be scrolled.
struct SectionMenuBar<Menu1: View, Trailing: View>: View {
    let title: String
    @ViewBuilder var menu: Menu1
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Menu {
                menu
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.title3.bold())
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.bold))
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
            trailing
        }
    }
}

// MARK: - Status pill

struct StatusPill: View {
    let text: String
    let tint: Color
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(filled ? tint.opacity(0.95) : tint.opacity(0.16)))
            .foregroundStyle(filled ? Color.black : tint)
    }
}

// MARK: - Progress

struct DetailedProgressView: View {
    let title: String
    let stepName: String
    let stepIndex: Int
    let stepCount: Int
    let fraction: Double
    let etaSeconds: Double?
    var queueRemaining: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
                Text("\(Int(fraction * 100))%")
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(Theme.accentGradient)
                        .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 7)

            HStack(spacing: 6) {
                Text("Step \(stepIndex) of \(stepCount)")
                Text("·")
                Text(stepName)
                Spacer()
                if let etaSeconds, etaSeconds.isFinite, etaSeconds > 1 {
                    Label(Self.timeLeft(etaSeconds), systemImage: "clock").monospacedDigit()
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if queueRemaining > 0 {
                Text("\(queueRemaining) more after this")
                    .font(.footnote).foregroundStyle(.tertiary)
            }

            // Said plainly rather than left to be discovered.
            //
            // iOS gives a backgrounded app that isn't playing anything about
            // thirty seconds and then suspends it. There is no entitlement,
            // no flag and no trick that changes that for a job like this one;
            // what happens instead is that the system runs it again later,
            // usually while the phone is idle and charging. The app used to
            // say nothing at all, so leaving it looked like the feature had
            // broken.
            Text("Keep PodSkipper open, or play something, and this keeps going. "
                 + "Leave it with nothing playing and iOS pauses it — it picks up "
                 + "again on its own, usually while the phone is charging.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func timeLeft(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s left" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m \(total % 60)s left" }
        return "\(minutes / 60)h \(minutes % 60)m left"
    }
}

// MARK: - Cached artwork
//
// AsyncImage refetches and re-decodes every time a row scrolls back on
// screen. In a list of 500 episodes that is the whole stutter.

@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// Raw bytes, keyed by URL, so a second request at a larger size doesn't
    /// have to hit the network again.
    private let dataCache = NSCache<NSString, NSData>()

    private init() {
        cache.countLimit = 250
        cache.totalCostLimit = 48 * 1024 * 1024
        dataCache.countLimit = 60
        dataCache.totalCostLimit = 24 * 1024 * 1024
    }

    /// Fixed rather than read from `UIScreen`, which is main-actor bound while
    /// the downsampler deliberately is not. 3 is the highest scale shipping
    /// iPhones use, so this only ever over-samples slightly on a 2x device —
    /// never under-samples, which would show as soft artwork.
    // `nonisolated` because `downsample` is nonisolated by design — it runs off
    // the main actor — and reads this. A `let` of a Sendable type is safe from
    // anywhere, but Swift 6 will not infer that across a global actor boundary
    // and CI already logs it as a future error.
    nonisolated static let screenScale: CGFloat = 3.0

    /// Artwork is requested at a handful of sizes — 30pt in the mini player,
    /// 46–56pt in rows, 104pt in grids, 168pt and 296pt on the show and player
    /// screens. Rounding to buckets keeps the cache from holding a separate
    /// copy for every pixel size a layout happens to produce.
    private static func bucket(for size: CGFloat) -> Int {
        let pixels = size * screenScale
        for candidate in [96, 160, 256, 400, 640, 900] where pixels <= CGFloat(candidate) {
            return candidate
        }
        return 1200
    }

    private static func key(_ url: String, _ bucket: Int) -> NSString {
        "\(url)#\(bucket)" as NSString
    }

    func cached(_ url: String, size: CGFloat) -> UIImage? {
        cache.object(forKey: Self.key(url, Self.bucket(for: size)))
    }

    func load(_ urlString: String, size: CGFloat) async -> UIImage? {
        let bucket = Self.bucket(for: size)
        let cacheKey = Self.key(urlString, bucket)
        if let image = cache.object(forKey: cacheKey) { return image }

        let requestKey = cacheKey as String
        if let existing = inFlight[requestKey] { return await existing.value }

        let cachedData = dataCache.object(forKey: urlString as NSString) as Data?

        let task = Task<UIImage?, Never> { [weak self] in
            let data: Data
            if let cachedData {
                data = cachedData
            } else {
                // Through the disk store, not straight to the network.
                //
                // This used to be a bare `try? await URLSession.shared.data`,
                // which meant every eviction from the memory cache was a fresh
                // round trip and every failed request was permanent — the view
                // that asked never asks again, because its `.task(id: url)` is
                // keyed on a URL that has not changed. Transcribing an episode
                // is exactly the memory pressure that empties an NSCache, which
                // is why covers vanished the moment Find Ads was pressed.
                guard let fetched = await ArtworkStore.shared.data(for: urlString)
                else { return nil }
                data = fetched
                // Keep the bytes so the same artwork asked for at a second
                // size — a 56pt row and a 296pt player, say — doesn't go back
                // to the network.
                // No `await`: the class is @MainActor and this Task inherits
                // that isolation, so the call is already on the right actor.
                self?.storeData(fetched, for: urlString)
            }
            // Decode straight to the size it will be drawn at, and do it
            // somewhere other than the main thread.
            //
            // Podcast artwork is routinely 3000x3000. Decoding that to a
            // UIImage costs ~36 MB of RAM *each*, so a screen of rows used to
            // blow through the cache ceiling and re-decode constantly. Sizing
            // it down fixed the memory half of that — but this class is
            // @MainActor, so the `Task` it starts inherits main-actor
            // isolation, and every one of those decodes was still running on
            // the thread that draws. Thirty milliseconds of JPEG decode
            // between two frames is a dropped frame, and a fast scroll through
            // a show's back catalogue is dozens of them in a row. That is the
            // stutter, and `nonisolated` on the function alone never fixed it:
            // it permits the work to run elsewhere, it does not move it.
            return await Self.decoded(data, to: bucket)
        }

        inFlight[requestKey] = task
        let image = await task.value
        inFlight[requestKey] = nil

        if let image {
            let bytes = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: cacheKey, cost: bytes)
        }
        return image
    }

    // MARK: - Palette

    /// Colour pulled out of the artwork, cached per URL.
    ///
    /// Apple Podcasts tints a show's whole header with a colour taken from its
    /// cover. It is also what makes Liquid Glass work: glass refracts what is
    /// behind it, and over flat black there is nothing to refract, which is why
    /// every control on the old header rendered as a dead grey slab.
    private var palettes: [String: ArtworkPalette] = [:]

    func cachedPalette(_ url: String) -> ArtworkPalette? { palettes[url] }

    func palette(for urlString: String) async -> ArtworkPalette {
        if let existing = palettes[urlString] { return existing }
        guard let image = await load(urlString, size: 120) else { return .fallback }
        // Off the main thread for the same reason the decode is: this walks
        // every pixel of a 24x24 redraw of the cover, and it runs once per
        // show the moment a header appears.
        let result = await Task.detached(priority: .utility) {
            ImageCache.analyse(image) ?? .fallback
        }.value
        palettes[urlString] = result
        return result
    }

    /// Averages the artwork at a very small size, weighting saturated pixels
    /// so a colourful cover doesn't get washed out by a white border.
    nonisolated private static func analyse(_ image: UIImage) -> ArtworkPalette? {
        guard let cgImage = image.cgImage else { return nil }

        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue

        // The buffer is only touched inside this closure. Handing `&pixels`
        // straight to CGContext would let the context keep a pointer that is
        // no longer guaranteed valid once the call returns.
        let sampled: [UInt8]? = pixels.withUnsafeMutableBytes { raw -> [UInt8]? in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: space, bitmapInfo: info) else { return nil }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return Array(raw.bindMemory(to: UInt8.self))
        }
        guard let samples = sampled else { return nil }

        // Hue is circular, so it is summed as a vector rather than averaged —
        // otherwise reds either side of 0 average to cyan.
        var hueX = 0.0, hueY = 0.0
        var satTotal = 0.0, brightTotal = 0.0, weightTotal = 0.0

        for index in stride(from: 0, to: samples.count - 3, by: 4) {
            let r = CGFloat(samples[index]) / 255
            let g = CGFloat(samples[index + 1]) / 255
            let b = CGFloat(samples[index + 2]) / 255

            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            UIColor(red: r, green: g, blue: b, alpha: 1)
                .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

            // Near-black and near-white pixels carry no useful hue.
            guard brightness > 0.12, brightness < 0.97 else { continue }

            // Saturated pixels count for more, so a cover's accent colour wins
            // over the white border around it.
            let weight = Double(0.15 + saturation * saturation)
            let radians = Double(hue) * 2 * .pi
            hueX += cos(radians) * weight
            hueY += sin(radians) * weight
            satTotal += Double(saturation) * weight
            brightTotal += Double(brightness) * weight
            weightTotal += weight
        }

        guard weightTotal > 0 else { return nil }

        var hue = atan2(hueY, hueX) / (2 * .pi)
        if hue < 0 { hue += 1 }

        return ArtworkPalette(hue: hue,
                              saturation: satTotal / weightTotal,
                              brightness: brightTotal / weightTotal)
    }

    private func storeData(_ data: Data, for url: String) {
        // Only worth keeping if it's small enough to be cheap. A 4 MB cover
        // isn't worth holding on to just to avoid one refetch.
        guard data.count < 2_000_000 else { return }
        dataCache.setObject(data as NSData, forKey: url as NSString, cost: data.count)
    }

    /// ImageIO decodes at the requested size directly, so the full-resolution
    /// bitmap never exists in memory at all.
    /// `downsample`, off the main thread for certain.
    ///
    /// `Task.detached` rather than a plain `Task`, because a plain one started
    /// from a main-actor context stays on the main actor no matter what the
    /// callee is marked.
    nonisolated private static func decoded(_ data: Data, to maxPixels: Int) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            downsample(data: data, to: maxPixels)
        }.value
    }

    nonisolated private static func downsample(data: Data, to maxPixels: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ] as [CFString: Any] as CFDictionary

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: thumbnail, scale: screenScale, orientation: .up)
    }
}

/// The colours a screen derives from a show's cover.
///
/// Deliberately clamped rather than used raw. A cover that is almost white
/// would produce a header you cannot read white text on, and one that is
/// nearly black would put us straight back to the flat grey glass problem.
struct ArtworkPalette: Equatable {
    var hue: Double
    var saturation: Double
    var brightness: Double

    static let fallback = ArtworkPalette(hue: 0.94, saturation: 0.5, brightness: 0.5)

    private func colour(saturation s: Double, brightness b: Double, opacity: Double = 1) -> Color {
        Color(hue: hue, saturation: min(max(s, 0), 1), brightness: min(max(b, 0), 1))
            .opacity(opacity)
    }

    /// The show header. One flat colour, no gradient.
    ///
    /// Measured off the real app: it takes the cover's dominant hue, drops
    /// the luminance to about 0.85x, and pushes saturation *up* — a
    /// 20%-saturated cover produced a 33%-saturated header. Mid-luminance and
    /// moderately saturated, so white text sits on it cleanly.
    var headerFlat: Color {
        colour(saturation: min(0.42, max(0.18, saturation * 1.6)),
               brightness: min(0.62, max(0.26, brightness * 0.85)))
    }

    /// Behind the player, under the drifting copies of the cover.
    ///
    /// Almost fully desaturated. The player background in the real app is
    /// about 0.8x the cover's luminance at roughly 6% saturation — the colour
    /// comes from the artwork layered on top, not from this.
    var playerAmbient: Color {
        colour(saturation: min(0.16, max(0.04, saturation * 0.2)),
               brightness: min(0.34, max(0.12, brightness * 0.5)))
    }
}

/// The tinted, blurred panel that sits behind a show header or the player.
///
/// Two layers: a gradient in the artwork's own colour, and the artwork itself
/// blown up and blurred on top of it. The gradient carries the colour; the
/// blurred art gives the glass controls real texture to refract, which is the
/// difference between Liquid Glass looking like glass and looking like a grey
/// rectangle.
struct ArtworkBackdrop: View {
    let url: String?
    var variant: Variant = .header
    enum Variant { case header, player }
    /// Passed down to the drifting layers, so the player can freeze its
    /// background while something is presented over it.
    var paused: Bool = false

    @State private var palette: ArtworkPalette = .fallback
    @State private var image: UIImage?

    var body: some View {
        Group {
            switch variant {
            case .header: header
            case .player: player
            }
        }
        .allowsHitTesting(false)
        .task(id: url) { await refresh() }
    }

    /// One flat colour, ending on a hard edge.
    ///
    /// Measured off the real app: the show header is a single saturated
    /// colour from behind the status bar down to a one-pixel cut to black —
    /// no gradient, no fade, no blurred copy of the cover behind it. This was
    /// a two-stop gradient with an additive artwork layer and a 190pt fade,
    /// which is a different and much busier thing.
    private var header: some View {
        palette.headerFlat
    }

    /// The ambient light behind the player.
    ///
    /// Apple Music and Podcasts do not extract a colour and draw a gradient —
    /// they stack several copies of the artwork at different scales, rotate
    /// them slowly against each other, blur the result and push the
    /// saturation. The colour harmonises with the cover because the cover *is*
    /// the gradient. That slow drift is the thing that reads as a glow.
    @ViewBuilder
    private var player: some View {
        if let image {
            AmbientMesh(image: image, tint: palette.playerAmbient, paused: paused)
        } else {
            palette.playerAmbient
        }
    }

    private func refresh() async {
        guard let url else {
            palette = .fallback
            image = nil
            return
        }
        if let ready = ImageCache.shared.cachedPalette(url) { palette = ready }
        // Cleared first, for the same reason the foreground artwork is: the
        // ambient wash behind the player is made *of* the cover, so keeping
        // the old one means the room is still lit by the previous episode.
        image = nil
        // 560, not 240.
        //
        // 240 was chosen on the grounds that it was about to be blurred into
        // mush anyway — but once the blur was baked into the source rather
        // than applied over the top, that copy was being stretched across a
        // whole screen with nothing left to hide its edges, and it arrived as
        // visible blocks. Still far short of a 3000px cover.
        image = await ImageCache.shared.load(url, size: 560)
        let resolved = await ImageCache.shared.palette(for: url)
        withAnimation(.easeOut(duration: 0.45)) { palette = resolved }
    }
}

/// Four copies of the cover, drifting.
///
/// Two of them travel round small circular orbits, two spin in place, all at
/// different periods so the pattern never repeats visibly. Blurred hard and
/// desaturated back down, because the player background in the real app sits
/// at roughly 0.8x the cover's luminance and almost no saturation — it is
/// light in the room, not a wash of colour.
struct AmbientArtwork: View {
    let image: UIImage
    /// Shown underneath, so the edges never reveal the page behind.
    let tint: Color
    /// Stops the drift.
    ///
    /// Four full-screen images and a very large blur, twenty times a second,
    /// for as long as the player is on screen. Behind a presented sheet or an
    /// open menu that is frames spent on something nobody can see — and a
    /// layer that keeps moving underneath a menu that does not is exactly what
    /// reads as a ghosted second image over the top of it.
    var paused: Bool = false

    /// Someone who has asked the system for less movement has asked for this
    /// too. It is decoration, and it is the largest moving thing in the app.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// The cover with every effect already baked in: blurred, desaturated and
    /// darkened, once, off the main thread.
    ///
    /// Nothing is filtered while the thing is on screen, and that is the whole
    /// point. A SwiftUI `.blur` of any large radius is Core Animation's
    /// gaussian, which works by shrinking the layer a long way, box-blurring
    /// the small copy three times and scaling it back up. At a 70-point radius
    /// across a whole screen the shrink is severe enough that the scale-back-up
    /// arrives as visible squares — the "low-res, boxy-pixellated" background
    /// photographed on an iPhone 16 Pro. The simulator composites through a
    /// different path and showed none of it, which is why this survived several
    /// rounds of looking at screenshots.
    ///
    /// Core Image's gaussian, applied once to the source, is a real gaussian
    /// and has no such step. And with no filter left in the frame loop, each
    /// frame is four textured quads.
    @State private var prepared: UIImage?

    private var still: Bool { paused || reduceMotion || scenePhase != .active || ProcessInfo.processInfo.isLowPowerModeEnabled }

    private struct Layer {
        let scale: CGFloat
        let orbit: CGFloat
        let period: Double
        let spins: Bool
    }

    /// Periods in seconds, and they are deliberately long.
    ///
    /// They used to be a third of this. The drift was never meant to be
    /// noticeable, and at the old speed it was: a menu opened over the player
    /// is a translucent panel sampling whatever is behind it, so a background
    /// that visibly moves turns into a smeared second image sliding around
    /// under the menu's text. That is the "ghosted image on top showing the
    /// scrolling" — the menu is static and the thing behind it is not.
    /// Photographed off a screen recording, because it only exists while a
    /// menu is open.
    ///
    /// Slow enough now that nothing perceptibly moves in the couple of
    /// seconds a menu is up, and the glow still breathes over a long listen.
    /// `scale` is a floor, not the final size — see `coveringScale` below.
    private static let layers: [Layer] = [
        Layer(scale: 1.50, orbit: 0.16, period: 34, spins: false),
        Layer(scale: 1.80, orbit: 0.11, period: 45, spins: false),
        Layer(scale: 2.15, orbit: 0.05, period: 61, spins: true),
        Layer(scale: 2.60, orbit: 0.00, period: 79, spins: true)
    ]

    /// How big a copy has to be before its own edges can never come on screen.
    ///
    /// This used to be handled by the big SwiftUI blur, which smeared the
    /// rectangular boundary of each copy into invisibility. With the blur gone
    /// the boundary is a hard line, and two of the four copies used to be
    /// *smaller* than the screen — so they would have appeared as four visible
    /// rectangles sliding over each other.
    ///
    /// A square of side S contains the circle of radius S/2 whatever angle it
    /// is turned to, so a copy covers the screen from anywhere on its orbit as
    /// long as S/2 clears the farthest screen corner plus the orbit radius.
    /// Computed rather than hard-coded because an iPad is a different shape and
    /// a hard-coded number that works on a phone does not work there.
    private func coveringScale(_ layer: Layer, in size: CGSize, side: CGFloat) -> CGFloat {
        let corner = hypot(size.width, size.height) / 2
        let needed = 2 * (corner + layer.orbit * side) / max(1, side)
        return max(layer.scale, needed * 1.02)
    }

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height)
            let source = prepared ?? image
            // Twenty frames a second. The drift is slow — each layer takes
            // ten to twenty-three seconds to come round — so twenty is smooth
            // to the eye, and a third fewer frames is a third less GPU time
            // for as long as the player is open. Still in Low Power Mode.
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: still)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    tint
                    ForEach(Self.layers.indices, id: \.self) { index in
                        let layer = Self.layers[index]
                        let scale = coveringScale(layer, in: geo.size, side: side)
                        let phase = (time / layer.period) * 2 * .pi
                        Image(uiImage: source)
                            .resizable()
                            .scaledToFill()
                            .frame(width: side * scale, height: side * scale)
                            .rotationEffect(.radians(layer.spins ? phase : -phase))
                            .offset(x: layer.orbit * side * CGFloat(cos(phase)),
                                    y: layer.orbit * side * CGFloat(sin(phase)))
                            .opacity(0.55)
                    }
                    // A plain colour on top, not `.brightness`, which is a
                    // filter and would put an offscreen pass back in the frame
                    // loop for the sake of one number.
                    Color.black.opacity(0.30)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            // The unprepared original is the fallback for the fraction of a
            // second before Core Image finishes, and it is a sharp cover. Give
            // it a real blur for that moment only; once `prepared` arrives
            // there is no filter here at all.
            .blur(radius: prepared == nil ? side * 0.14 : 0, opaque: true)
        }
        .clipped()
        // Keyed on the object rather than on the image itself: `.task(id:)`
        // wants something Equatable, and two UIImages of the same cover are
        // not usefully comparable.
        .task(id: ObjectIdentifier(image)) {
            prepared = await Self.prepare(image)
        }
    }

    /// Blur, desaturate and darken the cover once, off the main thread.
    ///
    /// Clamped before blurring and cropped after, or the gaussian samples
    /// transparent pixels past the edges and leaves a pale border all the way
    /// round.
    private static func prepare(_ image: UIImage) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let cgImage = image.cgImage else { return nil }
            let input = CIImage(cgImage: cgImage)
            let extent = input.extent

            guard let blur = CIFilter(name: "CIGaussianBlur") else { return nil }
            blur.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
            // In pixels, not points, which is why this reads off the CGImage
            // rather than off `image.size`: the cached cover is stored at the
            // screen's scale, so those two numbers differ by a factor of three.
            blur.setValue(extent.width * 0.16, forKey: kCIInputRadiusKey)
            guard var work = blur.outputImage?.cropped(to: extent) else { return nil }

            // Was `.saturation(0.75).brightness(-0.06)` in the view. Both are
            // filters, and a filter in the frame loop is the thing being
            // removed here.
            if let colour = CIFilter(name: "CIColorControls") {
                colour.setValue(work, forKey: kCIInputImageKey)
                colour.setValue(0.75, forKey: kCIInputSaturationKey)
                colour.setValue(-0.06, forKey: kCIInputBrightnessKey)
                if let out = colour.outputImage { work = out.cropped(to: extent) }
            }

            guard let rendered = CIContext().createCGImage(work, from: extent)
            else { return nil }
            return UIImage(cgImage: rendered, scale: image.scale, orientation: .up)
        }.value
    }
}

/// The player's background: the cover's own colours, flowing.
///
/// The drifting-copies version stopped looking broken on the phone once its
/// blur was baked in, but it also stopped looking like anything — four dim,
/// slow, desaturated copies under a black wash read as a flat grey-brown
/// room. It was reported as "there was a better dynamic background at some
/// point".
///
/// This is the other way Apple draws it: a mesh gradient. The cover is
/// reduced to a three-by-three grid of its own average colours, lifted so they
/// glow rather than mud, and the inner points of the mesh wander on slow,
/// unrelated sine waves, so the colours slide into each other the way they do
/// behind Apple Music's lyrics. A mesh gradient is drawn on the GPU as
/// geometry — there is no blur and no image anywhere in the frame loop, so
/// there is nothing to pixelate, on a phone or anywhere else.
struct AmbientMesh: View {
    let image: UIImage
    let tint: Color
    var paused: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var colours: [Color]?

    private var still: Bool { paused || reduceMotion || scenePhase != .active || ProcessInfo.processInfo.isLowPowerModeEnabled }

    var body: some View {
        ZStack {
            tint
            if let colours {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: still)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    MeshGradient(width: 3, height: 3,
                                 points: Self.points(at: t),
                                 colors: Self.rotated(colours, at: t),
                                 smoothsColors: true)
                }
                .transition(.opacity)
            }
            // Enough shade that white text stays readable over the brightest
            // cover, and no more.
            LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.38)],
                           startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeOut(duration: 0.6), value: colours == nil)
        .task(id: ObjectIdentifier(image)) {
            colours = await Self.sample(image)
        }
    }

    /// Corners pinned, edge points sliding along their edge, the centre
    /// wandering — each on its own period, so the pattern never visibly loops.
    ///
    /// About a quarter faster than the original 13–29 s periods, which were
    /// reported as barely moving. The next attempt halved them and was
    /// reported as too fast; "a tad" was 15–30 per cent.
    private static func points(at t: Double) -> [SIMD2<Float>] {
        func wave(_ period: Double, _ phase: Double = 0) -> Float {
            Float(sin(t / period * 2 * .pi + phase))
        }
        return [
            [0, 0], [0.5 + 0.24 * wave(13.6), 0], [1, 0],
            [0, 0.5 + 0.24 * wave(16.8, 1)],
            [0.5 + 0.22 * wave(10.4, 2), 0.5 + 0.22 * wave(15.2, 0.5)],
            [1, 0.5 + 0.24 * wave(18.4, 2.5)],
            [0, 1], [0.5 + 0.24 * wave(23.2, 1.5), 1], [1, 1]
        ]
    }

    /// The colours drift one place round the grid about once a minute,
    /// cross-fading, so a cover with a bright corner does not leave a fixed
    /// bright corner on the screen for an hour.
    private static func rotated(_ colours: [Color], at t: Double) -> [Color] {
        guard colours.count == 9 else { return colours }
        let ring = [0, 1, 2, 5, 8, 7, 6, 3]
        let position = t / 56
        let step = Int(position) % ring.count
        // Eased, so each colour lingers before moving on rather than sliding
        // at a constant crawl.
        let raw = position - floor(position)
        let blend = raw * raw * (3 - 2 * raw)
        var out = colours
        for (i, slot) in ring.enumerated() {
            let from = colours[ring[(i + step) % ring.count]]
            let to = colours[ring[(i + step + 1) % ring.count]]
            out[slot] = from.mix(with: to, by: blend)
        }
        return out
    }

    /// Nine colours for the grid, chosen to differ from each other.
    ///
    /// These were the nine cell averages of a three-by-three grid over the
    /// cover. Most covers are one colour with details, so averaging nine big
    /// cells gave nine near-identical colours — "mostly just one colour", as
    /// reported. Now a six-by-six sample is taken, the most vivid colour
    /// first, then repeatedly whichever colour is furthest from everything
    /// already chosen. A cover that really is one colour gets gentle
    /// neighbours of it — a shade either side in hue, lighter and darker — so
    /// there is still depth to move.
    private static func sample(_ image: UIImage) async -> [Color]? {
        await Task.detached(priority: .userInitiated) { () -> [Color]? in
            guard let cg = image.cgImage else { return nil }
            let size = 6
            var pixels = [UInt8](repeating: 0, count: size * size * 4)
            guard let context = CGContext(data: &pixels, width: size, height: size,
                                          bitsPerComponent: 8, bytesPerRow: size * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            context.interpolationQuality = .high
            context.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))

            typealias HSB = (h: Double, s: Double, b: Double)
            let all: [HSB] = (0..<(size * size)).map { i in
                var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
                UIColor(red: CGFloat(pixels[i * 4]) / 255,
                        green: CGFloat(pixels[i * 4 + 1]) / 255,
                        blue: CGFloat(pixels[i * 4 + 2]) / 255, alpha: 1)
                    .getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
                return (Double(hue), Double(sat), Double(bri))
            }
            func distance(_ a: HSB, _ b: HSB) -> Double {
                let dh = min(abs(a.h - b.h), 1 - abs(a.h - b.h))
                // Hue only counts where there is colour to have a hue.
                let chroma = min(a.s, b.s)
                return dh * 2 * chroma + abs(a.s - b.s) * 0.6 + abs(a.b - b.b) * 0.8
            }
            var picked: [HSB] = [all.max { $0.s * $0.b < $1.s * $1.b }!]
            while picked.count < 9 {
                let next = all.max { a, b in
                    picked.map { distance($0, a) }.min()! < picked.map { distance($0, b) }.min()!
                }!
                picked.append(next)
            }

            // Too alike to move visibly: build neighbours of the main colour.
            let spread = picked.dropFirst().map { distance(picked[0], $0) }.max() ?? 0
            if spread < 0.18 {
                let base = picked[0]
                let offsets: [(Double, Double)] = [(0, 0), (-0.05, 0.16), (0.05, -0.18),
                                                   (0.09, 0.06), (-0.09, -0.08), (0.03, 0.24),
                                                   (-0.03, -0.24), (0.13, 0), (-0.13, 0.10)]
                picked = offsets.map { dh, db in
                    ((base.h + dh + 1).truncatingRemainder(dividingBy: 1),
                     max(base.s, 0.35), base.b + db)
                }
            }

            // Vivid ones apart from each other: centre, then corners, then
            // edges.
            let slots = [4, 0, 8, 2, 6, 1, 7, 3, 5]
            var out = [Color](repeating: .black, count: 9)
            for (colour, slot) in zip(picked, slots) {
                let lifted = UIColor(hue: colour.h,
                                     saturation: min(1, colour.s * 1.35 + 0.05),
                                     brightness: min(0.8, max(0.24, colour.b * 0.95)),
                                     alpha: 1)
                out[slot] = Color(uiColor: lifted)
            }
            return out
        }.value
    }
}

struct Artwork: View {
    let url: String?
    var size: CGFloat = Metrics.artRow
    /// Left nil on purpose almost everywhere.
    ///
    /// The corner is derived from the size by default, which is what keeps a
    /// 30pt thumbnail and a 296pt cover reading as the same shape. Passing one
    /// explicitly is an override, not the normal case — five different radii
    /// were in use across the app before this.
    var corner: CGFloat? = nil
    /// Set when the artwork fills a region rather than a square of `size` —
    /// the hero wash behind a show header, for instance.
    var renderSize: CGFloat? = nil

    @State private var image: UIImage?

    private var decodeSize: CGFloat { renderSize ?? size }
    private var radius: CGFloat { corner ?? Metrics.artCorner(size) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    Image(systemName: "waveform")
                        .font(.system(size: max(11, size * 0.26)))
                        .foregroundStyle(.tertiary)
                )

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .task(id: url) {
            guard let url else { image = nil; return }
            if let ready = ImageCache.shared.cached(url, size: decodeSize) {
                image = ready
                return
            }
            // Let go of the last one first.
            //
            // Without this the previous episode's cover stays on screen until
            // the new one arrives, and in the player that is seconds of the
            // wrong show: the title and the show name update immediately, the
            // artwork does not, and what you are looking at is one episode's
            // name over another episode's cover. Caught in a screenshot where
            // the player said "Hard Drive Full" over the green Quiet Hours
            // square.
            image = nil
            // `.task(id:)` runs once and never again until the id changes, and
            // the id here is the artwork's URL — which does not change. So a
            // single failed fetch, from a moment offline or a request the
            // system cancelled during a fast scroll, left a permanently blank
            // square. Three attempts, backing off, and then it gives up for
            // real: the store underneath keeps its own cool-off, so this is
            // cheap and it is not a retry storm.
            for attempt in 0..<3 {
                if Task.isCancelled { return }
                if let loaded = await ImageCache.shared.load(url, size: decodeSize) {
                    image = loaded
                    return
                }
                let backoff = Duration.seconds(1 << attempt)
                try? await Task.sleep(for: backoff)
            }
        }
    }
}


extension Double {
    /// Keeps speed steps from accumulating floating-point drift.
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}


// MARK: - Glass sheets

extension EnvironmentValues {
    /// True inside a sheet presented with `glassSheet()`.
    @Entry var inGlassSheet: Bool = false
}

private struct AmoledScreen: ViewModifier {
    @Environment(\.inGlassSheet) private var inGlassSheet

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(inGlassSheet ? Color.clear.ignoresSafeArea() : Theme.background.ignoresSafeArea())
            // Soft, everywhere, as Apple Podcasts does: a variable blur that
            // fades out under the bars, not a hard-edged band. The hard style
            // is what drew the "transparent box with a defined border" at the
            // top and bottom of every tab — and when the bottom bar grows back
            // after a fast scroll, a hard band visibly jumps with it.
            .scrollEdgeEffectStyle(.soft, for: .all)
            .environment(\.defaultMinListRowHeight, 44)
    }
}
