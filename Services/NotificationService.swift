import Foundation
import UserNotifications
import SwiftData

/// New-episode alerts.
///
/// These are local notifications posted when a background refresh finds
/// something new — no push server, nothing leaves the phone. A show only
/// notifies if you turned it on in that show's settings.
enum NotificationService {

    static func requestPermissionIfNeeded(settings: AppSettings) async {
        guard settings.notificationsEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings()
        guard current.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Ask for permission because the user just switched it on.
    @discardableResult
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        return granted
    }

    static func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    /// Post one alert per show, not one per episode — three new episodes of a
    /// daily show should be a single line, not three buzzes.
    static func notifyNewEpisodes(_ episodes: [Episode], settings: AppSettings) async {
        guard settings.notificationsEnabled, await isAuthorized() else { return }

        let wanted = episodes.filter { $0.podcast?.notifyOnNewEpisodes == true }
        guard !wanted.isEmpty else { return }

        let byShow = Dictionary(grouping: wanted) { $0.podcast?.title ?? "A show" }

        for (show, items) in byShow {
            let content = UNMutableNotificationContent()
            content.title = show
            if items.count == 1 {
                content.body = items[0].title
                // Tapping it opens that episode.
                content.userInfo = ["episode": items[0].guid]
            } else {
                content.body = "\(items.count) new episodes"
            }
            content.sound = .default
            content.threadIdentifier = show

            let request = UNNotificationRequest(
                identifier: "new-\(show.hashValue)-\(Int(Date().timeIntervalSince1970))",
                content: content,
                trigger: nil          // deliver now
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// A job on one episode that didn't finish while the app was away.
    ///
    /// Tapping it opens that episode's status, which says where it is *now* —
    /// still stuck, running again, or done — rather than what it was when the
    /// notification was written.
    static func notifyJobProblem(_ episode: Episode, title: String, body: String) async {
        guard await isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = episode.title
        content.body = body
        content.sound = .default
        content.userInfo = ["episode": episode.guid]
        content.threadIdentifier = "jobs"
        let request = UNNotificationRequest(identifier: "job-\(episode.guid)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    static func clearDelivered() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
