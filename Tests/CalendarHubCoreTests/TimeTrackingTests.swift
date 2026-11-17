import Foundation
import XCTest
@testable import CalendarHubCore

final class TimeTrackingTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private let clientA = TimeClient(id: UUID().uuidString, name: "Client A")
    private let internalClient = TimeClient(id: TimeClient.internalID, name: "Internal")

    /// Tuesday 17 November 2026 at `hour`:`minute`, Lisbon time.
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 17) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func copy(_ title: String, _ start: Date, _ end: Date, from client: TimeClient,
                      key: String? = nil) -> SourceEvent {
        let sourceID = UUID(uuidString: client.id)!
        let key = key ?? title
        return SourceEvent(key: key, title: "[\(client.name)] \(title)", start: start, end: end,
                           notes: CopyFormatter.notes(meetingURL: nil, marker: CopyMarker(sourceID: sourceID, key: key)))
    }

    private func own(_ title: String, _ start: Date, _ end: Date) -> SourceEvent {
        SourceEvent(key: title, title: title, start: start, end: end)
    }

    // MARK: - Meetings

    func testMeetingsGoToTheirCalendarOrInternal() {
        let events = [
            copy("Standup", at(9, 30), at(9, 45), from: clientA),
            own("1:1", at(11), at(11, 30)),
        ]
        let entries = TimeTracking.meetingEntries(events: events, clients: [clientA, internalClient],
                                                  internalClient: internalClient, now: at(18))
        XCTAssertEqual(entries.map(\.clientName), ["Client A", "Internal"])
        XCTAssertEqual(entries.map(\.title), ["Standup", "1:1"])
        XCTAssertEqual(entries.map(\.source), [.meeting, .meeting])
        XCTAssertEqual(entries.first?.meetingKey, "Standup")
    }

    func testDeclinedCancelledAllDayAndOutOfOfficeAreNotLogged() {
        var declined = own("Declined", at(10), at(11))
        declined.isDeclined = true
        var cancelled = own("Cancelled", at(11), at(12))
        cancelled.isCancelled = true
        var allDay = own("Holiday", at(0), at(0, day: 18))
        allDay.isAllDay = true
        var away = own("Away", at(13), at(14))
        away.isOutOfOffice = true
        let retitled = own("Canceled: Review", at(14), at(15))
        let entries = TimeTracking.meetingEntries(events: [declined, cancelled, allDay, away, retitled],
                                                  clients: [], internalClient: internalClient, now: at(18))
        XCTAssertTrue(entries.isEmpty)
    }

    func testMeetingsCountOnlyUpToNow() {
        let entries = TimeTracking.meetingEntries(events: [own("Workshop", at(10), at(12)), own("Later", at(15), at(16))],
                                                  clients: [], internalClient: internalClient, now: at(11))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].end, at(11))
    }

    func testOverlappingMeetingsCountOnceForTheFirstToStart() {
        let events = [
            own("Hiring panel", at(16), at(17)),
            copy("Retro", at(16, 30), at(17, 30), from: clientA),
        ]
        let entries = TimeTracking.meetingEntries(events: events, clients: [clientA], internalClient: internalClient,
                                                  now: at(18))
        XCTAssertEqual(entries.map(\.clientName), ["Internal", "Client A"])
        XCTAssertEqual(entries[1].start, at(17))
        XCTAssertEqual(entries[1].end, at(17, 30))
        XCTAssertEqual(entries.map(\.duration).reduce(0, +), 90 * 60)
    }

    func testMeetingInsideAnEarlierOneGetsNothing() {
        // Morning started first and covers the call, so only Morning is logged, under its own key.
        let entries = TimeTracking.meetingEntries(events: [own("Call", at(10), at(11)), own("Morning", at(9), at(12))],
                                                  clients: [], internalClient: internalClient, now: at(18))
        XCTAssertEqual(entries.map(\.meetingKey), ["Morning"])
        XCTAssertEqual(entries.first?.duration, 3 * 3600)
    }

    func testReassignedMeetingGoesToItsNewClient() {
        let entries = TimeTracking.meetingEntries(events: [own("Prep for A", at(10), at(11))], clients: [clientA],
                                                  internalClient: internalClient,
                                                  reassigned: ["Prep for A": clientA], now: at(18))
        XCTAssertEqual(entries.first?.clientID, clientA.id)
    }

    func testCopyFromARemovedCalendarKeepsItsName() {
        let removed = TimeClient(id: UUID().uuidString, name: "Old Client")
        let entries = TimeTracking.meetingEntries(events: [copy("Sync", at(10), at(11), from: removed)],
                                                  clients: [], internalClient: internalClient, now: at(18))
        XCTAssertEqual(entries.first?.clientName, "Old Client")
        XCTAssertEqual(entries.first?.clientID, removed.id)
    }

    // MARK: - Combining

    func testTimerGivesWayToMeetings() {
        let meetings = [TimeEntry(client: internalClient, start: at(10), end: at(11), source: .meeting)]
        let timer = TimeEntry(client: clientA, start: at(9), end: at(12), source: .timer)
        let combined = TimeTracking.combine(meetings: meetings, logged: [timer])
        XCTAssertEqual(combined.map(\.clientName), ["Client A", "Internal", "Client A"])
        XCTAssertEqual(combined.map(\.duration).reduce(0, +), 3 * 3600)
        XCTAssertEqual(Set(combined.map(\.id)).count, 3)
    }

    func testOverlappingLoggedEntriesCountOnce() {
        let first = TimeEntry(client: clientA, start: at(9), end: at(11), source: .timer)
        let second = TimeEntry(client: internalClient, start: at(10), end: at(12), source: .assigned)
        let combined = TimeTracking.combine(meetings: [], logged: [second, first])
        XCTAssertEqual(combined.map(\.clientName), ["Client A", "Internal"])
        XCTAssertEqual(combined[1].start, at(11))
    }

    func testTotalsPerClientWithMeetingTime() {
        let entries = [
            TimeEntry(client: clientA, start: at(9), end: at(10), source: .meeting),
            TimeEntry(client: clientA, start: at(10), end: at(12), source: .timer),
            TimeEntry(client: internalClient, start: at(13), end: at(14), source: .meeting),
        ]
        let totals = TimeTracking.totals(of: entries)
        XCTAssertEqual(totals.map(\.client.name), ["Client A", "Internal"])
        XCTAssertEqual(totals[0].total, 3 * 3600)
        XCTAssertEqual(totals[0].meetings, 3600)
    }

    func testClipKeepsWhatIsInside() {
        let entry = TimeEntry(client: clientA, start: at(23, day: 16), end: at(1), source: .timer)
        let day = calendar.dateInterval(of: .day, for: at(12))!
        let clipped = TimeTracking.clip([entry], to: day)
        XCTAssertEqual(clipped.first?.start, day.start)
        XCTAssertEqual(clipped.first?.end, at(1))
    }

    // MARK: - Untracked time

    func testUntrackedGapsWithinWorkingHoursUpToNow() {
        let entries = [
            TimeEntry(client: clientA, start: at(9), end: at(12), source: .timer),
            TimeEntry(client: internalClient, start: at(12, 10), end: at(14), source: .meeting),
        ]
        let gaps = TimeTracking.untrackedGaps(on: at(12), entries: entries, workingHours: WorkingHours(),
                                              now: at(16, 30), calendar: calendar)
        // 12:00–12:10 is too short to list.
        XCTAssertEqual(gaps, [DateInterval(start: at(14), end: at(16, 30))])
    }

    func testNoGapsAtTheWeekend() {
        let saturday = at(12, day: 21)
        XCTAssertTrue(TimeTracking.untrackedGaps(on: saturday, entries: [], workingHours: WorkingHours(),
                                                 now: at(18, day: 21), calendar: calendar).isEmpty)
    }

    func testAfterWorkingDay() {
        XCTAssertFalse(TimeTracking.isAfterWorkingDay(at(16, 59), workingHours: WorkingHours(), calendar: calendar))
        XCTAssertTrue(TimeTracking.isAfterWorkingDay(at(17), workingHours: WorkingHours(), calendar: calendar))
    }

    // MARK: - Timer

    func testForgottenTimerStopsAtTheEndOfTheWorkingDay() {
        XCTAssertNil(TimeTracking.forgottenTimerEnd(start: at(14), now: at(18, 30), workingHours: WorkingHours(),
                                                    calendar: calendar))
        XCTAssertEqual(TimeTracking.forgottenTimerEnd(start: at(14), now: at(19), workingHours: WorkingHours(),
                                                      calendar: calendar), at(17))
        XCTAssertEqual(TimeTracking.forgottenTimerEnd(start: at(14), now: at(9, day: 18), workingHours: WorkingHours(),
                                                      calendar: calendar), at(17))
    }

    func testEveningTimerStopsAtMidnight() {
        XCTAssertNil(TimeTracking.forgottenTimerEnd(start: at(20), now: at(23, 30), workingHours: WorkingHours(),
                                                    calendar: calendar))
        XCTAssertEqual(TimeTracking.forgottenTimerEnd(start: at(20), now: at(8, day: 18), workingHours: WorkingHours(),
                                                      calendar: calendar), at(0, day: 18))
    }

    func testMenuBarText() {
        let timer = RunningTimer(client: TimeClient(id: "x", name: "A client with a very long name"), start: at(10))
        XCTAssertEqual(TimeTracking.menuBarText(for: timer, now: at(11, 12)), "A client with a… · 1h 12m")
    }

    // MARK: - Export

    func testCSV() {
        let hidden = TimeClient(id: UUID().uuidString, name: "Secret, Inc")
        let entries = [
            TimeEntry(client: clientA, start: at(9, 30), end: at(9, 45), source: .meeting, title: "Standup \"daily\""),
            TimeEntry(client: hidden, start: at(10), end: at(11, 30), source: .meeting, title: "Merger"),
            TimeEntry(client: internalClient, start: at(14), end: at(15), source: .timer),
        ]
        let csv = TimeTracking.csv(entries, calendar: calendar, hiddenTitles: [hidden.id])
        let expected = [
            "Date,Client,Start,End,Duration,Hours,Source,Title",
            #"2026-11-17,Client A,09:30,09:45,0:15,0.25,meeting,"Standup ""daily""""#,
            #"2026-11-17,"Secret, Inc",10:00,11:30,1:30,1.50,meeting,"#,
            "2026-11-17,Internal,14:00,15:00,1:00,1.00,timer,",
        ]
        XCTAssertEqual(csv, expected.map { $0 + "\r\n" }.joined())
    }

    func testCSVDefusesFormulas() {
        XCTAssertEqual(TimeTracking.csvField("=HYPERLINK(\"x\")"), "\"'=HYPERLINK(\"\"x\"\")\"")
        XCTAssertEqual(TimeTracking.csvField("-5"), "'-5")
    }

    func testExportPeriods() {
        let now = at(12)
        XCTAssertEqual(TimeTracking.Period.thisWeek.interval(now: now, calendar: calendar)?.start, at(0, day: 16))
        XCTAssertEqual(TimeTracking.Period.lastWeek.interval(now: now, calendar: calendar)?.start, at(0, day: 9))
        XCTAssertEqual(TimeTracking.Period.thisMonth.label(now: now, calendar: calendar), "2026-11")
        XCTAssertEqual(TimeTracking.Period.lastMonth.label(now: now, calendar: calendar), "2026-10")
        XCTAssertEqual(TimeTracking.Period.thisWeek.label(now: now, calendar: calendar), "2026-11-16")
    }

    // MARK: - Settings

    func testOptionsDecodeFromOlderSettings() throws {
        let options = try JSONDecoder().decode(TimeTrackingOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(options, TimeTrackingOptions())
        XCTAssertFalse(options.isEnabled)
        XCTAssertEqual(options.internalClient.name, "Internal")
    }

    func testClientsAreCalendarsThenManualThenInternal() {
        let source = SourceConfig(kind: .outlookWeb, calendarName: "X", name: "Client X")
        let manual = TimeClient.manual(named: "Prospect")
        let options = TimeTrackingOptions(internalName: "Mindful", extraClients: [manual])
        XCTAssertEqual(TimeTracking.clients(sources: [source], options: options).map(\.name),
                       ["Client X", "Prospect", "Mindful"])
        XCTAssertTrue(manual.isManual)
    }

    func testLogRoundTrips() throws {
        let log = TimeLog(entries: [TimeEntry(client: clientA, start: at(9), end: at(10), source: .timer)],
                          meetingClients: ["k": clientA], running: RunningTimer(client: internalClient, start: at(11)))
        XCTAssertEqual(try JSONDecoder().decode(TimeLog.self, from: JSONEncoder().encode(log)), log)
        XCTAssertTrue(TimeLog().isEmpty)
    }
}
