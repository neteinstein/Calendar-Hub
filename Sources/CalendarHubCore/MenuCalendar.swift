import Foundation

/// Date math for the menu's month view and event list. Pure logic, unit tested.
public enum MenuCalendar {
    /// Every day shown in a month grid: the month's days, padded to whole weeks with the
    /// neighbouring months' days. Always whole weeks, starting on the calendar's first weekday.
    /// Without weekends, each week keeps only its working days.
    public static func gridDays(for month: Date, calendar: Calendar, showsWeekends: Bool = true) -> [Date] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: month),
              let firstWeek = calendar.dateInterval(of: .weekOfYear, for: monthInterval.start),
              let lastDay = calendar.date(byAdding: .day, value: -1, to: monthInterval.end),
              let lastWeek = calendar.dateInterval(of: .weekOfYear, for: lastDay)
        else { return [] }

        var days: [Date] = []
        var day = firstWeek.start
        while day < lastWeek.end {
            if showsWeekends || !calendar.isDateInWeekend(day) {
                days.append(day)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    /// The weekdays (1 is Sunday) of a grid's columns, in order, starting on the calendar's
    /// first weekday.
    public static func weekdays(calendar: Calendar, showsWeekends: Bool = true) -> [Int] {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: Date()) else { return [] }
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: week.start),
                  showsWeekends || !calendar.isDateInWeekend(day) else { return nil }
            return calendar.component(.weekday, from: day)
        }
    }

    /// One day of the list view, with its events soonest first.
    public struct DaySection: Hashable, Sendable {
        public var day: Date
        public var events: [SourceEvent]

        public init(day: Date, events: [SourceEvent]) {
            self.day = day
            self.events = events
        }
    }

    /// Groups events into days for the list view, both sorted. A multi-day event appears
    /// under the day it starts.
    public static func sections(for events: [SourceEvent], calendar: Calendar) -> [DaySection] {
        let byDay = Dictionary(grouping: events) { calendar.startOfDay(for: $0.start) }
        return byDay.keys.sorted().map { day in
            DaySection(day: day, events: byDay[day]!.sorted { ($0.start, $0.title) < ($1.start, $1.title) })
        }
    }

    /// One day's events split for the event lists: all-day events first, then the timed ones
    /// starting before noon, then the rest. Each part keeps its order.
    public struct DayParts: Hashable, Sendable {
        public var allDay: [SourceEvent] = []
        public var morning: [SourceEvent] = []
        public var afternoon: [SourceEvent] = []
    }

    public static func parts(of events: [SourceEvent], calendar: Calendar) -> DayParts {
        var parts = DayParts()
        for event in events {
            if event.isAllDay {
                parts.allDay.append(event)
            } else if calendar.component(.hour, from: event.start) < 12 {
                parts.morning.append(event)
            } else {
                parts.afternoon.append(event)
            }
        }
        return parts
    }

    /// The secondary calendar an event in the main calendar was copied from, or nil for the main
    /// calendar's own events.
    public static func originID(of event: SourceEvent) -> UUID? {
        CopyMarker.find(in: event.notes)?.sourceID
    }

    /// The title to show for an event in the menu: a copy's title without its "[Calendar A] "
    /// prefix, since the menu shows the calendar's name and color next to it. "Busy" for none.
    public static func displayTitle(of event: SourceEvent) -> String {
        let title = originID(of: event) == nil ? event.title : CopyFormatter.originalTitle(event.title)
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Busy" : title
    }

    // MARK: - Next meeting

    /// A meeting worth counting down to: timed, and not declined, cancelled or out of office.
    static func isMeeting(_ event: SourceEvent) -> Bool {
        !event.isAllDay && !event.isDeclined && !event.isCancelled && !MeetingStats.isOutOfOffice(event)
    }

    /// How close the next meeting has to be for the menu to show it in the Up next card.
    public static let upNextLead: TimeInterval = 4 * 60 * 60

    /// The meeting to show as "Up next": the one under way, or else the next one to start
    /// today within `upNextLead`. Timed meetings only: not declined, cancelled or
    /// out-of-office events.
    public static func upNext(in events: [SourceEvent], now: Date, calendar: Calendar) -> SourceEvent? {
        events
            .filter { event in
                isMeeting(event) && event.end > now
                    && (event.start <= now
                        || (calendar.isDate(event.start, inSameDayAs: now)
                            && event.start.timeIntervalSince(now) <= upNextLead))
            }
            .min { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// Whole minutes from `now` to `date`, rounded up, so a meeting at 11:30 is "in 12 min"
    /// from 11:18:00 until 11:18:59 and never "in 0 min" before it starts.
    public static func minutes(from now: Date, to date: Date) -> Int {
        max(0, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// "12m", "1h", "1h 20m": short enough for the menu bar.
    public static func shortDuration(minutes: Int) -> String {
        let (h, m) = (minutes / 60, minutes % 60)
        return h == 0 ? "\(m)m" : m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// The Up next card's countdown: "in 12 min", "in 1h 20m", "starting now", or while it
    /// runs "now · 20 min left".
    public static func countdown(to event: SourceEvent, now: Date) -> String {
        if event.start > now {
            let minutes = minutes(from: now, to: event.start)
            return minutes < 60 ? "in \(minutes) min" : "in " + shortDuration(minutes: minutes)
        }
        let left = minutes(from: now, to: event.end)
        return left < 60 ? "now · \(left) min left" : "now · \(shortDuration(minutes: left)) left"
    }

    /// How close a meeting has to be for the menu bar to show it instead of the date.
    public static let menuBarLead: TimeInterval = 15 * 60

    /// The meeting the menu bar shows: the next one starting within `menuBarLead`, or else the
    /// one under way that ends first. A long block (focus time, say) doesn't hide the meeting
    /// about to start.
    public static func menuBarMeeting(in events: [SourceEvent], now: Date) -> SourceEvent? {
        let candidates = events.filter { isMeeting($0) && $0.end > now }
        if let soon = candidates
            .filter({ $0.start > now && $0.start.timeIntervalSince(now) <= menuBarLead })
            .min(by: { $0.start < $1.start }) {
            return soon
        }
        return candidates.filter { $0.start <= now }.min { $0.end < $1.end }
    }

    /// Longest title the menu bar shows, so the item doesn't push others off a small screen.
    static let menuBarTitleLength = 22

    /// What the menu bar shows for `event`: "Design review · 12m" within `menuBarLead` of its
    /// start, "Design review · 23m left" while it runs, or nil when it's further away or over.
    public static func menuBarText(for event: SourceEvent, now: Date) -> String? {
        guard !event.isAllDay, event.end > now, event.start.timeIntervalSince(now) <= menuBarLead else { return nil }
        var title = displayTitle(of: event)
        if title.count > menuBarTitleLength {
            title = title.prefix(menuBarTitleLength - 1).trimmingCharacters(in: .whitespaces) + "…"
        }
        if event.start > now {
            return "\(title) · \(shortDuration(minutes: minutes(from: now, to: event.start)))"
        }
        return "\(title) · \(shortDuration(minutes: minutes(from: now, to: event.end))) left"
    }

    /// How far through `event` `now` is, from 0 to 1, for the bar under the menu bar text: 0
    /// before it starts, nil whenever `menuBarText` shows nothing.
    public static func menuBarProgress(for event: SourceEvent, now: Date) -> Double? {
        guard menuBarText(for: event, now: now) != nil else { return nil }
        let length = event.end.timeIntervalSince(event.start)
        guard length > 0 else { return 1 }
        return min(max(now.timeIntervalSince(event.start) / length, 0), 1)
    }
}
