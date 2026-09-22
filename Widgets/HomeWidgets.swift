import AppIntents
import SwiftUI
import WidgetKit

/// Home Screen and Lock Screen widgets. They draw from `WidgetSnapshot`,
/// which the app writes into the App Group folder — so with no App Group (a
/// build without a paid account) they show "Open PodSkipper" and nothing else.
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        // The widget gallery shows the sample, so it's clear what it will be.
        completion(SnapshotEntry(date: .now, snapshot: context.isPreview ? .sample : WidgetSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // The app asks for a redraw whenever what's shown changes, so this
        // only needs an occasional refresh of its own.
        let entry = SnapshotEntry(date: .now, snapshot: WidgetSnapshot.read())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "UpNext", provider: SnapshotProvider()) { entry in
            UpNextFamilyView(entry: entry)
                .containerBackground(for: .widget) { WidgetStyle.background }
        }
        .configurationDisplayName("Up Next")
        .description("What's playing and what comes after it. Tap an episode to play it.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

private struct UpNextFamilyView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:
            UpNextWidgetView(snapshot: entry.snapshot, size: .small)
                .widgetURL(entry.snapshot?.upNext.first.map { WidgetLinks.play($0.guid) } ?? NowPlayingLink.player)
        case .systemLarge:
            UpNextWidgetView(snapshot: entry.snapshot, size: .large)
        case .accessoryRectangular:
            let item = entry.snapshot?.nowPlaying ?? entry.snapshot?.upNext.first
            VStack(alignment: .leading, spacing: 1) {
                Label("Up Next", systemImage: "waveform").font(.caption2.weight(.semibold))
                Text(item?.title ?? "Open PodSkipper").font(.caption).lineLimit(2)
            }
            .widgetURL(item.map { WidgetLinks.play($0.guid) } ?? NowPlayingLink.player)
        default:
            UpNextWidgetView(snapshot: entry.snapshot, size: .medium)
        }
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlaying", provider: SnapshotProvider()) { entry in
            NowPlayingWidgetView(snapshot: entry.snapshot, toggle: {
                AnyView(
                    Button(intent: CardPlayPauseIntent()) {
                        Image(systemName: entry.snapshot?.isPlaying == true ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(WidgetStyle.accent)
                    }
                    .buttonStyle(.plain)
                )
            })
            .widgetURL(NowPlayingLink.player)
            .containerBackground(for: .widget) { WidgetStyle.background }
        }
        .configurationDisplayName("Now Playing")
        .description("The episode that's playing, with play and pause.")
        .supportedFamilies([.systemSmall])
    }
}
