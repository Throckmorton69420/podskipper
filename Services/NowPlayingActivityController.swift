import ActivityKit
import Foundation

/// Starts, updates and ends the Lock Screen card.
@MainActor
final class NowPlayingActivityController {
    static let shared = NowPlayingActivityController()
    private init() {}

    private var activity: Activity<NowPlayingAttributes>?
    private var lastState: NowPlayingAttributes.ContentState?
    private var lastUpdate = Date.distantPast

    static let enabledKey = "lockScreenShortcut"

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
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

        // Only when something a person would see has changed, and not more
        // than every few seconds: iOS budgets Live Activity updates.
        guard state.title != lastState?.title || state.isPlaying != lastState?.isPlaying
                || Date().timeIntervalSince(lastUpdate) > 30 else { return }
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
