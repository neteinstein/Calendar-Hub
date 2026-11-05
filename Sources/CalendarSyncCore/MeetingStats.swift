import Foundation

/// Hours spent in meetings, for the menu's Stats view. Pure logic, unit tested.
public enum MeetingStats {
    /// Time in meetings over some period. `hours` counts time covered by overlapping meetings
    /// once; `countingOverlap` counts every meeting in full.
    public struct Hours: Hashable, Sendable {
        public var hours: Double
        public var countingOverlap: Double

        public init(hours: Double, countingOverlap: Double) {
            self.hours = hours
            self.countingOverlap = countingOverlap
        }

        public var hasOverlap: Bool { countingOverlap - hours >= 1.0 / 60 }

        public static func * (lhs: Hours, rhs: Double) -> Hours {
            Hours(hours: lhs.hours * rhs, countingOverlap: lhs.countingOverlap * rhs)
        }
    }

    public struct Summary: Hashable, Sendable {
        public var yesterday: Hours
        public var today: Hours
        /// What's already in the calendar for tomorrow.
        public var tomorrow: Hours
        /// The calendar week before this one.
        public var lastWeek: Hours
        /// The calendar month before this one.
        public var lastMonth: Hours
        /// Over the working days of the four weeks before today.
        public var averagePerWorkingDay: Hours
        /// The average for every working day of a year.
        public var perYear: Hours
        /// The week before last week, to show which way last week went.
        public var weekBefore: Hours
        /// The working days of the last two weeks, then today and tomorrow, for the chart.
        public var recentDays: [Day]
        /// The weekday (1 is Sunday) with the most meeting time on average over the four weeks
        /// before today, and that average.
        public var busiestWeekday: Int?
        public var busiestWeekdayHours: Double
        /// Meetings last week, and how many of them started within five minutes of the one before.
        public var meetingsLastWeek: Int
        public var backToBackLastWeek: Int
        /// The longest stretch without meetings left today within working hours, if any is left.
        public var freeBlockToday: DateInterval?
        public var longestFreeToday: TimeInterval? { freeBlockToday?.duration }
        /// Out of office within the working hours of this week's weekdays, and those hours.
        public var outOfOfficeThisWeek: Double
        public var workingHoursThisWeek: Double
    }

    public struct Day: Hashable, Sendable {
        public var day: Date
        public var hours: Hours
    }

    /// Gaps up to this long between meetings make them back to back.
    static let backToBackGap: TimeInterval = 5 * 60

    /// Working days in a year, for the yearly prediction.
    public static let workingDaysPerYear = 52.0 * 5

    /// Days before today the average is taken over.
    static let averageDays = 28

    /// Only timed meetings count: not all-day events, out of office, or meetings declined or cancelled.
    static func counts(_ event: SourceEvent) -> Bool {
        !event.isAllDay && !isOutOfOffice(event) && !event.isDeclined && !event.isCancelled && event.end > event.start
    }

    /// Shown as out of office, or titled like it: calendars without that status (iCloud, Google)
    /// and copies made before they kept it show such events as busy.
    static func isOutOfOffice(_ event: SourceEvent) -> Bool {
        if event.isOutOfOffice { return true }
        let title = event.title.lowercased()
        if outOfOfficePhrases.contains(where: title.contains) { return true }
        let words = title.split { !$0.isLetter }
        return words.contains("ooo") || words.contains("oof")
    }

    static let outOfOfficePhrases = ["out of office", "out-of-office", "out of the office", "fora do escritório"]

    /// The time `events` take up within `interval`; meetings running past its edges count only
    /// the part inside it.
    public static func hours(of events: [SourceEvent], in interval: DateInterval) -> Hours {
        hours(of: events, in: interval, where: counts)
    }

    /// `hours(of:in:)` for the events `included` picks.
    static func hours(of events: [SourceEvent], in interval: DateInterval,
                      where included: (SourceEvent) -> Bool) -> Hours {
        let parts = events.filter(included).compactMap { event -> (Date, Date)? in
            let start = max(event.start, interval.start), end = min(event.end, interval.end)
            return end > start ? (start, end) : nil
        }.sorted { $0.0 < $1.0 }

        var total: TimeInterval = 0, merged: TimeInterval = 0
        var current: (Date, Date)?
        for part in parts {
            total += part.1.timeIntervalSince(part.0)
            if let open = current, part.0 <= open.1 {
                current = (open.0, max(open.1, part.1))
            } else {
                if let open = current { merged += open.1.timeIntervalSince(open.0) }
                current = part
            }
        }
        if let open = current { merged += open.1.timeIntervalSince(open.0) }
        return Hours(hours: merged / 3600, countingOverlap: total / 3600)
    }

