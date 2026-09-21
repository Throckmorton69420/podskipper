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

    /// Called whenever Now Playing changes. Cheap when nothing has.
    func sync(guid: String?, title: String, show: String, isPlaying: Bool,
              secondsSkipped: Double, remaining: Double, rate: Double) {
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled, let guid else {
            end()
            return
        }
        let state = NowPlayingAttributes.ContentState(
            title: title, show: show, isPlaying: isPlaying,
            secondsSkipped: secondsSkipped,
            endsAt: isPlaying && remaining > 0 ? Date().addingTimeInterval(remaining / max(0.5, rate)) : nil)

        if let activity, activity.attributes.episodeGUID != guid {
            let old = activity
            self.activity = nil
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

        // Only when something a person would see has changed. The end time
        // moves with seeks and speed changes; a drift under half a minute is
        // not worth waking the Lock Screen for.
        let drift = abs((state.endsAt ?? .distantPast).timeIntervalSince(lastState?.endsAt ?? .distantPast))
        guard state.title != lastState?.title || state.isPlaying != lastState?.isPlaying
                || drift > 30 else { return }
        lastState = state
        lastUpdate = .now
        let current = activity
        Task { await current?.update(.init(state: state, staleDate: nil)) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
