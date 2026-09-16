import ActivityKit
import SwiftUI
import WidgetKit

@main
struct PodSkipperWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingLiveActivity()
    }
}

/// A card beside the Lock Screen's Now Playing controls that opens straight
/// to the player.
///
/// Tapping the system Now Playing controls on a sideloaded install does
/// nothing (or opens the installer), because iOS resolves which app to open
/// from the signature on the process holding the audio session, and a
/// re-signed build's signature does not name PodSkipper. A Live Activity is
/// PodSkipper's own, and its tap goes to `podskipper://player`.
struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            LockScreenCard(state: context.state)
                .widgetURL(NowPlayingLink.player)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.pink)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(skippedLine(context.state)).font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "waveform").foregroundStyle(.pink)
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "play.fill" : "pause.fill")
            } minimal: {
                Image(systemName: "waveform").foregroundStyle(.pink)
            }
            .widgetURL(NowPlayingLink.player)
        }
    }
}

private func skippedLine(_ state: NowPlayingAttributes.ContentState) -> String {
    let seconds = Int(state.secondsSkipped.rounded())
    guard seconds > 0 else { return "PodSkipper · open the player" }
    return seconds >= 60
        ? "\(seconds / 60)m \(seconds % 60)s of ads skipped"
        : "\(seconds)s of ads skipped"
}

private struct LockScreenCard: View {
    let state: NowPlayingAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "scissors")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.show)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(state.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(skippedLine(state))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Image(systemName: "chevron.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))
                if let endsAt = state.endsAt, state.isPlaying {
                    Text(endsAt, style: .timer)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 56)
                }
            }
        }
        .padding(14)
    }
}
