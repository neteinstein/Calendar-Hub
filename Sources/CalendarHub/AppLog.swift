import AppKit
import CalendarHubCore
import Foundation
import SwiftUI

/// The app's log. Every line goes to the system log, as `NSLog` did; while debug logging is
/// on (Settings › About), lines are also kept in memory for Settings › Logs, and written to
/// `~/Library/Logs/Calendar Hub/debug.log`, so a crash or a quit at launch still leaves them behind.
@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()
    /// Whether debug logging is on. Kept across launches, so a problem at launch is logged too.
    nonisolated static let enabledKey = "debugLogging"

    @Published private(set) var log = DebugLog()

    nonisolated static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// The log on disk. Feedback sends it, so it includes earlier launches.
    nonisolated static let file = DebugLogFile(
        url: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Calendar Hub/debug.log"))

    /// Marks a launch in the log, and logs an Objective-C exception before it ends the app.
    nonisolated static func start() {
        guard isEnabled else { return }
        write("Calendar Hub started. \(versionLine)")
        NSSetUncaughtExceptionHandler { exception in
            AppLog.write("Calendar Hub stopped on an exception: \(exception.name.rawValue): \(exception.reason ?? "")\n"
                + exception.callStackSymbols.joined(separator: "\n"))
        }
    }

    /// Logs `message` from any thread.
    nonisolated static func write(_ message: String) {
        NSLog("%@", message)
        guard isEnabled else { return }
        let date = Date()
        // Written right away, on this thread: the next line could be the app's last.
        file.append("\(DebugLog.time(date)) \(message)")
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
            Self.file.remove()
        }
    }

    func clear() {
        log.clear()
        Self.file.remove()
    }

    /// Shows the log file in Finder.
    func revealFile() {
        NSWorkspace.shared.activateFileViewerSelecting([Self.file.url])
    }

    nonisolated static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    nonisolated static var system: String {
        "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    nonisolated static var versionLine: String { "Calendar Hub \(version), \(system)" }

    /// Opens a new GitHub issue. With debug logging on, the log goes with it: its newest lines
    /// in the issue's text, and the whole log on the clipboard to paste when it doesn't all fit.
    func sendFeedback(openURL: OpenURLAction) {
        guard Self.isEnabled else {
            openURL(UpdateChecker.repoPage.appendingPathComponent("issues"))
            return
        }
        // The file has earlier launches too, such as one that crashed.
        let saved = Self.file.text()
        let text = saved.isEmpty ? log.text() : saved
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let body = DebugLog.feedbackBody(version: Self.version, system: Self.system, log: text)
        openURL(DebugLog.newIssueURL(repo: UpdateChecker.repoPage, body: body))
    }
}
