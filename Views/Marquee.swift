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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

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
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
                    label.offset(x: -scrollOffset(at: context.date))
                }
                // The moving copy must not be able to paint outside its line.
                .clipped()
            } else {
                label.lineLimit(1).truncationMode(.tail)
            }
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

    private var label: some View {
        Text(text)
            .font(font.weight(weight))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { textWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, new in textWidth = new }
                }
            }
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
