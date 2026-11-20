import AppKit
import CalendarHubCore

/// What Shortcuts, and `calendarhub://` links, can ask the running app to do. Set up once at
/// launch with the app's own objects.
@MainActor
final class AppActions {
    static var shared: AppActions?

    let settings: SettingsStore
    let controller: SyncController
    let tasks: TaskStore
    let timeTracker: TimeTracker

    init(settings: SettingsStore, controller: SyncController, tasks: TaskStore, timeTracker: TimeTracker) {
        self.settings = settings
        self.controller = controller
        self.tasks = tasks
        self.timeTracker = timeTracker
    }

    enum Failure: LocalizedError {
        case noMainCalendar, noMeeting, noLink, noClient(String), noTimer, notSaved(String), timeTrackingOff

        var errorDescription: String? {
            switch self {
            case .noMainCalendar: "Choose your main calendar in Calendar Hub's Settings first."
            case .noMeeting: "There are no more meetings today."
            case .noLink: "The next meeting has no link to join."
            case .noClient(let name): "Time Tracking has no client called \"\(name)\"."
            case .noTimer: "The timer isn't running."
            case .notSaved(let reason): reason
            case .timeTrackingOff: "Time Tracking is off. Turn it on in Calendar Hub's Settings."
            }
        }
    }

    /// The main calendar's events from 12 hours ago to the end of tomorrow.
    private func upcomingEvents(now: Date) throws -> [SourceEvent] {
        guard let targetID = settings.targetCalendarID,
              case .success(let events) = controller.eventKit.sourceEvents(
                  calendarID: targetID, from: now.addingTimeInterval(-12 * 3600),
                  to: Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now)) ?? now)
        else { throw Failure.noMainCalendar }
        return events
    }

    /// The meeting under way, or the next one, today or tomorrow.
    func nextMeeting(now: Date = Date()) throws -> SourceEvent? {
        MenuCalendar.nextMeeting(in: try upcomingEvents(now: now), now: now)
    }

    func nextMeetingText(now: Date = Date()) throws -> String {
        MenuCalendar.nextMeetingText(try nextMeeting(now: now), now: now)
    }

    /// Opens the join link of the meeting under way, or of the next one today that has a link.
    @discardableResult
    func joinNextMeeting(now: Date = Date()) throws -> String {
        let calendar = Calendar.current
        let candidates = try upcomingEvents(now: now)
            .filter { $0.end > now && calendar.isDate($0.start, inSameDayAs: now) && !$0.isDeclined && !$0.isCancelled && !$0.isAllDay }
            .sorted { $0.start < $1.start }
        guard !candidates.isEmpty else { throw Failure.noMeeting }
        guard let meeting = candidates.first(where: { $0.meetingURL != nil }), let url = meeting.meetingURL else {
            throw Failure.noLink
        }
        NSWorkspace.shared.open(url)
        return MenuCalendar.displayTitle(of: meeting)
    }

    /// Copies Share availability's text, with its last choices and `span`, and returns it.
    func copyAvailability(_ span: Availability.Span = .nextDays) throws -> String {
        guard let events = AvailabilityShare.events(settings: settings, controller: controller) else {
            throw Failure.noMainCalendar
        }
        var share = AvailabilityShare(settings: settings, controller: controller)
        share.span = span
        let text = share.text(events)
        AvailabilityShare.copy(text)
        return text
    }

    /// Starts Time Tracking's timer for the client named `name` (any case), or the one the
    /// timer last ran for, or the first client.
    @discardableResult
    func startTimer(client name: String?) throws -> String {
        guard settings.timeTracking.isEnabled else { throw Failure.timeTrackingOff }
        let clients = settings.timeClients
        let client: TimeClient?
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            client = clients.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
                ?? clients.first { $0.name.localizedCaseInsensitiveContains(name) }
            if client == nil { throw Failure.noClient(name) }
        } else {
            client = timeTracker.running.flatMap { running in clients.first { $0.id == running.clientID } } ?? clients.first
        }
        guard let client else { throw Failure.noClient(name ?? "") }
        timeTracker.start(client)
        return client.name
    }

    @discardableResult
    func stopTimer() throws -> String {
        guard let running = timeTracker.running else { throw Failure.noTimer }
        timeTracker.stop()
        return running.clientName
    }

    /// Adds a task to Reminders, due at `due` when there is one.
    func addTask(title: String, due: Date?) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw Failure.notSaved("A task needs a title.") }
        var task = tasks.newTask()
        task.title = title
        task.due = due
        if let due, let nudge = settings.taskOptions.dueNudge?.date(anchor: due, anchorHasTime: true, calendar: .current),
           nudge > Date() {
            task.nudges = [nudge]
        }
        tasks.save(task)
        if let problem = tasks.problem { throw Failure.notSaved(problem) }
    }

    func syncNow() async {
        await controller.syncNow()
    }

    // MARK: - Links

    /// Handles `calendarhub://` links, so a shortcut's Open URL, a script or a launcher can do
    /// what the Shortcuts actions do: `join`, `sync`, `availability?span=thisWeek`,
    /// `timer/start?client=Client%20X`, `timer/stop` and `task/new?title=…`. Links to a task's
    /// event, which reminders carry, open the menu.
    func open(_ url: URL) {
        guard url.scheme == TaskEventLink.scheme else { return }
        let path = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).joined(separator: "/")
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first })
        AppLog.write("Calendar Hub: opened a calendarhub link: \(path)")
        do {
            switch path {
            case "join": try joinNextMeeting()
            case "sync": Task { await syncNow() }
            case "availability":
                _ = try copyAvailability(query["span"].flatMap(Availability.Span.init(rawValue:)) ?? .nextDays)
            case "timer/start": try startTimer(client: query["client"])
            case "timer/stop": try stopTimer()
            case "task/new": try addTask(title: query["title"] ?? "", due: nil)
            default: MenuBarItem.shared.isInserted = true
            }
        } catch {
            AppLog.write("Calendar Hub: the link couldn't be done: \(error.localizedDescription)")
            NSSound.beep()
        }
    }
}
