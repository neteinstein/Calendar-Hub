import AppKit
import CalendarHubCore
import EventKit
import SwiftUI

/// Sample calendars and meetings shown in place of the user's own, for screenshots and demos:
/// set `CALENDAR_HUB_DEMO` (or `CALENDAR_HUB_SNAPSHOTS`) in the environment. Nothing is read
/// from or written to Calendar.app, and settings go to a separate defaults domain.
@MainActor
final class DemoCalendars {
    static var isRequested: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CALENDAR_HUB_DEMO"] != nil || environment["CALENDAR_HUB_SNAPSHOTS"] != nil
    }

    /// Only for making the calendar objects; they are never saved.
    private let store: EKEventStore
    let main: EKCalendar
    let calendarA: EKCalendar
    let personal: EKCalendar
    /// The Reminders list the sample tasks are in.
    let reminders: EKCalendar
    let sourceA = UUID()
    let sourceX = UUID()
    let defaults: UserDefaults

    init() {
        let store = EKEventStore()
        self.store = store
        func calendar(_ title: String, _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> EKCalendar {
            let calendar = EKCalendar(for: .event, eventStore: store)
            calendar.title = title
            calendar.cgColor = CGColor(red: red, green: green, blue: blue, alpha: 1)
            return calendar
        }
        main = calendar("Work", 0.07, 0.65, 0.58)
        calendarA = calendar("Calendar A", 0.55, 0.36, 0.96)
        personal = calendar("Personal", 0.95, 0.35, 0.45)
        reminders = EKCalendar(for: .reminder, eventStore: store)
        reminders.title = "Reminders"
        reminders.cgColor = CGColor(red: 1, green: 0.58, blue: 0, alpha: 1)
        let suite = "org.neteinstein.calendarhub.demo"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    var calendars: [EKCalendar] { [main, calendarA, personal] }

    /// Settings for the sample calendars: Work is the main calendar, Calendar A comes from
    /// Calendar.app, Client X from Outlook on the web, and the menu shows everything.
    func makeSettings() -> SettingsStore {
        let settings = SettingsStore(defaults: defaults)
        settings.targetCalendarID = main.calendarIdentifier
        settings.sources = [
            SourceConfig(id: sourceA, kind: .eventKit(calendarID: calendarA.calendarIdentifier), calendarName: "Calendar A",
                         showBusyInSecondary: true),
            SourceConfig(id: sourceX, kind: .outlookWeb, calendarName: "Client X", name: "Client X"),
        ]
        settings.twoWaySync = true
        settings.menuCalendarEnabled = true
        settings.menuCalendar.showsMeetingStats = true
        settings.worldClocks = WorldClockOptions(showsInMenu: true, clocks: [
            WorldClock(name: "New York", timeZoneID: "America/New_York"),
            WorldClock(name: "São Paulo", timeZoneID: "America/Sao_Paulo",
                       workingHours: WorkingHours(start: 10 * 60, end: 18 * 60)),
            WorldClock(name: "Berlin", timeZoneID: "Europe/Berlin"),
        ])
        settings.menuBar.showsNextMeeting = true
        settings.options.daysAhead = 14
        return settings
    }

    /// What the menu and Settings show for the last sync.
    var sourceStatus: [UUID: SyncController.SourceStatus] {
        let lastRead = Date().addingTimeInterval(-2 * 60)
        return [sourceA: .init(lastRead: lastRead, copies: 18), sourceX: .init(lastRead: lastRead, copies: 9)]
    }

    // MARK: - Tasks

    /// The sample tasks, changed here as the Tasks view changes them. Reminders is never touched.
    private(set) lazy var tasks: [TaskItem] = sampleTasks()

    func save(_ task: TaskItem) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.append(task)
        }
    }

    func remove(_ task: TaskItem) {
        tasks.removeAll { $0.id == task.id }
    }

    /// Notes in Markdown for the notes window's screenshot.
    private static let designDocNotes = """
        ## What to look at
        - **Navigation:** does the new sidebar hold up on a small screen?
        - The contrast of the *secondary* buttons
        - [x] Skim the summary
        - [ ] Read the open questions

        > Ana wants a decision on the color tokens.

        The doc: [Design review v3](https://example.com/design-v3)
        """

    /// Tasks to prepare two of today's meetings, a few others, and one done.
    private func sampleTasks() -> [TaskItem] {
        let calendar = Calendar.current
        let now = Date()
        let meetings = today()
        func link(_ title: String) -> TaskEventLink? {
            meetings.first { $0.title.hasSuffix(title) }.map { TaskEventLink($0) }
        }
        func at(_ hour: Int, inDays days: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: days, to: now)!
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        }
        var tasks: [TaskItem] = []
        if let review = link("Design review") {
            tasks.append(TaskItem(title: "Read the design doc", notes: Self.designDocNotes, due: review.start,
                                  nudges: [review.start - 5 * 60], event: review))
            tasks.append(TaskItem(title: "Bring the latest mockups", due: review.start, event: review))
        }
        if let oneOnOne = link("1:1 with Ana") {
            tasks.append(TaskItem(title: "Write down topics for Ana", due: oneOnOne.start,
                                  nudges: [oneOnOne.start - 30 * 60], event: oneOnOne))
        }
        tasks += [
            TaskItem(title: "Send the sprint notes", due: at(17), nudges: [at(16)]),
            TaskItem(title: "Book flights to Paris", due: calendar.startOfDay(for: at(9, inDays: 1)), dueHasTime: false,
                     nudges: [at(9, inDays: 1)]),
            TaskItem(title: "Renew the passport", creationDate: now - 3 * 86400),
            TaskItem(title: "Review the Q4 roadmap", isCompleted: true, completionDate: now - 3600),
        ]
        return tasks.enumerated().map { index, task in
            var task = task
            task.id = "demo-task-\(index)"
            task.creationDate = task.creationDate ?? now - Double(index) * 60
            return task
        }
    }

    // MARK: - Events

    /// The events of a sample calendar between `start` and `end`. Today's are placed around the
    /// current time, so the next meeting is always a few minutes away.
    func events(calendarID: String, from start: Date, to end: Date) -> [SourceEvent] {
        guard calendarID == main.calendarIdentifier else { return [] }
        let calendar = Calendar.current
        var events: [SourceEvent] = []
        var day = calendar.startOfDay(for: start)
        while day < end {
            events += calendar.isDateInToday(day) ? today() : sampleDay(day, calendar: calendar)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return events.filter { $0.end > start && $0.start < end }
    }

    private static let teams = URL(string: "https://teams.microsoft.com/l/meetup-join/demo")!
    private static let zoom = URL(string: "https://acme.zoom.us/j/123456789")!
    private static let meet = URL(string: "https://meet.google.com/abc-defg-hij")!

    /// An event in the main calendar: its own, or a copy titled and tagged the way syncing
    /// makes them.
    private func event(_ title: String, _ start: Date, minutes: Int, from source: UUID? = nil,
                       url: URL? = nil, location: String? = nil, allDay: Bool = false) -> SourceEvent {
        let prefix = source == sourceA ? "[Calendar A] " : source == sourceX ? "[Client X] " : ""
        // By day, not start: today's meetings follow the clock, and the sample tasks for them
        // must still find them.
        let key = "\(title)|\(Calendar.current.startOfDay(for: start).timeIntervalSince1970)"
        let notes = source.map { CopyFormatter.notes(meetingURL: url, marker: CopyMarker(sourceID: $0, key: key)) }
        return SourceEvent(key: key, title: prefix + title, start: start,
                           end: start.addingTimeInterval(Double(minutes) * 60), isAllDay: allDay,
                           meetingURL: url, notes: notes, location: location)
    }

    /// Today: two meetings done, one in about a quarter of an hour, three more later.
    private func today() -> [SourceEvent] {
        let calendar = Calendar.current
        let now = Date()
        // On the last five minutes, so the countdown reads 10 to 15 minutes.
        let t0 = Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 300).rounded(.down) * 300)
        func at(_ minutes: Int) -> Date { t0.addingTimeInterval(Double(minutes) * 60) }
        return [
            event("Lisbon office day", calendar.startOfDay(for: now), minutes: 24 * 60, allDay: true),
            event("Standup", at(-100), minutes: 15, from: sourceA, url: Self.teams),
            event("Sprint planning", at(-75), minutes: 60, from: sourceA, url: Self.teams),
            event("Design review", at(15), minutes: 45, url: Self.zoom, location: "Room 2.04"),
            event("1:1 with Ana", at(135), minutes: 30, location: "Ana's desk"),
            event("Architecture sync", at(225), minutes: 60, from: sourceA, url: Self.teams),
            event("Status call", at(315), minutes: 30, from: sourceX, url: Self.teams),
        ]
    }

    /// Any other day: a standup on weekdays and a few meetings that change from day to day.
    private func sampleDay(_ day: Date, calendar: Calendar) -> [SourceEvent] {
        guard !calendar.isDateInWeekend(day) else { return [] }
        func at(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        let n = calendar.ordinality(of: .day, in: .era, for: day) ?? 0
        var events = [event("Standup", at(9, 30), minutes: 15, from: sourceA, url: Self.teams)]
        if n % 2 == 0 { events.append(event("Roadmap review", at(11), minutes: 60, location: "Room 3.01")) }
        if n % 3 == 0 { events.append(event("Weekly sync", at(14), minutes: 60, from: sourceX, url: Self.teams)) }
        if n % 3 == 1 { events.append(event("API review", at(15), minutes: 60, from: sourceA, url: Self.teams)) }
        if n % 4 == 1 { events.append(event("Discovery workshop", at(10), minutes: 90, from: sourceX, url: Self.meet,
                                            location: "Client office")) }
        if n % 5 == 2 {
            // Two that overlap, so Meeting Stats has overlap to show.
            events.append(event("Hiring panel", at(16), minutes: 60, url: Self.zoom))
            events.append(event("Retro", at(16, 30), minutes: 60, from: sourceA, url: Self.teams))
        }
        return events
    }
}

