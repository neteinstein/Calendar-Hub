import Foundation

/// A task in the menu's Tasks view. Each one is a reminder in Reminders, so it's on the user's
/// other devices too and outlives the app: the due date is the reminder's, the nudges are its
/// alerts, and the event it's for is a link in its URL field.
public struct TaskItem: Hashable, Identifiable, Sendable {
    /// The reminder's `calendarItemIdentifier`; empty for a task not saved yet.
    public var id: String
    public var title: String
    public var notes: String?
    /// When it's due. Without `dueHasTime`, it's due that day: the start of the day.
    public var due: Date?
    public var dueHasTime: Bool
    public var isCompleted: Bool
    public var completionDate: Date?
    public var creationDate: Date?
    /// When Reminders nudges about it: the reminder's alerts, soonest first.
    public var nudges: [Date]
    /// The event it's for, if any.
    public var event: TaskEventLink?

    public init(id: String = "", title: String, notes: String? = nil, due: Date? = nil, dueHasTime: Bool = true,
                isCompleted: Bool = false, completionDate: Date? = nil, creationDate: Date? = nil,
                nudges: [Date] = [], event: TaskEventLink? = nil) {
        self.id = id
        self.title = title
        self.notes = notes
        self.due = due
        self.dueHasTime = dueHasTime
        self.isCompleted = isCompleted
        self.completionDate = completionDate
        self.creationDate = creationDate
        self.nudges = nudges
        self.event = event
    }

    /// What the task is timed by: its due date, or else its event's start.
    public var anchor: Date? { due ?? event?.start }

    /// Whether `anchor` has a time of day, rather than being a whole day.
    public var anchorHasTime: Bool { due != nil ? dueHasTime : event?.isAllDay != true }
}

/// The event a task is for, kept in the reminder's URL field as
/// `calendarhub://event?title=Design%20review&start=2026-11-06T14:00:00Z&key=…`, so Reminders
/// keeps it without the app. The key is the event's `SourceEvent.key`; the title and start are
/// as they were last seen, for when the event can't be read, and so the app can tell when it
/// moved.
public struct TaskEventLink: Hashable, Sendable {
    public static let scheme = "calendarhub"
    /// The scheme before the app was renamed from Calendar Sync. Links in reminders made then are
    /// still read; they get the new scheme when the app next writes them.
    public static let legacyScheme = "calendarsync"

    public var key: String
    public var title: String
    public var start: Date
    public var isAllDay: Bool

    public init(key: String, title: String, start: Date, isAllDay: Bool = false) {
        self.key = key
        self.title = title
        self.start = start
        self.isAllDay = isAllDay
    }

    /// Links to `event`, by the title the menu shows for it. The start is kept to the second,
    /// as the URL keeps it, so a link read back equals the one made.
    public init(_ event: SourceEvent) {
        self.init(key: event.key, title: MenuCalendar.displayTitle(of: event),
                  start: Date(timeIntervalSince1970: event.start.timeIntervalSince1970.rounded(.down)),
                  isAllDay: event.isAllDay)
    }

    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-_.~")
        return set
    }()

    public var url: URL {
        var items = [("title", title), ("start", ISO8601DateFormatter().string(from: start))]
        if isAllDay { items.append(("allDay", "1")) }
        items.append(("key", key))
        let query = items
            .map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: Self.allowed) ?? $1)" }
            .joined(separator: "&")
        return URL(string: "\(Self.scheme)://event?\(query)")!
    }

    /// The link in a reminder's URL field, or nil when it holds anything else.
    public init?(url: URL?) {
        guard let url, [Self.scheme, Self.legacyScheme].contains(url.scheme ?? ""), url.host == "event",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let key = value("key"), !key.isEmpty,
              let start = value("start").flatMap({ ISO8601DateFormatter().date(from: $0) })
        else { return nil }
        self.init(key: key, title: value("title") ?? "", start: start, isAllDay: value("allDay") == "1")
    }
}

/// A nudge as the user picks it: at a set time, or timed by the task's due date (or its
/// event's start), so it follows when that changes.
public enum Nudge: Codable, Hashable, Sendable {
    /// At the due time, or when the event starts.
    case atStart
    case before(minutes: Int)
    /// `days` days before the anchor's day (0 for that day), at `minute` minutes after midnight.
    case daysBefore(Int, atMinute: Int)
    case at(Date)

    /// The nudges the editor offers for a task timed to the minute, or to a whole day.
    public static func presets(anchorHasTime: Bool) -> [Nudge] {
        let mornings: [Nudge] = [.daysBefore(0, atMinute: 9 * 60), .daysBefore(1, atMinute: 9 * 60)]
        let before: [Nudge] = [.atStart, .before(minutes: 5), .before(minutes: 15), .before(minutes: 30), .before(minutes: 60)]
        return anchorHasTime ? before + mornings : mornings
    }

