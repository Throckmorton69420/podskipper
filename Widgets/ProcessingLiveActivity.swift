import ActivityKit
import SwiftUI
import WidgetKit

/// Finding ads, on the Lock Screen and in the Dynamic Island (pass 21).
/// Drawn like the app's activity bar: cover, show, title, a bar, the step,
/// "2 of 5" and the time left, which counts down by itself between updates.
struct ProcessingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ProcessingAttributes.self) { context in
            ProcessingCard(state: context.state, stale: context.isStale)
                .padding(14)
                .widgetURL(ProcessingLink.activity)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    NowPlayingCover(data: context.state.artwork, size: 44)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(ProcessingCard.stepLine(context.state, stale: context.isStale))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: context.state.fraction).tint(.pink)
                }
            } compactLeading: {
                Image(systemName: ProcessingCard.symbol(context.state.phase)).foregroundStyle(.pink)
            } compactTrailing: {
                Text(ProcessingCard.shortLine(context.state)).font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: ProcessingCard.symbol(context.state.phase)).foregroundStyle(.pink)
            }
            .widgetURL(ProcessingLink.activity)
        }
    }
}

struct ProcessingCard: View {
    let state: ProcessingAttributes.ContentState
    let stale: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NowPlayingCover(data: state.artwork, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: Self.symbol(state.phase)).foregroundStyle(.pink)
                    Text(state.show.isEmpty ? "PodSkipper" : state.show)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if state.total > 1 {
                        Text("\(state.position) of \(state.total)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Text(state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if state.phase == .working || state.phase == .waiting {
                    ProgressView(value: state.fraction).tint(.pink)
                }
                HStack {
                    Text(Self.stepLine(state, stale: stale)).lineLimit(1)
                    Spacer(minLength: 4)
                    if state.phase == .working, !stale, let ends = state.endsAt, ends > .now {
                        Text(timerInterval: Date.now...ends, countsDown: true)
                            .monospacedDigit().multilineTextAlignment(.trailing).frame(maxWidth: 70)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
    }

    static func symbol(_ phase: ProcessingAttributes.ContentState.Phase) -> String {
        switch phase {
        case .working: return "wand.and.sparkles"
        case .waiting: return "hourglass"
        case .paused: return "pause.circle"
        case .done: return "checkmark.circle.fill"
        }
    }

    static func stepLine(_ state: ProcessingAttributes.ContentState, stale: Bool) -> String {
        switch state.phase {
        case .done:
            return state.cuts == 0 ? "Ads found · nothing to cut"
                : "Ads found · \(state.cuts) cut\(state.cuts == 1 ? "" : "s") · \(Int((state.cutSeconds / 60).rounded())) min"
        case .paused: return state.step
        case .working, .waiting:
            // Not updated for a while: the app has most likely been paused
            // by iOS, and the card says so rather than a frozen number.
            if stale { return "Paused by iOS · opens where it stopped" }
            return "\(state.step) · \(Int(state.fraction * 100))%"
        }
    }

    static func shortLine(_ state: ProcessingAttributes.ContentState) -> String {
        switch state.phase {
        case .done: return "Done"
        case .paused: return "Paused"
        case .working, .waiting: return "\(Int(state.fraction * 100))%"
        }
    }
}
