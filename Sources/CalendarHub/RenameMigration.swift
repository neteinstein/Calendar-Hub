import AppKit
import CalendarHubCore
import Foundation

/// The app was called Calendar Sync, with the bundle ID `org.neteinstein.calendarsync`, until
/// 2.1.0. A new bundle ID starts with nothing, so on the first launch of Calendar Hub this brings
/// across what Calendar Sync kept: its settings, the Outlook sign-in, and the link in
/// ~/Applications. On every launch it has a Calendar Sync still running quit, and holds the old
/// instance lock, so a Calendar Sync started later (an old login item, say) quits rather than
/// syncing the same calendars twice.
enum RenameMigration {
    static let oldBundleID = "org.neteinstein.calendarsync"
    static let oldAppName = "Calendar Sync.app"
    private static let doneKey = "migratedFromCalendarSync"

    /// Held until the process ends, like the app's own lock.
    private static var oldLock: InstanceLock?

    static func run() {
        quitOldCopies()
        holdOldLock()
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        let settings = copySettings(into: defaults)
        let websiteData = copyWebsiteData()
        relinkApplications(defaults)
        defaults.set(true, forKey: doneKey)
        if settings > 0 || websiteData {
            AppLog.write("Calendar Hub brought across \(settings) settings\(websiteData ? " and the Outlook sign-in" : "") from Calendar Sync.")
        }
    }

    /// Asked to quit first, so it saves what's open; ended if it hasn't after a while.
    private static func quitOldCopies() {
        let old = NSRunningApplication.runningApplications(withBundleIdentifier: oldBundleID)
        guard !old.isEmpty else { return }
        AppLog.write("Calendar Hub has the Calendar Sync that was running quit.")
        old.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while old.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        old.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    /// Calendar Sync quits when its lock is held by a copy it can't take over from, which a
    /// Calendar Hub always is.
    private static func holdOldLock() {
        let url = applicationSupport.appendingPathComponent("\(oldBundleID)/instance.lock")
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path),
              let lock = try? InstanceLock.acquire(at: url)
        else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        lock.record(InstanceLock.Holder(pid: getpid(), version: version))
        oldLock = lock
    }

    /// Every setting Calendar Sync kept that Calendar Hub hasn't set yet. Returns how many.
    private static func copySettings(into defaults: UserDefaults) -> Int {
        guard let old = defaults.persistentDomain(forName: oldBundleID) else { return 0 }
        var copied = 0
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        return copied
    }

    /// The Outlook web view's data stores (cookies, sign-in), kept by WebKit per bundle ID.
    /// Copied before any web view opens; left alone when Calendar Hub already has its own.
    private static func copyWebsiteData() -> Bool {
        let fileManager = FileManager.default
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let newID = Bundle.main.bundleIdentifier ?? "org.neteinstein.calendarhub"
        var copied = false
        for folder in ["WebKit", "HTTPStorages"] {
            let from = library.appendingPathComponent("\(folder)/\(oldBundleID)")
            let to = library.appendingPathComponent("\(folder)/\(newID)")
            guard fileManager.fileExists(atPath: from.path), !fileManager.fileExists(atPath: to.path) else { continue }
            do {
                try fileManager.copyItem(at: from, to: to)
                copied = true
            } catch {
                AppLog.write("Calendar Hub couldn't copy Calendar Sync's \(folder) data: \(error)")
            }
        }
        return copied
    }

    /// The link a Homebrew install of Calendar Sync made in ~/Applications goes, and Calendar
    /// Hub makes its own (see `linkIntoApplicationsOnce`). A copy the user put there isn't a
    /// Homebrew link and stays.
    private static func relinkApplications(_ defaults: UserDefaults) {
        let fileManager = FileManager.default
        let link = fileManager.urls(for: .applicationDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(oldAppName)
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path),
              destination.contains("/opt/calendar-sync/")
        else { return }
        do {
            try fileManager.removeItem(at: link)
            defaults.set(false, forKey: "linkedIntoApplications")
        } catch {
            AppLog.write("Calendar Hub couldn't remove Calendar Sync's link in ~/Applications: \(error)")
        }
    }

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}
