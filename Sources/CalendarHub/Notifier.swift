import AppKit
import UserNotifications

/// Posts macOS notifications: overlaps a sync made, the morning summary, and meeting alerts
/// shown as notifications. Asks for permission the first time one is posted, not at launch,
/// so someone who never turns any on is never asked.
@MainActor
enum Notifier {
    /// Off in the demo, which must show nothing of its own.
    static var isEnabled = true

    private static var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter needs a bundle; a bare `swift run` binary has none and crashes.
        guard isEnabled, Bundle.main.bundleIdentifier != nil else { return nil }
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = ClickHandler.shared }
        return center
    }

    /// Posts a notification now. `id` replaces an earlier one with the same id still on screen.
    /// With `opens`, clicking it opens that link (a meeting's join link). `sound` plays the
    /// default sound with it.
    static func post(id: String, title: String, body: String, opens url: URL? = nil, sound: Bool = false) {
        guard let center else { return }
        Task {
            let granted: Bool
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional: granted = true
            case .notDetermined: granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            default: granted = false
            }
            guard granted else {
                AppLog.write("Calendar Hub: notifications aren't allowed, so \"\(title)\" wasn't shown")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let url { content.userInfo = [ClickHandler.urlKey: url.absoluteString] }
            if sound { content.sound = .default }
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            } catch {
                AppLog.write("Calendar Hub: couldn't post a notification: \(error)")
            }
        }
    }
}

/// Opens a notification's link when it's clicked, and shows notifications while Calendar Hub
/// is the active app (the menu open), which macOS otherwise holds back.
private final class ClickHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ClickHandler()
    static let urlKey = "url"

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let link = response.notification.request.content.userInfo[Self.urlKey] as? String,
           let url = URL(string: link) {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
