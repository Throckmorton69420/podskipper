import Foundation
import SwiftData
import UIKit
import WidgetKit

/// Writes what the Home Screen widgets show — see `WidgetSnapshot`.
///
/// Does nothing at all on a build without an App Group: `WidgetSnapshot.folder`
/// is nil there and every call returns at the first line.
@MainActor
final class WidgetPublisher {
    static let shared = WidgetPublisher()

    private var pending: Task<Void, Never>?
    private var last: WidgetSnapshot?
    private var thumbnails: [String: Data] = [:]

    /// Whether this build can share data with widgets at all.
    var isAvailable: Bool { WidgetSnapshot.folder != nil }

    /// Asks for a fresh snapshot shortly. Calls that arrive together — a new
    /// episode starting is a load, a play and a queue change — become one.
    func setNeedsUpdate() {
        guard isAvailable else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.update()
        }
    }

    private func update() async {
        let player = PlayerEngine.shared
        let current = player.currentEpisode
        var upcoming = player.upcomingProvider?(current, 6) ?? []
        if upcoming.isEmpty, let context = AppLibrary.context {
            var queue = FetchDescriptor<Episode>(predicate: #Predicate { $0.isInQueue && !$0.isPlayed },
                                                 sortBy: [SortDescriptor(\.queueOrder)])
            queue.fetchLimit = 6
            upcoming = (try? context.fetch(queue)) ?? []
        }

        var nowPlaying: WidgetSnapshot.Item?
        if let current { nowPlaying = await item(current, position: player.currentTime) }
        var next: [WidgetSnapshot.Item] = []
        for episode in upcoming where episode.guid != current?.guid {
            next.append(await item(episode, position: episode.playbackPosition))
        }
        let snapshot = WidgetSnapshot(nowPlaying: nowPlaying, isPlaying: player.isPlaying,
                                      upNext: next, updated: .now)

        // Only redraw the widgets when something they show has changed.
        var comparable = snapshot
        comparable.updated = last?.updated ?? snapshot.updated
        guard comparable != last else { return }
        if snapshot.write() {
            last = snapshot
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func item(_ episode: Episode, position: Double) async -> WidgetSnapshot.Item {
        let duration = max(1, episode.duration)
        return WidgetSnapshot.Item(
            guid: episode.guid,
            title: episode.title,
            show: episode.podcast?.title ?? "",
            artwork: await thumbnail(episode.artworkURL ?? episode.podcast?.artworkURL),
            progress: min(1, max(0, position / duration)),
            remaining: max(0, duration - position),
            adFree: episode.processingState == .ready)
    }

    /// A 120-pixel JPEG of the cover, kept so the same covers aren't redrawn
    /// on every update.
    private func thumbnail(_ url: String?) async -> Data? {
        guard let url else { return nil }
        if let cached = thumbnails[url] { return cached }
        guard let image = await ImageCache.shared.load(url, size: 60) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: 120, height: 120))
        }
        let data = small.jpegData(compressionQuality: 0.7)
        if thumbnails.count > 40 { thumbnails.removeAll() }
        thumbnails[url] = data
        return data
    }
}
