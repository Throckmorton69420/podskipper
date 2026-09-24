import Foundation
import Observation
import UserNotifications
import UIKit

/// Where the app has been asked to go from outside a screen: a notification
/// tap, or a job that was stopped while the app was away.
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    /// Set to an episode's guid to open its status sheet. RootView presents
    /// it and clears this.
    var statusEpisodeGUID: String?

    /// A page to open in the tab behind the player — its ⋯ menu's Go to Show
    /// and Episode Details. RootView closes the player and pushes it onto
    /// the tab's own navigation path, as Apple Podcasts does.
    var pendingRoute: PendingRoute?

    enum PendingRoute: Hashable {
        case show(ShowRoute)
        case episode(EpisodeRoute)
    }

    func open(_ route: ShowRoute) { pendingRoute = .show(route) }
    func open(_ route: EpisodeRoute) { pendingRoute = .episode(route) }

    /// A job the system stopped in the background, so the next time the app
    /// comes to the front it opens on that episode. This is the only way to
    /// answer a tap on the system's own "failed" notification — iOS draws that
    /// one and gives the app no way to know it was tapped.
    private let interruptedKey = "interruptedJob"

    func noteInterrupted(_ guid: String) {
        UserDefaults.standard.set(["guid": guid, "at": Date().timeIntervalSince1970],
                                  forKey: interruptedKey)
    }

    /// Called when the app becomes active. Opens the interrupted episode if
    /// it stopped within the last few hours; older than that is stale news.
    func openInterruptedIfAny() {
        guard let entry = UserDefaults.standard.dictionary(forKey: interruptedKey),
              let guid = entry["guid"] as? String,
              let at = entry["at"] as? Double else { return }
        UserDefaults.standard.removeObject(forKey: interruptedKey)
        guard Date().timeIntervalSince1970 - at < 6 * 3600 else { return }
        statusEpisodeGUID = guid
    }
}

/// Receives taps on PodSkipper's own notifications and routes them.
///
/// Without a delegate a tap just opens the app wherever it last was, which is
/// what the "tap the failure, land nowhere near it" report was.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// Must be set before launch finishes, or a tap that launched the app is
    /// delivered to nobody.
    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let guid = response.notification.request.content.userInfo["episode"] as? String
        Task { @MainActor in
            if let guid { AppRouter.shared.statusEpisodeGUID = guid }
            completionHandler()
        }
    }

    /// In the app already: still show it, as a banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