// MARK: - Screenshots

/// Renders the menu, the alert, the menu bar item and every Settings pane to PNG files, in
/// light and dark, then quits. Run by `scripts/screenshots.sh` with `CALENDAR_HUB_SNAPSHOTS`
/// set to the folder to write to. Uses the demo calendars, never the user's.
@MainActor
enum Snapshots {
    struct Context {
        let settings: SettingsStore
        let controller: SyncController
        let updates: UpdateChecker
        let tasks: TaskStore
        let defaults: UserDefaults
    }

    /// Set by the app at launch when screenshots were asked for.
    static var context: Context?

    static var folder: URL? {
        ProcessInfo.processInfo.environment["CALENDAR_HUB_SNAPSHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func runIfRequested() {
        guard let folder, let context else { return }
        MeetingStatsView.showsEverything = true
        Task {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Let the demo sync settle first.
            try? await Task.sleep(for: .seconds(1))
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                await render(context, appearance: appearance, suffix: suffix, to: folder)
            }
            AppLog.write("Calendar Hub: screenshots written to \(folder.path)")
            NSApp.terminate(nil)
        }
    }

    private static func render(_ context: Context, appearance: NSAppearance.Name, suffix: String, to folder: URL) async {
        func environment<V: View>(_ view: V) -> some View {
            view
                .environmentObject(context.settings)
                .environmentObject(context.controller)
                .environmentObject(context.updates)
                .environmentObject(context.tasks)
                .defaultAppStorage(context.defaults)
        }
        for mode in ["month", "list", "tasks", "clocks", "stats"] {
            context.defaults.set(mode, forKey: "menuCalendarMode")
            await shoot(environment(MenuDesk { MenuView() }), "menu-\(mode)-\(suffix)", appearance, to: folder)
        }
        if var next = context.controller.menuBarMeeting(now: Date()) {
            // As the alert first shows: a minute before the start.
            let length = next.end.timeIntervalSince(next.start)
            next.start = Date().addingTimeInterval(59)
            next.end = next.start.addingTimeInterval(length)
            await shoot(AlertDesk(event: next, origin: EventOrigin.of(next, settings: context.settings,
                                                                     eventKit: context.controller.eventKit),
                                  prepare: context.tasks.openTasks(forEvent: next.key).map(\.title)),
                        "alert-\(suffix)", appearance, to: folder, settle: 2)
        }
        if let task = context.tasks.tasks.first(where: { $0.notes?.isEmpty == false }) {
            await shoot(environment(WindowFrame(title: task.title) {
                TaskNotesView(draft: TaskNotesDraft(task: task, tasks: context.tasks)).frame(width: 480, height: 470)
            }), "task-notes-\(suffix)", appearance, to: folder)
        }
        await shoot(environment(MenuBarStrips(settings: context.settings, controller: context.controller)),
                    "menu-bar-\(suffix)", appearance, to: folder)
        for pane in SettingsPane.allCases where pane != .preview && pane != .logs {
            context.defaults.set(pane.rawValue, forKey: SettingsPane.defaultsKey)
            await shoot(environment(WindowFrame(title: pane.title) { SettingsView() }),
                        "settings-\(pane.rawValue)-\(suffix)", appearance, to: folder)
        }
    }

