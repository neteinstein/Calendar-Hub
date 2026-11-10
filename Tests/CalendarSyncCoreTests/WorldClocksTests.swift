import XCTest
@testable import CalendarSyncCore

final class WorldClocksTests: XCTestCase {
    let lisbon = TimeZone(identifier: "Europe/Lisbon")!
    let newYork = TimeZone(identifier: "America/New_York")!
    let berlin = TimeZone(identifier: "Europe/Berlin")!
    let kolkata = TimeZone(identifier: "Asia/Kolkata")!

    var local: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = lisbon
        return calendar
    }

    /// In Lisbon, November 2026 (UTC+0; New York is UTC−5, Berlin UTC+1).
    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        local.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testPeriods() {
        let hours = WorkingHours()
        // Tuesday 10 November, 15:00 in Lisbon: 10:00 in New York, 16:00 in Berlin, 20:30 in Kolkata.
        XCTAssertEqual(WorldClocks.period(at: date(10, 15), in: newYork, workingHours: hours), .working)
        XCTAssertEqual(WorldClocks.period(at: date(10, 15), in: berlin, workingHours: hours), .working)
        XCTAssertEqual(WorldClocks.period(at: date(10, 15), in: kolkata, workingHours: hours), .free)
        XCTAssertEqual(WorldClocks.period(at: date(10, 18), in: kolkata, workingHours: hours), .night)
        // Saturday 14 November, 11:00: a weekend, so not working.
        XCTAssertEqual(WorldClocks.period(at: date(14, 11), in: lisbon, workingHours: hours), .free)
    }

    func testSegmentsAreTheCityWorkingHoursInLocalTime() {
        let segments = WorldClocks.segments(on: date(10, 12), for: newYork, workingHours: WorkingHours(), calendar: local)
        XCTAssertEqual(segments.first, .init(start: 0, end: 3 * 60, period: .free))
        XCTAssertTrue(segments.contains(.init(start: 14 * 60, end: 22 * 60, period: .working)))
        XCTAssertEqual(segments.last?.end, 24 * 60)
    }

    func testHalfHourZones() {
        let segments = WorldClocks.segments(on: date(10, 12), for: kolkata, workingHours: WorkingHours(), calendar: local)
        XCTAssertTrue(segments.contains(.init(start: 3 * 60 + 30, end: 11 * 60 + 30, period: .working)))
    }

    func testOverlap() {
        let overlap = WorldClocks.overlap(on: date(10, 12), of: [lisbon, newYork, berlin],
                                          workingHours: WorkingHours(), calendar: local)
        XCTAssertEqual(overlap, [14 * 60..<16 * 60])
        XCTAssertEqual(WorldClocks.overlap(on: date(10, 12), of: [newYork, kolkata],
                                           workingHours: WorkingHours(), calendar: local), [])
        XCTAssertEqual(WorldClocks.overlap(on: date(14, 12), of: [lisbon], workingHours: WorkingHours(), calendar: local), [])
    }

    func testTexts() {
        XCTAssertEqual(WorldClocks.offsetText(newYork, from: lisbon, at: date(10, 12)), "−5h")
        XCTAssertEqual(WorldClocks.offsetText(kolkata, from: lisbon, at: date(10, 12)), "+5h30")
        XCTAssertEqual(WorldClocks.offsetText(lisbon, from: lisbon, at: date(10, 12)), "Same time")
        XCTAssertEqual(WorldClocks.dayText(kolkata, from: lisbon, at: date(10, 21)), "Tomorrow")
        XCTAssertEqual(WorldClocks.dayText(newYork, from: lisbon, at: date(10, 2)), "Yesterday")
        XCTAssertNil(WorldClocks.dayText(newYork, from: lisbon, at: date(10, 12)))
        XCTAssertEqual(WorldClocks.durationText(minutes: 150), "2h30")
        XCTAssertEqual(WorldClocks.durationText(minutes: 120), "2h")
        XCTAssertEqual(WorldClocks.durationText(minutes: 45), "45m")
    }

    func testSearch() {
        XCTAssertEqual(WorldClocks.search("new york").first?.timeZoneID, "America/New_York")
        XCTAssertEqual(WorldClocks.search("são paulo").first?.timeZoneID, "America/Sao_Paulo")
        XCTAssertTrue(WorldClocks.search("Lis").contains { $0.timeZoneID == "Europe/Lisbon" })
        XCTAssertTrue(WorldClocks.search("").isEmpty)
        XCTAssertEqual(WorldClocks.cityName(of: "America/Argentina/Buenos_Aires"), "Buenos Aires")
    }

    func testOptionsDecodeWhenEmpty() throws {
        let options = try JSONDecoder().decode(WorldClockOptions.self, from: Data("{}".utf8))
        XCTAssertFalse(options.showsInMenu)
        XCTAssertEqual(options.clocks, [])
    }
}
