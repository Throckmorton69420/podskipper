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

    /// What a widget row needs, read off the main thread.
    private struct Row: Sendable {
        var guid: String, title: String, show: String, artwork: String?
        var duration: Double, position: Double, ready: Bool
    }

    /// Pass 55 (his 30 Oct phone, build 1c40b4f): iOS ended PodSkipper as
    /// it went to the background — "scene-update watchdog", 10 s — with the
    /// main thread inside this update, waiting on SQLite for the episodes'
    /// details while the library was busy elsewhere. The library is now read
    /// on a context of its own, off the main thread; only the saved state is
    /// seen (the playing position comes from the player).
    private func update() async {
        let player = PlayerEngine.shared
        guard let container = AppLibrary.context?.container else { return }
        let currentGUID = player.currentEpisode?.guid
        let position = player.currentTime
        let isPlaying = player.isPlaying
        let rows = await Task.detached(priority: .utility) { () -> (now: Row?, next: [Row]) in
            let context = ModelContext(container)
            var current: Episode?
            if let guid = currentGUID {
                var one = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
                one.fetchLimit = 1
                current = try? context.fetch(one).first
            }
            var upcoming = NextUpProvider.upcoming(in: context, after: current, limit: 6)
            if upcoming.isEmpty {
                var queue = FetchDescriptor<Episode>(predicate: #Predicate { $0.isInQueue && !$0.isPlayed },
                                                     sortBy: [SortDescriptor(\.queueOrder)])
                queue.fetchLimit = 6
                upcoming = (try? context.fetch(queue)) ?? []
            }
            func row(_ e: Episode, at position: Double) -> Row {
                Row(guid: e.guid, title: e.title, show: e.podcast?.title ?? "",
                    artwork: e.artworkURL ?? e.podcast?.artworkURL, duration: max(1, e.duration),
                    position: position, ready: e.processingState == .ready)
            }
            return (current.map { row($0, at: position) },
                    upcoming.filter { $0.guid != currentGUID }.map { row($0, at: $0.playbackPosition) })
        }.value

        var nowPlaying: WidgetSnapshot.Item?
        if let now = rows.now { nowPlaying = await item(now) }
        var next: [WidgetSnapshot.Item] = []
        for row in rows.next { next.append(await item(row)) }
        let snapshot = WidgetSnapshot(nowPlaying: nowPlaying, isPlaying: isPlaying,
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

    private func item(_ row: Row) async -> WidgetSnapshot.Item {
        WidgetSnapshot.Item(
            guid: row.guid,
            title: row.title,
            show: row.show,
            artwork: await thumbnail(row.artwork),
            progress: min(1, max(0, row.position / row.duration)),
            remaining: max(0, row.duration - row.position),
            adFree: row.ready)
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