    /// Lays `view` out in a borderless window off screen, waits for its animations, and
    /// writes it to `<name>.png` at the screen's scale.
    private static func shoot<V: View>(_ view: V, _ name: String, _ appearance: NSAppearance.Name,
                                       to folder: URL, settle: Double = 1.5) async {
        // Drawn as in the window in front: sidebars and controls otherwise come out dimmed.
        let host = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
        let size = host.fittingSize
        let window = SnapshotWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: max(size.width, 100),
                                                        height: max(size.height, 100)),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(host.fittingSize)
        // Not activating the app, and not made key: a run would otherwise take the keyboard
        // from whatever the user is typing in, once per screenshot.
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(settle))
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: folder.appendingPathComponent(name + ".png"))
        window.orderOut(nil)
    }
}

/// A borderless window that says it's the key one without being it, so what it shows draws as
/// in the window in front (sidebars and controls otherwise come out dimmed) while the app
/// stays in the background.
private final class SnapshotWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// A slice of desktop under the menu bar, with the menu open below its icon.
private struct MenuDesk<Content: View>: View {
    @ViewBuilder let content: Content
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Spacer()
                MenuBarItemPreview(settings: settings, controller: controller, highlighted: true)
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Text(Date(), format: .dateTime.weekday().day().month().hour().minute())
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16)
            .frame(height: 28)
            .background(.black.opacity(0.18))
            HStack {
                Spacer()
                content
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                    .padding(.trailing, 120)
            }
            Spacer(minLength: 48)
        }
        .frame(width: 640)
        .background(Wallpaper())
    }
}

