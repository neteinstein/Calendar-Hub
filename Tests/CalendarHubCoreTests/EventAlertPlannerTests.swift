import XCTest
@testable import CalendarHubCore

final class EventAlertPlannerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// An event starting `minutes` from now, lasting `lasts` minutes.
    func event(_ key: String, startsIn minutes: Double, lasts: Double = 60) -> SourceEvent {
        let start = now + minutes * 60
        return SourceEvent(key: key, title: "Meeting \(key)", start: start, end: start + lasts * 60,
                           meetingURL: URL(string: "https://zoom.us/j/1"))
    }

    func due(_ events: [SourceEvent], shown: Set<String> = [], lead: Int = 1) -> [String] {
        EventAlertPlanner.dueAlerts(events: events, shown: shown, now: now, leadMinutes: lead).map(\.key)
    }

    func testDueFromLeadTimeUntilTheEventEnds() {
        XCTAssertEqual(due([event("starting", startsIn: 0)]), ["starting"])
        XCTAssertEqual(due([event("in-lead", startsIn: 1)]), ["in-lead"])
        XCTAssertEqual(due([event("too-early", startsIn: 1.5)]), [])
        XCTAssertEqual(due([event("under-way", startsIn: -30)]), ["under-way"], "a meeting already under way still alerts")
        XCTAssertEqual(due([event("over", startsIn: -61)]), [])
    }

    func testLeadMinutesWidenTheWindow() {
        XCTAssertEqual(due([event("e", startsIn: 5)], lead: 5), ["e"])
        XCTAssertEqual(due([event("e", startsIn: 5)], lead: 0), [])
    }

    func testEachEventAlertsOnce() {
        let events = [event("a", startsIn: 0), event("b", startsIn: 0)]
        XCTAssertEqual(due(events, shown: ["a"]), ["b"])
        XCTAssertEqual(due(events, shown: ["a", "b"]), [])
    }

    func testSkipsAllDayDeclinedAndCancelled() {
        var allDay = event("all-day", startsIn: 0); allDay.isAllDay = true
        var declined = event("declined", startsIn: 0); declined.isDeclined = true
        var cancelled = event("cancelled", startsIn: 0); cancelled.isCancelled = true
        XCTAssertEqual(due([allDay, declined, cancelled, event("ok", startsIn: 0)]), ["ok"])
    }

    func testSoonestFirst() {
        XCTAssertEqual(due([event("later", startsIn: 1), event("sooner", startsIn: -5)]), ["sooner", "later"])
    }

    func testOldSettingsDecodeToEnabled() throws {
        let decoded = try JSONDecoder().decode(EventAlertOptions.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.leadMinutes, 1)
        // Turned off is saved as off, so the new default doesn't turn it back on.
        let off = try JSONDecoder().decode(EventAlertOptions.self, from: Data(#"{"enabled":false}"#.utf8))
        XCTAssertFalse(off.enabled)
        let full = EventAlertOptions(enabled: true, leadMinutes: 5)
        let roundTrip = try JSONDecoder().decode(EventAlertOptions.self, from: JSONEncoder().encode(full))
        XCTAssertEqual(roundTrip, full)
    }

    func testNextAlertTimeIsTheEarliestUpcomingLeadTime() {
        let events = [event("later", startsIn: 10), event("sooner", startsIn: 3), event("now", startsIn: 0)]
        XCTAssertEqual(EventAlertPlanner.nextAlertTime(events: events, shown: [], now: now, leadMinutes: 1),
                       now + 2 * 60, "already-due alerts are left to the check; the next is 1 minute before 'sooner'")
        XCTAssertEqual(EventAlertPlanner.nextAlertTime(events: events, shown: ["sooner"], now: now, leadMinutes: 0),
                       now + 10 * 60)
        var declined = event("declined", startsIn: 2); declined.isDeclined = true
        XCTAssertNil(EventAlertPlanner.nextAlertTime(events: [declined], shown: [], now: now, leadMinutes: 1))
    }
}
