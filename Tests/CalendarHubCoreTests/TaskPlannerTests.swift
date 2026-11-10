import XCTest
@testable import CalendarHubCore

final class TaskPlannerTests: XCTestCase {
    /// Fixed calendar so the dates don't depend on the machine running the tests.
    var utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, month: Int = 11) -> Date {
        utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Thursday 5 November 2026, 10:00.
    var now: Date { date(5, 10) }

    func meeting(_ key: String = "evt-1", at start: Date, title: String = "Design review") -> SourceEvent {
        SourceEvent(key: key, title: title, start: start, end: start + 3600)
    }

    // MARK: - Event link

    func testEventLinkRoundTripsThroughTheURL() {
        let link = TaskEventLink(key: "ABC-123|2026-11-06T14:00:00Z", title: "Design review & Q&A = fun",
                                 start: date(6, 14))
        XCTAssertEqual(link.url.scheme, "calendarhub")
        XCTAssertEqual(TaskEventLink(url: link.url), link)
        let allDay = TaskEventLink(key: "k", title: "Offsite", start: date(6), isAllDay: true)
        XCTAssertEqual(TaskEventLink(url: allDay.url), allDay)
        // The URL keeps whole seconds; a link to an event starting between them reads back the
        // same, or every sync would take the event for moved.
        let fractional = TaskEventLink(meeting(at: date(6, 14) + 0.25))
        XCTAssertEqual(TaskEventLink(url: fractional.url), fractional)
        XCTAssertNil(TaskPlanner.realigned(TaskItem(title: "Slides", event: fractional),
                                           to: meeting(at: date(6, 14) + 0.25), calendar: utc))
    }

    func testLinksFromBeforeTheRenameStillRead() {
        let link = TaskEventLink(key: "k", title: "Design review", start: date(6, 14))
        let old = URL(string: link.url.absoluteString.replacingOccurrences(of: "calendarhub:", with: "calendarsync:"))
        XCTAssertEqual(TaskEventLink(url: old), link)
    }

    func testOtherURLsAreNoLink() {
        XCTAssertNil(TaskEventLink(url: nil))
        XCTAssertNil(TaskEventLink(url: URL(string: "https://example.com/event?key=a&start=2026-11-06T14:00:00Z")))
        XCTAssertNil(TaskEventLink(url: URL(string: "calendarhub://event?title=No%20key&start=2026-11-06T14:00:00Z")))
        XCTAssertNil(TaskEventLink(url: URL(string: "calendarhub://event?key=a&start=yesterday")))
    }

    func testLinkTakesTheTitleTheMenuShows() {
        let notes = CopyFormatter.notes(meetingURL: nil, marker: CopyMarker(sourceID: UUID(), key: "x"))
        let copy = SourceEvent(key: "k", title: "[Calendar A] Sprint planning", start: date(6, 9), end: date(6, 10),
                               notes: notes)
        XCTAssertEqual(TaskEventLink(copy).title, "Sprint planning")
    }

    // MARK: - Nudges

    func testNudgeDatesForATimedAnchor() {
        let anchor = date(6, 14)
        func at(_ nudge: Nudge) -> Date? { nudge.date(anchor: anchor, anchorHasTime: true, calendar: utc) }
        XCTAssertEqual(at(.atStart), anchor)
        XCTAssertEqual(at(.before(minutes: 60)), date(6, 13))
        XCTAssertEqual(at(.daysBefore(0, atMinute: 9 * 60)), date(6, 9))
        XCTAssertEqual(at(.daysBefore(1, atMinute: 9 * 60 + 30)), date(5, 9, 30))
        XCTAssertEqual(at(.at(date(1, 8))), date(1, 8))
    }

    func testNudgesBeforeAMorningMeetingGoBackOverMidnight() {
        let anchor = date(6, 0, 30)
        XCTAssertEqual(Nudge.before(minutes: 60).date(anchor: anchor, anchorHasTime: true, calendar: utc), date(5, 23, 30))
    }

    func testAWholeDayAnchorNudgesThatMorning() {
        let day = date(6)
        XCTAssertEqual(Nudge.atStart.date(anchor: day, anchorHasTime: false, calendar: utc), date(6, 9))
        XCTAssertEqual(Nudge.before(minutes: 15).date(anchor: day, anchorHasTime: false, calendar: utc), date(6, 9))
        XCTAssertEqual(Nudge.daysBefore(1, atMinute: 18 * 60).date(anchor: day, anchorHasTime: false, calendar: utc), date(5, 18))
    }

    func testRelativeNudgesNeedAnAnchor() {
        XCTAssertNil(Nudge.atStart.date(anchor: nil, anchorHasTime: true, calendar: utc))
        XCTAssertNil(Nudge.daysBefore(1, atMinute: 540).date(anchor: nil, anchorHasTime: true, calendar: utc))
        XCTAssertEqual(Nudge.at(date(7, 9)).date(anchor: nil, anchorHasTime: true, calendar: utc), date(7, 9))
    }

    func testNudgesAcrossAClockChange() {
        // Lisbon went back an hour at 02:00 on 25 October 2026, so that day had 25 hours.
        var lisbon = Calendar(identifier: .gregorian)
        lisbon.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        let monday = lisbon.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9))!
        let nudge = Nudge.daysBefore(1, atMinute: 9 * 60).date(anchor: monday, anchorHasTime: true, calendar: lisbon)!
        XCTAssertEqual(lisbon.dateComponents([.day, .hour, .minute], from: nudge), DateComponents(day: 25, hour: 9, minute: 0))
    }

    func testSavedNudgesAreReadBackAsTheirPresets() {
        let anchor = date(6, 14)
        func match(_ date: Date) -> Nudge { Nudge.matching(date, anchor: anchor, anchorHasTime: true, calendar: utc) }
        XCTAssertEqual(match(date(6, 13)), .before(minutes: 60))
        XCTAssertEqual(match(date(5, 9)), .daysBefore(1, atMinute: 540))
        XCTAssertEqual(match(date(6, 11, 12)), .at(date(6, 11, 12)))
        XCTAssertEqual(Nudge.matching(date(6, 13), anchor: nil, anchorHasTime: true, calendar: utc), .at(date(6, 13)))
    }

    func testNudgeTitles() {
        XCTAssertEqual(Nudge.atStart.title(forEvent: true), "When it starts")
        XCTAssertEqual(Nudge.atStart.title(forEvent: false), "At the due time")
        XCTAssertEqual(Nudge.before(minutes: 15).title(forEvent: true), "15 minutes before")
        XCTAssertEqual(Nudge.before(minutes: 60).title(forEvent: true), "1 hour before")
        XCTAssertEqual(Nudge.before(minutes: 120).title(forEvent: true), "2 hours before")
        XCTAssertEqual(Nudge.daysBefore(0, atMinute: 540).title(forEvent: true), "That day at 9:00")
        XCTAssertEqual(Nudge.daysBefore(1, atMinute: 540).title(forEvent: true), "The day before at 9:00")
        XCTAssertEqual(Nudge.daysBefore(3, atMinute: 1050).title(forEvent: true), "3 days before at 17:30")
        XCTAssertNil(Nudge.at(now).title(forEvent: true))
    }

    func testNextNudge() {
        let task = TaskItem(id: "t", title: "Slides", nudges: [date(5, 9), date(5, 15), date(6, 9)])
        XCTAssertEqual(TaskPlanner.nextNudge(of: task, now: now), date(5, 15))
        var done = task
        done.isCompleted = true
        XCTAssertNil(TaskPlanner.nextNudge(of: done, now: now))
        XCTAssertNil(TaskPlanner.nextNudge(of: task, now: date(7)))
    }

    // MARK: - Sections

    func testSections() {
        let tasks = [
            TaskItem(id: "late", title: "Late", due: date(5, 9)),
            TaskItem(id: "yesterday", title: "Yesterday", due: date(4), dueHasTime: false),
            TaskItem(id: "today-day", title: "Today, all day", due: date(5), dueHasTime: false),
            TaskItem(id: "today", title: "Today", due: date(5, 17)),
            TaskItem(id: "event", title: "For the meeting", event: TaskEventLink(meeting(at: date(5, 14)))),
            TaskItem(id: "tomorrow", title: "Tomorrow", due: date(6, 9)),
            TaskItem(id: "later", title: "Later", due: date(20, 9)),
            TaskItem(id: "someday-b", title: "B", creationDate: date(2)),
            TaskItem(id: "someday-a", title: "A", creationDate: date(1)),
            TaskItem(id: "done-old", title: "Done", isCompleted: true, completionDate: date(3)),
            TaskItem(id: "done-new", title: "Done", due: date(1, 9), isCompleted: true, completionDate: date(5, 8)),
        ]
        let sections = TaskPlanner.sections(tasks, now: now, calendar: utc)
        XCTAssertEqual(sections.map(\.kind), [.overdue, .today, .tomorrow, .later, .someday, .done])
        XCTAssertEqual(sections.map { $0.tasks.map(\.id) }, [
            ["yesterday", "late"],
            ["today-day", "event", "today"],
            ["tomorrow"],
            ["later"],
            ["someday-a", "someday-b"],
            ["done-new", "done-old"],
        ])
    }

    func testAWholeDayIsNotOverdueUntilItEnds() {
        let task = TaskItem(title: "Today", due: date(5), dueHasTime: false)
        XCTAssertFalse(TaskPlanner.isOverdue(task, now: date(5, 23, 59), calendar: utc))
        XCTAssertTrue(TaskPlanner.isOverdue(task, now: date(6, 0, 1), calendar: utc))
        let allDayEvent = TaskItem(title: "Offsite prep", event: TaskEventLink(key: "k", title: "Offsite", start: date(5), isAllDay: true))
        XCTAssertFalse(TaskPlanner.isOverdue(allDayEvent, now: now, calendar: utc))
    }

    func testTasksByDayPutOverdueOnesOnToday() {
        let tasks = [
            TaskItem(id: "late", title: "Late", due: date(3, 9)),
            TaskItem(id: "today-time", title: "At five", due: date(5, 17)),
            TaskItem(id: "today-day", title: "Today", due: date(5), dueHasTime: false),
            TaskItem(id: "event", title: "Prep", event: TaskEventLink(meeting(at: date(7, 14)))),
            TaskItem(id: "someday", title: "No date"),
            TaskItem(id: "done", title: "Done", due: date(5, 9), isCompleted: true),
        ]
        let days = TaskPlanner.byDay(tasks, now: now, calendar: utc)
        XCTAssertEqual(days.keys.sorted(), [date(5), date(7)])
        XCTAssertEqual(days[date(5)]?.map(\.id), ["today-day", "late", "today-time"])
        XCTAssertEqual(days[date(7)]?.map(\.id), ["event"])
    }

    func testNoSectionsForNoTasks() {
        XCTAssertEqual(TaskPlanner.sections([], now: now, calendar: utc), [])
    }

    func testOpenTasksForAnEvent() {
        let link = TaskEventLink(meeting(at: date(6, 14)))
        let tasks = [
            TaskItem(id: "b", title: "B", due: date(6, 12), event: link),
            TaskItem(id: "a", title: "A", due: date(6, 11), event: link),
            TaskItem(id: "done", title: "Done", isCompleted: true, event: link),
            TaskItem(id: "other", title: "Other", event: TaskEventLink(meeting("evt-2", at: date(6, 14)))),
        ]
        XCTAssertEqual(TaskPlanner.openTasks(forEvent: "evt-1", in: tasks).map(\.id), ["a", "b"])
    }

    // MARK: - Keeping up with the event

    func testAMovedEventTakesTheDueDateAndNudgesAlong() {
        let original = meeting(at: date(6, 14))
        let task = TaskItem(id: "t", title: "Slides", due: date(6, 14), nudges: [date(6, 13), date(5, 9)],
                            event: TaskEventLink(original))
        let moved = meeting(at: date(7, 16))
        let realigned = TaskPlanner.realigned(task, to: moved, calendar: utc)
        XCTAssertEqual(realigned?.due, date(7, 16))
        XCTAssertEqual(realigned?.nudges, [date(7, 15), date(6, 11)])
        XCTAssertEqual(realigned?.event?.start, date(7, 16))
    }

    func testAWholeDayDueDateStaysAWholeDay() {
        let task = TaskItem(title: "Slides", due: date(6), dueHasTime: false, event: TaskEventLink(meeting(at: date(6, 14))))
        XCTAssertEqual(TaskPlanner.realigned(task, to: meeting(at: date(6, 16)), calendar: utc)?.due, date(6))
        XCTAssertEqual(TaskPlanner.realigned(task, to: meeting(at: date(8, 9)), calendar: utc)?.due, date(8))
    }

    func testARenamedEventOnlyUpdatesTheLink() {
        let task = TaskItem(title: "Slides", due: date(6, 14), nudges: [date(6, 13)], event: TaskEventLink(meeting(at: date(6, 14))))
        let renamed = TaskPlanner.realigned(task, to: meeting(at: date(6, 14), title: "Design crit"), calendar: utc)
        XCTAssertEqual(renamed?.event?.title, "Design crit")
        XCTAssertEqual(renamed?.due, date(6, 14))
        XCTAssertEqual(renamed?.nudges, [date(6, 13)])
    }

    func testNothingToRealign() {
        let event = meeting(at: date(6, 14))
        let task = TaskItem(title: "Slides", due: date(6, 14), event: TaskEventLink(event))
        XCTAssertNil(TaskPlanner.realigned(task, to: event, calendar: utc), "unchanged")
        XCTAssertNil(TaskPlanner.realigned(task, to: meeting("evt-2", at: date(7, 9)), calendar: utc), "another event")
        var done = task
        done.isCompleted = true
        XCTAssertNil(TaskPlanner.realigned(done, to: meeting(at: date(7, 9)), calendar: utc), "done")
    }

    // MARK: - Options

    func testOldSettingsDecodeToTheDefaults() throws {
        let decoded = try JSONDecoder().decode(TaskOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, TaskOptions())
        XCTAssertEqual(decoded.eventNudge, .before(minutes: 60))
    }

    func testANudgeTurnedOffStaysOff() throws {
        var options = TaskOptions()
        options.eventNudge = nil
        options.listID = "list"
        let roundTrip = try JSONDecoder().decode(TaskOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(roundTrip, options)
        XCTAssertNil(roundTrip.eventNudge)
        XCTAssertEqual(roundTrip.dueNudge, .atStart)
    }
}
