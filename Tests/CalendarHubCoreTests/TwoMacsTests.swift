import XCTest
@testable import CalendarHubCore

/// Two Macs copying the same secondary calendar into one shared main calendar. Each Mac gave
/// the calendar its own id, so their copies carry different markers.
final class TwoMacsTests: XCTestCase {
    // Mac 1's id comes first, so where both Macs made a copy of one meeting, Mac 1's stays.
    let mac1 = SourceConfig(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                            kind: .outlookWeb, calendarName: "Client A")
    let mac2 = SourceConfig(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                            kind: .outlookWeb, calendarName: "Client A")
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ key: String, _ title: String, at hour: Double) -> SourceEvent {
        SourceEvent(key: key, title: title, start: base + hour * 3600, end: base + (hour + 1) * 3600)
    }

    var meetings: [SourceEvent] { [event("1", "Standup", at: 1), event("2", "Review", at: 2), event("3", "Retro", at: 3)] }

    /// Simulates applying a plan, so the next run sees the copies it made.
    func applied(_ plan: SyncPlan, to existing: [ExistingCopy] = [], prefix: String) -> [ExistingCopy] {
        var copies = existing
        for (i, action) in plan.actions.enumerated() {
            switch action {
            case .create(let s):
                copies.append(ExistingCopy(eventID: "\(prefix)-\(i)", marker: s.marker, title: s.title, start: s.start,
                                           end: s.end, isAllDay: s.isAllDay, url: s.url, notes: s.notes, location: s.location))
            case .update(let id, let s):
                let index = copies.firstIndex { $0.eventID == id }!
                copies[index] = ExistingCopy(eventID: id, marker: s.marker, title: s.title, start: s.start, end: s.end,
                                             isAllDay: s.isAllDay, url: s.url, notes: s.notes, location: s.location)
            case .delete(let id, _, _):
                copies.removeAll { $0.eventID == id }
            }
        }
        return copies
    }

    func plan(_ source: SourceConfig, _ events: [SourceEvent], existing: [ExistingCopy],
              options: SyncOptions = SyncOptions()) -> SyncPlan {
        SyncPlanner.plan(sources: [(source, .success(events))], existing: existing, options: options,
                         setUpHere: [source.id])
    }

    func deletedIDs(_ plan: SyncPlan) -> Set<String> {
        Set(plan.actions.compactMap { if case .delete(let id, _, _) = $0 { id } else { nil } })
    }

    // MARK: - Calendars keyed the same on both Macs (Outlook on the web)

    func testTheOtherMacsCopiesAreUsedInsteadOfDuplicated() {
        let copies = applied(plan(mac1, meetings, existing: []), prefix: "mac1")

        let second = plan(mac2, meetings, existing: copies)
        XCTAssertTrue(second.isEmpty, "\(second.actions)")
        XCTAssertEqual(second.unchangedCount, 3)
        XCTAssertEqual(second.otherMacIDs, [mac1.id: mac2.id])

        XCTAssertTrue(plan(mac1, meetings, existing: copies).isEmpty, "and Mac 1 still finds its own")
    }

    func testBothMacsKeepTheSameOneOfTwoCopies() {
        // What 2.0.35 left: each Mac made its own copy of every meeting.
        let existing = applied(plan(mac1, meetings, existing: []), prefix: "mac1")
            + applied(plan(mac2, meetings, existing: []), prefix: "mac2")

        let onMac1 = plan(mac1, meetings, existing: existing)
        let onMac2 = plan(mac2, meetings, existing: existing)
        let mac2Copies = Set(existing.filter { $0.marker?.sourceID == mac2.id }.map(\.eventID))
        XCTAssertEqual(deletedIDs(onMac1), mac2Copies)
        XCTAssertEqual(deletedIDs(onMac2), mac2Copies, "the same ones, so one copy of each is left")
        XCTAssertEqual(onMac1.actions.count, 3)
        XCTAssertEqual(onMac2.actions.count, 3)

        let cleaned = applied(onMac2, to: existing, prefix: "mac2")
        XCTAssertTrue(plan(mac1, meetings, existing: cleaned).isEmpty)
        XCTAssertTrue(plan(mac2, meetings, existing: cleaned).isEmpty)
    }

    func testTheOtherMacsCopiesFollowTheMeetingOnceThatMacStops() {
        let copies = applied(plan(mac1, meetings, existing: []), prefix: "mac1")

        var moved = event("1", "Standup (moved)", at: 5)
        moved.title = "Standup (moved)"
        var cancelled = event("3", "Canceled: Retro", at: 3)
        cancelled.isCancelled = true
        let next = plan(mac2, [moved, event("2", "Review", at: 2), cancelled], existing: copies)

        XCTAssertEqual(next.creates, 0)
        XCTAssertEqual(deletedIDs(next), ["mac1-2"], "the cancelled meeting's copy goes")
        guard case .update(let id, let spec) = next.actions.first(where: { if case .update = $0 { true } else { false } })
        else { return XCTFail("\(next.actions)") }
        XCTAssertEqual(id, "mac1-0")
        XCTAssertEqual(spec.title, "[Client A] Standup (moved)")
        XCTAssertEqual(spec.start, base + 5 * 3600)
        XCTAssertEqual(spec.marker, copies[0].marker, "it keeps Mac 1's marker, so Mac 1 doesn't rewrite it back")
        XCTAssertEqual(CopyMarker.find(in: spec.notes), copies[0].marker)

        // Mac 1, back again, has nothing to change.
        XCTAssertTrue(plan(mac1, [moved, event("2", "Review", at: 2), cancelled],
                           existing: applied(next, to: copies, prefix: "mac2")).isEmpty)
    }

    func testAMeetingGoneFromTheCalendarTakesTheOtherMacsCopyWithIt() {
        let copies = applied(plan(mac1, meetings, existing: []), prefix: "mac1")
        let next = plan(mac2, Array(meetings.prefix(2)), existing: copies)
        XCTAssertEqual(deletedIDs(next), ["mac1-2"])
        XCTAssertEqual(next.actions.count, 1)
    }

    func testCalendarsNamedDifferentlyAreNotTakenForOne() {
        var other = mac2
        other.calendarName = "Client B"
        let copies = applied(plan(mac1, meetings, existing: []), prefix: "mac1")
        let next = plan(other, meetings, existing: copies)
        XCTAssertEqual(next.creates, 3)
        XCTAssertEqual(next.deletes, 0, "the other Mac's copies are left alone")
        XCTAssertTrue(next.otherMacIDs.isEmpty)
    }

    func testOtherCalendarsOfTheOtherMacAreLeftAlone() {
        let clientB = SourceConfig(kind: .outlookWeb, calendarName: "Client B")
        let copies = applied(plan(mac1, meetings, existing: []), prefix: "mac1")
            + applied(plan(clientB, [event("b1", "Kickoff", at: 4)], existing: []), prefix: "b")
        let next = plan(mac2, meetings, existing: copies)
        XCTAssertTrue(next.isEmpty, "\(next.actions)")
    }

    func testMeetingsLeftOutHereAreLeftToTheOtherMac() {
        var declined = event("2", "Review", at: 2)
        declined.isDeclined = true
        let copyDeclined = SyncOptions(skipDeclined: false)
        let copies = applied(plan(mac1, [meetings[0], declined], existing: [], options: copyDeclined), prefix: "mac1")
        let next = plan(mac2, [meetings[0], declined], existing: copies)
        XCTAssertTrue(next.isEmpty, "\(next.actions)")
    }

    func testCalendarsSetUpHereAreNeverTakenForAnotherMacs() {
        // Two calendars set up here, with one of them read this time.
        let copies = applied(plan(mac1, meetings, existing: []), prefix: "mac1")
        let next = SyncPlanner.plan(sources: [(mac2, .success(meetings))], existing: copies, options: SyncOptions(),
                                    setUpHere: [mac1.id, mac2.id])
        XCTAssertEqual(next.creates, 3)
        XCTAssertEqual(next.deletes, 0)
    }

    // MARK: - Calendars keyed differently on each Mac (Calendar.app)

    func testCopiesAlikeAreUsedWhenTheKeysDiffer() {
        let copies = applied(plan(mac1, meetings, existing: []), prefix: "mac1")
        let keyedHere = meetings.map { var e = $0; e.key = "mac2-" + e.key; return e }

        let next = plan(mac2, keyedHere, existing: copies)
        XCTAssertTrue(next.isEmpty, "\(next.actions)")
        XCTAssertTrue(next.otherMacIDs.isEmpty, "a lookalike doesn't prove it's the same calendar")

        // Without that proof, a copy matching nothing is left: it may be a meeting this Mac can't see.
        let fewer = plan(mac2, Array(keyedHere.prefix(2)), existing: copies)
        XCTAssertTrue(fewer.isEmpty, "\(fewer.actions)")
    }

    func testHiddenMeetingsAtOneTimeEachKeepTheirCopy() {
        var hidden1 = mac1, hidden2 = mac2
        hidden1.hideMeetingName = true
        hidden2.hideMeetingName = true
        let two = [event("1", "Interview", at: 1), event("2", "Budget", at: 1)]
        let copies = applied(plan(hidden1, two, existing: []), prefix: "mac1")
        XCTAssertEqual(copies.map(\.title), ["[Client A] Busy", "[Client A] Busy"])

        let next = plan(hidden2, two.map { var e = $0; e.key = "mac2-" + e.key; return e }, existing: copies)
        XCTAssertTrue(next.isEmpty, "\(next.actions)")
    }

    // MARK: - Busy events

    func testTheOtherMacsCopyOfAMeetingIsNotShownAsBusyInItsOwnCalendar() {
        var secondary = mac2
        secondary.kind = .eventKit(calendarID: "client-a")
        secondary.showBusyInSecondary = true
        let copies = applied(plan(mac1, meetings, existing: []), prefix: "mac1")
        let inMain = copies.map {
            SourceEvent(key: $0.eventID, title: $0.title, start: $0.start, end: $0.end, notes: $0.notes)
        }
        let busy = SyncPlanner.planBusy(for: secondary, mainEvents: .success(inMain), existing: [],
                                        options: SyncOptions(), otherMacIDs: [mac1.id: secondary.id])
        XCTAssertTrue(busy.isEmpty, "\(busy.actions)")

        let unknown = SyncPlanner.planBusy(for: secondary, mainEvents: .success(inMain), existing: [], options: SyncOptions())
        XCTAssertEqual(unknown.creates, 3, "as before, without knowing that Mac's id")
    }

    // MARK: - Busy events added by both Macs

    var busy1: SourceConfig {
        var c = mac1
        c.kind = .eventKit(calendarID: "client-a")
        c.showBusyInSecondary = true
        return c
    }

    var busy2: SourceConfig {
        var c = mac2
        c.kind = .eventKit(calendarID: "client-a")
        c.showBusyInSecondary = true
        return c
    }

    var mainCalendar: [SourceEvent] { [event("m1", "Lunch", at: 1), event("m2", "Dentist", at: 4)] }

    /// The Busy events in the secondary calendar as `source` reads them after `plan` (see
    /// `EventKitBridge.busyEvents`).
    func busyEvents(_ plan: SyncPlan, to existing: [ExistingCopy] = [], prefix: String, readBy source: SourceConfig) -> [ExistingCopy] {
        applied(plan, to: existing, prefix: prefix).map {
            var busy = $0
            if case .tagged(let marker) = CopyFormatter.busyMatch(title: busy.title, notes: busy.notes, sourceID: source.id) {
                busy.marker = marker
            }
            return busy
        }
    }

    func planBusy(_ source: SourceConfig, existing: [ExistingCopy], main: [SourceEvent]? = nil,
                  options: SyncOptions = SyncOptions()) -> SyncPlan {
        SyncPlanner.planBusy(for: source, mainEvents: .success(main ?? mainCalendar), existing: existing, options: options)
    }

    func testTheOtherMacsBusyEventsAreUsedInsteadOfDuplicated() {
        let made = busyEvents(planBusy(busy1, existing: []), prefix: "mac1", readBy: busy2)
        XCTAssertEqual(made.count, 2)
        let next = planBusy(busy2, existing: made)
        XCTAssertTrue(next.isEmpty, "\(next.actions)")
        XCTAssertEqual(next.unchangedCount, 2)
    }

    func testBothMacsKeepTheSameOneOfTwoBusyEvents() {
        let both = applied(planBusy(busy1, existing: []), prefix: "mac1")
            + applied(planBusy(busy2, existing: []), prefix: "mac2")
        let read = { (source: SourceConfig) in
            self.busyEvents(SyncPlan(actions: [], failedSources: [:], unchangedCount: 0), to: both, prefix: "", readBy: source)
        }
        let onMac1 = planBusy(busy1, existing: read(busy1))
        let onMac2 = planBusy(busy2, existing: read(busy2))
        XCTAssertEqual(onMac1.deletes, 2)
        XCTAssertEqual(deletedIDs(onMac1), deletedIDs(onMac2), "the same ones, so one is left at each time")
        XCTAssertEqual(onMac1.actions.count, 2)
        XCTAssertEqual(onMac2.actions.count, 2)
        let firstToken = [busy1.id, busy2.id].map { CopyFormatter.busyToken(sourceID: $0) }.min()!
        let kept = both.filter { !deletedIDs(onMac1).contains($0.eventID) }
        XCTAssertTrue(kept.allSatisfy { $0.notes.contains(firstToken) })
    }

    func testTheOtherMacsBusyEventGoesWithItsMeeting() {
        let made = busyEvents(planBusy(busy1, existing: []), prefix: "mac1", readBy: busy2)
        let next = planBusy(busy2, existing: made, main: [mainCalendar[0]])
        XCTAssertEqual(deletedIDs(next), ["mac1-1"])
        XCTAssertEqual(next.actions.count, 1)
    }

    func testTheOtherMacsBusyEventKeepsItsToken() {
        let made = busyEvents(planBusy(busy1, existing: []), prefix: "mac1", readBy: busy2)
        var outOfOffice = busy2
        outOfOffice.busyStyle = .outOfOffice
        let next = planBusy(outOfOffice, existing: made)
        XCTAssertEqual(next.updates, 2)
        for case .update(_, let spec) in next.actions {
            XCTAssertEqual(spec.title, "Out of office")
            XCTAssertTrue(spec.notes.contains(CopyFormatter.busyToken(sourceID: busy1.id)))
            XCTAssertFalse(spec.notes.contains(CopyFormatter.busyToken(sourceID: busy2.id)))
        }
    }

    func testBusyEventsLeftOutHereAreLeftToTheOtherMac() {
        var holiday = event("m3", "Holiday", at: 0)
        holiday.isAllDay = true
        holiday.end = holiday.start + 86400
        let main = mainCalendar + [holiday]
        let made = busyEvents(planBusy(busy1, existing: [], main: main), prefix: "mac1", readBy: busy2)
        XCTAssertEqual(made.count, 3)
        let next = planBusy(busy2, existing: made, main: main, options: SyncOptions(skipAllDay: true))
        XCTAssertTrue(next.isEmpty, "\(next.actions)")
    }

    func testTurningBusyOffLeavesTheOtherMacsBusyEvents() {
        let made = busyEvents(planBusy(busy1, existing: []), prefix: "mac1", readBy: busy2)
        let mine = busyEvents(planBusy(busy2, existing: [], main: [event("m9", "Call", at: 6)]), prefix: "mac2", readBy: busy2)
        let removal = SyncPlanner.planBusyRemoval(for: busy2, existing: made + mine, addedHere: true)
        XCTAssertEqual(deletedIDs(removal), Set(mine.map(\.eventID)))
    }

    func testTheOtherMacsBusyEventsAreNeverCopied() {
        let made = applied(planBusy(busy1, existing: []), prefix: "mac1")
        let inSecondary = made.map { SourceEvent(key: $0.eventID, title: $0.title, start: $0.start, end: $0.end, notes: $0.notes) }
            + [event("s1", "Client call", at: 7)]
        let copies = plan(busy2, inSecondary, existing: [])
        XCTAssertEqual(copies.creates, 1)
        guard case .create(let spec) = copies.actions[0] else { return XCTFail() }
        XCTAssertEqual(spec.title, "[Client A] Client call")
    }
}
