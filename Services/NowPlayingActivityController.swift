import ActivityKit
import Foundation
import UIKit

/// Starts, updates and ends the Lock Screen card.
///
/// Reported: it sat in the Dynamic Island the whole time, stayed there after
/// the app was swiped away, and looked like a battery cost. All three were
/// fair. It is now off unless turned on in Settings, it is only up while
/// something is actually playing — pausing takes it down — it is updated only
/// when the episode or play state changes (the countdown runs itself on the
/// Lock Screen, so it needs no ticking from here), and it is ended when the
/// app is closed and again at every launch, in case a close gave it no chance.
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
        guard isEnabled, isPlaying, ActivityAuthorizationInfo().areActivitiesEnabled, let guid else {
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
