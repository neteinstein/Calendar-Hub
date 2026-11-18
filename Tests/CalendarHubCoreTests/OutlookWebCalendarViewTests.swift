import XCTest
@testable import CalendarHubCore

final class OutlookWebCalendarViewTests: XCTestCase {
    let berlin = TimeZone(identifier: "Europe/Berlin")!
    let monday = ISO8601DateFormatter().date(from: "2026-11-16T00:00:00Z")!
    var nextMonday: Date { monday.addingTimeInterval(7 * 86400) }

    func json(_ request: OutlookWebWriter.Request) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any])
    }

    func testAsksForTheCalendarBetweenTheDates() throws {
        let requests = OutlookWebCalendarView.requests(from: monday, to: nextMonday, timeZone: berlin)
        XCTAssertEqual(requests.map(\.action), ["GetCalendarView", "FindItem", "FindItem"])

        let calendarView = try json(requests[0])
        XCTAssertEqual(calendarView["__type"] as? String, "GetCalendarViewJsonRequest:#Exchange")
        let body = try XCTUnwrap(calendarView["Body"] as? [String: Any])
        XCTAssertEqual(body["RangeStart"] as? String, "2026-11-16T00:00:00Z")
        XCTAssertEqual(body["RangeEnd"] as? String, "2026-11-23T00:00:00Z")
        let folder = try XCTUnwrap((body["CalendarId"] as? [String: Any])?["BaseFolderId"] as? [String: Any])
        XCTAssertEqual(folder["Id"] as? String, "calendar")
        let header = try XCTUnwrap(calendarView["Header"] as? [String: Any])
        let zone = (header["TimeZoneContext"] as? [String: Any])?["TimeZoneDefinition"] as? [String: Any]
        XCTAssertEqual(zone?["Id"] as? String, "W. Europe Standard Time")

        let pagings = try requests.dropFirst().map { request -> [String: Any] in
            let body = try XCTUnwrap(try json(request)["Body"] as? [String: Any])
            XCTAssertEqual(body["__type"] as? String, "FindItemRequest:#Exchange")
            return try XCTUnwrap(body["Paging"] as? [String: Any])
        }
        XCTAssertEqual(pagings.map { $0["__type"] as? String }, ["CalendarPageView:#Exchange", "CalendarView:#Exchange"])
        XCTAssertEqual(pagings[0]["StartDate"] as? String, "2026-11-16T00:00:00Z")
        XCTAssertEqual(pagings[0]["EndDate"] as? String, "2026-11-23T00:00:00Z")
    }

    func testAsksForNothingButTheCalendar() {
        for request in OutlookWebCalendarView.requests(from: monday, to: nextMonday) {
            XCTAssertFalse(request.body.contains("Inbox"))
            XCTAssertTrue(request.body.contains("\"Id\":\"calendar\""))
        }
    }

    let getCalendarViewAnswer = Data("""
    {"Body":{"__type":"GetCalendarViewResponseMessage:#Exchange","ResponseClass":"Success","Items":[
      {"__type":"CalendarItem:#Exchange","ItemId":{"Id":"AAMk1","ChangeKey":"x"},"Subject":"Busy",
       "Start":"2026-11-17T10:00:00+01:00","End":"2026-11-17T11:00:00+01:00","CalendarItemType":"Single",
       "LegacyFreeBusyStatus":"Busy"}
    ]}}
    """.utf8)

    let findItemAnswer = Data("""
    {"Body":{"ResponseMessages":{"Items":[{"__type":"FindItemResponseMessage:#Exchange","ResponseClass":"Success",
      "RootFolder":{"IncludesLastItemInRange":true,"Items":[
        {"__type":"CalendarItem:#Exchange","ItemId":{"Id":"AAMk2"},"Subject":"Planning",
         "Start":"2026-11-18T09:00:00Z","End":"2026-11-18T09:30:00Z"}
      ]}}]}}}
    """.utf8)

    func testReadsEitherAnswer() {
        XCTAssertTrue(OutlookWebCalendarView.answers(getCalendarViewAnswer, from: monday, to: nextMonday))
        XCTAssertTrue(OutlookWebCalendarView.answers(findItemAnswer, from: monday, to: nextMonday))
        XCTAssertEqual(OutlookWebParser.itemIDs(fromPayloads: [getCalendarViewAnswer, findItemAnswer]), ["AAMk1", "AAMk2"])
    }

    func testAnAnswerForAnotherWeekOrAnErrorDoesNotCount() {
        XCTAssertFalse(OutlookWebCalendarView.answers(getCalendarViewAnswer, from: nextMonday,
                                                      to: nextMonday.addingTimeInterval(7 * 86400)))
        let error = Data(#"{"Body":{"ResponseClass":"Error","MessageText":"The request is invalid."}}"#.utf8)
        XCTAssertFalse(OutlookWebCalendarView.answers(error, from: monday, to: nextMonday))
        XCTAssertFalse(OutlookWebCalendarView.answers(Data("<html></html>".utf8), from: monday, to: nextMonday))
    }

    /// Outlook gives every event a SeriesMasterItemId, empty for one that doesn't repeat (as the
    /// Busy events are). Taken for a repeating event, no Busy event was ever recognised, and
    /// every sync added them all again.
    func testABusyEventWithOutlooksEmptySeriesIDIsFound() throws {
        let source = UUID()
        let notes = "Busy\n\n" + CopyFormatter.busyToken(sourceID: source)
        let week = try JSONSerialization.data(withJSONObject: ["Body": ["Items": [[
            "__type": "CalendarItem:#Exchange", "CalendarItemType": "Single", "IsRecurring": false, "IsMeeting": false,
            "ItemId": ["__type": "ItemId:#Exchange", "Id": "AAk1", "ChangeKey": "x"],
            "SeriesMasterItemId": ["__type": "ItemId:#Exchange"],
            "Subject": "Busy", "Preview": notes, "FreeBusyType": "Busy", "ResponseType": "Organizer",
            "Start": "2026-11-18T10:00:00Z", "End": "2026-11-18T10:30:00Z",
            "StartTimeZoneId": "GMT Standard Time", "EndTimeZoneId": "GMT Standard Time",
        ] as [String: Any]]]])
        let detail = try JSONSerialization.data(withJSONObject: [
            "Body": ["Items": [["ItemId": ["Id": "AAk1"], "SeriesMasterItemId": ["__type": "ItemId:#Exchange"],
                                "Body": ["BodyType": "Text", "Value": notes]]]],
        ])
        let found = try XCTUnwrap(OutlookWebParser.busyEvents(fromPayloads: [week], details: [detail], sourceID: source))
        XCTAssertEqual(found.map(\.eventID), ["AAk1"])

        // One that does repeat is still left alone.
        let repeating = Data(String(decoding: week, as: UTF8.self)
            .replacingOccurrences(of: #""IsRecurring":false"#, with: #""IsRecurring":true"#).utf8)
        XCTAssertEqual(OutlookWebParser.busyEvents(fromPayloads: [repeating], details: [detail], sourceID: source)?.count, 0)
    }

    /// A week loaded this way has item ids, so its Busy events can be found once loaded in full.
    func testBusyEventsAreFoundInAWeekLoadedThisWay() throws {
        let source = UUID()
        let notes = "Busy\n\n" + CopyFormatter.busyToken(sourceID: source)
        let detail = try JSONSerialization.data(withJSONObject: [
            "Body": ["Items": [["ItemId": ["Id": "AAMk1"], "Body": ["BodyType": "Text", "Value": notes]]]],
        ])
        let found = try XCTUnwrap(OutlookWebParser.busyEvents(fromPayloads: [getCalendarViewAnswer], details: [detail],
                                                              sourceID: source))
        XCTAssertEqual(found.map(\.eventID), ["AAMk1"])
    }
}
