import Foundation

// Time tracking per client: meetings counted from the main calendar, a timer for the rest, and
// the untracked time within working hours. Off until turned on. Pure logic, unit tested.

/// Who time is logged to: a secondary calendar, a client added by hand, or Internal (the main
/// calendar's own meetings).
public struct TimeClient: Codable, Hashable, Identifiable, Sendable {
    /// A secondary calendar's `SourceConfig.id`, `internalID`, or `manual-<uuid>` for one added
    /// by hand.
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// The main calendar's own meetings, and time given to no client.
    public static let internalID = "internal"

    /// A new client added by hand, for work no calendar has (a proposal for a prospect, say).
    public static func manual(named name: String) -> TimeClient {
        TimeClient(id: "manual-" + UUID().uuidString, name: name)
    }

    public var isInternal: Bool { id == Self.internalID }
    public var isManual: Bool { id.hasPrefix("manual-") }
}

/// The Time Tracking settings. Off until turned on; then each part can be turned off on its own.
public struct TimeTrackingOptions: Codable, Hashable, Sendable {
    /// The menu gets a Time Tracking view, and time can be logged. Off, nothing is recorded.
    public var isEnabled: Bool
    /// Meetings in the main calendar are logged by themselves: copies to the calendar they came
    /// from, the main calendar's own meetings to Internal.
    public var countsMeetings: Bool
    /// A timer in the menu for the work that isn't a meeting.
    public var timerEnabled: Bool
    /// The menu bar item shows the running timer.
    public var showsTimerInMenuBar: Bool
    /// The time within working hours with nothing logged is listed, to be assigned to a client,
    /// and the menu points it out once the working day is over.
    public var nudgesUntracked: Bool
    /// What the main calendar's own meetings are logged as. "Internal" while empty.
    public var internalName: String
    /// Clients added by hand, for work no calendar has.
    public var extraClients: [TimeClient]

    public init(isEnabled: Bool = false, countsMeetings: Bool = true, timerEnabled: Bool = true,
                showsTimerInMenuBar: Bool = false, nudgesUntracked: Bool = true, internalName: String = "",
                extraClients: [TimeClient] = []) {
        self.isEnabled = isEnabled
        self.countsMeetings = countsMeetings
        self.timerEnabled = timerEnabled
        self.showsTimerInMenuBar = showsTimerInMenuBar
        self.nudgesUntracked = nudgesUntracked
        self.internalName = internalName
        self.extraClients = extraClients
    }

    // Settings saved by older versions don't have every key yet.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TimeTrackingOptions()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        countsMeetings = try c.decodeIfPresent(Bool.self, forKey: .countsMeetings) ?? defaults.countsMeetings
        timerEnabled = try c.decodeIfPresent(Bool.self, forKey: .timerEnabled) ?? defaults.timerEnabled
        showsTimerInMenuBar = try c.decodeIfPresent(Bool.self, forKey: .showsTimerInMenuBar) ?? defaults.showsTimerInMenuBar
        nudgesUntracked = try c.decodeIfPresent(Bool.self, forKey: .nudgesUntracked) ?? defaults.nudgesUntracked
        internalName = try c.decodeIfPresent(String.self, forKey: .internalName) ?? defaults.internalName
        extraClients = try c.decodeIfPresent([TimeClient].self, forKey: .extraClients) ?? defaults.extraClients
    }

    /// Internal, by the name chosen for it.
    public var internalClient: TimeClient {
        let name = internalName.trimmingCharacters(in: .whitespacesAndNewlines)
        return TimeClient(id: TimeClient.internalID, name: name.isEmpty ? "Internal" : name)
    }

    /// Whether the timer can run: Time Tracking and its timer are both on.
    public var timerAvailable: Bool { isEnabled && timerEnabled }
}

/// Where a logged stretch of time came from.
public enum TimeEntrySource: String, Codable, Hashable, Sendable {
    /// A meeting in the main calendar, counted by itself.
    case meeting
    /// The timer.
    case timer
    /// Untracked time given to a client from the list of gaps.
    case assigned
}

/// A stretch of time logged to a client.
public struct TimeEntry: Codable, Hashable, Identifiable, Sendable {
    /// A UUID for the entries kept in the log; `meeting:<event key>` for meetings, which are
    /// read from the calendar every time and never kept.
    public var id: String
    public var clientID: String
    /// Kept with the entry, so it keeps its client's name when the client is removed.
    public var clientName: String
    public var start: Date
    public var end: Date
    public var source: TimeEntrySource
    /// The meeting's title; nil for the timer and assigned time.
    public var title: String?
    /// For a timer left running and stopped at the end of the working day: when it was really
    /// stopped. Shown until the user keeps that time or dismisses it.
    public var stoppedLate: Date?
    /// A meeting's event key, to give it to another client.
    public var meetingKey: String?