    /// The span of events `summary` needs.
    public static func window(now: Date, calendar: Calendar) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? today
        let starts = [
            calendar.date(byAdding: .weekOfYear, value: -2, to: thisWeek),
            calendar.date(byAdding: .month, value: -1, to: thisMonth),
            calendar.date(byAdding: .day, value: -averageDays, to: today),
        ].compactMap { $0 }
        let end = calendar.date(byAdding: .day, value: 2, to: today) ?? today
        return DateInterval(start: starts.min() ?? today, end: end)
    }

    public static func summary(of events: [SourceEvent], now: Date, calendar: Calendar,
                               workingHours: WorkingHours = WorkingHours()) -> Summary {
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> DateInterval {
            let start = calendar.date(byAdding: .day, value: offset, to: today)!
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        }
        func previous(_ component: Calendar.Component) -> DateInterval {
            guard let current = calendar.dateInterval(of: component, for: now),
                  let start = calendar.date(byAdding: component, value: -1, to: current.start)
            else { return DateInterval(start: today, duration: 0) }
            return DateInterval(start: start, end: current.start)
        }

        let averageStart = calendar.date(byAdding: .day, value: -averageDays, to: today)!
        let recent = hours(of: events, in: DateInterval(start: averageStart, end: today))
        let workingDays = (0..<averageDays).filter { offset in
            !calendar.isDateInWeekend(calendar.date(byAdding: .day, value: offset, to: averageStart)!)
        }.count
        let average = recent * (1 / Double(max(workingDays, 1)))

        let lastWeek = previous(.weekOfYear)
        let weekBefore = DateInterval(
            start: calendar.date(byAdding: .weekOfYear, value: -1, to: lastWeek.start) ?? lastWeek.start,
            end: lastWeek.start)

        let recentDays = (-14...1).map(day).filter { offset in
            offset.start >= today || !calendar.isDateInWeekend(offset.start)
        }.map { Day(day: $0.start, hours: hours(of: events, in: $0)) }

        // Average per weekday over the four weeks: each weekday shows up four times.
        var byWeekday: [Int: Double] = [:]
        for offset in -averageDays..<0 {
            let interval = day(offset)
            byWeekday[calendar.component(.weekday, from: interval.start), default: 0] += hours(of: events, in: interval).hours
        }
        let busiest = byWeekday.filter { $0.value > 0 }.max { ($0.value, -$0.key) < ($1.value, -$1.key) }

        let lastWeekMeetings = events.filter(counts)
            .filter { $0.start >= lastWeek.start && $0.start < lastWeek.end }
            .sorted { $0.start < $1.start }
        var backToBack = 0
        var latestEnd: Date?
        for meeting in lastWeekMeetings {
            if let end = latestEnd, meeting.start >= end, meeting.start.timeIntervalSince(end) <= backToBackGap {
                backToBack += 1
            }
            latestEnd = max(latestEnd ?? meeting.end, meeting.end)
        }

        // This week's weekdays, within working hours.
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)
        let workingDaysThisWeek = (0..<7).compactMap { offset -> DateInterval? in
            guard let week = thisWeek, let day = calendar.date(byAdding: .day, value: offset, to: week.start),
                  !calendar.isDateInWeekend(day) else { return nil }
            return workingHours.interval(on: day, calendar: calendar)
        }
        let outOfOffice = workingDaysThisWeek.reduce(Hours(hours: 0, countingOverlap: 0)) { total, day in
            let away = hours(of: events, in: day, where: countsAsAway)
            return Hours(hours: total.hours + away.hours, countingOverlap: total.countingOverlap + away.countingOverlap)
        }

        return Summary(
            yesterday: hours(of: events, in: day(-1)),
            today: hours(of: events, in: day(0)),
            tomorrow: hours(of: events, in: day(1)),
            lastWeek: hours(of: events, in: previous(.weekOfYear)),
            lastMonth: hours(of: events, in: previous(.month)),
            averagePerWorkingDay: average,
            perYear: average * workingDaysPerYear,
            weekBefore: hours(of: events, in: weekBefore),
            recentDays: recentDays,
            busiestWeekday: busiest?.key,
            busiestWeekdayHours: (busiest?.value ?? 0) / Double(averageDays / 7),
            meetingsLastWeek: lastWeekMeetings.count,
            backToBackLastWeek: backToBack,
            freeBlockToday: longestFree(in: events, now: now, calendar: calendar, workingHours: workingHours),
            outOfOfficeThisWeek: outOfOffice.hours,
            workingHoursThisWeek: workingDaysThisWeek.reduce(0) { $0 + $1.duration } / 3600
        )
    }

    /// Out of office, all-day ones included, unless declined or cancelled.
    static func countsAsAway(_ event: SourceEvent) -> Bool {
        isOutOfOffice(event) && !event.isDeclined && !event.isCancelled && event.end > event.start
    }

    /// The longest gap between meetings from now until the end of today's working hours. The
    /// earliest one when two are as long.
    static func longestFree(in events: [SourceEvent], now: Date, calendar: Calendar,
                            workingHours: WorkingHours) -> DateInterval? {
        guard let day = workingHours.interval(on: now, calendar: calendar),
              max(now, day.start) < day.end else { return nil }
        let (dayStart, dayEnd) = (day.start, day.end)
        var cursor = max(now, dayStart)
        var longest: DateInterval?
        func consider(_ end: Date) {
            guard end > cursor, end.timeIntervalSince(cursor) > (longest?.duration ?? 0) else { return }
            longest = DateInterval(start: cursor, end: end)
        }
        for meeting in events.filter(counts).sorted(by: { $0.start < $1.start }) where meeting.end > cursor {
            guard meeting.start < dayEnd else { break }
            consider(meeting.start)
            cursor = max(cursor, meeting.end)
        }
        if cursor < dayEnd { consider(dayEnd) }
        return longest
    }

    /// How last week compared with the week before: "+25%", "−10%", or nil when there's
    /// nothing to compare with.
    public static func trend(_ summary: Summary) -> Double? {
        guard summary.weekBefore.hours > 0 else { return nil }
        return summary.lastWeek.hours / summary.weekBefore.hours - 1
    }

    // MARK: - Text

    /// "45 min", "1 hour", "2.5 hours", "1359 hours".
    public static func format(_ hours: Double) -> String {
        if hours > 0, hours < 1 { return "\(Int((hours * 60).rounded())) min" }
        // Tenths only while they matter.
        let rounded = hours >= 100 ? hours.rounded() : (hours * 10).rounded() / 10
        let number = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return rounded == 1 ? "1 hour" : "\(number) hours"
    }

    /// The overlap note shown next to the hours, like "(25 counting overlap)", or nil without overlap.
    public static func overlapNote(_ hours: Hours) -> String? {
        guard hours.hasOverlap else { return nil }
        let full = format(hours.countingOverlap)
        // After "20 hours", "25 hours" reads as just "25"; mixed units keep theirs.
        let number = full.hasSuffix(" hours") && format(hours.hours).hasSuffix(" hours") ? String(full.dropLast(6)) : full
        return "(\(number) counting overlap)"
    }

    /// "20 hours (25 counting overlap)".
    public static func text(_ hours: Hours) -> String {
        [format(hours.hours), overlapNote(hours)].compactMap { $0 }.joined(separator: " ")
    }

    /// Something else that takes about as long, nonstop, with where it starts and ends for the
    /// ones that go somewhere. Sorted by hours.
    static let comparisons: [(hours: Double, what: String, route: Route?)] = [
        (13, "swim across the English Channel", Route(from: "Dover", to: "Calais")),
        (22, "fly from Lisbon to Sydney", Route(from: "Lisbon", to: "Sydney")),
        (50, "drive from Lisbon to Moscow", Route(from: "Lisbon", to: "Moscow")),
        (76, "fly from the Earth to the Moon on Apollo 11", Route(from: "Earth", to: "Moon")),
        (112, "walk from Porto to Madrid", Route(from: "Porto", to: "Madrid")),
        (156, "walk the Camino de Santiago from the Pyrenees", Route(from: "Pyrenees", to: "Santiago")),
        (350, "walk from Lisbon to Paris", Route(from: "Lisbon", to: "Paris")),
        (900, "walk from Lisbon to Moscow", Route(from: "Lisbon", to: "Moscow")),
        (1920, "go around the world in 80 days", nil),
        (8015, "walk around the Earth along the equator", nil),
    ]

    /// The two ends of a journey in `comparisons`, for drawing it.
    public struct Route: Hashable, Sendable {
        public var from: String
        public var to: String
    }

    /// The journey `comparison(forYearlyHours:)` pictures a year as, when it goes from one
    /// place to another.
    public static func route(forYearlyHours hours: Double) -> Route? {
        guard hours >= 1 else { return nil }
        return comparisons.last(where: { $0.hours <= hours })?.route
    }

    /// A fun way to picture a year of meetings: "15 days nonstop — about as long as it takes
    /// to walk from Lisbon to Paris."
    public static func comparison(forYearlyHours hours: Double) -> String? {
        guard hours >= 1 else { return nil }
        let days = hours / 24
        let daysText = days < 1 ? format(hours) : days < 1.5 ? "1 day" : "\(Int(days.rounded())) days"
        guard let reference = comparisons.last(where: { $0.hours <= hours }) else {
            return "\(daysText) nonstop — not quite enough to \(comparisons[0].what)."
        }
        let ratio = hours / reference.hours
        if ratio < 1.2 {
            return "\(daysText) nonstop — about as long as it takes to \(reference.what)."
        }
        let times = ratio < 10 ? ((ratio * 10).rounded() / 10) : ratio.rounded()
        let timesText = times == times.rounded() ? String(Int(times)) : String(format: "%.1f", times)
        return "\(daysText) nonstop — enough to \(reference.what) \(timesText) times."
    }
}
