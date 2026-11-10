import XCTest
@testable import CalendarHubCore

final class BusyPlannerTests: XCTestCase {
    let secondaryA = SourceConfig(kind: .eventKit(calendarID: "secondary-a"), calendarName: "Calendar A", showBusyInSecondary: true)
    let secondaryB = SourceConfig(kind: .eventKit(calendarID: "secondary-b"), calendarName: "Calendar B")
    let base = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ key: String, _ title: String, at hour: Double, notes: String? = nil) -> SourceEvent {
        SourceEvent(key: key, title: title, start: base + hour * 3600, end: base + (hour + 1) * 3600,
                    meetingURL: URL(string: "https://zoom.us/j/1"), notes: notes)
    }

    /// A main-calendar event that is itself a copy made from `source`.
    func copyOf(_ source: SourceConfig, key: String, at hour: Double) -> SourceEvent {
        event("main-\(key)", "[\(source.calendarName)] Meeting", at: hour,
              notes: "Copied by Calendar Hub.\n\n" + CopyMarker(sourceID: source.id, key: key).encoded)
    }

    func copies(from plan: SyncPlan) -> [ExistingCopy] {
        plan.actions.enumerated().compactMap { i, action in
            guard case .create(let s) = action else { return nil }
            return ExistingCopy(eventID: "busy-\(i)", marker: s.marker, title: s.title, start: s.start,
                                end: s.end, isAllDay: s.isAllDay, url: s.url, notes: s.notes)
        }
    }

    func testBusyEventsCarryNoDetails() throws {
        let plan = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success([event("m1", "Salary review with HR", at: 2)]),
                                        existing: [], options: SyncOptions())
        XCTAssertEqual(plan.creates, 1)
        guard case .create(let spec) = plan.actions[0] else { return XCTFail() }
        XCTAssertEqual(spec.title, "Busy")
        XCTAssertNil(spec.url)
        XCTAssertNil(spec.location)
        let token = CopyFormatter.busyToken(sourceID: secondaryA.id)
        XCTAssertEqual(spec.notes, "Busy\n\n" + token, "the description says Busy and carries the calendar's code")
        XCTAssertEqual(token.count, 32)
        XCTAssertTrue(token.allSatisfy { "0123456789abcdef".contains($0) }, "an opaque code")
        XCTAssertNil(CopyMarker.find(in: spec.notes), "no marker written")
        XCTAssertFalse(spec.notes.localizedCaseInsensitiveContains("calsync"), "nothing names the app")
        XCTAssertFalse(spec.notes.localizedCaseInsensitiveContains("Calendar Hub"))
        XCTAssertFalse(spec.notes.contains("Salary"), "nothing of the meeting")
        XCTAssertFalse(spec.notes.contains("m1"), "not even its key")
        XCTAssertEqual(spec.marker, CopyFormatter.busyMarker(sourceID: secondaryA.id), "known in the plan as a Busy event")
        XCTAssertTrue(CopyFormatter.isBusy(spec))
        XCTAssertEqual(spec.start, base + 2 * 3600)
    }

    func testTokenIsPerCalendar() {
        XCTAssertEqual(CopyFormatter.busyToken(sourceID: secondaryA.id), CopyFormatter.busyToken(sourceID: secondaryA.id))
        XCTAssertNotEqual(CopyFormatter.busyToken(sourceID: secondaryA.id), CopyFormatter.busyToken(sourceID: secondaryB.id))
        // Another calendar's token isn't this calendar's Busy event.
        let other = CopyFormatter.busyNotes(sourceID: secondaryB.id)
        XCTAssertNil(CopyFormatter.busyMatch(title: "Busy", notes: other, sourceID: secondaryA.id))
    }

    func testOutOfOfficeStyleCarriesNoDetailsEither() {
        var secondary = secondaryA
        secondary.busyStyle = .outOfOffice
        let plan = SyncPlanner.planBusy(for: secondary, mainEvents: .success([event("m1", "Salary review with HR", at: 2)]),
                                        existing: [], options: SyncOptions())
        XCTAssertEqual(plan.creates, 1)
        guard case .create(let spec) = plan.actions[0] else { return XCTFail() }
        XCTAssertEqual(spec.title, "Out of office")
        XCTAssertTrue(spec.isOutOfOffice)
        XCTAssertNil(spec.url)
        XCTAssertEqual(spec.notes, CopyFormatter.busyNotes(sourceID: secondaryA.id))
        XCTAssertTrue(CopyFormatter.isBusy(spec))
    }

    func testAllDayEventsStayAllDayAndTimedOnesKeepTheirZone() {
        var holiday = event("h", "Holiday", at: 0)
        holiday.isAllDay = true
        holiday.timeZone = TimeZone(identifier: "Europe/Lisbon")
        var call = event("c", "Call", at: 4)
        call.timeZone = TimeZone(identifier: "America/New_York")
        let plan = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success([holiday, call]), existing: [], options: SyncOptions())
        let specs = plan.actions.compactMap { if case .create(let s) = $0 { s } else { nil } }
        XCTAssertEqual(specs.map(\.isAllDay), [true, false])
        XCTAssertNil(specs[0].timeZone, "all-day events are floating")
        XCTAssertEqual(specs[1].timeZone?.identifier, "America/New_York")
    }

    func testSwitchingStyleUpdatesExistingCopies() {
        let main = [event("m1", "A", at: 1)]
        let first = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success(main), existing: [], options: SyncOptions())
        var secondary = secondaryA
        secondary.busyStyle = .outOfOffice
        let switched = SyncPlanner.planBusy(for: secondary, mainEvents: .success(main),
                                            existing: copies(from: first), options: SyncOptions())
        XCTAssertEqual(switched.updates, 1, "the same event is kept, only the title changes")
        XCTAssertEqual(switched.creates, 0)
        XCTAssertEqual(switched.deletes, 0)
        guard case .update(_, let spec) = switched.actions[0] else { return XCTFail() }
        XCTAssertEqual(spec.title, "Out of office")
    }

    func testSkipsCopiesOfTheSameCalendarButShowsOtherSecondaryCalendars() {
        let main = [copyOf(secondaryA, key: "a1", at: 1), copyOf(secondaryB, key: "b1", at: 3), event("own", "Dentist", at: 5)]
        let plan = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success(main), existing: [], options: SyncOptions())
        let starts = plan.actions.compactMap { if case .create(let s) = $0 { s.start } else { nil } }
        XCTAssertEqual(starts, [base + 3 * 3600, base + 5 * 3600])
    }

    func testBusyEventsAreNeverCopiedBackIntoMain() {
        var ooo = secondaryA
        ooo.busyStyle = .outOfOffice
        for secondary in [secondaryA, ooo] {
            let plan = SyncPlanner.planBusy(for: secondary, mainEvents: .success([event("m1", "Dentist", at: 2)]),
                                            existing: [], options: SyncOptions(skipOutOfOffice: false))
            guard case .create(let busy) = plan.actions[0] else { return XCTFail() }
            // The secondary calendar now holds the Busy event; syncing that calendar into main must skip it,
            // also when the server hands the description back as HTML.
            let secondaryEvents = [event("busy-event", busy.title, at: 2, notes: busy.notes),
                                event("busy-html", busy.title, at: 3, notes: "<p>\(busy.notes)</p>\r\n")]
            let forward = SyncPlanner.plan(sources: [(secondary, .success(secondaryEvents))], existing: [],
                                           options: SyncOptions(skipOutOfOffice: false))
            XCTAssertTrue(forward.isEmpty)
        }
    }

    func testRecognisesBusyEvents() {
        let id = secondaryA.id
        func match(_ title: String, _ notes: String?) -> CopyFormatter.BusyMatch? {
            CopyFormatter.busyMatch(title: title, notes: notes, sourceID: id)
        }
        // As they're made now, also when a server hands the description back as HTML.
        let notes = CopyFormatter.busyNotes(sourceID: id), tagged = CopyFormatter.BusyMatch.tagged(CopyFormatter.busyMarker(sourceID: id))
        let token = CopyFormatter.busyToken(sourceID: id)
        XCTAssertEqual(match("Busy", notes), tagged)
        XCTAssertEqual(match("Out of office", notes), tagged)
        XCTAssertEqual(match("Busy", "<div>Busy</div><div><br></div><div>\(token)</div>"), tagged)
        XCTAssertEqual(match("Busy", "<p>Busy</p>\r\n<p>&nbsp;</p>\r\n<p>\(token)</p>"), tagged)
        // As versions 2.0.0 to 2.0.5 made them: "Busy" and nothing else.
        XCTAssertEqual(match("Busy", "Busy"), .untagged)
        XCTAssertEqual(match("Out of office", "Busy\n"), .untagged)
        XCTAssertEqual(match("Busy", "<html><body><p>Busy</p></body></html>"), .untagged)
        // Made by 1.x, with a hidden marker.
        let legacy = CopyMarker(sourceID: id, key: "busy-1a2b")
        XCTAssertEqual(match("Busy", legacy.encoded), .tagged(legacy))
        // The secondary calendar's own events.
        XCTAssertNil(match("Busy", nil))
        XCTAssertNil(match("Busy", "Busy with the release"))
        XCTAssertNil(match("Busy", "Busy " + token + " x"))
        XCTAssertNil(match("Focus time", "Busy"))
        XCTAssertNil(match("Focus time", notes))
        // A copy in the main calendar isn't a Busy event.
        let copy = "Copied by Calendar Hub.\n\n" + CopyMarker(sourceID: id, key: "m1").encoded
        XCTAssertNil(match("Busy", copy))
        XCTAssertFalse(CopyFormatter.isBusyEvent(title: "Busy", notes: copy, sourceID: id))
        XCTAssertTrue(CopyFormatter.isBusyEvent(title: "Busy", notes: notes, sourceID: id))
    }

    func testOneBusyEventPerTime() {
        let main = [event("m1", "A", at: 1), event("m2", "B", at: 1), event("m3", "C", at: 2)]
        let plan = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success(main), existing: [], options: SyncOptions())
        XCTAssertEqual(plan.creates, 2)
        // A duplicate already in the secondary calendar is removed.
        var existing = copies(from: plan)
        existing.append(ExistingCopy(eventID: "dupe", marker: nil, title: "Busy", start: base + 3600, end: base + 2 * 3600,
                                     isAllDay: false, url: nil, notes: "Busy"))
        let next = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success(main), existing: existing, options: SyncOptions())
        XCTAssertEqual(next.actions.count, 1)
        XCTAssertEqual(next.deletes, 1)
        XCTAssertEqual(next.unchangedCount, 2)
    }

    func testBusyEventsFromOlderVersionsGetTheTokenOnce() {
        let main: SourceFetchResult = .success([event("m1", "A", at: 1)])
        // 1.x marked them with a key of their own; 2.0.0 to 2.0.5 wrote "Busy" and nothing else.
        let marker = CopyMarker(sourceID: secondaryA.id, key: "busy-1a2b")
        let marked = ExistingCopy(eventID: "old", marker: marker, title: "Busy", start: base + 3600, end: base + 2 * 3600,
                                  isAllDay: false, url: nil, notes: marker.encoded)
        let bare = ExistingCopy(eventID: "bare", marker: nil, title: "Busy", start: base + 3600, end: base + 2 * 3600,
                                isAllDay: false, url: nil, notes: "<p>Busy</p>")
        for legacy in [marked, bare] {
            let plan = SyncPlanner.planBusy(for: secondaryA, mainEvents: main, existing: [legacy], options: SyncOptions())
            XCTAssertEqual(plan.actions.count, 1)
            guard case .update(let id, let spec) = plan.actions[0] else { return XCTFail() }
            XCTAssertEqual(id, legacy.eventID)
            XCTAssertEqual(spec.notes, CopyFormatter.busyNotes(sourceID: secondaryA.id))
            // Once rewritten, it's left alone.
            let rewritten = ExistingCopy(eventID: id, marker: spec.marker, title: spec.title, start: spec.start,
                                         end: spec.end, isAllDay: false, url: nil, notes: spec.notes)
            XCTAssertTrue(SyncPlanner.planBusy(for: secondaryA, mainEvents: main, existing: [rewritten], options: SyncOptions()).isEmpty)
        }
    }

    func testHTMLDescriptionIsNotRewrittenEverySync() {
        let main: SourceFetchResult = .success([event("m1", "A", at: 1)])
        let first = SyncPlanner.planBusy(for: secondaryA, mainEvents: main, existing: [], options: SyncOptions())
        guard case .create(let spec) = first.actions[0] else { return XCTFail() }
        // Servers store the description as HTML, each with its own idea of a blank line.
        let token = CopyFormatter.busyToken(sourceID: secondaryA.id)
        for html in ["<p>Busy</p><p>\(token)</p>",
                     "<div>Busy</div><div><br></div><div>\(token)</div>",
                     "<html><body>Busy<br><br>\(token)<br></body></html>",
                     "Busy\r\n\r\n\r\n\(token)\r\n"] {
            let stored = ExistingCopy(eventID: "e", marker: spec.marker, title: "Busy", start: base + 3600, end: base + 2 * 3600,
                                      isAllDay: false, url: nil, notes: html)
            XCTAssertTrue(SyncPlanner.planBusy(for: secondaryA, mainEvents: main, existing: [stored], options: SyncOptions()).isEmpty, html)
        }
    }

    func testAlertsAreClearedOnlyWhenAsked() {
        let main: SourceFetchResult = .success([event("m1", "A", at: 1)])
        var alerting = copies(from: SyncPlanner.planBusy(for: secondaryA, mainEvents: main, existing: [], options: SyncOptions()))[0]
        alerting.eventID = "e"
        alerting.hasAlerts = true
        // Left alone on a normal sync, so a calendar that adds its alerts back isn't rewritten every time.
        XCTAssertTrue(SyncPlanner.planBusy(for: secondaryA, mainEvents: main, existing: [alerting], options: SyncOptions()).isEmpty)

        let plan = SyncPlanner.planBusy(for: secondaryA, mainEvents: main, existing: [alerting], options: SyncOptions(),
                                        clearingAlerts: true)
        XCTAssertEqual(plan.actions.count, 1)
        guard case .update(let id, _) = plan.actions[0] else { return XCTFail() }
        XCTAssertEqual(id, "e")

        var quiet = alerting
        quiet.hasAlerts = false
        XCTAssertTrue(SyncPlanner.planBusy(for: secondaryA, mainEvents: main, existing: [quiet], options: SyncOptions(),
                                           clearingAlerts: true).isEmpty)
    }

    func testSecondRunIsNoOpAndChangesFollow() {
        let main = [event("m1", "A", at: 1), event("m2", "B", at: 3)]
        let first = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success(main), existing: [], options: SyncOptions())
        let existing = copies(from: first)
        XCTAssertTrue(SyncPlanner.planBusy(for: secondaryA, mainEvents: .success(main), existing: existing, options: SyncOptions()).isEmpty)

        // Busy events are matched by time: a moved meeting's Busy event is replaced.
        let moved = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success([event("m1", "A", at: 6)]),
                                         existing: existing, options: SyncOptions())
        XCTAssertEqual(moved.creates, 1)
        XCTAssertEqual(moved.deletes, 2)
        XCTAssertEqual(moved.updates, 0)
    }

    func testFailureLeavesBusyEventsAlone() {
        let first = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success([event("m1", "A", at: 1)]),
                                         existing: [], options: SyncOptions())
        let next = SyncPlanner.planBusy(for: secondaryA, mainEvents: .failure("Main calendar not found"),
                                        existing: copies(from: first), options: SyncOptions())
        XCTAssertTrue(next.isEmpty)
        XCTAssertEqual(next.failedSources[secondaryA.id], "Main calendar not found")
    }

    func testTurningBusyOffTakesBackBusyEvents() {
        let first = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success([event("m1", "A", at: 1), event("m2", "B", at: 3)]),
                                         existing: [], options: SyncOptions())
        var existing = copies(from: first)
        let marker = CopyMarker(sourceID: secondaryA.id, key: "busy-1a2b")
        existing.append(ExistingCopy(eventID: "legacy", marker: marker, title: "Busy", start: base, end: base + 3600,
                                     isAllDay: false, url: nil, notes: marker.encoded))

        let plan = SyncPlanner.planBusyRemoval(existing: existing, addedHere: true)
        let deleted = plan.actions.compactMap { if case .delete(let id, _, _) = $0 { id } else { nil } }
        XCTAssertEqual(Set(deleted), ["busy-0", "busy-1", "legacy"])
        XCTAssertTrue(SyncPlanner.planBusyRemoval(existing: [], addedHere: true).isEmpty)

        // In a calendar no Busy events were added to since 2.0.0, a look-alike without a marker
        // is the user's own: only the marked ones are taken back.
        existing.append(ExistingCopy(eventID: "lookalike", marker: nil, title: "Busy", start: base + 7200, end: base + 3 * 3600,
                                     isAllDay: false, url: nil, notes: "Busy"))
        let untouched = SyncPlanner.planBusyRemoval(existing: existing, addedHere: false)
        XCTAssertEqual(Set(untouched.actions.compactMap { if case .delete(let id, _, _) = $0 { id } else { nil } }),
                       ["busy-0", "busy-1", "legacy"])
    }

    func testFiltersFollowOptions() {
        var declined = event("d", "Declined", at: 1); declined.isDeclined = true
        var allDay = event("a", "Holiday", at: 2); allDay.isAllDay = true
        var cancelled = event("c", "Cancelled", at: 3); cancelled.isCancelled = true
        let plan = SyncPlanner.planBusy(for: secondaryA, mainEvents: .success([declined, allDay, cancelled]),
                                        existing: [], options: SyncOptions(skipDeclined: true, skipAllDay: true))
        XCTAssertTrue(plan.isEmpty)
    }

    func testOldSettingsStillDecode() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":{"outlookWeb":{}},"calendarName":"Calendar B","hideMeetingName":true,"isEnabled":true}"#
        let decoded = try JSONDecoder().decode(SourceConfig.self, from: Data(old.utf8))
        XCTAssertFalse(decoded.showBusyInSecondary)
        XCTAssertEqual(decoded.busyStyle, .busy)
        XCTAssertTrue(decoded.hideMeetingName)
        var ooo = secondaryA
        ooo.busyStyle = .outOfOffice
        let roundTrip = try JSONDecoder().decode(SourceConfig.self, from: JSONEncoder().encode(ooo))
        XCTAssertEqual(roundTrip, ooo)
    }

    func testShowBusyKeepsItsSavedKey() throws {
        let saved = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":{"outlookWeb":{}},"calendarName":"Calendar B","showBusyInClient":true}"#
        XCTAssertTrue(try JSONDecoder().decode(SourceConfig.self, from: Data(saved.utf8)).showBusyInSecondary)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(secondaryA)) as? [String: Any]
        XCTAssertEqual(encoded?["showBusyInClient"] as? Bool, true)
    }
}