    /// When it goes off, or nil for one timed by an anchor the task doesn't have. A whole-day
    /// anchor has no time to count back from, so those nudge that day at 9:00.
    public func date(anchor: Date?, anchorHasTime: Bool, calendar: Calendar) -> Date? {
        if case .at(let date) = self { return date }
        guard let anchor else { return nil }
        switch self {
        case .atStart, .before:
            guard anchorHasTime else {
                return Nudge.daysBefore(0, atMinute: 9 * 60).date(anchor: anchor, anchorHasTime: false, calendar: calendar)
            }
            if case .before(let minutes) = self { return anchor.addingTimeInterval(-60 * Double(minutes)) }
            return anchor
        case .daysBefore(let days, let minute):
            guard let day = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: anchor)) else { return nil }
            return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
        case .at(let date):
            return date
        }
    }

    /// The nudge among `presets(anchorHasTime:)` that goes off at `date`, or `.at(date)`.
    public static func matching(_ date: Date, anchor: Date?, anchorHasTime: Bool, calendar: Calendar) -> Nudge {
        guard anchor != nil else { return .at(date) }
        return presets(anchorHasTime: anchorHasTime).first {
            $0.date(anchor: anchor, anchorHasTime: anchorHasTime, calendar: calendar) == date
        } ?? .at(date)
    }

    /// "1 hour before", "The day before at 9:00", or for an event "When it starts". Nil for a
    /// set time, which the app formats itself.
    public func title(forEvent: Bool) -> String? {
        switch self {
        case .atStart:
            return forEvent ? "When it starts" : "At the due time"
        case .before(let minutes):
            if minutes % 60 == 0 { return minutes == 60 ? "1 hour before" : "\(minutes / 60) hours before" }
            return minutes == 1 ? "1 minute before" : "\(minutes) minutes before"
        case .daysBefore(let days, let minute):
            let time = WorkingHours.text(minute)
            switch days {
            case 0: return "That day at \(time)"
            case 1: return "The day before at \(time)"
            default: return "\(days) days before at \(time)"
            }
        case .at:
            return nil
        }
    }
}

/// Settings for the Tasks view and the nudges new tasks get.
public struct TaskOptions: Codable, Hashable, Sendable {
    /// The menu gets a Tasks view, next to List.
    public var showsInMenu: Bool
    /// The Reminders list tasks are kept in, or nil for the one Reminders adds new reminders to.
    public var listID: String?
    /// The nudge a new task for an event gets, or nil for none.
    public var eventNudge: Nudge?
    /// The nudge a new task with a due date gets, or nil for none.
    public var dueNudge: Nudge?

    public init(showsInMenu: Bool = true, listID: String? = nil, eventNudge: Nudge? = .before(minutes: 60),
                dueNudge: Nudge? = .atStart) {
        self.showsInMenu = showsInMenu
        self.listID = listID
        self.eventNudge = eventNudge
        self.dueNudge = dueNudge
    }

    enum CodingKeys: String, CodingKey {
        case showsInMenu, listID, eventNudge, dueNudge
    }

    // Settings saved by older versions don't have every key yet. A nudge turned off is saved
    // as null, so it isn't taken for a missing key and turned back on.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TaskOptions()
        showsInMenu = try c.decodeIfPresent(Bool.self, forKey: .showsInMenu) ?? defaults.showsInMenu
        listID = try c.decodeIfPresent(String.self, forKey: .listID)
        eventNudge = c.contains(.eventNudge) ? try c.decodeIfPresent(Nudge.self, forKey: .eventNudge) : defaults.eventNudge
        dueNudge = c.contains(.dueNudge) ? try c.decodeIfPresent(Nudge.self, forKey: .dueNudge) : defaults.dueNudge
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(showsInMenu, forKey: .showsInMenu)
        try c.encodeIfPresent(listID, forKey: .listID)
        try c.encode(eventNudge, forKey: .eventNudge)
        try c.encode(dueNudge, forKey: .dueNudge)
    }
}

/// Sorting, timing and keeping tasks in step with their events. Pure logic, unit tested.
public enum TaskPlanner {
    /// One group of the Tasks view.
    public struct Section: Hashable, Sendable {
        public enum Kind: String, CaseIterable, Sendable {
            case overdue, today, tomorrow, later, someday, done

            public var title: String {
                switch self {
                case .overdue: "Overdue"
                case .today: "Today"
                case .tomorrow: "Tomorrow"
                case .later: "Later"
                case .someday: "No date"
                case .done: "Done"
                }
            }
        }

        public var kind: Kind
        public var tasks: [TaskItem]