/// The menu bar item as the menu bar draws it.
private struct MenuBarItemPreview: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: SyncController
    var highlighted = false
    @StateObject private var clock = Clock()

    var body: some View {
        CalendarHubApp.MenuBarLabel(settings: settings, controller: controller, clock: clock)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(highlighted ? Color.primary.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// The menu bar item with the date, then with the next meeting, then with its progress bar too.
private struct MenuBarStrips: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: SyncController

    var body: some View {
        VStack(spacing: 12) {
            strip(showsNextMeeting: false)
            strip(showsNextMeeting: true)
            strip(showsNextMeeting: true, showsMeetingProgress: true)
        }
        .padding(20)
        .frame(width: 520)
        .background(Wallpaper())
    }

    private func strip(showsNextMeeting: Bool, showsMeetingProgress: Bool = false) -> some View {
        let shown = SettingsStore(defaults: UserDefaults(
            suiteName: "org.neteinstein.calendarhub.demo.strip\(showsNextMeeting)\(showsMeetingProgress)")!)
        shown.menuCalendarEnabled = true
        shown.targetCalendarID = settings.targetCalendarID
        shown.menuBar.showsNextMeeting = showsNextMeeting
        shown.menuBar.showsMeetingProgress = showsMeetingProgress
        return HStack(spacing: 14) {
            Spacer()
            MenuBarItemPreview(settings: shown, controller: controller)
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text(Date(), format: .dateTime.weekday().day().month().hour().minute())
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The full-screen alert over a desktop with a couple of windows, blurred the way the alert
/// blurs the real one.
private struct AlertDesk: View {
    let event: SourceEvent
    let origin: EventOrigin?
    let prepare: [String]

    var body: some View {
        ZStack {
            ZStack(alignment: .topLeading) {
                Wallpaper()
                fakeWindow.frame(width: 560, height: 420).offset(x: 70, y: 60)
                fakeWindow.frame(width: 520, height: 380).offset(x: 520, y: 200)
            }
            .blur(radius: 18)
            Color.black.opacity(0.28)
            EventAlertView(event: event, origin: origin, prepare: prepare, blursDesktop: false, dismiss: {}, snooze: {})
        }
        .frame(width: 1160, height: 720)
        .clipped()
    }

    private var fakeWindow: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 7) {
                        Circle().fill(.red).frame(width: 12, height: 12)
                        Circle().fill(.yellow).frame(width: 12, height: 12)
                        Circle().fill(.green).frame(width: 12, height: 12)
                    }
                    ForEach(0..<7) { line in
                        Capsule().fill(.primary.opacity(0.12)).frame(width: CGFloat(140 + (line * 53) % 220), height: 10)
                    }
                }
                .padding(16)
            }
    }
}

/// A window around a Settings pane or a task's notes: title bar with its title, background,
/// rounded edge and shadow.
private struct WindowFrame<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 12, height: 12)
                    Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 12, height: 12)
                    Spacer()
                }
                .padding(.leading, 14)
            }
            .frame(height: 38)
            .background(.bar)
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 22, y: 10)
            .padding(40)
            .background(Wallpaper())
    }
}

/// A soft desktop picture: indigo to teal, like the app's icon.
private struct Wallpaper: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(red: 0.16, green: 0.17, blue: 0.38), Color(red: 0.05, green: 0.25, blue: 0.27)]
                : [Color(red: 0.74, green: 0.78, blue: 0.93), Color(red: 0.74, green: 0.89, blue: 0.85)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
