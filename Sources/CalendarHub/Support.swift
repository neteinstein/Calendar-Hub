import AppKit
import CalendarHubCore
import Foundation

/// Donations: the donate page, and what the menu's occasional ask for one remembers.
@MainActor
enum Support {
    /// When this copy first ran a version with the ask, so it waits a while before the first one.
    static let firstRunKey = "supportFirstRun"
    /// When "Later" was last chosen on the ask.
    static let putAwayKey = "supportNudgePutAway"
    /// Set for good after a donation (the donate page opened from anywhere in the app) or
    /// "Don't Ask Again"; cleared by the checkbox in Settings › About.
    static let stoppedKey = "supportNudgeStopped"

    /// Off for the README's screenshots.
    static var showsNudge = true

    /// Opens the donate page, and stops the ask: whoever opened it has donated or chose not to.
    static func donate() {
        UserDefaults.standard.set(true, forKey: stoppedKey)
        NSWorkspace.shared.open(UpdateChecker.donatePage)
    }

    /// Notes the first run, at launch.
    static func recordFirstRun(_ defaults: UserDefaults = .standard, now: Date = Date()) {
        if defaults.object(forKey: firstRunKey) == nil {
            defaults.set(now.timeIntervalSince1970, forKey: firstRunKey)
        }
    }

    static func nudgeIsDue(now: Date, firstRun: Double, putAway: Double, stopped: Bool) -> Bool {
        guard showsNudge, firstRun > 0 else { return false }
        return SupportNudge.isDue(now: now,
                                  firstRun: Date(timeIntervalSince1970: firstRun),
                                  lastPutAway: putAway > 0 ? Date(timeIntervalSince1970: putAway) : nil,
                                  stopped: stopped)
    }
}
