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
    /// The category the Tasks view can be filtered by, if any: "Work", "Home". Kept with the
    /// event link in the reminder's URL field (see `TaskLink`).
    public var category: String?

    public init(id: String = "", title: String, notes: String? = nil, due: Date? = nil, dueHasTime: Bool = true,
                isCompleted: Bool = false, completionDate: Date? = nil, creationDate: Date? = nil,
                nudges: [Date] = [], event: TaskEventLink? = nil, category: String? = nil) {
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
        self.category = category
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

    /// `name=value` pairs, percent-encoded so `&`, `=` and spaces in a title survive.
    static func query(_ items: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return items
            .map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $1)" }
            .joined(separator: "&")
    }

    var queryItems: [(String, String)] {
        var items = [("title", title), ("start", ISO8601DateFormatter().string(from: start))]
        if isAllDay { items.append(("allDay", "1")) }
        items.append(("key", key))
        return items
    }

    public var url: URL {
        URL(string: "\(Self.scheme)://event?\(Self.query(queryItems))")!
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

/// What the app keeps in a reminder's URL field: the event link (see `TaskEventLink`) with the
/// task's category after it, `calendarhub://event?…&category=Work`, or for a task without an
/// event, `calendarhub://task?category=Work`. So the category goes wherever the reminder goes,
/// without showing in its title or notes.
public enum TaskLink {
    /// The URL for a task for `event` in `category`, or nil when it has neither.
    public static func url(event: TaskEventLink?, category: String?) -> URL? {
        let category = TaskPlanner.cleanCategory(category)
        let extra = category.map { [("category", $0)] } ?? []
        if let event {
            return URL(string: "\(TaskEventLink.scheme)://event?\(TaskEventLink.query(event.queryItems + extra))")
        }
        guard !extra.isEmpty else { return nil }
        return URL(string: "\(TaskEventLink.scheme)://task?\(TaskEventLink.query(extra))")
    }

    /// Whether `url` is one of the app's: a URL put in the field some other way is the user's.
    public static func isOurs(_ url: URL?) -> Bool {
        guard let url, [TaskEventLink.scheme, TaskEventLink.legacyScheme].contains(url.scheme ?? "") else { return false }
        return url.host == "event" || url.host == "task"
    }

    /// The category kept in `url`, if it's one of the app's and has one.
    public static func category(in url: URL?) -> String? {
        guard isOurs(url), let url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        return TaskPlanner.cleanCategory(items.first { $0.name == "category" }?.value)
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
    /// Each category's color, by its name in lowercase: given when the category is first seen
    /// (see `TaskPlanner.colors(for:given:)`), then as the user picks.
    public var categoryColors: [String: TaskCategoryColor]

    public init(showsInMenu: Bool = true, listID: String? = nil, eventNudge: Nudge? = .before(minutes: 60),
                dueNudge: Nudge? = .atStart, categoryColors: [String: TaskCategoryColor] = [:]) {
        self.showsInMenu = showsInMenu
        self.listID = listID
        self.eventNudge = eventNudge
        self.dueNudge = dueNudge
        self.categoryColors = categoryColors
    }

    /// The color `category` is shown in.
    public func color(of category: String) -> TaskCategoryColor {
        categoryColors[category.lowercased()] ?? TaskCategoryColor.preferred(for: category)
    }

    enum CodingKeys: String, CodingKey {
        case showsInMenu, listID, eventNudge, dueNudge, categoryColors
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
        // Colors are kept by name, so one a later version adds is skipped here, not the lot.
        let colors = (try? c.decodeIfPresent([String: String].self, forKey: .categoryColors)) ?? [:]
        categoryColors = colors.compactMapValues(TaskCategoryColor.init(rawValue:))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(showsInMenu, forKey: .showsInMenu)
        try c.encodeIfPresent(listID, forKey: .listID)
        try c.encode(eventNudge, forKey: .eventNudge)
        try c.encode(dueNudge, forKey: .dueNudge)
        try c.encode(categoryColors.mapValues(\.rawValue), forKey: .categoryColors)
    }
}

/// The colors a task category can have: the system's named colors, most distinct first.
public enum TaskCategoryColor: String, CaseIterable, Codable, Hashable, Sendable {
    case blue, orange, green, purple, pink, teal, red, yellow, indigo, mint, brown, gray

    public var title: String { rawValue.capitalized }

    /// The color `category` gets when nothing else has a say: picked by its name, the same on
    /// every Mac.
    public static func preferred(for category: String) -> TaskCategoryColor {
        // FNV-1a, as Swift's own hashes change from one launch to the next.
        var hash: UInt32 = 2_166_136_261
        for byte in category.lowercased().utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return allCases[Int(hash % UInt32(allCases.count))]
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

    /// `category` without spaces around it, or nil when that leaves nothing.
    public static func cleanCategory(_ category: String?) -> String? {
        guard let trimmed = category?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// The categories of `tasks`, for the Tasks view's filter: each once whatever its case,
    /// spelled as the first task with it has it, in alphabetical order.
    public static func categories(_ tasks: [TaskItem]) -> [String] {
        var seen: [String: String] = [:]
        for task in tasks {
            guard let category = cleanCategory(task.category) else { continue }
            let folded = category.lowercased()
            if seen[folded] == nil { seen[folded] = category }
        }
        return seen.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// `category` as typed, spelled like the one of `existing` it matches but for case, so
    /// "work" goes in with "Work". Nil for none.
    public static func category(_ category: String?, matching existing: [String]) -> String? {
        guard let category = cleanCategory(category) else { return nil }
        return existing.first { $0.caseInsensitiveCompare(category) == .orderedSame } ?? category
    }

    /// `given` with a color for each of `categories` that has none yet, by lowercase name: the
    /// one its name prefers, or when another category has that, the next one nobody has, so
    /// categories look different while there are colors to go round. The colors given stay.
    public static func colors(for categories: [String], given: [String: TaskCategoryColor]) -> [String: TaskCategoryColor] {
        var colors = given
        let palette = TaskCategoryColor.allCases
        for category in categories {
            let key = category.lowercased()
            guard colors[key] == nil else { continue }
            let taken = Set(categories.compactMap { colors[$0.lowercased()] })
            let preferred = TaskCategoryColor.preferred(for: category)
            let start = palette.firstIndex(of: preferred) ?? 0
            colors[key] = (0..<palette.count).lazy
                .map { palette[(start + $0) % palette.count] }
                .first { !taken.contains($0) } ?? preferred
        }
        return colors
    }

    /// The tasks in `category`, whatever its case; all of them for nil.
    public static func tasks(_ tasks: [TaskItem], in category: String?) -> [TaskItem] {
        guard let category = cleanCategory(category) else { return tasks }
        return tasks.filter { cleanCategory($0.category)?.caseInsensitiveCompare(category) == .orderedSame }
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
