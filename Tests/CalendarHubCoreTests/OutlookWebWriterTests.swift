import XCTest
@testable import CalendarHubCore

final class OutlookWebWriterTests: XCTestCase {
    let outlook = SourceConfig(kind: .outlookWeb, calendarName: "Work", showBusyInSecondary: true)
    let lisbon = TimeZone(identifier: "Europe/Lisbon")!
    let berlin = TimeZone(identifier: "Europe/Berlin")!

    func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func json(_ request: OutlookWebWriter.Request) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any])
    }

    func item(_ request: OutlookWebWriter.Request) throws -> [String: Any] {
        let body = try XCTUnwrap(try json(request)["Body"] as? [String: Any])
        return try XCTUnwrap((body["Items"] as? [[String: Any]])?.first)
    }

    func testCreatesABusyEventWithNothingButItsTimes() throws {
        let event = SourceEvent(key: "m1", title: "Salary review", start: date("2026-11-04T10:00:00Z"),
                                end: date("2026-11-04T11:00:00Z"), meetingURL: URL(string: "https://zoom.us/j/1"),
                                notes: "Private", location: "Room 1")
        let spec = CopyFormatter.busySpec(for: event, source: outlook)
        let requests = OutlookWebWriter.requests(for: .create(spec), timeZone: berlin)
        XCTAssertEqual(requests.map(\.action), ["CreateItem"])

        let request = try json(requests[0])
        XCTAssertEqual(request["__type"] as? String, "CreateItemJsonRequest:#Exchange")
        let body = try XCTUnwrap(request["Body"] as? [String: Any])
        XCTAssertEqual(body["SendMeetingInvitations"] as? String, "SendToNone")

        let item = try item(requests[0])
        XCTAssertEqual(item["Subject"] as? String, "Busy")
        let description = try XCTUnwrap((item["Body"] as? [String: Any])?["Value"] as? String)
        XCTAssertEqual(description, "Busy\n\n" + CopyFormatter.busyToken(sourceID: outlook.id), "says Busy, plus the calendar's code")
        XCTAssertFalse(description.localizedCaseInsensitiveContains("calsync"), "nothing names the app")
        XCTAssertEqual(item["Start"] as? String, "2026-11-04T10:00:00Z")
        XCTAssertEqual(item["End"] as? String, "2026-11-04T11:00:00Z")
        XCTAssertEqual(item["LegacyFreeBusyStatus"] as? String, "Busy")
        XCTAssertEqual(item["ReminderIsSet"] as? Bool, false)
        XCTAssertEqual(item["IsAllDayEvent"] as? Bool, false)
        XCTAssertNil(item["Location"])
        XCTAssertNil(item["RequiredAttendees"])
        for secret in ["Salary", "zoom", "Private", "Room"] {
            XCTAssertFalse(requests[0].body.contains(secret), secret)
        }
    }

    func testOutOfOfficeStyle() throws {
        var source = outlook
        source.busyStyle = .outOfOffice
        let event = SourceEvent(key: "m1", title: "x", start: date("2026-11-04T10:00:00Z"), end: date("2026-11-04T11:00:00Z"))
        let item = try item(OutlookWebWriter.requests(for: .create(CopyFormatter.busySpec(for: event, source: source)))[0])
        XCTAssertEqual(item["Subject"] as? String, "Out of office")
        XCTAssertEqual(item["LegacyFreeBusyStatus"] as? String, "OOF")
    }

    func testAllDayEventsAreWrittenAsMidnightsOfThisMacsDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = berlin
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 4))!
        // As EventKit has it: a second before midnight after the last day.
        let end = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 23, minute: 59, second: 59))!
        let event = SourceEvent(key: "m1", title: "Trip", start: start, end: end, isAllDay: true)
        let requests = OutlookWebWriter.requests(for: .create(CopyFormatter.busySpec(for: event, source: outlook)), timeZone: berlin)
        let item = try item(requests[0])
        XCTAssertEqual(item["IsAllDayEvent"] as? Bool, true)
        XCTAssertEqual(item["Start"] as? String, "2026-11-04T00:00:00+01:00")
        XCTAssertEqual(item["End"] as? String, "2026-11-06T00:00:00+01:00")
        XCTAssertEqual(item["StartTimeZoneId"] as? String, "W. Europe Standard Time")
        let header = try XCTUnwrap(try json(requests[0])["Header"] as? [String: Any])
        let context = try XCTUnwrap(header["TimeZoneContext"] as? [String: Any])
        XCTAssertEqual((context["TimeZoneDefinition"] as? [String: Any])?["Id"] as? String, "W. Europe Standard Time")

        // And they're read back on the same days.
        let read = OutlookWebParser.allDayRange(item["Start"]!, item["End"]!, start: Date(), end: Date(), timeZone: berlin)
        XCTAssertEqual(read.start, start)
        XCTAssertEqual(read.end, end)
    }

    func testUpdateIsDeleteThenCreate() {
        let event = SourceEvent(key: "m1", title: "x", start: date("2026-11-04T10:00:00Z"), end: date("2026-11-04T11:00:00Z"))
        let spec = CopyFormatter.busySpec(for: event, source: outlook)
        let requests = OutlookWebWriter.requests(for: .update(eventID: "AAMk1", spec))
        XCTAssertEqual(requests.map(\.action), ["DeleteItem", "CreateItem"])
        XCTAssertTrue(requests[0].body.contains("\"AAMk1\""))
    }

    func testDeleteSendsNoCancellations() throws {
        let requests = OutlookWebWriter.requests(for: .delete(eventID: "AAMk1", title: "Busy", start: Date()))
        XCTAssertEqual(requests.map(\.action), ["DeleteItem"])
        let body = try XCTUnwrap(try json(requests[0])["Body"] as? [String: Any])
        XCTAssertEqual(body["SendMeetingCancellations"] as? String, "SendToNone")
        XCTAssertEqual(body["DeleteType"] as? String, "MoveToDeletedItems")
        XCTAssertEqual((body["ItemIds"] as? [[String: Any]])?.first?["Id"] as? String, "AAMk1")
    }

    func testReadsOutlooksAnswer() {
        let ok = #"{"Body":{"ResponseMessages":{"Items":[{"ResponseClass":"Success","ResponseCode":"NoError"}]}}}"#
        XCTAssertNil(OutlookWebWriter.problem(inResponse: ok))

        let failed = #"{"Body":{"ResponseClass":"Success","ResponseMessages":{"Items":[{"ResponseClass":"Error","ResponseCode":"ErrorItemNotFound","MessageText":"The specified object was not found in the store."}]}}}"#
        XCTAssertEqual(OutlookWebWriter.problem(inResponse: failed), "The specified object was not found in the store.")

        XCTAssertNotNil(OutlookWebWriter.problem(inResponse: nil))
        XCTAssertNotNil(OutlookWebWriter.problem(inResponse: "<html>Sign in</html>"))
        XCTAssertNotNil(OutlookWebWriter.problem(inResponse: #"{"value":[]}"#))
    }

    func testWindowsTimeZoneNames() {
        let now = date("2026-11-04T10:00:00Z")
        XCTAssertEqual(OutlookWebWriter.windowsZoneID(for: TimeZone(identifier: "Europe/London")!, near: now), "GMT Standard Time")
        // Not in the list itself: the zone with the same offsets all year.
        XCTAssertEqual(OutlookWebWriter.windowsZoneID(for: lisbon, near: now), "GMT Standard Time")
        XCTAssertEqual(OutlookWebWriter.windowsZoneID(for: TimeZone(identifier: "UTC")!, near: now), "UTC")
        XCTAssertEqual(OutlookWebWriter.windowsZoneID(for: TimeZone(identifier: "Europe/Kiev")!, near: now), "FLE Standard Time")
        XCTAssertEqual(OutlookWebWriter.windowsCase("aus central w. standard time"), "AUS Central W. Standard Time")
        XCTAssertEqual(OutlookWebWriter.windowsCase("central standard time (mexico)"), "Central Standard Time (Mexico)")
        XCTAssertEqual(OutlookWebWriter.windowsCase("utc+12"), "UTC+12")
        XCTAssertEqual(OutlookWebWriter.windowsCase("sa pacific standard time"), "SA Pacific Standard Time")
    }

    // MARK: - Reading the Busy events back

    func testFindsTheBusyEventsItWroteWithTheirItemIDs() throws {
        let week = """
        {"Body":{"Items":[
          {"ItemId":{"Id":"busy1"},"Subject":"Busy","Start":"2026-11-04T10:00:00Z","End":"2026-11-04T11:00:00Z","CalendarItemType":"Single"},
          {"ItemId":{"Id":"own"},"Subject":"Busy","Start":"2026-11-04T12:00:00Z","End":"2026-11-04T13:00:00Z"},
          {"ItemId":{"Id":"meeting"},"Subject":"Busy","Start":"2026-11-04T14:00:00Z","End":"2026-11-04T15:00:00Z"},
          {"ItemId":{"Id":"series"},"Subject":"Busy","Start":"2026-11-04T16:00:00Z","End":"2026-11-04T17:00:00Z","CalendarItemType":"Occurrence"},
          {"ItemId":{"Id":"standup"},"Subject":"Standup","Start":"2026-11-04T09:00:00Z","End":"2026-11-04T09:15:00Z"}
        ]}}
        """
        let details = """
        {"Body":{"ResponseMessages":{"Items":[{"Items":[
          {"ItemId":{"Id":"busy1"},"Body":{"BodyType":"HTML","Value":"<html><body><div>Busy</div></body></html>"}},
          {"ItemId":{"Id":"own"},"Body":{"BodyType":"Text","Value":"Dentist"}},
          {"ItemId":{"Id":"meeting"},"Body":{"BodyType":"Text","Value":"Busy"},
           "RequiredAttendees":[{"Mailbox":{"EmailAddress":"a@example.com"}}]},
          {"ItemId":{"Id":"series"},"Body":{"BodyType":"Text","Value":"Busy"}},
          {"ItemId":{"Id":"standup"},"Body":{"BodyType":"Text","Value":"Daily"}}
        ]}]}}}
        """
        let busy = try XCTUnwrap(OutlookWebParser.busyEvents(fromPayloads: [Data(week.utf8)], details: [Data(details.utf8)], sourceID: outlook.id))
        XCTAssertEqual(busy.map(\.eventID), ["busy1"])
        XCTAssertEqual(busy[0].title, "Busy")
        XCTAssertEqual(busy[0].start, date("2026-11-04T10:00:00Z"))
        XCTAssertNil(busy[0].marker)

        // Matched by time, a Busy event that's still wanted is kept. Made by a version before
        // 2.0.6, its description is just "Busy", so it's rewritten once to carry the marker.
        let main = SourceEvent(key: "m1", title: "Planning", start: date("2026-11-04T10:00:00Z"), end: date("2026-11-04T11:00:00Z"))
        let plan = SyncPlanner.planBusy(for: outlook, mainEvents: .success([main]), existing: busy, options: SyncOptions())
        XCTAssertEqual(plan.updates, 1)
        XCTAssertEqual(plan.creates, 0)
        guard case .update(let id, let spec) = plan.actions[0] else { return XCTFail() }
        XCTAssertEqual(id, "busy1")
        // Read back with the marker in its body (as HTML, the way Outlook stores it), it's left alone.
        let week2 = #"{"Items":[{"ItemId":{"Id":"busy2"},"Subject":"Busy","Start":"2026-11-04T10:00:00Z","End":"2026-11-04T11:00:00Z"}]}"#
        let details2 = """
        {"Items":[{"ItemId":{"Id":"busy2"},"Body":{"BodyType":"HTML","Value":"<div>Busy</div><div><br></div><div>\(CopyFormatter.busyToken(sourceID: outlook.id))</div>"}}]}
        """
        let marked = try XCTUnwrap(OutlookWebParser.busyEvents(fromPayloads: [Data(week2.utf8)], details: [Data(details2.utf8)], sourceID: outlook.id))
        XCTAssertEqual(marked.map(\.eventID), ["busy2"])
        XCTAssertEqual(marked[0].marker, spec.marker)
        let again = SyncPlanner.planBusy(for: outlook, mainEvents: .success([main]), existing: marked, options: SyncOptions())
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(again.unchangedCount, 1)

        // And they're never copied into the main calendar.
        let events = OutlookWebParser.events(fromPayloads: [Data(week.utf8)], details: [Data(details.utf8)])
        let copy = SyncPlanner.plan(sources: [(outlook, .success(events))], existing: [], options: SyncOptions())
        XCTAssertFalse(copy.actions.contains { if case .create(let s) = $0 { s.start == date("2026-11-04T10:00:00Z") } else { false } })
    }

    func testCantTellWithoutTheDescription() {
        // The week view has no body, and the meeting couldn't be loaded in full.
        let week = #"{"Items":[{"ItemId":{"Id":"busy1"},"Subject":"Busy","Start":"2026-11-04T10:00:00Z","End":"2026-11-04T11:00:00Z"}]}"#
        XCTAssertNil(OutlookWebParser.busyEvents(fromPayloads: [Data(week.utf8)], sourceID: outlook.id))

        // Other events without one don't matter.
        let other = #"{"Items":[{"ItemId":{"Id":"x"},"Subject":"Standup","Start":"2026-11-04T10:00:00Z","End":"2026-11-04T11:00:00Z"}]}"#
        XCTAssertEqual(OutlookWebParser.busyEvents(fromPayloads: [Data(other.utf8)], sourceID: outlook.id)?.count, 0)
    }
}
