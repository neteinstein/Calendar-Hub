import Foundation

/// What the desktop widget shows, written by the app to a file only the user can read and read
/// by the widget, which can't read the calendars itself: the day's meetings from now on, and
/// the hours of meetings in it.
public struct WidgetSnapshot: Codable, Hashable, Sendable {
    public struct Meeting: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var start: Date
        public var end: Date
        /// The calendar it came from, as `#RRGGBB`, or nil for the main calendar's own.
        public var color: String?
        public var calendarName: String?
        public var url: URL?

        public init(id: String, title: String, start: Date, end: Date, color: String? = nil,
                    calendarName: String? = nil, url: URL? = nil) {
            self.id = id
            self.title = title
            self.start = start
            self.end = end
            self.color = color
            self.calendarName = calendarName
            self.url = url
        }
    }

    public var written: Date
    /// Today's meetings that haven't ended, and tomorrow's, soonest first.
    public var meetings: [Meeting]
    /// Hours of meetings today, counted as Meeting Stats counts them.
    public var hoursToday: Double
    /// The daily meeting limit, when it's on.
    public var limitHours: Double?

    public init(written: Date, meetings: [Meeting], hoursToday: Double, limitHours: Double?) {
        self.written = written
        self.meetings = meetings
        self.hoursToday = hoursToday
        self.limitHours = limitHours
    }

    /// The snapshot for `events`, the main calendar's events today and tomorrow. `origin`
    /// gives a copy's calendar name and color.
    public static func make(events: [SourceEvent], now: Date, limitHours: Double?, calendar: Calendar,
                            origin: (SourceEvent) -> (name: String, color: String?)?) -> WidgetSnapshot {
        let meetings = events.filter { MenuCalendar.isMeeting($0) && $0.end > now }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            .prefix(12)
            .map { event in
                let from = origin(event)
                return Meeting(id: event.key, title: MenuCalendar.displayTitle(of: event), start: event.start, end: event.end,
                               color: from?.color, calendarName: from?.name, url: event.meetingURL)
            }
        let today = events.filter { MenuCalendar.isMeeting($0) && calendar.isDate($0.start, inSameDayAs: now) }
        return WidgetSnapshot(written: now, meetings: Array(meetings),
                              hoursToday: MeetingLimit.hours(on: now, in: today, calendar: calendar), limitHours: limitHours)
    }

    /// The meetings still to come or under way at `date`, today only.
    public func upcoming(at date: Date, calendar: Calendar) -> [Meeting] {
        meetings.filter { $0.end > date && calendar.isDate($0.start, inSameDayAs: date) }
    }

    /// When what the widget shows next changes: a meeting starting or ending after `date`.
    public func changes(after date: Date) -> [Date] {
        Array(Set(meetings.flatMap { [$0.start, $0.end] }.filter { $0 > date })).sorted()
    }

    /// The file's name, in the app's Application Support folder.
    public static let fileName = "widget.json"
}
