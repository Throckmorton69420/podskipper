import SwiftUI
import UIKit
import ImageIO
import CoreGraphics

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

    static let hairline = Color.white.opacity(0.09)

    /// Minimum comfortable touch target. Apple asks for 44; transport
    /// controls get used without looking, so they get more.
    static let tapTarget: CGFloat = 56
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

enum Metrics {

    // Artwork, named by role rather than by number.
    static let artMini: CGFloat = 30      // mini player
    static let artRow: CGFloat = 52       // list rows
    static let artTile: CGFloat = 112     // grids and horizontal strips
    static let artTileWide: CGFloat = 156 // the same grids on a regular width
    static let artHero: CGFloat = 190     // show header
    static let artPlayer: CGFloat = 296   // full player

    /// Apple keeps a cover's corner proportional to its size, which is why a
    /// 30pt thumbnail and a 300pt cover read as the same shape. Clamped at
    /// both ends so tiny art doesn't go square and huge art doesn't go oval.
    static func artCorner(_ size: CGFloat) -> CGFloat {
        min(18, max(6, size * 0.13))
    }

    // Surfaces.
    static let cardCorner: CGFloat = 16
    static let panelCorner: CGFloat = 20

    // Spacing.
    static let gutter: CGFloat = 20          // screen side padding, compact
    static let gutterWide: CGFloat = 56      // screen side padding, regular
    static let rowGap: CGFloat = 12
    static let tight: CGFloat = 6

    /// Line length stops being readable long before a 13-inch iPad runs out of
    /// width, so content is capped and centred rather than stretched.
    static let readableMax: CGFloat = 760

    /// Clearance for the floating mini player and tab bar. Every screen used
    /// to pick its own number between 60 and 90.
    static let bottomInset: CGFloat = 84
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

    func contentRow(top: CGFloat = 10, bottom: CGFloat = 10) -> some View {
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
    func amoledScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .scrollEdgeEffectStyle(.hard, for: .all)
            .environment(\.defaultMinListRowHeight, 44)
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
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.8))
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.34, weight: .semibold))
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

    private var active: Bool {
        pipeline.isRunning || (publisher?.isPublishing ?? false)
    }

    var body: some View {
        Group {
            if active {
                HStack(spacing: 11) {
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

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                    }

                    Spacer(minLength: 0)

                    Text("\(Int(fraction * 100))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassPanel(cornerRadius: 18)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.28), value: active)
    }

    private var fraction: Double {
        pipeline.isRunning ? pipeline.overallFraction : (publisher?.overallFraction ?? 0)
    }

    private var title: String {
        if pipeline.isRunning { return pipeline.currentEpisodeTitle ?? "Processing" }
        return publisher?.currentEpisodeTitle ?? "Publishing"
    }

    private var detail: String {
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
            step = publisher?.stage.number ?? 1
            total = FeedPublisher.Stage.count
            eta = publisher?.etaSeconds
            queued = publisher?.itemsRemaining ?? 0
        }
        var parts = ["Step \(step)/\(total)", stage]
        if let eta, eta.isFinite, eta > 1 {
            parts.append(DetailedProgressView.timeLeft(eta))
        }
        if queued > 0 { parts.append("+\(queued) queued") }
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
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.13))
                    Capsule().fill(Theme.accentGradient)
                        .frame(width: max(3, geo.size.width * clampedFraction))
                        .animation(.easeOut(duration: 0.35), value: clampedFraction)
                }
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
            .font(.caption2)
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
                    .font(.caption2.monospacedDigit().weight(.semibold))
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
            Text(title).font(.title3.bold())
            Spacer()
            trailing
        }
        .textCase(nil)
        // Uses the same adaptive gutter as the rows underneath it. With a
        // hardcoded 20 here, every heading sat flush left on an iPad while its
        // own rows were indented — a visible misalignment down every screen.
        .plainRow(top: 18, bottom: 4)
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
enum AdaptiveGrid {
    static func columns(compactMinimum: CGFloat,
                        regularMinimum: CGFloat,
                        spacing: CGFloat = 14,
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
                    .font(.system(size: 11, weight: .bold))
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
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(tint.opacity(0.16)))
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
                    .font(.system(size: 13, weight: .bold))
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
                    .font(.system(size: 12, weight: .semibold))
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
                        .font(.caption.weight(.bold))
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
            .font(.caption2.weight(.semibold))
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
                    .font(.caption.monospacedDigit().weight(.semibold))
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
            .font(.caption2)
            .foregroundStyle(.secondary)

