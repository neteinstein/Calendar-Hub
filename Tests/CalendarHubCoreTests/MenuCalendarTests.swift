import XCTest
@testable import CalendarHubCore

final class MenuCalendarTests: XCTestCase {
    /// Fixed calendar so the grid doesn't depend on the machine running the tests.
    var utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2 // Monday
        return calendar
    }()

    func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testGridCoversTheMonthInWholeWeeks() {
        // October 2026: the 1st is a Thursday, the 31st a Saturday.
        let days = MenuCalendar.gridDays(for: date(2026, 10, 24), calendar: utc)
        XCTAssertEqual(days.count % 7, 0)
        XCTAssertEqual(days.first, date(2026, 9, 28), "padded back to Monday the 28th of September")
        XCTAssertEqual(days.last, date(2026, 11, 1), "padded forward to Sunday the 1st of November")
        XCTAssertTrue(days.contains(date(2026, 10, 1)))
        XCTAssertTrue(days.contains(date(2026, 10, 31)))
        XCTAssertEqual(utc.component(.weekday, from: days.first!), utc.firstWeekday)
    }

    func testGridOfAMonthThatIsExactWeeks() {
        // February 2027: the 1st is a Monday and it has 28 days, so no padding at all.
        let days = MenuCalendar.gridDays(for: date(2027, 2, 14), calendar: utc)
        XCTAssertEqual(days.count, 28)
        XCTAssertEqual(days.first, date(2027, 2, 1))
        XCTAssertEqual(days.last, date(2027, 2, 28))
    }

    func testGridAcrossAMidnightClockChange() {
        // São Paulo started summer time on 4 November 2018 at midnight: that day began at 01:00.
        var saoPaulo = Calendar(identifier: .gregorian)
        saoPaulo.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        saoPaulo.firstWeekday = 2
        let month = saoPaulo.date(from: DateComponents(year: 2018, month: 11, day: 15))!
        let days = MenuCalendar.gridDays(for: month, calendar: saoPaulo)
        XCTAssertEqual(days.count, 35, "29 October to 2 December")
        XCTAssertEqual(Set(days.map { saoPaulo.startOfDay(for: $0) }).count, 35, "no day twice, none skipped")
        XCTAssertEqual(days.map { saoPaulo.component(.day, from: $0) }.prefix(8), [29, 30, 31, 1, 2, 3, 4, 5])
    }

    func testGridStartingOnSunday() {
        let sunday = MenuCalendarOptions(weekStart: .sunday).applied(to: utc)
        let days = MenuCalendar.gridDays(for: date(2026, 10, 24), calendar: sunday)
        XCTAssertEqual(days.first, date(2026, 9, 27), "padded back to Sunday the 27th of September")
        XCTAssertEqual(days.last, date(2026, 10, 31), "the 31st is a Saturday, so no padding forward")
        XCTAssertEqual(MenuCalendar.weekdays(calendar: sunday), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(MenuCalendar.weekdays(calendar: utc), [2, 3, 4, 5, 6, 7, 1])
        XCTAssertEqual(MenuCalendarOptions().applied(to: utc).firstWeekday, 2, "system keeps the calendar's own")
    }

    func testGridWithoutWeekends() {
        for weekStart in [MenuCalendarOptions.WeekStart.monday, .sunday] {
            let calendar = MenuCalendarOptions(weekStart: weekStart).applied(to: utc)
            let days = MenuCalendar.gridDays(for: date(2026, 10, 24), calendar: calendar, showsWeekends: false)
            XCTAssertEqual(days.count, 25, "five weeks of five working days")
            XCTAssertFalse(days.contains { calendar.isDateInWeekend($0) })
            XCTAssertEqual(days.first, date(2026, 9, 28))
            XCTAssertEqual(days.last, date(2026, 10, 30))
            XCTAssertEqual(MenuCalendar.weekdays(calendar: calendar, showsWeekends: false), [2, 3, 4, 5, 6])
        }
    }

    func testOptionsFromOlderSettings() throws {
        let options = try JSONDecoder().decode(MenuCalendarOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(options, MenuCalendarOptions(weekStart: .system, showsWeekends: true, shadesAllDay: true,
                                                    colorsByCalendar: true, shadesTimeOfDay: true))
    }

    func testPartsSplitAllDayMorningAndAfternoon() {
        let events = [
            SourceEvent(key: "all", title: "Holiday", start: date(2026, 10, 24), end: date(2026, 10, 25), isAllDay: true),
            SourceEvent(key: "am", title: "Standup", start: date(2026, 10, 24, hour: 9), end: date(2026, 10, 24, hour: 10)),
            SourceEvent(key: "late-am", title: "Review", start: date(2026, 10, 24, hour: 11), end: date(2026, 10, 24, hour: 13)),
            SourceEvent(key: "noon", title: "Lunch", start: date(2026, 10, 24, hour: 12), end: date(2026, 10, 24, hour: 13)),
            SourceEvent(key: "pm", title: "Retro", start: date(2026, 10, 24, hour: 16), end: date(2026, 10, 24, hour: 17)),
        ]
        let parts = MenuCalendar.parts(of: events, calendar: utc)
        XCTAssertEqual(parts.allDay.map(\.key), ["all"])
        XCTAssertEqual(parts.morning.map(\.key), ["am", "late-am"], "by start time, even when it runs past noon")
        XCTAssertEqual(parts.afternoon.map(\.key), ["noon", "pm"])
    }

    func testOriginOfACopyAndOfAnOwnEvent() {
        let sourceID = UUID()
        let marker = CopyMarker(sourceID: sourceID, key: "abc").encoded
        let copy = SourceEvent(key: "c", title: "[A] Standup", start: date(2026, 10, 24, hour: 9),
                               end: date(2026, 10, 24, hour: 10), notes: "Agenda\n\n\(marker)")
        let own = SourceEvent(key: "o", title: "Dentist", start: date(2026, 10, 24, hour: 9), end: date(2026, 10, 24, hour: 10))
        XCTAssertEqual(MenuCalendar.originID(of: copy), sourceID)
        XCTAssertNil(MenuCalendar.originID(of: own))
    }

    func testSectionsGroupByDaySoonestFirst() {
        let events = [
            SourceEvent(key: "b", title: "Later today", start: date(2026, 10, 24, hour: 15), end: date(2026, 10, 24, hour: 16)),
            SourceEvent(key: "c", title: "Tomorrow", start: date(2026, 10, 25, hour: 9), end: date(2026, 10, 25, hour: 10)),
            SourceEvent(key: "a", title: "Earlier today", start: date(2026, 10, 24, hour: 9), end: date(2026, 10, 24, hour: 10)),
        ]
        let sections = MenuCalendar.sections(for: events, calendar: utc)
        XCTAssertEqual(sections.map(\.day), [date(2026, 10, 24), date(2026, 10, 25)])
        XCTAssertEqual(sections[0].events.map(\.key), ["a", "b"])
        XCTAssertEqual(sections[1].events.map(\.key), ["c"])
    }

    func testSectionsOfNoEvents() {
        XCTAssertEqual(MenuCalendar.sections(for: [], calendar: utc), [])
    }

    // MARK: - Titles and the next meeting

    func testOriginalTitleDropsTheCalendarPrefix() {
        XCTAssertEqual(CopyFormatter.originalTitle("[Calendar A] Sprint planning"), "Sprint planning")
        XCTAssertEqual(CopyFormatter.originalTitle("[A]Standup"), "Standup")
        XCTAssertEqual(CopyFormatter.originalTitle("Dentist"), "Dentist")
        XCTAssertEqual(CopyFormatter.originalTitle("[Draft]"), "[Draft]", "nothing after the brackets: keep it")
        XCTAssertEqual(CopyFormatter.originalTitle("Review [v2] notes"), "Review [v2] notes")
    }

    func testDisplayTitleStripsOnlyCopies() {
        let marker = CopyMarker(sourceID: UUID(), key: "k").encoded
        let copy = SourceEvent(key: "c", title: "[A] Standup", start: date(2026, 11, 5, hour: 9),
                               end: date(2026, 11, 5, hour: 10), notes: marker)
        let own = SourceEvent(key: "o", title: "[Draft] Plan", start: date(2026, 11, 5, hour: 9), end: date(2026, 11, 5, hour: 10))
        let untitled = SourceEvent(key: "u", title: " ", start: date(2026, 11, 5, hour: 9), end: date(2026, 11, 5, hour: 10))
        XCTAssertEqual(MenuCalendar.displayTitle(of: copy), "Standup")
        XCTAssertEqual(MenuCalendar.displayTitle(of: own), "[Draft] Plan", "the main calendar's own events keep their title")
        XCTAssertEqual(MenuCalendar.displayTitle(of: untitled), "Busy")
    }

    func testUpNextIsTheMeetingUnderWayOrTheNextOneToday() {
        let now = date(2026, 11, 5, hour: 11)
        func event(_ key: String, _ start: Int, _ end: Int, day: Int = 5, allDay: Bool = false, declined: Bool = false) -> SourceEvent {
            SourceEvent(key: key, title: key, start: date(2026, 11, day, hour: start), end: date(2026, 11, day, hour: end),
                        isAllDay: allDay, isDeclined: declined)
        }
        XCTAssertEqual(MenuCalendar.upNext(in: [event("pm", 14, 15), event("now", 10, 12), event("past", 9, 10)],
                                           now: now, calendar: utc)?.key, "now")
        XCTAssertEqual(MenuCalendar.upNext(in: [event("pm", 14, 15), event("noon", 12, 13), event("past", 9, 10)],
                                           now: now, calendar: utc)?.key, "noon")
        XCTAssertNil(MenuCalendar.upNext(in: [event("tomorrow", 9, 10, day: 6), event("past", 9, 10)], now: now, calendar: utc),
                     "nothing left today")
        XCTAssertNil(MenuCalendar.upNext(in: [event("all day", 0, 24, allDay: true), event("declined", 12, 13, declined: true)],
                                         now: now, calendar: utc))
        let away = SourceEvent(key: "ooo", title: "Out of office", start: date(2026, 11, 5, hour: 10),
                               end: date(2026, 11, 5, hour: 18), isOutOfOffice: true)
        XCTAssertNil(MenuCalendar.upNext(in: [away], now: now, calendar: utc), "out of office isn't a meeting")
    }

    func testCountdowns() {
        let start = date(2026, 11, 5, hour: 11).addingTimeInterval(30 * 60)
        let meeting = SourceEvent(key: "m", title: "Design review", start: start, end: start.addingTimeInterval(45 * 60))
        let at = { (minutes: Double) in start.addingTimeInterval(minutes * 60) }
        XCTAssertEqual(MenuCalendar.countdown(to: meeting, now: at(-12)), "in 12 min")
        XCTAssertEqual(MenuCalendar.countdown(to: meeting, now: at(-11.5)), "in 12 min", "rounded up")
        XCTAssertEqual(MenuCalendar.countdown(to: meeting, now: at(-80)), "in 1h 20m")
        XCTAssertEqual(MenuCalendar.countdown(to: meeting, now: at(25)), "now · 20 min left")
        XCTAssertEqual(MenuCalendar.menuBarText(for: meeting, now: at(-12)), "Design review · 12m")
        XCTAssertEqual(MenuCalendar.menuBarText(for: meeting, now: at(22)), "Design review · 23m left")
        XCTAssertNil(MenuCalendar.menuBarText(for: meeting, now: at(-16)), "more than 15 minutes away")
        XCTAssertNil(MenuCalendar.menuBarText(for: meeting, now: at(45)), "over")
        let long = SourceEvent(key: "l", title: "Quarterly business review with the regional leads", start: start, end: at(60))
        XCTAssertEqual(MenuCalendar.menuBarText(for: long, now: at(-5)), "Quarterly business re… · 5m")
        XCTAssertEqual(MenuCalendar.shortDuration(minutes: 60), "1h")
    }

    func testMenuBarProgress() {
        let start = date(2026, 11, 5, hour: 10)
        func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }
        let meeting = SourceEvent(key: "m", title: "Design review", start: start, end: at(40))
        XCTAssertEqual(MenuCalendar.menuBarProgress(for: meeting, now: at(-5)), 0, "not started yet")
        XCTAssertEqual(MenuCalendar.menuBarProgress(for: meeting, now: at(10)), 0.25)
        XCTAssertEqual(MenuCalendar.menuBarProgress(for: meeting, now: at(30)), 0.75)
        XCTAssertNil(MenuCalendar.menuBarProgress(for: meeting, now: at(-20)), "not in the menu bar yet")
        XCTAssertNil(MenuCalendar.menuBarProgress(for: meeting, now: at(40)), "over")
    }

    func testMeetingProgressNeedsTheMeetingTitle() throws {
        XCTAssertFalse(MenuBarOptions(showsNextMeeting: false, showsMeetingProgress: true).drawsMeetingProgress)
        XCTAssertTrue(MenuBarOptions(showsNextMeeting: true, showsMeetingProgress: true).drawsMeetingProgress)
        let old = try JSONDecoder().decode(MenuBarOptions.self, from: Data(#"{"showsWeekday":true,"showsNextMeeting":true}"#.utf8))
        XCTAssertFalse(old.showsMeetingProgress, "off for settings saved before it existed")
    }

    func testMenuBarPrefersTheMeetingAboutToStart() {
        let now = date(2026, 11, 5, hour: 11)
        let focus = SourceEvent(key: "focus", title: "Focus", start: date(2026, 11, 5, hour: 9), end: date(2026, 11, 5, hour: 13))
        let soon = SourceEvent(key: "soon", title: "Standup", start: now.addingTimeInterval(10 * 60), end: now.addingTimeInterval(25 * 60))
        let later = SourceEvent(key: "later", title: "Review", start: date(2026, 11, 5, hour: 14), end: date(2026, 11, 5, hour: 15))
        XCTAssertEqual(MenuCalendar.menuBarMeeting(in: [focus, soon, later], now: now)?.key, "soon")
        XCTAssertEqual(MenuCalendar.menuBarMeeting(in: [focus, later], now: now)?.key, "focus")
        XCTAssertNil(MenuCalendar.menuBarMeeting(in: [later], now: now))
    }

    func testMeetingServiceNames() {
        XCTAssertEqual(MeetingLink.serviceName(of: URL(string: "https://teams.microsoft.com/l/meetup-join/19%3a")!), "Teams")
        XCTAssertEqual(MeetingLink.serviceName(of: URL(string: "https://acme.zoom.us/j/123")!), "Zoom")
        XCTAssertEqual(MeetingLink.serviceName(of: URL(string: "https://meet.google.com/abc-defg-hij")!), "Meet")
        XCTAssertNil(MeetingLink.serviceName(of: URL(string: "https://notzoom.us/j/1")!))
        XCTAssertNil(MeetingLink.serviceName(of: URL(string: "https://whereby.com/room")!))
    }
}