    public init(id: String = UUID().uuidString, clientID: String, clientName: String, start: Date, end: Date,
                source: TimeEntrySource, title: String? = nil, stoppedLate: Date? = nil, meetingKey: String? = nil) {
        self.id = id
        self.clientID = clientID
        self.clientName = clientName
        self.start = start
        self.end = end
        self.source = source
        self.title = title
        self.stoppedLate = stoppedLate
        self.meetingKey = meetingKey
    }

    public init(client: TimeClient, start: Date, end: Date, source: TimeEntrySource, title: String? = nil) {
        self.init(clientID: client.id, clientName: client.name, start: start, end: end, source: source, title: title)
    }

    public var duration: TimeInterval { max(end.timeIntervalSince(start), 0) }
    public var interval: DateInterval { DateInterval(start: start, end: max(end, start)) }
    public var client: TimeClient { TimeClient(id: clientID, name: clientName) }

    static let meetingPrefix = "meeting:"
}

/// The timer while it runs. Saved, so quitting the app doesn't lose it.
public struct RunningTimer: Codable, Hashable, Sendable {
    public var clientID: String
    public var clientName: String
    public var start: Date

    public init(client: TimeClient, start: Date) {
        clientID = client.id
        clientName = client.name
        self.start = start
    }

    public var client: TimeClient { TimeClient(id: clientID, name: clientName) }
}

/// What Time Tracking keeps: the timer's entries and assigned time, the meetings given to
/// another client than their own, and the running timer. Meetings themselves are read from the
/// calendar each time, so a meeting cancelled after it was logged leaves the log by itself.
public struct TimeLog: Codable, Hashable, Sendable {
    public var entries: [TimeEntry]
    /// Meetings logged to another client than their calendar's, by event key.
    public var meetingClients: [String: TimeClient]
    public var running: RunningTimer?

    public init(entries: [TimeEntry] = [], meetingClients: [String: TimeClient] = [:], running: RunningTimer? = nil) {
        self.entries = entries
        self.meetingClients = meetingClients
        self.running = running
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([TimeEntry].self, forKey: .entries) ?? []
        meetingClients = try c.decodeIfPresent([String: TimeClient].self, forKey: .meetingClients) ?? [:]
        running = try c.decodeIfPresent(RunningTimer.self, forKey: .running)
    }

    public var isEmpty: Bool { entries.isEmpty && meetingClients.isEmpty && running == nil }
}

public enum TimeTracking {
    /// Pieces of time shorter than this are left out: a meeting overlapping another by a few
    /// seconds, say.
    static let shortest: TimeInterval = 60

    /// Gaps shorter than this aren't worth assigning.
    public static let shortestGap: TimeInterval = 15 * 60

    /// How long after the end of the working day a running timer counts as forgotten.
    public static let forgottenAfter: TimeInterval = 2 * 60 * 60

    // MARK: - Clients

    /// Every client time can be logged to: the secondary calendars, then the clients added by
    /// hand, then Internal.
    public static func clients(sources: [SourceConfig], options: TimeTrackingOptions) -> [TimeClient] {
        sources.map(client(for:)) + options.extraClients + [options.internalClient]
    }

    /// A secondary calendar as a client, by the name the menu gives it.
    public static func client(for source: SourceConfig) -> TimeClient {
        TimeClient(id: source.id.uuidString, name: source.name ?? source.calendarName)
    }

    // MARK: - Meetings

    /// Whether a main-calendar event is logged as a meeting: timed, and not declined,
    /// cancelled or out of office.
    public static func counts(_ event: SourceEvent) -> Bool {
        MeetingStats.counts(event) && !SourceEvent.isCancelledTitle(event.title)
    }

