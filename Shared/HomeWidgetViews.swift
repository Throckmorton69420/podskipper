import SwiftUI
import UIKit

/// The Home Screen widgets' drawing, shared with the app so it can show them
/// in Settings (the simulator run photographs them there — see
/// `WidgetGalleryView`).
enum WidgetStyle {
    static let accent = Color(red: 1.0, green: 0.33, blue: 0.47)
    static let warm = Color(red: 1.0, green: 0.60, blue: 0.24)
    static let background = LinearGradient(colors: [Color(red: 0.16, green: 0.08, blue: 0.11),
                                                     Color(red: 0.04, green: 0.02, blue: 0.03)],
                                            startPoint: .top, endPoint: .bottom)

    static func left(_ seconds: Double) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m left" }
        return "\(minutes)m left"
    }
}

struct WidgetCover: View {
    let data: Data?
    var size: CGFloat

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [WidgetStyle.accent, WidgetStyle.warm],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "waveform").font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
    }
}

/// Shown when the app has never been able to write a snapshot — a build with
/// no App Group.
struct WidgetNeedsApp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "waveform").font(.title3.weight(.semibold)).foregroundStyle(WidgetStyle.accent)
            Spacer(minLength: 0)
            Text("Open PodSkipper").font(.headline)
            Text("Up Next appears here once the app can share it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Up Next. Small: the next episode. Medium: three. Large: six.
struct UpNextWidgetView: View {
    enum Size { case small, medium, large }
    let snapshot: WidgetSnapshot?
    let size: Size

    private var items: [WidgetSnapshot.Item] {
        guard let snapshot else { return [] }
        // What is playing leads, then the queue after it.
        var list = snapshot.nowPlaying.map { [$0] } ?? []
        list += snapshot.upNext.filter { $0.guid != snapshot.nowPlaying?.guid }
        return list
    }

    var body: some View {
        if snapshot == nil {
            WidgetNeedsApp()
        } else if items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("Up Next", systemImage: "list.bullet").font(.caption.weight(.semibold))
                    .foregroundStyle(WidgetStyle.accent)
                Spacer(minLength: 0)
                Text("Nothing queued").font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else if size == .small {
            small(items[0])
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Up Next", systemImage: "list.bullet")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(WidgetStyle.accent)
                ForEach(items.prefix(size == .large ? 6 : 3)) { item in
                    Link(destination: WidgetLinks.play(item.guid)) { row(item) }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func small(_ item: WidgetSnapshot.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                WidgetCover(data: item.artwork, size: 52)
                Spacer(minLength: 0)
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(WidgetStyle.accent)
            }
            Spacer(minLength: 0)
            Text(item.show).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(item.title).font(.caption.weight(.semibold)).lineLimit(2)
            Text(WidgetStyle.left(item.remaining)).font(.caption2).foregroundStyle(WidgetStyle.warm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func row(_ item: WidgetSnapshot.Item) -> some View {
        HStack(spacing: 10) {
            WidgetCover(data: item.artwork, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.caption.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(item.show).lineLimit(1)
                    if item.adFree { Image(systemName: "wand.and.sparkles").foregroundStyle(.green) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(WidgetStyle.left(item.remaining)).font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// What is playing, with play and pause.
struct NowPlayingWidgetView: View {
    let snapshot: WidgetSnapshot?
    /// Set in the widget extension: a button that runs in the app. Nil in the
    /// in-app gallery.
    var toggle: (() -> AnyView)?

    var body: some View {
        if let snapshot, let item = snapshot.nowPlaying {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    WidgetCover(data: item.artwork, size: 56)
                    Spacer(minLength: 0)
                    if let toggle { toggle() } else {
                        Image(systemName: snapshot.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 30)).foregroundStyle(WidgetStyle.accent)
                    }
                }
                Spacer(minLength: 0)
                Text(item.title).font(.caption.weight(.semibold)).lineLimit(2)
                Capsule().fill(.white.opacity(0.15)).frame(height: 3)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule().fill(LinearGradient(colors: [WidgetStyle.accent, WidgetStyle.warm],
                                                          startPoint: .leading, endPoint: .trailing))
                                .frame(width: proxy.size.width * min(1, max(0.02, item.progress)))
                        }
                    }
                    .frame(height: 3)
                Text(WidgetStyle.left(item.remaining)).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        } else if snapshot == nil {
            WidgetNeedsApp()
        } else {
            VStack(alignment: .leading) {
                Image(systemName: "waveform").font(.title3).foregroundStyle(WidgetStyle.accent)
                Spacer(minLength: 0)
                Text("Nothing playing").font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
