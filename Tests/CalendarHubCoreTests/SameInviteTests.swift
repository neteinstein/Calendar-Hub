import XCTest
@testable import CalendarHubCore

/// One invitation sent to more than one of your calendars gets one copy in the main calendar.
final class SameInviteTests: XCTestCase {
    let calendarA = SourceConfig(kind: .eventKit(calendarID: "secondary-a"), calendarName: "Calendar A")
    let calendarB = SourceConfig(kind: .eventKit(calendarID: "secondary-b"), calendarName: "Calendar B")
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ key: String, _ title: String, at hour: Double, uid: String? = nil,
               declined: Bool = false, notes: String? = nil) -> SourceEvent {
        SourceEvent(key: key, title: title, start: base + hour * 3600, end: base + (hour + 1) * 3600,
                    isDeclined: declined, notes: notes, inviteID: uid)
    }

    func created(_ plan: SyncPlan) -> [CopySpec] {
        plan.actions.compactMap { if case .create(let spec) = $0 { spec } else { nil } }
    }

    func copies(from plan: SyncPlan) -> [ExistingCopy] {
        created(plan).enumerated().map { i, s in
            ExistingCopy(eventID: "copy-\(i)", marker: s.marker, title: s.title, start: s.start,
                         end: s.end, isAllDay: s.isAllDay, url: s.url, notes: s.notes, location: s.location)
        }
    }

    // MARK: - Matching

    func testMatchesBySameTimesAndTitleOrInvitationID() {
        let review = event("a1", "Design review", at: 1)
        XCTAssertTrue(SameInvite.matches(review, event("b1", "design  REVIEW ", at: 1)), "case and spacing don't count")
        XCTAssertTrue(SameInvite.matches(event("a1", "Design review", at: 1, uid: "uid-1"),
                                         event("b1", "Updated: Design review", at: 1, uid: "uid-1")),
                      "the invitation's id is enough")
        XCTAssertTrue(SameInvite.matches(event("a1", "Design review", at: 1, uid: "040000008200E000"),
                                         event("b1", "Design review", at: 1, uid: "abc@google.com")),
                      "servers that keep their own ids still match by title")
        XCTAssertFalse(SameInvite.matches(review, event("b1", "Design review", at: 2)), "another time is another meeting")
        XCTAssertFalse(SameInvite.matches(review, event("b1", "Standup", at: 1)))
        XCTAssertFalse(SameInvite.matches(event("a1", "Standup", at: 1, uid: "series"),
                                          event("b1", "Standup", at: 25, uid: "series")),
                       "occurrences of one series share an id, but not their times")
        XCTAssertFalse(SameInvite.matches(event("a1", "", at: 1), event("b1", "", at: 1)), "no title, no id: can't tell")
    }

    // MARK: - Two secondary calendars

    func testInviteInTwoSecondaryCalendarsIsCopiedOnce() {
        let plan = SyncPlanner.plan(sources: [
            (calendarA, .success([event("a1", "Design review", at: 1)])),
            (calendarB, .success([event("b1", "Design review", at: 1), event("b2", "Retro", at: 3)])),
        ], existing: [], options: SyncOptions())

        XCTAssertEqual(created(plan).map(\.title), ["[Calendar A] Design review", "[Calendar B] Retro"],
                       "the calendar set up first copies it")
        XCTAssertEqual(plan.sameInviteCount, 1)

        let again = SyncPlanner.plan(sources: [
            (calendarA, .success([event("a1", "Design review", at: 1)])),
            (calendarB, .success([event("b1", "Design review", at: 1), event("b2", "Retro", at: 3)])),
        ], existing: copies(from: plan), options: SyncOptions())
        XCTAssertTrue(again.isEmpty)
    }

    func testDuplicateMadeBeforeIsRemoved() {
        let before = SyncPlanner.plan(sources: [(calendarB, .success([event("b1", "Design review", at: 1)]))],
                                      existing: [], options: SyncOptions())
        let both = SyncPlanner.plan(sources: [
            (calendarA, .success([event("a1", "Design review", at: 1)])),
            (calendarB, .success([event("b1", "Design review", at: 1)])),
        ], existing: copies(from: before), options: SyncOptions())

        XCTAssertEqual(created(both).map(\.title), ["[Calendar A] Design review"])
        XCTAssertEqual(both.deletes, 1)
    }

    func testCalendarThatDoesNotCopyItLeavesItToTheNext() {
        // Declined in A, accepted in B: B's copy is the only one.
        let plan = SyncPlanner.plan(sources: [
            (calendarA, .success([event("a1", "Design review", at: 1, declined: true)])),
            (calendarB, .success([event("b1", "Design review", at: 1)])),
        ], existing: [], options: SyncOptions())
        XCTAssertEqual(created(plan).map(\.title), ["[Calendar B] Design review"])
    }

    func testCalendarNotReadThisTimeStillCounts() {
        // Only B is due; A was read by an earlier sync and copies the meeting.
        let plan = SyncPlanner.plan(
            sources: [(calendarB, .success([event("b1", "Design review", at: 1)]))],
            existing: [], options: SyncOptions(),
            lastRead: [(calendarA, [event("a1", "Design review", at: 1)]),
                       (calendarB, [event("b1", "Design review", at: 1)])])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.sameInviteCount, 1)

        // A later in the list: B comes first and copies it.
        let reordered = SyncPlanner.plan(
            sources: [(calendarB, .success([event("b1", "Design review", at: 1)]))],
            existing: [], options: SyncOptions(),
            lastRead: [(calendarB, [event("b1", "Design review", at: 1)]),
                       (calendarA, [event("a1", "Design review", at: 1)])])
        XCTAssertEqual(created(reordered).map(\.title), ["[Calendar B] Design review"])
    }

    func testDisabledCalendarDoesNotCount() {
        var disabled = calendarA
        disabled.isEnabled = false
        let plan = SyncPlanner.plan(
            sources: [(calendarB, .success([event("b1", "Design review", at: 1)]))],
            existing: [], options: SyncOptions(),
            lastRead: [(disabled, [event("a1", "Design review", at: 1)])])
        XCTAssertEqual(plan.creates, 1)
    }

    // MARK: - Main calendar

    func testInviteAlreadyInMainCalendarIsNotCopied() {
        let plan = SyncPlanner.plan(
            sources: [(calendarA, .success([event("a1", "Design review", at: 1), event("a2", "Retro", at: 3)]))],
            existing: [], options: SyncOptions(),
            mainEvents: [event("m1", "Design review", at: 1)])
        XCTAssertEqual(created(plan).map(\.title), ["[Calendar A] Retro"])
    }

    func testMainCalendarCopiesAndDeclinedMeetingsDoNotCount() {
        let copyInMain = event("m1", "Design review", at: 1,
                               notes: CopyMarker.hashed(sourceID: calendarB.id, key: "b1").encoded)
        let declinedInMain = event("m2", "Retro", at: 3, declined: true)
        let plan = SyncPlanner.plan(
            sources: [(calendarA, .success([event("a1", "Design review", at: 1), event("a2", "Retro", at: 3)]))],
            existing: [], options: SyncOptions(),
            mainEvents: [copyInMain, declinedInMain])
        XCTAssertEqual(plan.creates, 2)
    }

    // MARK: - Busy events

    func testNoBusyEventForAMeetingTheSecondaryCalendarHasItself() {
        var busyA = calendarA
        busyA.showBusyInSecondary = true
        let plan = SyncPlanner.planBusy(
            for: busyA,
            mainEvents: .success([event("m1", "Design review", at: 1), event("m2", "1:1", at: 3)]),
            existing: [], options: SyncOptions(),
            known: [(busyA, [event("a1", "Design review", at: 1)])])
        XCTAssertEqual(created(plan).map(\.start), [base + 3 * 3600])
        XCTAssertEqual(plan.sameInviteCount, 1)
    }

    func testNoBusyEventForACopyOfTheSameInviteFromAnotherCalendar() {
        var busyB = calendarB
        busyB.showBusyInSecondary = true
        // A copied the meeting, so B, which has it too, didn't.
        let copyFromA = event("m1", "[Calendar A] Busy", at: 1,
                              notes: "Copied by Calendar Hub.\n\n" + CopyMarker.hashed(sourceID: calendarA.id, key: "a1").encoded)
        let known = [(calendarA, [event("a1", "Design review", at: 1)]),
                     (busyB, [event("b1", "Design review", at: 1)])]
        let plan = SyncPlanner.planBusy(for: busyB, mainEvents: .success([copyFromA]),
                                        existing: [], options: SyncOptions(), known: known)
        XCTAssertTrue(plan.isEmpty)

        // Declined in B, the time shows as free there, so it gets a Busy event.
        let declined = [(calendarA, [event("a1", "Design review", at: 1)]),
                        (busyB, [event("b1", "Design review", at: 1, declined: true)])]
        let busy = SyncPlanner.planBusy(for: busyB, mainEvents: .success([copyFromA]),
                                        existing: [], options: SyncOptions(), known: declined)
        XCTAssertEqual(busy.creates, 1)
    }

    func testBusyEventOfAMeetingNowInBothCalendarsIsRemoved() {
        var busyA = calendarA
        busyA.showBusyInSecondary = true
        let main = SourceFetchResult.success([event("m1", "Design review", at: 1)])
        let first = SyncPlanner.planBusy(for: busyA, mainEvents: main, existing: [], options: SyncOptions())
        let existing = copies(from: first)
        XCTAssertEqual(existing.count, 1)

        let next = SyncPlanner.planBusy(for: busyA, mainEvents: main, existing: existing, options: SyncOptions(),
                                        known: [(busyA, [event("a1", "Design review", at: 1)])])
        XCTAssertEqual(next.deletes, 1)
        XCTAssertEqual(next.creates, 0)
    }
}