        public init(kind: Kind, tasks: [TaskItem]) {
            self.kind = kind
            self.tasks = tasks
        }
    }

    /// Whether `task` is past its due date (or its event's start), or for a whole day, past
    /// that day.
    public static func isOverdue(_ task: TaskItem, now: Date, calendar: Calendar) -> Bool {
        guard !task.isCompleted, let anchor = task.anchor else { return false }
        return task.anchorHasTime ? anchor < now : anchor < calendar.startOfDay(for: now)
    }

    /// The tasks in the groups the Tasks view shows, empty ones left out: overdue, today,
    /// tomorrow, later, then those without a date, and last the done ones, latest first.
    /// Each group is soonest first.
    public static func sections(_ tasks: [TaskItem], now: Date, calendar: Calendar) -> [Section] {
        var byKind: [Section.Kind: [TaskItem]] = [:]
        for task in tasks {
            byKind[kind(of: task, now: now, calendar: calendar), default: []].append(task)
        }
        return Section.Kind.allCases.compactMap { kind in
            guard let list = byKind[kind] else { return nil }
            let sorted: [TaskItem]
            switch kind {
            case .done:
                sorted = list.sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
            case .someday:
                sorted = list.sorted { ($0.creationDate ?? .distantPast, $0.title) < ($1.creationDate ?? .distantPast, $1.title) }
            default:
                // A whole day sorts before that day's times.
                sorted = list.sorted { ($0.anchor ?? .distantFuture, $0.title) < ($1.anchor ?? .distantFuture, $1.title) }
            }
            return Section(kind: kind, tasks: sorted)
        }
    }

    private static func kind(of task: TaskItem, now: Date, calendar: Calendar) -> Section.Kind {
        if task.isCompleted { return .done }
        guard let anchor = task.anchor else { return .someday }
        if isOverdue(task, now: now, calendar: calendar) { return .overdue }
        if calendar.isDate(anchor, inSameDayAs: now) { return .today }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(anchor, inSameDayAs: tomorrow) { return .tomorrow }
        return .later
    }

    /// The open tasks by the day the menu's calendar shows them on: the day they're due, or
    /// their event starts, and today for overdue ones. Tasks without a date are on no day.
    /// Each day's tasks are whole-day ones first, then by time.
    public static func byDay(_ tasks: [TaskItem], now: Date, calendar: Calendar) -> [Date: [TaskItem]] {
        let today = calendar.startOfDay(for: now)
        var days: [Date: [TaskItem]] = [:]
        for task in tasks where !task.isCompleted {
            guard let anchor = task.anchor else { continue }
            let day = isOverdue(task, now: now, calendar: calendar) ? today : calendar.startOfDay(for: anchor)
            days[day, default: []].append(task)
        }
        return days.mapValues { list in
            list.sorted { ($0.anchorHasTime ? 1 : 0, $0.anchor ?? .distantFuture, $0.title)
                < ($1.anchorHasTime ? 1 : 0, $1.anchor ?? .distantFuture, $1.title) }
        }
    }

    /// The task's next nudge after `now`, or nil once it's done or has none left.
    public static func nextNudge(of task: TaskItem, now: Date) -> Date? {
        task.isCompleted ? nil : task.nudges.filter { $0 > now }.min()
    }

    /// The open tasks for the event with `key`, soonest due first.
    public static func openTasks(forEvent key: String, in tasks: [TaskItem]) -> [TaskItem] {
        tasks
            .filter { !$0.isCompleted && $0.event?.key == key }
            .sorted { ($0.anchor ?? .distantFuture, $0.title) < ($1.anchor ?? .distantFuture, $1.title) }
    }

    /// `task` brought in step with its event as it is now: when the event moved, the due date
    /// and the nudges move with it, so a nudge an hour before stays an hour before, and the
    /// link takes the event's new title and start. A due date without a time moves by as many
    /// days as the event did. Nil when nothing changed, and for a done task.
    public static func realigned(_ task: TaskItem, to event: SourceEvent, calendar: Calendar) -> TaskItem? {
        guard !task.isCompleted, let link = task.event, link.key == event.key else { return nil }
        let current = TaskEventLink(event)
        guard current != link else { return nil }
        var task = task
        let moved = event.start.timeIntervalSince(link.start)
        if moved != 0 {
            if task.dueHasTime {
                task.due = task.due.map { $0.addingTimeInterval(moved) }
            } else if let due = task.due {
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: link.start),
                                                   to: calendar.startOfDay(for: event.start)).day ?? 0
                task.due = calendar.date(byAdding: .day, value: days, to: due) ?? due
            }
            task.nudges = task.nudges.map { $0.addingTimeInterval(moved) }
        }
        task.event = current
        return task
    }
}
