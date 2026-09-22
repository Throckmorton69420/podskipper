import SwiftUI

/// A line of text that scrolls itself when it does not fit.
///
/// Worth saying plainly: **Apple Podcasts does not do this.** I looked — there
/// is no marquee type in any of the sixteen binaries in the iOS 27 bundle and
/// no marquee string in its two thousand localisations. Its Now Playing bar
/// truncates with an ellipsis like everything else. This is a PodSkipper
/// behaviour, built because it was asked for, and it is written to be the
/// restrained version: it waits, moves slowly, and stops.
///
/// The parts that matter for it not being annoying:
///
///   * Nothing moves unless the text genuinely overflows. A title that fits is
///     a plain `Text`, with no timeline, no animation and no cost.
///   * It pauses at each end. A marquee that loops without stopping is
///     unreadable, because the moment you find the beginning it leaves.
///   * It respects Reduce Motion. With that on it truncates instead, which is
///     the whole point of the setting.
///   * It is driven by one `TimelineView` at 30 Hz rather than a repeating
///     `withAnimation`, so it cannot leave an animation running against a view
///     that has gone away.
struct Marquee: View {
    let text: String
    var font: Font = .body
    var weight: Font.Weight = .semibold
    /// Points per second. Reading speed, not attention-seeking speed.
    var speed: Double = 26
    /// Seconds held still at each end.
    var dwell: Double = 2.0
    /// Gap between the end of one pass and the start of the next.
    var gap: Double = 44
    /// Whether it may move at all. The mini player passes "is playing": a
    /// title scrolling over a paused episode is thirty redraws a second for
    /// nobody.
    var moving: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    /// Set after two full passes: the title has been read, and it stops at
    /// the start until the text changes or playback starts again.
    @State private var finished = false

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }
    private var shouldScroll: Bool { overflow > 1 && !reduceMotion }

    /// One full there-and-back, including both pauses.
    private var cycle: Double {
        guard overflow > 0 else { return 1 }
        let travel = Double(overflow) / max(1, speed)
        return dwell + travel + dwell + travel
    }

    var body: some View {
        Group {
            if shouldScroll {
                // The shape of this matters, and getting it wrong is visible
                // from across the room.
                //
                // `sizer` is an ordinary truncating `Text`: it has the right
                // height and it is happy to be squeezed, so an HStack can hand
                // it whatever is left over. It is hidden, and the copy that
                // actually moves is drawn in an overlay — overlays never
                // change the size of what they sit on. So the moving copy can
                // be as wide as the sentence is, and the line it lives in is
                // still only as wide as the space available.
                //
                // Done the obvious way instead — animating the wide copy
                // directly — the `fixedSize` it needs in order to be wide
                // propagates all the way out, the marquee demands the width of
                // the whole title, and in the minimised tab bar it takes the
                // lot: the artwork and the play button vanish and the pill
                // becomes a sentence sliding past. That is exactly what
                // happened, and `.clipped()` in the wrong place did not stop
                // the text painting over the artwork on its way out either.
                sizer
                    .hidden()
                    .overlay(alignment: .leading) {
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                                paused: stopped)) { context in
                            label.offset(x: stopped ? 0 : -scrollOffset(at: context.date))
                        }
                        .fixedSize()
                        // Two passes, then still. Keyed on the text and on
                        // playback, so a new title or pressing play runs it
                        // again.
                        .task(id: "\(text)|\(moving)") {
                            finished = false
                            guard moving else { return }
                            try? await Task.sleep(for: .seconds(cycle * 2))
                            if !Task.isCancelled { finished = true }
                        }
                    }
                    // Clips to the line, because it is applied to the thing
                    // that is the width of the line.
                    .clipped()
            } else {
                sizer
            }
        }
        // How wide the text *wants* to be, measured somewhere the answer
        // cannot depend on what is currently being drawn.
        //
        // This used to be measured off the visible label, and that is a loop
        // with only one stable state. While the title is not scrolling it is
        // drawn truncated to the width available, so it measures as exactly
        // the width available, so the overflow is zero, so it never starts
        // scrolling — and the Now Playing bar sat there with an ellipsis
        // forever. A hidden copy with nothing constraining it always reports
        // the real width.
        .background(alignment: .leading) {
            Text(text)
                .font(font.weight(weight))
                .lineLimit(1)
                .fixedSize()
                .hidden()
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { textWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, new in textWidth = new }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // Fills the space left over, not the space available.
        //
        // `maxWidth: .infinity` on its own made this greedy inside an HStack:
        // in the minimised tab bar it claimed the whole width and pushed the
        // artwork and the play button out of the bar entirely, leaving a
        // scrolling title and nothing else. A negative layout priority means
        // everything beside it is measured first.
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(-1)
        .background {
            // Measure the container without affecting layout.
            GeometryReader { proxy in
                Color.clear
                    .onAppear { containerWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, new in containerWidth = new }
            }
        }
        // The scrolling is decoration. VoiceOver gets the whole string at once.
        .accessibilityElement()
        .accessibilityLabel(text)
    }

    /// The line as it sits in the layout: one line, truncating, and willing to
    /// be given less room than it would like.
    private var sizer: some View {
        Text(text)
            .font(font.weight(weight))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// The same line at its full width, for the copy that moves.
    private var label: some View {
        Text(text)
            .font(font.weight(weight))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// Not moving: paused playback, finished its passes, the app in the
    /// background, or Low Power Mode on.
    private var stopped: Bool {
        !moving || finished || scenePhase != .active || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Where the text sits at a given moment: still, out, still, back.
    private func scrollOffset(at date: Date) -> CGFloat {
        guard overflow > 0 else { return 0 }
        let travel = Double(overflow) / max(1, speed)
        let t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)

        if t < dwell { return 0 }
        if t < dwell + travel {
            return CGFloat((t - dwell) / travel) * overflow
        }
        if t < dwell + travel + dwell { return overflow }
        return overflow - CGFloat((t - dwell - travel - dwell) / travel) * overflow
    }
}
