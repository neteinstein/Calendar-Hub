import CalendarHubCore
import SwiftUI

@main
struct CalendarHubApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var controller: SyncController
    @StateObject private var alerts: EventAlertController
    @StateObject private var updates: UpdateChecker
    @StateObject private var tasks: TaskStore
    @StateObject private var taskNotes: TaskNotesWindows
    @StateObject private var clock = Clock()
    @StateObject private var menuBarItem = MenuBarItem.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Held until the process ends. See `InstanceLock`.
    private static var instanceLock: InstanceLock?

    init() {
        // The demo (sample calendars, for screenshots) runs next to the real app and leaves
        // Calendar.app, the Applications folder and the real settings alone.
        let demo = DemoCalendars.isRequested ? DemoCalendars() : nil
        if demo == nil {
            AppLog.start()
            Self.quitIfAlreadyRunning()
            RenameMigration.run()
            Self.linkIntoApplicationsOnce()
        }
        let settings = demo?.makeSettings() ?? SettingsStore()
        let controller = SyncController(settings: settings, demo: demo)
        let updates = UpdateChecker(defaults: demo?.defaults ?? .standard)
        let tasks = TaskStore(settings: settings, controller: controller)
        _settings = StateObject(wrappedValue: settings)
        _controller = StateObject(wrappedValue: controller)
        _updates = StateObject(wrappedValue: updates)
        _tasks = StateObject(wrappedValue: tasks)
        _taskNotes = StateObject(wrappedValue: TaskNotesWindows(settings: settings, controller: controller, tasks: tasks))
        _alerts = StateObject(wrappedValue: EventAlertController(settings: settings, eventKit: controller.eventKit,
                                                                 tasks: tasks, checks: demo == nil))
        if let demo, Snapshots.folder != nil {
            Snapshots.context = .init(settings: settings, controller: controller, updates: updates, tasks: tasks,
                                      defaults: demo.defaults)
            // Screenshots need no menu bar icon of their own.
            MenuBarItem.shared.isInserted = false
        }
    }

    /// A copy already running would sync the same calendars: an "Open at login" item next to
    /// a `brew services` one, or a source build next to a Homebrew one. Every copy shares the
    /// lock file, so a later one quits here, before it asks for calendar access, syncs or shows
    /// anything. Unless the one running is an older version: then this copy has it quit and
    /// carries on, so starting the app after an update is all it takes to run the new version.
    /// If the lock can't be taken at all, running beats not running.
    private static func quitIfAlreadyRunning() {
        guard instanceLock == nil else { return }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.neteinstein.calendarhub/instance.lock")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        do {
            guard let lock = try InstanceLock.acquire(at: url) ?? takeOver(at: url, version: version) else {
                AppLog.write("Calendar Hub is already running, so this copy quits.")
                AppDelegate.askRunningCopyToShowMenuBarItem()
                exit(0)
            }
            // For the next copy to start, which takes over only from an older one.
            lock.record(InstanceLock.Holder(pid: getpid(), version: version))
            instanceLock = lock
        } catch {
            AppLog.write("Calendar Hub couldn't check for another running copy, so it runs anyway: \(error)")
        }
    }

    /// Has an older copy holding the lock quit, and takes the lock once it's gone. nil when
    /// the running copy is as new as this one, can't be found, or won't go.
    private static func takeOver(at url: URL, version: String) throws -> InstanceLock? {
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() }
        // The lock file outlives the copy that wrote it, so only a holder still running counts.
        // Without one, the lock is held by a copy from before 2.0.15, which wrote nothing: any
        // of the others, so all of them go.
        let holder = InstanceLock.holder(at: url).flatMap { holder in
            others.contains { $0.processIdentifier == holder.pid } ? holder : nil
        }
        guard InstanceLock.replaces(holder, version: version) else { return nil }
        let old = holder.map { holder in others.filter { $0.processIdentifier == holder.pid } } ?? others
        guard !old.isEmpty else { return nil }
        AppLog.write("Calendar Hub \(version) takes over from the \(holder?.version ?? "older") copy that was running.")

        // Asked to quit first, so it saves what's open; ended if it hasn't after a while (a
        // dialog left open keeps it from quitting).
        old.forEach { $0.terminate() }
        if let lock = try acquire(at: url, within: 5) { return lock }
        old.forEach { $0.forceTerminate() }
        return try acquire(at: url, within: 3)
    }

    /// Tries for the lock until it's free or `seconds` have passed.
    private static func acquire(at url: URL, within seconds: TimeInterval) throws -> InstanceLock? {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let lock = try InstanceLock.acquire(at: url) { return lock }
            guard Date() < deadline else { return nil }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// A Homebrew install links itself into ~/Applications, through the opt path so the link
    /// follows upgrades. Skipped when /Applications already has the app, say a link an admin
    /// made. Only once: a link the user removes stays removed. If it fails, the next launch
    /// tries again.
    private static func linkIntoApplicationsOnce() {
        let defaults = UserDefaults.standard
        let key = "linkedIntoApplications"
        let fileManager = FileManager.default
        guard !defaults.bool(forKey: key),
              let target = ApplicationsLink.homebrewOptBundle(
                  forResolvedBundle: Bundle.main.bundleURL.resolvingSymlinksInPath()
              ),
              fileManager.fileExists(atPath: target.path)
        else { return }
        let home = fileManager.urls(for: .applicationDirectory, in: .userDomainMask)[0]
        let system = fileManager.urls(for: .applicationDirectory, in: .localDomainMask)[0]
        do {
            if try ApplicationsLink.ensure(linkTo: target, in: home, unlessIn: [system]) == .created {
                AppLog.write("Calendar Hub linked itself into \(home.path).")
            }
            defaults.set(true, forKey: key)
        } catch {
            AppLog.write("Calendar Hub couldn't link itself into \(home.path): \(error)")
        }
    }

    /// The icon in the menu bar: a calendar glyph, plus today's date when the menu calendar
    /// is on, and with it the week day when that is on too. With "Show the next meeting" on, a
    /// meeting about to start or under way takes the date's place, with a bar under it that fills
    /// as the meeting runs when that is on too. A badge on the glyph marks a
    /// sync with problems; menu bar labels are drawn in one color, so it's part of the symbol.
    /// `Clock` keeps the date and the minutes right as the minutes pass. Not a TimelineView: in a
    /// menu bar label it re-renders the button in an endless loop and the app hangs at launch.
    struct MenuBarLabel: View {
        @ObservedObject var settings: SettingsStore
        @ObservedObject var controller: SyncController
        @ObservedObject var clock: Clock

        /// "26 Oct", or "Mon 26 Oct" with the week day, in the locale's own field order.
        private var dateStyle: Date.FormatStyle {
            let style = Date.FormatStyle.dateTime.day().month(.abbreviated)
            return settings.menuBar.showsWeekday ? style.weekday(.abbreviated) : style
        }

        /// "Design review · 12m", when that's on and a meeting is close or under way.
        private var meetingText: String? {
            guard settings.menuBar.showsNextMeeting,
                  let meeting = controller.menuBarMeeting(now: clock.now) else { return nil }
            return MenuCalendar.menuBarText(for: meeting, now: clock.now)
        }

        /// How far through the meeting in `meetingText` it is, when its progress bar is on.
        private var meetingProgress: Double? {
            guard settings.menuBar.drawsMeetingProgress,
                  let meeting = controller.menuBarMeeting(now: clock.now) else { return nil }
            return MenuCalendar.menuBarProgress(for: meeting, now: clock.now)
        }

        var body: some View {
            let hasProblems = !controller.problems.isEmpty || controller.setupProblem != nil
            let text = meetingText
            if let text, let progress = meetingProgress {
                Image(nsImage: Self.progressImage(symbol: hasProblems ? Self.problemIcon : "calendar",
                                                  text: text, progress: progress))
                    .renderingMode(.template)
            } else if settings.menuShowsCalendar || text != nil {
                HStack(spacing: 3) {
                    Image(systemName: hasProblems ? Self.problemIcon : "calendar")
                    if let text {
                        Text(text)
                    } else {
                        Text(clock.now, format: dateStyle)
                    }
                }
            } else {
                Image(systemName: hasProblems ? Self.problemIcon : "calendar.badge.clock")
            }
        }

        /// In place of the plain calendar while the last sync had problems, so it can't be missed.
        private static let problemIcon = "calendar.badge.exclamationmark"

        /// The glyph and the meeting's text with a bar under the text that fills as the meeting
        /// runs, drawn into one template image: a menu bar label shows only its text and images,
        /// so a shape in it would never be drawn. Fits the menu bar's height.
        private static func progressImage(symbol: String, text: String, progress: Double) -> NSImage {
            let content = HStack(alignment: .center, spacing: 3) {
                Image(systemName: symbol)
                Text(text)
                    .padding(.bottom, 4)
                    .overlay(alignment: .bottom) {
                        Capsule().fill(.black.opacity(0.3))
                            .overlay(alignment: .leading) {
                                GeometryReader { bar in
                                    Capsule().frame(width: max(bar.size.width * progress, progress > 0 ? 2 : 0))
                                }
                            }
                            .frame(height: 2)
                    }
            }
            .font(Font(NSFont.menuBarFont(ofSize: 0)))
            .foregroundStyle(.black)
            .padding(.vertical, 1)
            let renderer = ImageRenderer(content: content)
            renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
            let image = renderer.nsImage ?? NSImage()
            image.isTemplate = true
            return image
        }
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $menuBarItem.isInserted) {
            MenuView()
                .environmentObject(settings)
                .environmentObject(controller)
                .environmentObject(updates)
                .environmentObject(tasks)
                .environment(\.openTaskNotes, OpenTaskNotesAction { [taskNotes] in taskNotes.show($0) })
        } label: {
            MenuBarLabel(settings: settings, controller: controller, clock: clock)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(controller)
                .environmentObject(updates)
                .environmentObject(tasks)
        }
    }
}

