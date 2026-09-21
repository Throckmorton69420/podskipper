import ActivityKit
import Foundation
import UIKit

/// Starts, updates and ends the Lock Screen card.
///
/// When it is shown: whenever PodSkipper has an episode loaded — playing or
/// paused — which is exactly when PodSkipper is what Now Playing shows. The
/// previous pass took it down on pause, and that defeated the point: a paused
/// episode is still in Now Playing and still wants a way back into the app.
/// It goes away when the app is swiped away (ended on termination, and again
/// at the next launch in case the close gave it no chance), when nothing is
/// loaded, and when the setting is off, which is the default. It is updated
/// only when the episode or play state changes; the countdown runs itself on
/// the Lock Screen.
@MainActor
final class NowPlayingActivityController {
    static let shared = NowPlayingActivityController()

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            Self.endAllBlocking()
        }
        // Anything left over from a run that ended without warning.
        Task { await Self.endAll() }
    }

    /// Call at launch so the leftover sweep runs.
    func start() {}

    nonisolated static func endAll() async {
        for activity in Activity<NowPlayingAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// The app is being closed: there is no later to finish this in.
    nonisolated static func endAllBlocking() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await endAll()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1.5)
    }

    private var activity: Activity<NowPlayingAttributes>?
    private var lastState: NowPlayingAttributes.ContentState?
    private var lastUpdate = Date.distantPast

    /// A new key, so everyone starts with it off — the old one defaulted on.
    static let enabledKey = "lockScreenShortcutOptIn"

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// The cover as a JPEG small enough for a Live Activity update (the
    /// whole update must stay under 4 KB), by artwork address.
    private var thumbnails: [String: Data] = [:]
    private var loadingThumbnail: String?

    /// Called whenever Now Playing changes. Cheap when nothing has.
    func sync(guid: String?, title: String, show: String, isPlaying: Bool,
              secondsSkipped: Double, elapsed: Double, duration: Double, rate: Double,
              published: Date?, artworkURL: String?) {
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled, let guid else {
            end()
            return
        }
        let remaining = max(0, duration - elapsed)
        var state = NowPlayingAttributes.ContentState(
            title: title, show: show, isPlaying: isPlaying,
            secondsSkipped: secondsSkipped,
            endsAt: isPlaying && remaining > 0 ? Date().addingTimeInterval(remaining / max(0.5, rate)) : nil,
            published: published,
            elapsed: elapsed, duration: duration, rate: rate,
            artwork: artworkURL.flatMap { thumbnails[$0] })

        if let artworkURL, thumbnails[artworkURL] == nil, loadingThumbnail != artworkURL {
            loadingThumbnail = artworkURL
            Task { [weak self] in
                let data = await Self.thumbnail(for: artworkURL)
                guard let self else { return }
                self.loadingThumbnail = nil
                if let data {
                    self.thumbnails[artworkURL] = data
                    // Send again with the cover now that there is one.
                    self.lastState = nil
                    self.sync(guid: guid, title: title, show: show, isPlaying: isPlaying,
                              secondsSkipped: secondsSkipped, elapsed: elapsed, duration: duration,
                              rate: rate, published: published, artworkURL: artworkURL)
                }
            }
        }
        if state.artwork == nil, let previous = lastState?.artwork, lastState?.title == title {
            state.artwork = previous
        }

        if let activity, activity.attributes.episodeGUID != guid {
            let old = activity
            self.activity = nil
            lastState = nil
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }

        if activity == nil {
            do {
                activity = try Activity.request(
                    attributes: NowPlayingAttributes(episodeGUID: guid),
                    content: .init(state: state, staleDate: nil),
                    pushType: nil)
                lastState = state
                lastUpdate = .now
            } catch {
                // Not permitted (Live Activities off for the app, or a
                // sideloaded signature iOS refuses). Nothing else to do.
            }
            return
        }

        // Only when something a person would see has changed. While playing
        // the bar and countdown move by themselves, so a drift under half a
        // minute is not worth waking the Lock Screen for; while paused, a
        // seek of more than a few seconds is.
        let drift = abs((state.endsAt ?? .distantPast).timeIntervalSince(lastState?.endsAt ?? .distantPast))
        let pausedMove = !isPlaying && abs(elapsed - (lastState?.elapsed ?? elapsed)) > 5
        guard state.title != lastState?.title || state.isPlaying != lastState?.isPlaying
                || state.artwork != lastState?.artwork
                || (isPlaying && drift > 30) || pausedMove else { return }
        lastState = state
        lastUpdate = .now
        let current = activity
        Task { await current?.update(.init(state: state, staleDate: nil)) }
    }

    /// A 72-pixel JPEG of the cover, shrunk until it fits.
    private static func thumbnail(for url: String) async -> Data? {
        guard let image = await ImageCache.shared.load(url, size: 72) else { return nil }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 72, height: 72),
                                               format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let small = renderer.image { _ in image.draw(in: CGRect(x: 0, y: 0, width: 72, height: 72)) }
        for quality in [0.6, 0.45, 0.3] {
            if let data = small.jpegData(compressionQuality: quality), data.count <= 2600 { return data }
        }
        return nil
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
