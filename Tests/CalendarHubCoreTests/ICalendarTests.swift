import XCTest
@testable import CalendarHubCore

final class ICalendarTests: XCTestCase {
    let lisbon = TimeZone(identifier: "Europe/Lisbon")!
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = lisbon
        return calendar
    }

    func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func ics(_ events: String) -> String {
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n" + events + "END:VCALENDAR\r\n"
    }

    func testSingleEventWithFoldedDescriptionAndMeet() {
        let text = ics("""
        BEGIN:VEVENT\r
        DTSTART:20261119T140000Z\r
        DTEND:20261119T150000Z\r
        UID:abc@google.com\r
        SUMMARY:Design review\\, round 2\r
        DESCRIPTION:Agenda:\\nslides\r
          and more\r
        X-GOOGLE-CONFERENCE:https://meet.google.com/abc-defg-hij\r
        ATTENDEE;CN=Me;PARTSTAT=TENTATIVE:mailto:Me@Example.com\r
        BEGIN:VALARM\r
        ACTION:DISPLAY\r
        END:VALARM\r
        END:VEVENT\r

        """)
        let events = ICalendar.sourceEvents(ICalendar.events(in: text, timeZone: lisbon), account: "me@example.com",
                                            from: at(2026, 11, 19), to: at(2026, 11, 20))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].title, "Design review, round 2")
        XCTAssertEqual(events[0].notes, "Agenda:\nslides and more")
        XCTAssertEqual(events[0].meetingURL?.absoluteString, "https://meet.google.com/abc-defg-hij")
        XCTAssertTrue(events[0].isUnconfirmed)
        XCTAssertEqual(events[0].inviteID, "abc@google.com")
        XCTAssertEqual(events[0].start, at(2026, 11, 19, 14))
    }

    func testWeeklyWithExceptionAndMovedOccurrence() {
        let text = ics("""
        BEGIN:VEVENT\r
        DTSTART;TZID=Europe/Lisbon:20261102T093000\r
        DTEND;TZID=Europe/Lisbon:20261102T094500\r
        RRULE:FREQ=WEEKLY;BYDAY=MO,WE\r
        EXDATE;TZID=Europe/Lisbon:20261111T093000\r
        UID:standup\r
        SUMMARY:Standup\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        DTSTART;TZID=Europe/Lisbon:20261118T110000\r
        DTEND;TZID=Europe/Lisbon:20261118T111500\r
        RECURRENCE-ID;TZID=Europe/Lisbon:20261118T093000\r
        UID:standup\r
        SUMMARY:Standup (moved)\r
        END:VEVENT\r

        """)
        let events = ICalendar.sourceEvents(ICalendar.events(in: text, timeZone: .current), account: nil,
                                            from: at(2026, 11, 9), to: at(2026, 11, 21))
        XCTAssertEqual(events.map(\.start), [at(2026, 11, 9, 9, 30), at(2026, 11, 16, 9, 30), at(2026, 11, 18, 11)])
        XCTAssertEqual(events.last?.title, "Standup (moved)")
        XCTAssertEqual(events.last?.key, "gcal|standup|\(at(2026, 11, 18, 9, 30).ISO8601Format())")
    }

    func testMonthlyLastFridayWithCountAndAllDay() {
        let text = ics("""
        BEGIN:VEVENT\r
        DTSTART;TZID=Europe/Lisbon:20260130T160000\r
        DURATION:PT1H\r
        RRULE:FREQ=MONTHLY;BYDAY=-1FR;COUNT=3\r
        UID:retro\r
        SUMMARY:Retro\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        DTSTART;VALUE=DATE:20260227\r
        DTEND;VALUE=DATE:20260228\r
        UID:holiday\r
        SUMMARY:Holiday\r
        END:VEVENT\r

        """)
        let events = ICalendar.sourceEvents(ICalendar.events(in: text, timeZone: lisbon), account: nil,
                                            from: at(2026, 1, 1), to: at(2026, 12, 31))
        XCTAssertEqual(events.filter { $0.title == "Retro" }.map(\.start),
                       [at(2026, 1, 30, 16), at(2026, 2, 27, 16), at(2026, 3, 27, 16)])
        let holiday = events.first { $0.title == "Holiday" }
        XCTAssertEqual(holiday?.isAllDay, true)
        XCTAssertEqual(holiday?.start, at(2026, 2, 27))
    }

    func testDailyUntilAndDeclinedAndCancelled() {
        let text = ics("""
        BEGIN:VEVENT\r
        DTSTART:20261116T080000Z\r
        DTEND:20261116T083000Z\r
        RRULE:FREQ=DAILY;INTERVAL=2;UNTIL=20261120T235959Z\r
        UID:d\r
        SUMMARY:Sync\r
        ATTENDEE;PARTSTAT=DECLINED:mailto:me@example.com\r
        END:VEVENT\r
        BEGIN:VEVENT\r
        DTSTART:20261117T080000Z\r
        DTEND:20261117T083000Z\r
        UID:c\r
        STATUS:CANCELLED\r
        SUMMARY:Gone\r
        END:VEVENT\r

        """)
        let events = ICalendar.sourceEvents(ICalendar.events(in: text), account: "me@example.com",
                                            from: at(2026, 11, 1), to: at(2026, 12, 1))
        XCTAssertEqual(events.filter { $0.title == "Sync" }.count, 3)
        XCTAssertTrue(events.filter { $0.title == "Sync" }.allSatisfy(\.isDeclined))
        XCTAssertEqual(events.first { $0.title == "Gone" }?.isCancelled, true)
    }

    func testYearlyAndMonthlyByMonthDay() {
        let rule = ICalendar.rule("FREQ=MONTHLY;BYMONTHDAY=-1", fallback: lisbon)!
        let dates = ICalendar.expand(rule, from: at(2026, 1, 31, 10), before: at(2026, 5, 1), calendar: calendar, limit: 100)
        XCTAssertEqual(dates, [at(2026, 1, 31, 10), at(2026, 2, 28, 10), at(2026, 3, 31, 10), at(2026, 4, 30, 10)])
        let yearly = ICalendar.rule("FREQ=YEARLY", fallback: lisbon)!
        XCTAssertEqual(ICalendar.expand(yearly, from: at(2024, 2, 29, 9), before: at(2029, 1, 1), calendar: calendar, limit: 100),
                       [at(2024, 2, 29, 9), at(2028, 2, 29, 9)])
    }

    func testDurations() {
        XCTAssertEqual(ICalendar.duration("PT1H30M"), 5400)
        XCTAssertEqual(ICalendar.duration("P1D"), 86400)
        XCTAssertEqual(ICalendar.duration("-PT15M"), -900)
        XCTAssertEqual(ICalendar.duration("P1W"), 604800)
    }
}