/// Whether the menu bar icon is in the menu bar, as the `MenuBarExtra`'s binding. Without a
/// binding, SwiftUI quits the app when the icon is removed: hidden in System Settings › Menu Bar,
/// or ⌘-dragged out. Then every launch ended a second later and nothing synced. With it the app
/// keeps running and syncing without the icon, and opening the app again puts the icon back.
@MainActor
final class MenuBarItem: ObservableObject {
    static let shared = MenuBarItem()

    /// Publishes only real changes: SwiftUI writes the binding back while it updates the scene,
    /// and publishing every write re-renders the scene, which writes it again, without end.
    var isInserted: Bool {
        get { inserted }
        set {
            guard newValue != inserted else { return }
            objectWillChange.send()
            inserted = newValue
            AppLog.write(newValue
                  ? "Calendar Hub's menu bar icon is back."
                  : "Calendar Hub's menu bar icon was removed. The app keeps syncing; open it again to bring the icon back.")
        }
    }

    private var inserted = true
}

/// Puts the menu bar icon back when the app is opened again while it runs.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Posted by a later copy as it quits, so opening the app again works whichever way it was
    /// started.
    nonisolated private static let showMenuBarItem = Notification.Name("org.neteinstein.calendarhub.showMenuBarItem")

    nonisolated static func askRunningCopyToShowMenuBarItem() {
        DistributedNotificationCenter.default().postNotificationName(
            showMenuBarItem, object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Snapshots.runIfRequested()
        DistributedNotificationCenter.default().addObserver(
            forName: Self.showMenuBarItem, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { MenuBarItem.shared.isInserted = true }
        }
    }

    /// Opening the app while it runs: Finder, Spotlight or `open`.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MenuBarItem.shared.isInserted = true
        return true
    }
}

/// The current minute, for the menu bar label. Ticks on the minute, so a shown time changes
/// when the system clock does, and the label redraws at most once a minute.
@MainActor
final class Clock: ObservableObject {
    @Published private(set) var now = Clock.minute(of: Date())
    private var timer: Timer?

    init() {
        // On the main run loop, so the block runs on the main actor; in the common modes, so
        // it keeps ticking while the menu is open.
        let timer = Timer(fire: now + 60, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        let minute = Self.minute(of: Date())
        if minute != now { now = minute }
    }

    /// `date` with its seconds dropped.
    private static func minute(of date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }
}
