import XCTest
@testable import CalendarHubCore

final class AvailabilityTests: XCTestCase {
    let lisbon = TimeZone(identifier: "Europe/Lisbon")!
    let london = TimeZone(identifier: "Europe/London")!
    let newYork = TimeZone(identifier: "America/New_York")!
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    let english = Locale(identifier: "en_GB")

    var local: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = lisbon
        calendar.firstWeekday = 2 // Monday
        return calendar
    }

    /// In Lisbon, November 2026 (UTC+0). Tuesday the 17th.
    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        local.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func meeting(_ start: Date, _ end: Date, allDay: Bool = false, declined: Bool = false,
                 unconfirmed: Bool = false, outOfOffice: Bool = false, title: String = "M") -> SourceEvent {
        SourceEvent(key: UUID().uuidString, title: title, start: start, end: end, isAllDay: allDay,
                    isDeclined: declined, isUnconfirmed: unconfirmed, isOutOfOffice: outOfOffice)
    }

    func interval(_ day: Int, _ from: (Int, Int), _ to: (Int, Int)) -> DateInterval {
        DateInterval(start: date(day, from.0, from.1), end: date(day, to.0, to.1))
    }

    // MARK: - Days

    func testNextDaysSkipsTheWeekendAndADayAlreadyOver() {
        // Thursday the 19th after work: Friday, Monday and Tuesday.
        let days = Availability.days(of: .nextDays, now: date(19, 18), calendar: local, workingHours: WorkingHours())
        XCTAssertEqual(days, [date(20, 0), date(23, 0), date(24, 0)])
        // During the working day, today counts.
        XCTAssertEqual(Availability.days(of: .nextDays, now: date(19, 10), calendar: local, workingHours: WorkingHours()).first,
                       date(19, 0))
        // With 15 minutes left, it doesn't when slots have to be half an hour.
        XCTAssertEqual(Availability.days(of: .nextDays, now: date(19, 16, 40), calendar: local, workingHours: WorkingHours(),
                                         minimum: 30 * 60).first, date(20, 0))
    }

    func testThisWeekFromTodayAndNextWeek() {
        let now = date(18, 10) // Wednesday
        XCTAssertEqual(Availability.days(of: .thisWeek, now: now, calendar: local, workingHours: WorkingHours()),
                       [date(18, 0), date(19, 0), date(20, 0)])
        XCTAssertEqual(Availability.days(of: .nextWeek, now: now, calendar: local, workingHours: WorkingHours()),
                       [23, 24, 25, 26, 27].map { date($0, 0) })
        // On a Saturday, this week has nothing left.
        XCTAssertEqual(Availability.days(of: .thisWeek, now: date(21, 10), calendar: local, workingHours: WorkingHours()), [])
    }

    // MARK: - Free slots

    func testFreeSlotsAroundMeetingsWithinWorkingHours() {
        let events = [
            meeting(date(18, 8), date(18, 9, 30)), // starts before work
            meeting(date(18, 10, 15), date(18, 11)),
            meeting(date(18, 10, 30), date(18, 12)), // overlaps the one before
            meeting(date(18, 12, 20), date(18, 12, 40)), // leaves gaps too short to share
            meeting(date(18, 16, 30), date(18, 18)),
        ]
        let slots = Availability.freeSlots(in: events, on: date(18, 0), now: date(17, 12), calendar: local,
                                           workingHours: WorkingHours(), minimum: 30 * 60)
        XCTAssertEqual(slots, [interval(18, (9, 30), (10, 15)), interval(18, (12, 40), (16, 30))])
    }

    func testDeclinedCancelledAndAllDayAreFreeButUnconfirmedAndOutOfOfficeAreBusy() {
        let events = [
            meeting(date(18, 9), date(18, 10), declined: true),
            meeting(date(18, 0), date(19, 0), allDay: true),
            meeting(date(18, 10), date(18, 11), unconfirmed: true),
            meeting(date(18, 14), date(18, 17), title: "Out of office"),
        ]
        let slots = Availability.freeSlots(in: events, on: date(18, 0), now: date(17, 12), calendar: local,
                                           workingHours: WorkingHours(), minimum: 30 * 60)
        XCTAssertEqual(slots, [interval(18, (9, 0), (10, 0)), interval(18, (11, 0), (14, 0))])
        // An all-day out of office takes the whole day.
        let away = [meeting(date(18, 0), date(19, 0), allDay: true, outOfOffice: true)]
        XCTAssertEqual(Availability.freeSlots(in: away, on: date(18, 0), now: date(17, 12), calendar: local,
                                              workingHours: WorkingHours(), minimum: 30 * 60), [])
    }

    func testTodayStartsAtTheNextQuarterHour() {
        let slots = Availability.freeSlots(in: [], on: date(17, 0), now: date(17, 10, 47), calendar: local,
                                           workingHours: WorkingHours(), minimum: 30 * 60)
        XCTAssertEqual(slots, [interval(17, (11, 0), (17, 0))])
        // Too little of the day left.
        XCTAssertEqual(Availability.freeSlots(in: [], on: date(17, 0), now: date(17, 16, 40), calendar: local,
                                              workingHours: WorkingHours(), minimum: 30 * 60), [])
    }

    func testOnlyWhileTheRecipientWorksToo() {
        // New York works 9:00–17:00 there: 14:00–22:00 in Lisbon.
        let slots = Availability.freeSlots(in: [meeting(date(18, 15), date(18, 16))], on: date(18, 0), now: date(17, 12),
                                           calendar: local, workingHours: WorkingHours(),
                                           recipient: .init(timeZone: newYork, workingHours: WorkingHours()),
                                           minimum: 30 * 60)
        XCTAssertEqual(slots, [interval(18, (14, 0), (15, 0)), interval(18, (16, 0), (17, 0))])
        // Tokyo works 9:00–17:00 there: midnight to 8:00 in Lisbon, so there's no overlap.
        XCTAssertEqual(Availability.freeSlots(in: [], on: date(18, 0), now: date(17, 12), calendar: local,
                                              workingHours: WorkingHours(),
                                              recipient: .init(timeZone: tokyo, workingHours: WorkingHours()),
                                              minimum: 30 * 60), [])
    }

    func testPlanLeavesOutDaysPastWhatIsRead() {
        // Reads up to Thursday the 19th: Friday the 20th is left out.
        let plan = Availability.plan(.thisWeek, events: [], now: date(18, 8), calendar: local, workingHours: WorkingHours(),
                                     minimum: 30 * 60, readsUntil: date(20, 0))
        XCTAssertEqual(plan.days.map(\.day), [date(18, 0), date(19, 0)])
        XCTAssertEqual(plan.readsUntil, date(19, 0))
        let everything = Availability.plan(.thisWeek, events: [], now: date(18, 8), calendar: local,
                                           workingHours: WorkingHours(), minimum: 30 * 60, readsUntil: date(30, 0))
        XCTAssertNil(everything.readsUntil)
    }

    // MARK: - Text

    func testTextInTheRecipientsTime() {
        let events = [meeting(date(18, 10, 15), date(18, 14)), meeting(date(18, 16, 30), date(18, 17))]
        let plan = Availability.plan(.thisWeek, events: events, now: date(18, 8), calendar: local, workingHours: WorkingHours(),
                                     minimum: 30 * 60, readsUntil: date(20, 0))
        // London keeps Lisbon's time in November.
        XCTAssertEqual(Availability.text(of: plan, timeZone: london, placeName: "London", locale: english), """
            My availability (London time, GMT):
            • Wed 18 Nov: 09:00–10:15, 14:00–16:30
            • Thu 19 Nov: 09:00–17:00
            """)
        // New York is five hours behind.
        XCTAssertTrue(Availability.text(of: plan, timeZone: newYork, placeName: "New York", locale: english)
            .contains("• Wed 18 Nov: 04:00–05:15, 09:00–11:30"))
    }

    func testTextUnderTheDayItIsThere() {
        // 17:00 on Wednesday in Lisbon is already Thursday in Tokyo.
        let plan = Availability.Plan(days: [.init(day: date(18, 0), slots: [interval(18, (16, 0), (17, 0))])], readsUntil: nil)
        XCTAssertEqual(Availability.text(of: plan, timeZone: tokyo, placeName: "Tokyo", locale: english), """
            My availability (Tokyo time, GMT+9):
            • Thu 19 Nov: 01:00–02:00
            """)
    }

    func testTextWithoutFreeTime() {
        let plan = Availability.Plan(days: [.init(day: date(18, 0), slots: [])], readsUntil: nil)
        XCTAssertEqual(Availability.text(of: plan, timeZone: lisbon, placeName: "Lisbon", locale: english),
                       "My availability (Lisbon time, GMT): no free time.")
    }

    func testFlag() {
        XCTAssertEqual(WorldClocks.flag(of: "Europe/London"), "🇬🇧")
        XCTAssertEqual(WorldClocks.flag(of: "Europe/Lisbon"), "🇵🇹")
        XCTAssertNil(WorldClocks.flag(of: "UTC"))
    }
}

extension AvailabilityTests {
    func testZoneText() {
        let day = date(18, 12)
        XCTAssertEqual(Availability.zoneText(name: "New York", timeZone: newYork, at: day), "New York time, GMT−5")
        XCTAssertEqual(Availability.zoneText(name: "Mumbai", timeZone: TimeZone(identifier: "Asia/Kolkata")!, at: day),
                       "Mumbai time, GMT+5:30")
        // Summer time.
        let july = local.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 12))!
        XCTAssertEqual(Availability.zoneText(name: "London", timeZone: london, at: july), "London time, GMT+1")
    }
}
