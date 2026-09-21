import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

@main
struct PodSkipperWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingLiveActivity()
    }
}

/// The Lock Screen card and Dynamic Island, drawn to look like the app's own
/// mini player: the episode's cover, the show and release date, the title, a
/// progress bar that moves by itself. The Lock Screen card has no buttons —
/// the system's Now Playing box directly above it has them — while the
/// expanded Dynamic Island, which has nothing above it, keeps play, back and
/// forward.
///
/// Tapping the system Now Playing controls on a sideloaded install does
/// nothing (or opens the installer), because iOS resolves which app to open
/// from the signature on the process holding the audio session, and a
/// re-signed build's signature does not name PodSkipper. A Live Activity is
/// PodSkipper's own, and its tap goes to `podskipper://player`.
struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            NowPlayingCard(state: context.state)
                .widgetURL(NowPlayingLink.player)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    NowPlayingCover(data: context.state.artwork, size: 52)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nowPlayingMetaLine(context.state))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text(context.state.title)
                            .font(.subheadline.weight(.semibold)).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        NowPlayingProgressRow(state: context.state)
                        NowPlayingControls(isPlaying: context.state.isPlaying)
                    }
                }
            } compactLeading: {
                NowPlayingCover(data: context.state.artwork, size: 22, corner: 5)
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(.pink)
            } minimal: {
                NowPlayingCover(data: context.state.artwork, size: 22, corner: 11)
            }
            .widgetURL(NowPlayingLink.player)
        }
    }
}

