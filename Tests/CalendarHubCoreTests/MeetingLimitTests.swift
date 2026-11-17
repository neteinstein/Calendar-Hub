import XCTest
@testable import CalendarHubCore

final class MeetingLimitTests: XCTestCase {
    var utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2 // Monday
        return calendar
    }()

    /// 9:00 to 17:00.
    let workingHours = WorkingHours()
    let on = MeetingLimitOptions(isEnabled: true, hours: 5, marksBusy: true)

    /// November 2026: the 17th is a Tuesday, the 21st a Saturday.
    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func meeting(_ start: Date, _ end: Date, title: String = "M", outOfOffice: Bool = false,
                 allDay: Bool = false, notes: String? = nil) -> SourceEvent {
        SourceEvent(key: UUID().uuidString, title: title, start: start, end: end, isAllDay: allDay,
                    isOutOfOffice: outOfOffice, notes: notes)
    }

    /// 9–11, 12–14, 15–16:30 on the 18th: 5.5 hours, free 11–12, 14–15 and 16:30–17.
    var fullDay: [SourceEvent] {
        [meeting(date(18, 9), date(18, 11)),
         meeting(date(18, 12), date(18, 14)),
         meeting(date(18, 15), date(18, 16, 30))]
    }

    func block(_ id: String, _ start: Date, _ end: Date) -> ExistingCopy {
        let spec = MeetingLimit.spec(for: DateInterval(start: start, end: end), calendar: utc)
        return ExistingCopy(eventID: id, marker: nil, title: spec.title, start: start, end: end,
                            isAllDay: false, url: nil, notes: spec.notes)
    }

    func blockEvent(_ start: Date, _ end: Date) -> SourceEvent {
        meeting(start, end, title: "Busy", notes: MeetingLimit.notes(dayKey: MeetingLimit.dayKey(start, calendar: utc)))
    }

    func plan(_ events: [SourceEvent], existing: [ExistingCopy] = [], days: [Date]? = nil,
              now: Date? = nil, options: MeetingLimitOptions? = nil, skipped: Set<String> = []) -> SyncPlan {
        MeetingLimit.planBlocks(mainEvents: events, existing: existing, days: days ?? [date(18, 0)],
                                now: now ?? date(17, 12), options: options ?? on, workingHours: workingHours,
                                skippedDays: skipped, calendar: utc)
    }

    func created(_ plan: SyncPlan) -> [DateInterval] {
        plan.actions.compactMap { if case .create(let spec) = $0 { DateInterval(start: spec.start, end: spec.end) } else { nil } }
    }

    // MARK: - Marker

    func testBlocksAreRecognisedAndAreNotCopies() {
        let notes = MeetingLimit.notes(dayKey: "2026-11-18")
        XCTAssertTrue(notes.hasSuffix("calsync:v1:limit:2026-11-18"))
        XCTAssertTrue(MeetingLimit.isBlock(notes: notes))
        XCTAssertNil(CopyMarker.find(in: notes), "Not a copy of any source, so a sync never takes it for one")
        XCTAssertTrue(CopyMarker.isCopy(notes), "Never copied back into the main calendar")
        XCTAssertFalse(MeetingLimit.isBlock(notes: "Busy"))
        XCTAssertFalse(MeetingLimit.isBlock(notes: nil))
    }

    func testBlocksAreNotMeetings() {
        let block = blockEvent(date(18, 11), date(18, 12))
        XCTAssertFalse(MeetingStats.counts(block))
        XCTAssertFalse(MenuCalendar.isMeeting(block))
        XCTAssertTrue(EventAlertPlanner.dueAlerts(events: [block], shown: [], now: date(18, 11), leadMinutes: 0).isEmpty)
        XCTAssertEqual(MeetingLimit.hours(on: date(18, 0), in: fullDay + [block], calendar: utc), 5.5)
    }

    // MARK: - Full days

    func testFullDays() {
        let events = fullDay + [meeting(date(19, 9), date(19, 13))] // 4h on the 19th
        let days = MeetingLimit.days(from: date(17, 10), to: date(20, 0), calendar: utc)
        XCTAssertEqual(days, [date(17, 0), date(18, 0), date(19, 0)])
        let full = MeetingLimit.fullDays(days, events: events, options: on, calendar: utc, workingHours: workingHours)
        XCTAssertEqual(full, [MeetingLimit.FullDay(day: date(18, 0), hours: 5.5)])

        var off = on
        off.isEnabled = false
        XCTAssertTrue(MeetingLimit.fullDays(days, events: events, options: off, calendar: utc, workingHours: workingHours).isEmpty)
    }

    func testExactlyTheLimitIsFull() {
        let events = [meeting(date(18, 9), date(18, 14))]
        XCTAssertEqual(MeetingLimit.fullDays([date(18, 0)], events: events, options: on, calendar: utc,
                                             workingHours: workingHours).count, 1)
    }

    func testOverlapCountsOnceAndDeclinedAllDayDoNotCount() {
        let events = [
            meeting(date(18, 9), date(18, 12)),
            meeting(date(18, 10), date(18, 13)), // 4h together
            meeting(date(18, 0), date(19, 0), allDay: true),
            SourceEvent(key: "d", title: "D", start: date(18, 14), end: date(18, 16), isDeclined: true),
        ]
        XCTAssertTrue(MeetingLimit.fullDays([date(18, 0)], events: events, options: on, calendar: utc,
                                            workingHours: workingHours).isEmpty)
    }

    func testWeekendsAndOutOfOfficeDaysHaveNoLimit() {
        let saturday = [meeting(date(21, 9), date(21, 16))]
        XCTAssertTrue(MeetingLimit.fullDays([date(21, 0)], events: saturday, options: on, calendar: utc,
                                            workingHours: workingHours).isEmpty)
        let away = fullDay + [meeting(date(18, 0), date(19, 0), title: "Holiday", outOfOffice: true, allDay: true)]
        XCTAssertTrue(MeetingLimit.fullDays([date(18, 0)], events: away, options: on, calendar: utc,
                                            workingHours: workingHours).isEmpty)
        XCTAssertTrue(plan(away).isEmpty)
    }

    func testMessages() {
        let tomorrow = MeetingLimit.FullDay(day: date(18, 0), hours: 5 + 20.0 / 60)
        XCTAssertEqual(MeetingLimit.message(for: tomorrow, limit: 5, now: date(17, 12), calendar: utc),
                       "Tomorrow: 5h 20m of meetings, over your 5h limit")
        XCTAssertEqual(MeetingLimit.message(for: MeetingLimit.FullDay(day: date(17, 0), hours: 5), limit: 5,
                                            now: date(17, 12), calendar: utc),
                       "Today: 5h of meetings, at your 5h limit")
        XCTAssertEqual(MeetingLimit.message(for: MeetingLimit.FullDay(day: date(19, 0), hours: 6), limit: 4.5,
                                            now: date(17, 12), calendar: utc),
                       "Thursday: 6h of meetings, over your 4h 30m limit")
    }

    // MARK: - Free time

    func testFreeIntervalsWithinWorkingHours() {
        let events = fullDay + [meeting(date(18, 8), date(18, 9, 30))] // starts before working hours
        XCTAssertEqual(MeetingLimit.freeIntervals(in: events, on: date(18, 0), calendar: utc, workingHours: workingHours), [
            DateInterval(start: date(18, 11), end: date(18, 12)),
            DateInterval(start: date(18, 14), end: date(18, 15)),
            DateInterval(start: date(18, 16, 30), end: date(18, 17)),
        ])
    }

    func testShortGapsGetNoBlock() {
        let events = [meeting(date(18, 9), date(18, 12)), meeting(date(18, 12, 10), date(18, 17))]
        XCTAssertTrue(MeetingLimit.freeIntervals(in: events, on: date(18, 0), calendar: utc, workingHours: workingHours).isEmpty)
    }

    func testBlocksDoNotTakeTime() {
        let events = fullDay + [blockEvent(date(18, 11), date(18, 12))]
        XCTAssertEqual(MeetingLimit.freeIntervals(in: events, on: date(18, 0), calendar: utc, workingHours: workingHours).first,
                       DateInterval(start: date(18, 11), end: date(18, 12)))
    }

    // MARK: - Planning blocks

    func testFullDayGetsBlocksInItsFreeTime() {
        let plan = plan(fullDay)
        XCTAssertEqual(created(plan), [
            DateInterval(start: date(18, 11), end: date(18, 12)),
            DateInterval(start: date(18, 14), end: date(18, 15)),
            DateInterval(start: date(18, 16, 30), end: date(18, 17)),
        ])
        guard case .create(let spec) = plan.actions[0] else { return XCTFail() }
        XCTAssertEqual(spec.title, "Busy")
        XCTAssertNil(spec.marker)
        XCTAssertTrue(CopyFormatter.isBusy(spec), "Saved without alerts")
        XCTAssertFalse(spec.isOutOfOffice)
        XCTAssertTrue(spec.notes.hasSuffix("calsync:v1:limit:2026-11-18"))
    }

    func testNothingWithoutBlocksTurnedOn() {
        var options = on
        options.marksBusy = false
        XCTAssertTrue(plan(fullDay, options: options).isEmpty)
    }

    func testBlocksInPlaceStay() {
        let existing = [block("a", date(18, 11), date(18, 12)), block("b", date(18, 14), date(18, 15)),
                        block("c", date(18, 16, 30), date(18, 17))]
        let events = fullDay + existing.map { blockEvent($0.start, $0.end) }
        let plan = plan(events, existing: existing)
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.unchangedCount, 3)
    }

    func testAMeetingBookedIntoABlockMovesIt() {
        let existing = [block("a", date(18, 11), date(18, 12)), block("b", date(18, 14), date(18, 15)),
                        block("c", date(18, 16, 30), date(18, 17))]
        // Meetings always win: someone booked 14:00–14:30 over the block.
        let events = fullDay + [meeting(date(18, 14), date(18, 14, 30))]
        let plan = plan(events, existing: existing)
        XCTAssertEqual(plan.actions.count, 1)
        guard case .update(let id, let spec) = plan.actions[0] else { return XCTFail("\(plan.actions)") }
        XCTAssertEqual(id, "b")
        XCTAssertEqual(DateInterval(start: spec.start, end: spec.end), DateInterval(start: date(18, 14, 30), end: date(18, 15)))
    }

    func testDayBelowTheLimitLosesItsBlocks() {
        let existing = [block("a", date(18, 11), date(18, 12)), block("b", date(18, 14), date(18, 15))]
        // The 12–14 meeting was cancelled: 3.5 hours left.
        let events = [meeting(date(18, 9), date(18, 11)), meeting(date(18, 15), date(18, 16, 30))]
        let plan = plan(events, existing: existing)
        XCTAssertEqual(plan.deletes, 2)
        XCTAssertEqual(plan.creates, 0)
    }

    func testTurningTheLimitOffRemovesEveryBlock() {
        let existing = [block("a", date(18, 11), date(18, 12)), block("z", date(30, 11), date(30, 12))]
        var off = on
        off.isEnabled = false
        let plan = plan(fullDay, existing: existing, options: off)
        XCTAssertEqual(plan.deletes, 2, "Also the ones on days outside the window")
    }

    func testPastBlocksStayAndPastGapsGetNone() {
        let existing = [block("a", date(18, 11), date(18, 12))]
        let plan = plan(fullDay, existing: existing, now: date(18, 14, 20))
        XCTAssertEqual(plan.unchangedCount, 1)
        XCTAssertEqual(created(plan), [
            DateInterval(start: date(18, 14), end: date(18, 15)), // under way: drawn whole, so it stays put
            DateInterval(start: date(18, 16, 30), end: date(18, 17)),
        ])
    }

    func testSkippedDayKeepsWhatItHasAndGetsNothingNew() {
        let existing = [block("a", date(18, 11), date(18, 12))]
        let plan = plan(fullDay, existing: existing, skipped: ["2026-11-18"])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.unchangedCount, 1)

        let below = self.plan([meeting(date(18, 9), date(18, 11))], existing: existing, skipped: ["2026-11-18"])
        XCTAssertEqual(below.deletes, 1, "Still removed once the day drops below the limit")
    }

    func testBlockDeletedByHandIsNoticed() {
        let existing = [block("a", date(18, 11), date(18, 12)), block("c", date(18, 16, 30), date(18, 17))]
        let written = ["2026-11-18": 3, "2026-11-19": 0, "2026-11-20": 1]
        XCTAssertEqual(MeetingLimit.deletedByHand(existing: existing, written: written, calendar: utc),
                       ["2026-11-18", "2026-11-20"])
        XCTAssertEqual(MeetingLimit.blockCounts(existing, calendar: utc), ["2026-11-18": 2])
    }

    func testStateForgetsPastDays() {
        let state = MeetingLimitState(skippedDays: ["2026-11-16", "2026-11-18"], written: ["2026-11-16": 1, "2026-11-17": 2])
        XCTAssertEqual(state.pruned(before: "2026-11-17"),
                       MeetingLimitState(skippedDays: ["2026-11-18"], written: ["2026-11-17": 2]))
    }

    func testOptionsDecodeFromOlderSettings() throws {
        let options = try JSONDecoder().decode(MeetingLimitOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(options, MeetingLimitOptions())
        XCTAssertFalse(options.isEnabled)
        XCTAssertFalse(options.marksBusy)
        let source = try JSONDecoder().decode(SourceConfig.self, from: Data(
            #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":{"outlookWeb":{}},"calendarName":"A"}"#.utf8))
        XCTAssertFalse(source.marksFullDays)
    }

    // MARK: - Two-way sync

    func testBlocksReachOnlyCalendarsThatMarkFullDays() {
        let block = blockEvent(date(18, 11), date(18, 12))
        let meeting = meeting(date(18, 9), date(18, 10))
        var source = SourceConfig(kind: .eventKit(calendarID: "x"), calendarName: "Client", showBusyInSecondary: true)
        func busyTimes() -> [Date] {
            SyncPlanner.planBusy(for: source, mainEvents: .success([meeting, block]), existing: [], options: SyncOptions())
                .actions.compactMap { if case .create(let spec) = $0 { spec.start } else { nil } }
        }
        XCTAssertEqual(busyTimes(), [date(18, 9)])
        source.marksFullDays = true
        XCTAssertEqual(busyTimes(), [date(18, 9), date(18, 11)])
    }
}
