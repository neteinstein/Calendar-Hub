import XCTest
@testable import CalendarHubCore

final class SyncOverlapsTests: XCTestCase {
    let source = SourceConfig(kind: .eventKit(calendarID: "secondary-cal"), calendarName: "Calendar A")
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ key: String, _ title: String, at hour: Double, length: Double = 1) -> SourceEvent {
        SourceEvent(key: key, title: title, start: base + hour * 3600, end: base + (hour + length) * 3600)
    }

    func applied(_ plan: SyncPlan) -> [ExistingCopy] {
        plan.actions.enumerated().compactMap { i, action in
            guard case .create(let s) = action else { return nil }
            return ExistingCopy(eventID: "copy-\(i)", marker: s.marker, title: s.title, start: s.start,
                                end: s.end, isAllDay: s.isAllDay, url: s.url, notes: s.notes)
        }
    }

    func testANewCopyOverlappingAMainMeetingIsReported() {
        let main = [event("m1", "Design review", at: 1)]
        let plan = SyncPlanner.plan(sources: [(source, .success([event("1", "Sprint planning", at: 1.5)]))],
                                    existing: [], options: SyncOptions())
        let found = SyncOverlaps.find(plan: plan, existing: [], mainEvents: main, now: base)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].title, "[Calendar A] Sprint planning")
        XCTAssertEqual(found[0].others, ["Design review"])
    }

    func testBackToBackIsNotAnOverlap() {
        let main = [event("m1", "Design review", at: 1)]
        let plan = SyncPlanner.plan(sources: [(source, .success([event("1", "Sprint planning", at: 2)]))],
                                    existing: [], options: SyncOptions())
        XCTAssertTrue(SyncOverlaps.find(plan: plan, existing: [], mainEvents: main, now: base).isEmpty)
    }

    func testACopyThatStaysPutIsNotReportedAgain() {
        let main = [event("m1", "Design review", at: 1)]
        let events = [event("1", "Sprint planning", at: 1)]
        let first = SyncPlanner.plan(sources: [(source, .success(events))], existing: [], options: SyncOptions())
        let existing = applied(first)
        var renamed = events
        renamed[0].title = "Sprint planning (moved room)"
        let second = SyncPlanner.plan(sources: [(source, .success(renamed))], existing: existing, options: SyncOptions())
        XCTAssertEqual(second.updates, 1)
        XCTAssertTrue(SyncOverlaps.find(plan: second, existing: existing, mainEvents: main, now: base).isEmpty)
    }

    func testAMovedCopyIsReported() {
        let main = [event("m1", "Design review", at: 3)]
        let first = SyncPlanner.plan(sources: [(source, .success([event("1", "Sprint planning", at: 1)]))],
                                     existing: [], options: SyncOptions())
        let existing = applied(first)
        let second = SyncPlanner.plan(sources: [(source, .success([event("1", "Sprint planning", at: 3)]))],
                                      existing: existing, options: SyncOptions())
        let found = SyncOverlaps.find(plan: second, existing: existing, mainEvents: main, now: base)
        XCTAssertEqual(found.map(\.others), [["Design review"]])
    }

    func testTwoNewCopiesOnEachOtherAreOneOverlap() {
        let other = SourceConfig(kind: .eventKit(calendarID: "other"), calendarName: "Client X")
        let plan = SyncPlanner.plan(sources: [(source, .success([event("1", "Sprint planning", at: 1)])),
                                              (other, .success([event("2", "Kickoff", at: 1)]))],
                                    existing: [], options: SyncOptions())
        let found = SyncOverlaps.find(plan: plan, existing: [], mainEvents: [], now: base)
        XCTAssertEqual(found.count, 1)
    }

    func testDeclinedAllDayAndPastAreLeftOut() {
        var declined = event("m1", "Declined", at: 1)
        declined.isDeclined = true
        var allDay = event("m2", "Holiday", at: 0, length: 24)
        allDay.isAllDay = true
        let plan = SyncPlanner.plan(sources: [(source, .success([event("1", "Sprint planning", at: 1)]))],
                                    existing: [], options: SyncOptions())
        XCTAssertTrue(SyncOverlaps.find(plan: plan, existing: [], mainEvents: [declined, allDay], now: base).isEmpty)
        let main = [event("m3", "Design review", at: 1)]
        XCTAssertTrue(SyncOverlaps.find(plan: plan, existing: [], mainEvents: main, now: base + 5 * 3600).isEmpty)
    }

    func testTheCopyItselfInTheMainCalendarDoesNotCount() {
        let first = SyncPlanner.plan(sources: [(source, .success([event("1", "Sprint planning", at: 1)]))],
                                     existing: [], options: SyncOptions())
        let existing = applied(first)
        // The main calendar's events include the copy, carrying its marker.
        let mainCopy = SourceEvent(key: "copy", title: existing[0].title, start: base + 3600, end: base + 7200,
                                   notes: existing[0].notes)
        let second = SyncPlanner.plan(sources: [(source, .success([event("1", "Sprint planning", at: 1.5)]))],
                                      existing: existing, options: SyncOptions())
        XCTAssertTrue(SyncOverlaps.find(plan: second, existing: existing, mainEvents: [mainCopy], now: base).isEmpty)
    }
}
