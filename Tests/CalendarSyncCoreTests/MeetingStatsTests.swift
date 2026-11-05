import XCTest
@testable import CalendarSyncCore

final class MeetingStatsTests: XCTestCase {
    var utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2 // Monday
        return calendar
    }()

    func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    func meeting(_ start: Date, _ end: Date, allDay: Bool = false, declined: Bool = false) -> SourceEvent {
        SourceEvent(key: UUID().uuidString, title: "M", start: start, end: end, isAllDay: allDay, isDeclined: declined)
    }

    func testOverlapsCountOnceAndInFull() {
        let events = [
            meeting(date(11, 3, 9), date(11, 3, 11)),
            meeting(date(11, 3, 10), date(11, 3, 12)), // overlaps the first by an hour
            meeting(date(11, 3, 14), date(11, 3, 15)),
        ]
        let hours = MeetingStats.hours(of: events, in: DateInterval(start: date(11, 3, 0), end: date(11, 4, 0)))
        XCTAssertEqual(hours.hours, 4)
        XCTAssertEqual(hours.countingOverlap, 5)
        XCTAssertEqual(MeetingStats.text(hours), "4 hours (5 counting overlap)")
    }

    func testNoOverlapNoteWithoutOverlap() {
        let hours = MeetingStats.hours(of: [meeting(date(11, 3, 9), date(11, 3, 10, 30))],
                                       in: DateInterval(start: date(11, 3, 0), end: date(11, 4, 0)))
        XCTAssertEqual(MeetingStats.text(hours), "1.5 hours")
    }

    func testSkipsAllDayDeclinedAndClipsToTheInterval() {
        let events = [
            meeting(date(11, 3, 0), date(11, 4, 0), allDay: true),
            meeting(date(11, 3, 9), date(11, 3, 10), declined: true),
            meeting(date(11, 2, 23), date(11, 3, 1)), // half of it is the day before
        ]
        let hours = MeetingStats.hours(of: events, in: DateInterval(start: date(11, 3, 0), end: date(11, 4, 0)))
        XCTAssertEqual(hours.countingOverlap, 1)
    }

    func testSummaryPeriods() {
        // Tuesday 3 November 2026. Last week is Monday 26 October to Sunday 1 November; last month October.
        let now = date(11, 3, 12)
        let events = [
            meeting(date(11, 2, 9), date(11, 2, 10)),   // yesterday
            meeting(date(11, 3, 9), date(11, 3, 11)),   // today
            meeting(date(11, 4, 9), date(11, 4, 12)),   // tomorrow
            meeting(date(10, 30, 9), date(10, 30, 13)), // last week and last month
            meeting(date(10, 5, 9), date(10, 5, 14)),   // last month only
        ]
        let summary = MeetingStats.summary(of: events, now: now, calendar: utc)
        XCTAssertEqual(summary.yesterday.hours, 1)
        XCTAssertEqual(summary.today.hours, 2)
        XCTAssertEqual(summary.tomorrow.hours, 3)
        XCTAssertEqual(summary.lastWeek.hours, 4)
        XCTAssertEqual(summary.lastMonth.hours, 9)
        // The four weeks before today (6 October to 2 November) hold 20 working days and 1 + 4 hours.
        XCTAssertEqual(summary.averagePerWorkingDay.hours, 0.25, accuracy: 0.0001)
        XCTAssertEqual(summary.perYear.hours, 65, accuracy: 0.0001)

        let window = MeetingStats.window(now: now, calendar: utc)
        XCTAssertLessThanOrEqual(window.start, date(10, 1, 0))
        XCTAssertEqual(window.end, date(11, 5, 0))
    }

    func testFormat() {
        XCTAssertEqual(MeetingStats.format(0), "0 hours")
        XCTAssertEqual(MeetingStats.format(0.75), "45 min")
        XCTAssertEqual(MeetingStats.format(1), "1 hour")
        XCTAssertEqual(MeetingStats.format(20), "20 hours")
        XCTAssertEqual(MeetingStats.format(1358.5), "1359 hours")
        XCTAssertEqual(MeetingStats.text(.init(hours: 0.5, countingOverlap: 1.5)), "30 min (1.5 hours counting overlap)")
    }

    func testComparison() {
        XCTAssertNil(MeetingStats.comparison(forYearlyHours: 0))
        XCTAssertEqual(MeetingStats.comparison(forYearlyHours: 360),
                       "15 days nonstop — about as long as it takes to walk from Lisbon to Paris.")
        XCTAssertEqual(MeetingStats.comparison(forYearlyHours: 700),
                       "29 days nonstop — enough to walk from Lisbon to Paris 2 times.")
        XCTAssertEqual(MeetingStats.comparison(forYearlyHours: 5),
                       "5 hours nonstop — not quite enough to swim across the English Channel.")
    }

    func testRoute() {
        XCTAssertEqual(MeetingStats.route(forYearlyHours: 360), MeetingStats.Route(from: "Lisbon", to: "Paris"))
        XCTAssertNil(MeetingStats.route(forYearlyHours: 5), "not enough for any journey")
        XCTAssertNil(MeetingStats.route(forYearlyHours: 2000), "around the world goes nowhere in particular")
    }

    func testInsights() {
        // Tuesday 3 November 2026, 10:00.
        let now = date(11, 3, 10)
        let events = [
            // Last week: two meetings back to back, one after a long gap.
            meeting(date(10, 28, 9), date(10, 28, 10)),
            meeting(date(10, 28, 10, 5), date(10, 28, 11)),
            meeting(date(10, 28, 15), date(10, 28, 16)),
            // The week before: one hour.
            meeting(date(10, 20, 9), date(10, 20, 10)),
            // Today: free 10:00–11:00, a meeting to 12:00, then free until 17:00.
            meeting(date(11, 3, 11), date(11, 3, 12)),
        ]
        let summary = MeetingStats.summary(of: events, now: now, calendar: utc)
        XCTAssertEqual(summary.meetingsLastWeek, 3)
        XCTAssertEqual(summary.backToBackLastWeek, 1)
        XCTAssertEqual(MeetingStats.trend(summary)!, 1.9166, accuracy: 0.001, "2.92 hours against 1")
        XCTAssertEqual(summary.busiestWeekday, 4, "Wednesday")
        XCTAssertEqual(summary.longestFreeToday, 5 * 3600)
        XCTAssertEqual(summary.freeBlockToday, DateInterval(start: date(11, 3, 12), end: date(11, 3, 17)))
        // Ten working days, today and tomorrow.
        XCTAssertEqual(summary.recentDays.count, 12)
        XCTAssertEqual(summary.recentDays.last?.day, date(11, 4, 0))
    }

    func testSkipsOutOfOffice() {
        let day = DateInterval(start: date(11, 3, 0), end: date(11, 4, 0))
        var shownAsOutOfOffice = meeting(date(11, 3, 9), date(11, 3, 17))
        shownAsOutOfOffice.isOutOfOffice = true
        let titled = ["Out of office", "[Work] Out of Office – dentist", "OOO", "Pedro OOO afternoon", "OOF", "Fora do escritório"]
            .map { title -> SourceEvent in
                var event = meeting(date(11, 3, 13), date(11, 3, 14))
                event.title = title
                return event
            }
        var standup = meeting(date(11, 3, 10), date(11, 3, 11))
        standup.title = "Standup (room Foo)"
        let hours = MeetingStats.hours(of: [shownAsOutOfOffice, standup] + titled, in: day)
        XCTAssertEqual(hours.countingOverlap, 1, "only the standup counts")
    }

    func testCopiesKeepOutOfOffice() {
        let source = SourceConfig(kind: .eventKit(calendarID: "work"), calendarName: "Work")
        var leave = meeting(date(11, 3, 9), date(11, 3, 17))
        leave.title = "Holiday"
        leave.isOutOfOffice = true
        XCTAssertTrue(CopyFormatter.spec(for: leave, source: source).isOutOfOffice)
        XCTAssertFalse(CopyFormatter.spec(for: meeting(date(11, 3, 9), date(11, 3, 10)), source: source).isOutOfOffice)
    }

    func testOutOfOfficeThisWeekWithinWorkingHours() {
        // Wednesday 4 November 2026; the week runs Monday 2 to Sunday 8.
        var holiday = meeting(date(11, 2, 0), date(11, 3, 0), allDay: true)
        holiday.isOutOfOffice = true // all of Monday: 8 hours
        var dentist = meeting(date(11, 4, 16), date(11, 4, 19))
        dentist.title = "OOO dentist" // 16:00 to 17:00 counts
        var overlapping = meeting(date(11, 4, 16, 30), date(11, 4, 17))
        overlapping.isOutOfOffice = true // inside the dentist, counts once
        var weekend = meeting(date(11, 7, 9), date(11, 7, 17))
        weekend.isOutOfOffice = true
        var declined = meeting(date(11, 5, 9), date(11, 5, 12), declined: true)
        declined.isOutOfOffice = true
        let events = [holiday, dentist, overlapping, weekend, declined, meeting(date(11, 3, 9), date(11, 3, 10))]

        let summary = MeetingStats.summary(of: events, now: date(11, 4, 12), calendar: utc)
        XCTAssertEqual(summary.outOfOfficeThisWeek, 9)
        XCTAssertEqual(summary.workingHoursThisWeek, 40)

        let longDays = MeetingStats.summary(of: events, now: date(11, 4, 12), calendar: utc,
                                            workingHours: WorkingHours(start: 8 * 60, end: 18 * 60 + 30))
        XCTAssertEqual(longDays.outOfOfficeThisWeek, 10.5 + 2.5)
        XCTAssertEqual(longDays.workingHoursThisWeek, 52.5)
    }

    func testWorkingHoursDefaultToNineToFive() throws {
        let options = try JSONDecoder().decode(MenuCalendarOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(options.workingHours, WorkingHours(start: 540, end: 1020))
        XCTAssertEqual(WorkingHours.text(17 * 60 + 30), "17:30")
    }

    func testNoFreeTimeAfterWorkingHours() {
        XCTAssertNil(MeetingStats.summary(of: [], now: date(11, 3, 19), calendar: utc).longestFreeToday)
    }
}
