import Foundation

/// Builds the requests that ask Outlook's own service (`service.svc`) for the meetings in a
/// date range, for a week Outlook on the web loaded in a way `OutlookWebSource` couldn't see
/// (from a background worker, say). Without them that week is read from the page, which has no
/// item ids, so two way sync can't tell its Busy events apart and leaves them all alone.
///
/// Outlook's format isn't documented, so there are a few ways of asking, tried in turn: its
/// web app's own `GetCalendarView`, then Exchange's `FindItem` over a calendar view, under the
/// two names the view goes by. `OutlookWebParser` reads any of the answers.
///
/// EXPERIMENTAL, like the rest of Outlook on the web.
public enum OutlookWebCalendarView {
    /// The ways to ask for the meetings starting in `[from, to)`, most likely to work first.
    ///
    /// - Parameter timeZone: this Mac's time zone, which Outlook writes the answer's times in.
    public static func requests(from: Date, to: Date, timeZone: TimeZone = .current) -> [OutlookWebWriter.Request] {
        let zone = OutlookWebWriter.windowsZoneID(for: timeZone, near: from)
        let start = utc(from), end = utc(max(to, from))
        let calendar: [String: Any] = ["__type": "DistinguishedFolderId:#Exchange", "Id": "calendar"]

        let calendarView: [String: Any] = [
            "__type": "GetCalendarViewRequest:#Exchange",
            "CalendarId": ["__type": "TargetFolderId:#Exchange", "BaseFolderId": calendar],
            "RangeStart": start,
            "RangeEnd": end,
        ]
        func findItem(paging: String) -> OutlookWebWriter.Request {
            let body: [String: Any] = [
                "__type": "FindItemRequest:#Exchange",
                "ItemShape": ["__type": "ItemResponseShape:#Exchange", "BaseShape": "AllProperties"],
                "ParentFolderIds": [calendar],
                "Traversal": "Shallow",
                "Paging": [
                    "__type": "\(paging):#Exchange", "StartDate": start, "EndDate": end, "MaxEntriesReturned": 1000,
                ] as [String: Any],
            ]
            return .init(action: "FindItem", body: OutlookWebWriter.json(request: "FindItemJsonRequest", body: body, windowsZone: zone))
        }
        return [
            .init(action: "GetCalendarView",
                  body: OutlookWebWriter.json(request: "GetCalendarViewJsonRequest", body: calendarView, windowsZone: zone)),
            findItem(paging: "CalendarPageView"),
            findItem(paging: "CalendarView"),
        ]
    }

    /// Whether `answer` holds the meetings of `[from, to)`: at least one of them. An answer
    /// without any can't be told from one Outlook didn't understand, and a week read with no
    /// meetings fails the read anyway (see `OutlookWebSource`).
    public static func answers(_ answer: Data, from: Date, to: Date) -> Bool {
        OutlookWebParser.events(fromPayloads: [answer]).contains { $0.start >= from && $0.start < to }
    }

    private static func utc(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