    /// The meetings in `events` as entries, each to its client, up to `now`. A copy goes to the
    /// secondary calendar it came from (by the name in its title when that calendar was
    /// removed), the main calendar's own meetings to Internal, and a meeting given to another
    /// client to that one. Time in overlapping meetings is logged once, to the meeting that
    /// started first (the longer one when they start together), so nothing counts twice.
    public static func meetingEntries(events: [SourceEvent], clients: [TimeClient], internalClient: TimeClient,
                                      reassigned: [String: TimeClient] = [:], now: Date) -> [TimeEntry] {
        let byID = Dictionary(clients.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let meetings = events
            .filter { counts($0) && $0.start < now }
            .sorted { ($0.start, -$0.end.timeIntervalSince1970, $0.key) < ($1.start, -$1.end.timeIntervalSince1970, $1.key) }
        var covered: [DateInterval] = []
        var entries: [TimeEntry] = []
        for event in meetings {
            let client = reassigned[event.key] ?? meetingClient(of: event, clients: byID, internalClient: internalClient)
            let whole = DateInterval(start: event.start, end: min(event.end, now))
            for (index, piece) in subtract(covered, from: whole).enumerated() {
                entries.append(TimeEntry(id: TimeEntry.meetingPrefix + event.key + (index == 0 ? "" : "#\(index)"),
                                         clientID: client.id, clientName: client.name,
                                         start: piece.start, end: piece.end, source: .meeting,
                                         title: MenuCalendar.displayTitle(of: event), meetingKey: event.key))
            }
            covered.append(whole)
        }
        return entries
    }

    /// The client a meeting goes to by itself, before any reassignment.
    public static func meetingClient(of event: SourceEvent, clients: [String: TimeClient],
                                     internalClient: TimeClient) -> TimeClient {
        guard let origin = MenuCalendar.originID(of: event) else { return internalClient }
        if let client = clients[origin.uuidString] { return client }
        // A secondary calendar no longer set up here: by the name its copies carry.
        let title = event.title
        if title.hasPrefix("["), let close = title.firstIndex(of: "]") {
            let name = title[title.index(after: title.startIndex)..<close].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return TimeClient(id: origin.uuidString, name: name) }
        }
        return TimeClient(id: origin.uuidString, name: "Removed calendar")
    }

    // MARK: - Combining

    /// The day's (or week's) logged time without overlaps, soonest first: meetings keep their
    /// time, and the timer's entries and assigned time get what's left around them, the earlier
    /// entry first. So a timer left running through a meeting gives the meeting its time.
    public static func combine(meetings: [TimeEntry], logged: [TimeEntry]) -> [TimeEntry] {
        var covered = meetings.map(\.interval)
        var result = meetings
        for entry in logged.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            let pieces = subtract(covered, from: entry.interval)
            for (index, piece) in pieces.enumerated() {
                var part = entry
                part.start = piece.start
                part.end = piece.end
                if index > 0 { part.id = entry.id + "#\(index)" }
                result.append(part)
            }
            covered.append(entry.interval)
        }
        return result.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    /// `entries` cut to `interval`, leaving out those outside it.
    public static func clip(_ entries: [TimeEntry], to interval: DateInterval) -> [TimeEntry] {
        entries.compactMap { entry in
            let start = max(entry.start, interval.start)
            let end = min(entry.end, interval.end)
            guard end.timeIntervalSince(start) >= shortest else { return nil }
            var clipped = entry
            clipped.start = start
            clipped.end = end
            return clipped
        }
    }

    /// What's left of `interval` once the `covered` intervals are taken out, in order. Pieces
    /// shorter than a minute are dropped.
    static func subtract(_ covered: [DateInterval], from interval: DateInterval) -> [DateInterval] {
        var pieces = [interval]
        for cut in covered where cut.duration > 0 {
            pieces = pieces.flatMap { piece -> [DateInterval] in
                guard cut.start < piece.end, cut.end > piece.start else { return [piece] }
                var rest: [DateInterval] = []
                if cut.start > piece.start { rest.append(DateInterval(start: piece.start, end: cut.start)) }
                if cut.end < piece.end { rest.append(DateInterval(start: cut.end, end: piece.end)) }
                return rest
            }
        }
        return pieces.filter { $0.duration >= shortest }
    }

    // MARK: - Totals

    /// One client's time, with the part of it spent in meetings.
    public struct ClientTotal: Hashable, Identifiable, Sendable {
        public var client: TimeClient
        public var total: TimeInterval
        public var meetings: TimeInterval
        public var id: String { client.id }
    }

    /// Each client's time in `entries`, most first. A client's latest name wins.
    public static func totals(of entries: [TimeEntry]) -> [ClientTotal] {
        var totals: [String: ClientTotal] = [:]
        for entry in entries.sorted(by: { $0.start < $1.start }) {
            var total = totals[entry.clientID] ?? ClientTotal(client: entry.client, total: 0, meetings: 0)
            total.client.name = entry.clientName
            total.total += entry.duration
            if entry.source == .meeting { total.meetings += entry.duration }
            totals[entry.clientID] = total
        }
        return totals.values.sorted {
            ($0.total, $1.client.name.localizedLowercase) > ($1.total, $0.client.name.localizedLowercase)
        }
    }

    /// "6h 40m", "45m", "0m": hours and minutes, rounded to the minute.
    public static func duration(_ seconds: TimeInterval) -> String {
        MenuCalendar.shortDuration(minutes: Int((max(seconds, 0) / 60).rounded()))
    }

    // MARK: - Untracked time

