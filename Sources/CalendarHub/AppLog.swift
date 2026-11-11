import AppKit
import CalendarHubCore
import Foundation
import SwiftUI

/// The app's log. Every line goes to the system log, as `NSLog` did; while debug logging is
/// on (Settings › About), lines are also kept in memory for Settings › Logs and for feedback.
@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()
    /// Whether debug logging is on. Kept across launches, so a problem at launch is logged too.
    static let enabledKey = "debugLogging"

    @Published private(set) var log = DebugLog()

    nonisolated static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Logs `message` from any thread.
    nonisolated static func write(_ message: String) {
        NSLog("%@", message)
        guard isEnabled else { return }
        let date = Date()
        if Thread.isMainThread {
            MainActor.assumeIsolated { shared.log.append(message, at: date) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { shared.log.append(message, at: date) } }
        }
    }

    /// Turns debug logging on or off. Turning it off drops the lines kept.
    func setEnabled(_ enabled: Bool) {
        guard enabled != Self.isEnabled else { return }
        if enabled {
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            Self.write("Calendar Hub: debug logging on. \(Self.versionLine)")
        } else {
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            log.clear()
        }
    }

    func clear() { log.clear() }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var system: String {
        "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    static var versionLine: String { "Calendar Hub \(version), \(system)" }

    /// Opens a new GitHub issue. With debug logging on, the log goes with it: its newest lines
    /// in the issue's text, and the whole log on the clipboard to paste when it doesn't all fit.
    func sendFeedback(openURL: OpenURLAction) {
        guard Self.isEnabled else {
            openURL(UpdateChecker.repoPage.appendingPathComponent("issues"))
            return
        }
        let text = log.text()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let body = DebugLog.feedbackBody(version: Self.version, system: Self.system, log: text)
        openURL(DebugLog.newIssueURL(repo: UpdateChecker.repoPage, body: body))
    }
}
