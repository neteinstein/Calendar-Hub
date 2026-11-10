import XCTest
@testable import CalendarHubCore

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
        func schedules(_ timeZones: [TimeZone]) -> [WorldClocks.Schedule] {
            timeZones.map { .init(timeZone: $0, workingHours: WorkingHours()) }
        }
        let overlap = WorldClocks.overlap(on: date(10, 12), of: schedules([lisbon, newYork, berlin]), calendar: local)
        XCTAssertEqual(overlap, [14 * 60..<16 * 60])
        XCTAssertEqual(WorldClocks.overlap(on: date(10, 12), of: schedules([newYork, kolkata]), calendar: local), [])
        XCTAssertEqual(WorldClocks.overlap(on: date(14, 12), of: schedules([lisbon]), calendar: local), [])
    }

    func testOverlapUsesEachCityWorkingHours() {
        // New York starts at 7:00 there (12:00 in Lisbon) and Berlin ends at 19:00 there (18:00 in Lisbon).
        let overlap = WorldClocks.overlap(on: date(10, 12), of: [
            .init(timeZone: lisbon, workingHours: WorkingHours()),
            .init(timeZone: newYork, workingHours: WorkingHours(start: 7 * 60, end: 15 * 60)),
            .init(timeZone: berlin, workingHours: WorkingHours(start: 11 * 60, end: 19 * 60)),
        ], calendar: local)
        XCTAssertEqual(overlap, [12 * 60..<17 * 60])
        // Kolkata works late, so it meets New York: 19:00 to 23:00 there is 13:30 to 17:30 in Lisbon.
        XCTAssertEqual(WorldClocks.overlap(on: date(10, 12), of: [
            .init(timeZone: newYork, workingHours: WorkingHours()),
            .init(timeZone: kolkata, workingHours: WorkingHours(start: 19 * 60, end: 23 * 60)),
        ], calendar: local), [14 * 60..<17 * 60 + 30])
        // Working hours win over the night.
        XCTAssertEqual(WorldClocks.period(at: date(10, 17), in: kolkata,
                                          workingHours: WorkingHours(start: 19 * 60, end: 23 * 60)), .working)
    }

    func testLocalName() {
        var options = WorldClockOptions()
        XCTAssertEqual(options.localName(in: lisbon), "Lisbon")
        options.localNames[lisbon.identifier] = "Porto"
        XCTAssertEqual(options.localName(in: lisbon), "Porto")
        // The name stays with its time zone.
        XCTAssertEqual(options.localName(in: newYork), "New York")
        options.localNames[lisbon.identifier] = "  "
        XCTAssertEqual(options.localName(in: lisbon), "Lisbon")
    }

    func testClocksSavedWithoutWorkingHoursDecode() throws {
        let json = #"{"showsInMenu":true,"clocks":[{"id":"6F1B0C0E-6C55-4B8E-9E0B-0C7A4C0E2B11","name":"Berlin","timeZoneID":"Europe/Berlin"}]}"#
        let options = try JSONDecoder().decode(WorldClockOptions.self, from: Data(json.utf8))
        XCTAssertNil(options.clocks.first?.workingHours)
        XCTAssertEqual(options.localNames, [:])
        var clock = try XCTUnwrap(options.clocks.first)
        clock.workingHours = WorkingHours(start: 8 * 60, end: 16 * 60)
        let saved = try JSONDecoder().decode(WorldClock.self, from: JSONEncoder().encode(clock))
        XCTAssertEqual(saved.workingHours, WorkingHours(start: 8 * 60, end: 16 * 60))
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

    func testSearchByCountry() {
        let english = Locale(identifier: "en_US")
        func ids(_ query: String, locale: Locale = english) -> [String] {
            WorldClocks.search(query, limit: 20, locale: locale, at: date(10, 12)).map(\.timeZoneID)
        }
        // One time zone, one city.
        XCTAssertEqual(ids("Germany").first, "Europe/Berlin")
        XCTAssertEqual(ids("japan"), ["Asia/Tokyo"])
        // A city for each time the country keeps, the main one first, and no more.
        XCTAssertEqual(Array(ids("Portugal").prefix(2)), ["Europe/Lisbon", "Atlantic/Azores"])
        XCTAssertFalse(ids("Portugal").contains("Atlantic/Madeira"))
        let states = ids("United States")
        XCTAssertEqual(Array(states.prefix(3)), ["America/New_York", "America/Chicago", "America/Denver"])
        XCTAssertTrue(states.contains("America/Phoenix"))
        XCTAssertTrue(states.contains("America/Los_Angeles"))
        XCTAssertTrue(states.contains("Pacific/Honolulu"))
        XCTAssertFalse(states.contains("America/Detroit"))
        // The start of a name, what people call it, and its name in the Mac's language.
        XCTAssertEqual(ids("Portug").first, "Europe/Lisbon")
        XCTAssertEqual(ids("uk").first, "Europe/London")
        XCTAssertEqual(ids("usa").first, "America/New_York")
        XCTAssertEqual(ids("Alemanha", locale: Locale(identifier: "pt_PT")).first, "Europe/Berlin")
        XCTAssertEqual(ids("Germany", locale: Locale(identifier: "pt_PT")).first, "Europe/Berlin")
        // A country named in full comes before the cities that start the same way.
        XCTAssertEqual(ids("India").first, "Asia/Calcutta")
        // Cities still come by their own name.
        XCTAssertEqual(ids("Detroit").first, "America/Detroit")
        XCTAssertEqual(WorldClocks.search("Lisbon", locale: english).first?.countryName(locale: english), "Portugal")
    }

    func testEveryCityWithACountryIsKnown() {
        // The table covers the time zones macOS lists, less the ones without a country.
        let without = WorldClocks.places.filter { $0.countryCode == nil }.map(\.timeZoneID)
        XCTAssertEqual(without, [], "no country for \(without)")
    }

    func testOptionsDecodeWhenEmpty() throws {
        let options = try JSONDecoder().decode(WorldClockOptions.self, from: Data("{}".utf8))
        XCTAssertFalse(options.showsInMenu)
        XCTAssertEqual(options.clocks, [])
    }
}