    /// The stretches of `day`'s working hours, up to `now`, with nothing logged, each at least
    /// `shortestGap` long. None on weekends.
    public static func untrackedGaps(on day: Date, entries: [TimeEntry], workingHours: WorkingHours, now: Date,
                                     calendar: Calendar) -> [DateInterval] {
        guard !calendar.isDateInWeekend(day), let hours = workingHours.interval(on: day, calendar: calendar),
              hours.start < now else { return [] }
        let until = DateInterval(start: hours.start, end: min(hours.end, now))
        return subtract(entries.map(\.interval), from: until).filter { $0.duration >= shortestGap }
    }

    /// Whether the menu should point out today's untracked time: the working day is over.
    public static func isAfterWorkingDay(_ now: Date, workingHours: WorkingHours, calendar: Calendar) -> Bool {
        guard !calendar.isDateInWeekend(now), let hours = workingHours.interval(on: now, calendar: calendar) else {
            return false
        }
        return now >= hours.end
    }

    // MARK: - Timer

    /// Where a timer started at `start` and still running at `now` should have stopped, if it
    /// was left running: the end of the working day it started in, once that's
    /// `forgottenAfter` behind. A timer started after working hours (or at the weekend) stops at
    /// midnight once that's passed. Nil while the timer is still believable.
    public static func forgottenTimerEnd(start: Date, now: Date, workingHours: WorkingHours,
                                         calendar: Calendar) -> Date? {
        if !calendar.isDateInWeekend(start), let hours = workingHours.interval(on: start, calendar: calendar),
           start < hours.end {
            return now >= hours.end.addingTimeInterval(forgottenAfter) ? hours.end : nil
        }
        guard let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start)) else {
            return nil
        }
        return now >= midnight ? midnight : nil
    }

    /// "Client A · 1h 12m": the running timer in the menu bar, its client's name shortened.
    public static func menuBarText(for timer: RunningTimer, now: Date) -> String {
        var name = timer.clientName
        if name.count > menuBarNameLength {
            name = name.prefix(menuBarNameLength - 1).trimmingCharacters(in: .whitespaces) + "…"
        }
        let minutes = max(0, Int(now.timeIntervalSince(timer.start) / 60))
        return "\(name) · \(MenuCalendar.shortDuration(minutes: minutes))"
    }

    static let menuBarNameLength = 16

    // MARK: - Export

    /// The periods time can be exported for.
    public enum Period: String, CaseIterable, Sendable {
        case thisWeek, lastWeek, thisMonth, lastMonth

        public var title: String {
            switch self {
            case .thisWeek: "This week"
            case .lastWeek: "Last week"
            case .thisMonth: "This month"
            case .lastMonth: "Last month"
            }
        }

        /// The period around `now`, whole days.
        public func interval(now: Date, calendar: Calendar) -> DateInterval? {
            let (component, offset): (Calendar.Component, Int) = switch self {
            case .thisWeek: (.weekOfYear, 0)
            case .lastWeek: (.weekOfYear, -1)
            case .thisMonth: (.month, 0)
            case .lastMonth: (.month, -1)
            }
            guard let date = calendar.date(byAdding: component, value: offset, to: now) else { return nil }
            return calendar.dateInterval(of: component, for: date)
        }

        /// For the file's name: "2026-11-16" for a week, "2026-11" for a month.
        public func label(now: Date, calendar: Calendar) -> String {
            guard let interval = interval(now: now, calendar: calendar) else { return rawValue }
            let parts = calendar.dateComponents([.year, .month, .day], from: interval.start)
            let month = String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
            switch self {
            case .thisWeek, .lastWeek: return month + String(format: "-%02d", parts.day ?? 0)
            case .thisMonth, .lastMonth: return month
            }
        }
    }

    /// `entries` as CSV for a timesheet: date, client, start, end, duration (h:mm), hours,
    /// source and title, one row per entry, soonest first. Titles of meetings from the clients
    /// in `hiddenTitles` (calendars with Hide meeting names on) are left out. A field that a
    /// spreadsheet would read as a formula is prefixed with an apostrophe.
    public static func csv(_ entries: [TimeEntry], calendar: Calendar, hiddenTitles: Set<String> = []) -> String {
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH:mm"

        var rows = [["Date", "Client", "Start", "End", "Duration", "Hours", "Source", "Title"]]
        for entry in entries.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            let minutes = Int((entry.duration / 60).rounded())
            let title = entry.source == .meeting && !hiddenTitles.contains(entry.clientID) ? entry.title ?? "" : ""
            rows.append([
                day.string(from: entry.start),
                entry.clientName,
                time.string(from: entry.start),
                time.string(from: entry.end),
                String(format: "%d:%02d", minutes / 60, minutes % 60),
                String(format: "%.2f", Double(minutes) / 60),
                entry.source.rawValue,
                title,
            ])
        }
        return rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    static func csvField(_ value: String) -> String {
        var value = value
        if let first = value.first, "=+-@\t\r".contains(first) { value = "'" + value }
        guard value.contains(where: { ",\"\n\r".contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
