import Foundation

/// The notification at the start of the working day: the day's meetings, the first one, the
/// tasks due, and how much of the meeting limit is left.
public enum MorningSummary {
    /// When today's summary is due: the start of the working day, on weekdays. Nil on a
    /// weekend, or once the working day is over, so a Mac woken in the evening says nothing.
    public static func dueTime(now: Date, workingHours: WorkingHours, calendar: Calendar) -> Date? {
        guard !calendar.isDateInWeekend(now),
              let hours = workingHours.interval(on: now, calendar: calendar),
              now >= hours.start, now < hours.end else { return nil }
        return hours.start
    }

    /// "2026-11-19", to send the summary once a day.
    public static func dayKey(_ now: Date, calendar: Calendar) -> String {
        MeetingLimit.dayKey(now, calendar: calendar)
    }

    /// The meetings that count: timed, not declined, cancelled, out of office or a full
    /// day's Busy block.
    static func meetings(_ events: [SourceEvent]) -> [SourceEvent] {
        events.filter {
            !$0.isAllDay && !$0.isDeclined && !$0.isCancelled && !$0.isOutOfOffice && !MeetingLimit.isBlock($0)
        }
    }

    /// The notification's title and body.
    /// - Parameters:
    ///   - events: the main calendar's events today.
    ///   - tasksDue: the titles of the open tasks due today, or overdue.
    ///   - limitHours: the daily meeting limit, when it's on.
    public static func text(events: [SourceEvent], tasksDue: [String], limitHours: Double?, now: Date,
                            calendar: Calendar, locale: Locale = .current) -> (title: String, body: String) {
        let meetings = meetings(events).sorted { $0.start < $1.start }
        let hours = MeetingLimit.hours(on: now, in: meetings, calendar: calendar)
        let minutes = Int((hours * 60).rounded())
        var lines: [String] = []
        let title: String
        if meetings.isEmpty {
            title = "Good morning: no meetings today"
        } else {
            title = "Good morning: \(MenuCalendar.shortDuration(minutes: minutes)) of meetings today"
            let first = meetings.first { $0.end > now } ?? meetings[0]
            let time = first.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                                              calendar: calendar, timeZone: calendar.timeZone))
            let count = meetings.count == 1 ? "1 meeting" : "\(meetings.count) meetings"
            lines.append("\(count). First: \(MenuCalendar.displayTitle(of: first)) at \(time).")
        }
        if let limitHours, limitHours > 0 {
            let left = Int((limitHours * 60).rounded()) - minutes
            lines.append(left > 0
                ? "\(MenuCalendar.shortDuration(minutes: left)) left before your \(MenuCalendar.shortDuration(minutes: Int(limitHours * 60))) limit."
                : "Over your \(MenuCalendar.shortDuration(minutes: Int(limitHours * 60))) limit.")
        }
        switch tasksDue.count {
        case 0: break
        case 1: lines.append("Task due: \(tasksDue[0]).")
        default:
            let shown = tasksDue.prefix(2).joined(separator: ", ")
            lines.append("\(tasksDue.count) tasks due: \(shown)\(tasksDue.count > 2 ? "…" : ".")")
        }
        return (title, lines.joined(separator: " "))
    }
}
