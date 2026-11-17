import Foundation

/// Free time across every calendar, written out to paste into an email or chat: "My
/// availability (London time, GMT): • Tue 18 Nov: 09:00–10:15, 14:00–16:30". Pure logic, unit
/// tested.
///
/// The main calendar holds a copy of every meeting, so it's the only one read. Busy is what
/// Meeting Stats counts: timed meetings, unaccepted ones included, and out of office (all-day
/// ones too). Free time is within the user's working hours on their weekdays, and optionally
/// within the other person's working hours too.
public enum Availability {
    /// Which days to share.
    public enum Span: String, CaseIterable, Codable, Sendable {
        /// The next three working days, today included while enough of its working hours is left.
        case nextDays
        /// The working days left this week, today included.
        case thisWeek
        /// Next week's working days.
        case nextWeek

        public var title: String {
            switch self {
            case .nextDays: return "Next \(Availability.nextDaysCount) days"
            case .thisWeek: return "This week"
            case .nextWeek: return "Next week"
            }
        }
    }

    /// How many working days `Span.nextDays` covers.
    public static let nextDaysCount = 3

    /// Slots start on a quarter hour: one free from now starts at the next one.
    static let quarterHour: TimeInterval = 15 * 60

    /// The days of `span`, each as its start: the user's working days, Monday to Friday. For
    /// `nextDays`, today counts while at least `minimum` of its working hours is left.
    public static func days(of span: Span, now: Date, calendar: Calendar,
                            workingHours: WorkingHours, minimum: TimeInterval = 0) -> [Date] {
        let today = calendar.startOfDay(for: now)
        func dayAt(_ offset: Int, from start: Date) -> Date? {
            calendar.date(byAdding: .day, value: offset, to: start).map(calendar.startOfDay(for:))
        }
        switch span {
        case .nextDays:
            var days: [Date] = []
            for offset in 0..<21 where days.count < nextDaysCount {
                guard let day = dayAt(offset, from: today), !calendar.isDateInWeekend(day),
                      let working = workingHours.interval(on: day, calendar: calendar),
                      working.end.timeIntervalSince(max(working.start, nextQuarterHour(after: now, calendar: calendar))) >= max(minimum, 1)
                else { continue }
                days.append(day)
            }
            return days
        case .thisWeek, .nextWeek:
            guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now),
                  let start = span == .thisWeek ? thisWeek.start : dayAt(7, from: thisWeek.start)
            else { return [] }
            return (0..<7).compactMap { dayAt($0, from: start) }
                .filter { $0 >= today && !calendar.isDateInWeekend($0) }
        }
    }

    /// Takes up time: what Meeting Stats counts as a meeting, or as out of office.
    static func isBusy(_ event: SourceEvent) -> Bool {
        MeetingStats.counts(event) || MeetingStats.countsAsAway(event)
    }

    /// `date`, or the next quarter hour after it.
    static func nextQuarterHour(after date: Date, calendar: Calendar) -> Date {
        let midnight = calendar.startOfDay(for: date)
        let seconds = date.timeIntervalSince(midnight)
        let rounded = (seconds / quarterHour).rounded(.up) * quarterHour
        return midnight.addingTimeInterval(rounded)
    }

    /// When the other person works during `day`, by their working hours in their own time. Their
    /// weekends don't count: only the user's do.
    static func workingTime(_ schedule: WorldClocks.Schedule, during day: DateInterval, calendar: Calendar) -> [DateInterval] {
        var theirs = calendar
        theirs.timeZone = schedule.timeZone
        let theirDay = theirs.startOfDay(for: day.start)
        return (-1...1).compactMap { offset -> DateInterval? in
            guard let date = theirs.date(byAdding: .day, value: offset, to: theirDay),
                  let working = schedule.workingHours.interval(on: date, calendar: theirs) else { return nil }
            return intersection(working, day)
        }
    }

    static func intersection(_ a: DateInterval, _ b: DateInterval) -> DateInterval? {
        let start = max(a.start, b.start), end = min(a.end, b.end)
        return end > start ? DateInterval(start: start, end: end) : nil
    }

    /// `intervals` less the time `busy` takes up.
    static func subtract(_ busy: [DateInterval], from intervals: [DateInterval]) -> [DateInterval] {
        let busy = busy.sorted { $0.start < $1.start }
        return intervals.flatMap { interval -> [DateInterval] in
            var free: [DateInterval] = []
            var cursor = interval.start
            for block in busy where block.end > cursor {
                guard block.start < interval.end else { break }
                if block.start > cursor { free.append(DateInterval(start: cursor, end: block.start)) }
                cursor = max(cursor, block.end)
            }
            if cursor < interval.end { free.append(DateInterval(start: cursor, end: interval.end)) }
            return free
        }
    }

    /// The free stretches of `day` at least `minimum` long: within the working hours, from the
    /// next quarter hour after `now`, and within `recipient`'s working hours when given.
    public static func freeSlots(in events: [SourceEvent], on day: Date, now: Date, calendar: Calendar,
                                 workingHours: WorkingHours, recipient: WorldClocks.Schedule? = nil,
                                 minimum: TimeInterval) -> [DateInterval] {
        guard let working = workingHours.interval(on: day, calendar: calendar) else { return [] }
        let from = max(working.start, nextQuarterHour(after: now, calendar: calendar))
        guard working.end > from else { return [] }
        var allowed = [DateInterval(start: from, end: working.end)]
        if let recipient {
            allowed = workingTime(recipient, during: allowed[0], calendar: calendar)
        }
        let busy = events.filter(isBusy).map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
        return subtract(busy, from: allowed).filter { $0.duration >= minimum }
    }

    /// What to share: each day's free slots, and how far ahead the calendars were read.
    public struct Plan: Hashable, Sendable {
        public struct Day: Hashable, Sendable {
            public var day: Date
            public var slots: [DateInterval]
        }

        public var days: [Day]
        /// The span's days past what Calendar Hub reads were left out: the last day it reads.
        /// Nil when none were.
        public var readsUntil: Date?

        public var isEmpty: Bool { days.allSatisfy(\.slots.isEmpty) }
    }

    /// The free slots of every day of `span`. Days starting at or after `readsUntil`, past what
    /// the sync reads, are left out: their copies may be missing.
    public static func plan(_ span: Span, events: [SourceEvent], now: Date, calendar: Calendar,
                            workingHours: WorkingHours, recipient: WorldClocks.Schedule? = nil,
                            minimum: TimeInterval, readsUntil: Date) -> Plan {
        let all = days(of: span, now: now, calendar: calendar, workingHours: workingHours, minimum: minimum)
        let read = all.filter { $0 < readsUntil }
        let lastRead = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: readsUntil))
        return Plan(
            days: read.map { day in
                Plan.Day(day: day, slots: freeSlots(in: events, on: day, now: now, calendar: calendar,
                                                    workingHours: workingHours, recipient: recipient, minimum: minimum))
            },
            readsUntil: read.count < all.count ? lastRead : nil)
    }

    // MARK: - Text

    /// "London time, GMT", "New York time, GMT−5", "Mumbai time, GMT+5:30": the place's name and
    /// its offset at `date`. Written out rather than an abbreviation such as WET, which depends on
    /// the system and that the other person may not know.
    public static func zoneText(name: String, timeZone: TimeZone, at date: Date) -> String {
        let minutes = timeZone.secondsFromGMT(for: date) / 60
        var offset = "GMT"
        if minutes != 0 {
            offset += (minutes > 0 ? "+" : "−") + "\(abs(minutes) / 60)"
            if abs(minutes) % 60 != 0 { offset += String(format: ":%02d", abs(minutes) % 60) }
        }
        return "\(name) time, \(offset)"
    }

    /// The text to paste:
    ///
    ///     My availability (London time, GMT):
    ///     • Tue 18 Nov: 09:00–10:15, 14:00–16:30
    ///     • Wed 19 Nov: 11:00–12:00
    ///
    /// Times are in `timeZone`, and each slot is under the day it starts on there. Days with no
    /// free time are left out.
    public static func text(of plan: Plan, timeZone: TimeZone, placeName: String, locale: Locale,
                            calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        var theirs = calendar
        theirs.timeZone = timeZone
        theirs.locale = locale
        func formatter(_ template: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.calendar = theirs
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }
        let dayFormat = formatter("EEEdMMM"), timeFormat = formatter("jmm")

        let slots = plan.days.flatMap(\.slots).sorted { $0.start < $1.start }
        let header = "My availability (\(zoneText(name: placeName, timeZone: timeZone, at: slots.first?.start ?? plan.days.first?.day ?? Date())))"
        guard !slots.isEmpty else { return header + ": no free time." }

        var lines: [String] = []
        var current: (day: Date, times: [String])?
        func flush() {
            if let current { lines.append("• \(dayFormat.string(from: current.day)): \(current.times.joined(separator: ", "))") }
        }
        for slot in slots {
            let day = theirs.startOfDay(for: slot.start)
            let time = "\(timeFormat.string(from: slot.start))–\(timeFormat.string(from: slot.end))"
            if current?.day == day {
                current?.times.append(time)
            } else {
                flush()
                current = (day, [time])
            }
        }
        flush()
        return ([header + ":"] + lines).joined(separator: "\n")
    }
}
