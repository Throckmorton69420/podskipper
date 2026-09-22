import Foundation

/// What the Home Screen widgets show, written by the app and read by the
/// widget extension.
///
/// Widgets run in their own process and can't open the app's database. The
/// supported way to hand them data is an App Group — a folder both can read —
/// and an App Group needs a paid developer account (it is an entitlement in
/// the provisioning profile). So:
///
/// • With an App Group (a paid account): the app writes this small file after
///   anything the widgets show changes, and asks WidgetKit to redraw.
/// • Without one (today's sideloaded build): `folder` is nil, nothing is
///   written, and the widgets say to open PodSkipper. Nothing else changes.
///
/// The group identifier must match the one in `Support/PodSkipper-Paid.entitlements`
/// and `Support/Widgets-Paid.entitlements`.
struct WidgetSnapshot: Codable, Hashable, Sendable {

    static let appGroup = "group.com.yourname.podskipper"
    static let fileName = "widget-snapshot.json"

    struct Item: Codable, Hashable, Sendable, Identifiable {
        var guid: String
        var title: String
        var show: String
        /// A small JPEG of the cover (about 120 px), because a widget can't
        /// load images from the network.
        var artwork: Data?
        /// 0…1 through the episode.
        var progress: Double
        /// Seconds left, at normal speed.
        var remaining: Double
        var adFree: Bool
        var id: String { guid }
    }

    var nowPlaying: Item?
    var isPlaying: Bool
    var upNext: [Item]
    var updated: Date

    /// The shared folder, or nil when the build has no App Group.
    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static func read() -> WidgetSnapshot? {
        guard let url = folder?.appendingPathComponent(fileName),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    /// Returns false when there is nowhere to write it.
    @discardableResult
    func write() -> Bool {
        guard let url = Self.folder?.appendingPathComponent(Self.fileName),
              let data = try? JSONEncoder().encode(self) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// For previews, the in-app gallery and the widget picker.
    static let sample = WidgetSnapshot(
        nowPlaying: Item(guid: "sample-now", title: "Crossing the Pennines on a Tandem Nobody Asked For",
                         show: "The Long Way Round", artwork: nil, progress: 0.34, remaining: 3880, adFree: true),
        isPlaying: true,
        upNext: [
            Item(guid: "sample-1", title: "The Zip Drive Was Actually Fine, Everyone",
                 show: "Hard Drive Full", artwork: nil, progress: 0.1, remaining: 4700, adFree: true),
            Item(guid: "sample-2", title: "#199 - Are You Garbage?",
                 show: "Quiet Hours", artwork: nil, progress: 0, remaining: 6660, adFree: true),
            Item(guid: "sample-3", title: "The Night Shift at a Twenty-Four Hour Bakery",
                 show: "Quiet Hours", artwork: nil, progress: 0, remaining: 5640, adFree: false),
        ],
        updated: .now)
}

enum WidgetLinks {
    /// Plays one episode (podskipper://play/<guid>).
    static func play(_ guid: String) -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let escaped = guid.addingPercentEncoding(withAllowedCharacters: allowed) ?? guid
        return URL(string: "podskipper://play/\(escaped)") ?? NowPlayingLink.player
    }
}
