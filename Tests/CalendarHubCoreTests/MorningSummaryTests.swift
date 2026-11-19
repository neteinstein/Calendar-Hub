import XCTest
@testable import CalendarHubCore

final class MorningSummaryTests: XCTestCase {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return calendar
    }()
    let locale = Locale(identifier: "en_GB")

    /// Thursday 19 November 2026.
    func at(_ hour: Int, _ minute: Int = 0, day: Int = 19) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func event(_ title: String, _ hour: Int, _ minute: Int = 0, minutes: Int = 60) -> SourceEvent {
        SourceEvent(key: title, title: title, start: at(hour, minute), end: at(hour, minute) + Double(minutes) * 60)
    }

    func testDueAtTheStartOfTheWorkingDayOnWeekdays() {
        let hours = WorkingHours()
        XCTAssertNil(MorningSummary.dueTime(now: at(8), workingHours: hours, calendar: calendar))
        XCTAssertEqual(MorningSummary.dueTime(now: at(9, 5), workingHours: hours, calendar: calendar), at(9))
        XCTAssertNil(MorningSummary.dueTime(now: at(18), workingHours: hours, calendar: calendar))
        XCTAssertNil(MorningSummary.dueTime(now: at(10, day: 21), workingHours: hours, calendar: calendar), "Saturday")
    }

    func testText() {
        let events = [event("Standup", 9, 30, minutes: 15), event("Design review", 14, minutes: 90)]
        let text = MorningSummary.text(events: events, tasksDue: ["Send slides", "Book flights", "Expenses"],
                                       limitHours: 5, now: at(9), calendar: calendar, locale: locale)
        XCTAssertEqual(text.title, "Good morning: 1h 45m of meetings today")
        // The time's format differs between Foundation versions.
        XCTAssertTrue(text.body.hasPrefix("2 meetings. First: Standup at "), text.body)
        XCTAssertTrue(text.body.hasSuffix(". 3h 15m left before your 5h limit. 3 tasks due: Send slides, Book flights…"), text.body)
    }

    func testNoMeetings() {
        var declined = event("Declined", 10)
        declined.isDeclined = true
        let text = MorningSummary.text(events: [declined], tasksDue: [], limitHours: nil, now: at(9), calendar: calendar)
        XCTAssertEqual(text.title, "Good morning: no meetings today")
        XCTAssertEqual(text.body, "")
    }

    func testMeetingUnderway() {
        let events = [event("Standup", 9, 30, minutes: 15)]
        XCTAssertFalse(EventAlertPlanner.meetingUnderway(events: events, now: at(9, 29)))
        XCTAssertTrue(EventAlertPlanner.meetingUnderway(events: events, now: at(9, 30)))
        XCTAssertFalse(EventAlertPlanner.meetingUnderway(events: events, now: at(9, 45)))
    }

    func testOldAlertSettingsDecode() throws {
        let options = try JSONDecoder().decode(EventAlertOptions.self, from: Data(#"{"enabled":false,"leadMinutes":3}"#.utf8))
        XCTAssertFalse(options.morningSummary)
        XCTAssertFalse(options.focusDuringMeetings)
        XCTAssertEqual(options.leadMinutes, 3)
    }
}

final class NextMeetingTests: XCTestCase {
    func testNextMeetingSkipsDeclinedAndEnded() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var declined = SourceEvent(key: "d", title: "Declined", start: base + 600, end: base + 1200)
        declined.isDeclined = true
        let ended = SourceEvent(key: "e", title: "Ended", start: base - 3600, end: base - 60)
        let later = SourceEvent(key: "l", title: "Later", start: base + 7200, end: base + 9000)
        let next = MenuCalendar.nextMeeting(in: [declined, ended, later], now: base)
        XCTAssertEqual(next?.key, "l")
        XCTAssertTrue(MenuCalendar.nextMeetingText(next, now: base).hasPrefix("Later, "))
        XCTAssertEqual(MenuCalendar.nextMeetingText(nil, now: base), "No more meetings")
    }
}

final class WidgetSnapshotTests: XCTestCase {
    func testSnapshot() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 10))!
        let hour: TimeInterval = 3600
        var declined = SourceEvent(key: "d", title: "Declined", start: now + hour, end: now + 2 * hour)
        declined.isDeclined = true
        let events = [
            SourceEvent(key: "past", title: "Standup", start: now - 2 * hour, end: now - hour),
            SourceEvent(key: "now", title: "Design review", start: now - 600, end: now + 1200),
            declined,
            SourceEvent(key: "tomorrow", title: "Planning", start: now + 24 * hour, end: now + 25 * hour),
        ]
        let snapshot = WidgetSnapshot.make(events: events, now: now, limitHours: 5, calendar: calendar) { event in
            event.key == "now" ? ("Calendar A", "#FF0000") : nil
        }
        XCTAssertEqual(snapshot.meetings.map(\.id), ["now", "tomorrow"])
        XCTAssertEqual(snapshot.meetings[0].calendarName, "Calendar A")
        XCTAssertEqual(snapshot.hoursToday, 1.5, accuracy: 0.01)
        XCTAssertEqual(snapshot.upcoming(at: now, calendar: calendar).map(\.id), ["now"])
        XCTAssertEqual(snapshot.changes(after: now).first, now + 1200)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
    }
}