            if queueRemaining > 0 {
                Text("\(queueRemaining) more after this")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
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
    // No `nonisolated(unsafe)`: a `let` of a Sendable type is already safe to
    // read from anywhere, and the annotation only produced a warning.
    static let screenScale: CGFloat = 3.0

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
                guard let url = URL(string: urlString),
                      let (fetched, _) = try? await URLSession.shared.data(from: url)
                else { return nil }
                data = fetched
                // Keep the bytes so the same artwork asked for at a second
                // size — a 56pt row and a 296pt player, say — doesn't go back
                // to the network.
                // No `await`: the class is @MainActor and this Task inherits
                // that isolation, so the call is already on the right actor.
                self?.storeData(fetched, for: urlString)
            }
            // Decode straight to the size it will be drawn at.
            //
            // Podcast artwork is routinely 3000x3000. Decoding that to a
            // UIImage costs ~36 MB of RAM *each*, so a screen of rows used to
            // blow through the cache ceiling and re-decode constantly — the
            // stutter people read as "scrolling is janky".
            return Self.downsample(data: data, to: bucket)
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
        let result = Self.analyse(image) ?? .fallback
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

    /// Top of a header, behind the artwork and the glass controls.
    ///
    /// Capped low on purpose. A fully saturated cover was tinting the whole
    /// top of the show page bright crimson, which is nothing like the Podcasts
    /// app — there the colour is a suggestion, not a wash.
    var headerTop: Color {
        colour(saturation: min(0.46, max(0.16, saturation * 0.62)),
               brightness: min(0.30, max(0.14, brightness * 0.42)))
    }

    /// Where the header meets the content below it.
    var headerBottom: Color {
        colour(saturation: min(0.32, max(0.08, saturation * 0.36)),
               brightness: min(0.11, max(0.04, brightness * 0.16)))
    }

    /// A brighter pull for the player, which is a full screen of its own.
    var playerTop: Color {
        colour(saturation: min(0.70, max(0.28, saturation * 0.95)),
               brightness: min(0.46, max(0.22, brightness * 0.62)))
    }

    var playerBottom: Color {
        colour(saturation: min(0.55, max(0.18, saturation * 0.7)),
               brightness: min(0.20, max(0.08, brightness * 0.28)))
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
    /// Fade the bottom edge into the page instead of ending on a hard line.
    var fadeHeight: CGFloat = 120

    enum Variant { case header, player }

    @State private var palette: ArtworkPalette = .fallback
    @State private var image: UIImage?

    private var top: Color { variant == .header ? palette.headerTop : palette.playerTop }
    private var bottom: Color { variant == .header ? palette.headerBottom : palette.playerBottom }

    var body: some View {
        ZStack {
            LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)

            if let image {
                // Additive, so it has to stay faint. At 0.34 and 1.5x
                // saturation this layer was adding most of a second copy of
                // the cover's colour on top of a gradient already in that
                // colour, and the header came out luminous pink.
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 60, opaque: false)
                    .opacity(variant == .header ? 0.15 : 0.26)
                    .saturation(1.1)
                    .blendMode(.plusLighter)
            }
        }
        .compositingGroup()
        .overlay(alignment: .bottom) {
            // The old header stopped on a hard horizontal edge right above the
            // artwork. This is the fix for that seam.
            LinearGradient(colors: [.clear, Theme.background],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: fadeHeight)
        }
        .drawingGroup()
        .allowsHitTesting(false)
        .task(id: url) { await refresh() }
    }

    private func refresh() async {
        guard let url else {
            palette = .fallback
            image = nil
            return
        }
        if let ready = ImageCache.shared.cachedPalette(url) { palette = ready }
        image = await ImageCache.shared.load(url, size: 120)
        let resolved = await ImageCache.shared.palette(for: url)
        withAnimation(.easeOut(duration: 0.45)) { palette = resolved }
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
            image = await ImageCache.shared.load(url, size: decodeSize)
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
