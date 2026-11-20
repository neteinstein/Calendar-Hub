import Foundation
import UserNotifications

/// Posts macOS notifications: overlaps a sync made, and the morning summary. Asks for
/// permission the first time one is posted, not at launch, so someone who never turns either
/// on is never asked.
@MainActor
enum Notifier {
    /// Off in the demo, which must show nothing of its own.
    static var isEnabled = true

    private static var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter needs a bundle; a bare `swift run` binary has none and crashes.
        guard isEnabled, Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// Posts a notification now. `id` replaces an earlier one with the same id still on screen.
    static func post(id: String, title: String, body: String) {
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
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            } catch {
                AppLog.write("Calendar Hub: couldn't post a notification: \(error)")
            }
        }
    }
}
