import Foundation

/// Recognises one meeting that reached more than one calendar: an invitation sent to two of
/// your addresses, or to your main calendar and a secondary one. Only one copy of it should
/// end up in the main calendar.
public enum SameInvite {
    /// Whether `a` and `b` are the same meeting: at the same times, with the same invitation id
    /// (the iCalendar UID) or the same title. The title stands in for the id because servers
    /// don't always agree on it (Exchange and Google can each keep their own), and Outlook on
    /// the web's week view gives none.
    public static func matches(_ a: SourceEvent, _ b: SourceEvent, calendar: Calendar = .current) -> Bool {
        guard a.isAllDay == b.isAllDay, sameTimes(a, b, calendar: calendar) else { return false }
        if let id = a.inviteID, !id.isEmpty, id == b.inviteID { return true }
        let title = comparable(a.title)
        return !title.isEmpty && title == comparable(b.title)
    }

    /// A title with case and spacing evened out, which servers don't keep alike.
    static func comparable(_ title: String) -> String {
        title.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// All-day events by their first and last day, as `SyncPlanner.sameTimes` compares them.
    static func sameTimes(_ a: SourceEvent, _ b: SourceEvent, calendar: Calendar) -> Bool {
        if a.isAllDay {
            return calendar.isDate(a.start, inSameDayAs: b.start)
                && calendar.isDate(a.end - 1, inSameDayAs: b.end - 1)
        }
        return abs(a.start.timeIntervalSince(b.start)) < 1 && abs(a.end.timeIntervalSince(b.end)) < 1
    }

    /// Whether a main-calendar event is a meeting of its own there, which a secondary calendar's
    /// copy of the same invitation would duplicate: not a copy, and not cancelled or declined
    /// (a meeting declined in the main calendar but accepted in a secondary one still gets copied).
    static func isOriginal(_ event: SourceEvent) -> Bool {
        !event.isCancelled && !event.isDeclined && !CopyMarker.isCopy(event.notes)
    }
}
