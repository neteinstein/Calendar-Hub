import XCTest
@testable import CalendarHubCore

final class SupportNudgeTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60
    private let firstRun = Date(timeIntervalSince1970: 1_800_000_000)

    func testNotBeforeTheAppHasBeenInUseForAMonth() {
        XCTAssertFalse(SupportNudge.isDue(now: firstRun, firstRun: firstRun, lastPutAway: nil, stopped: false))
        XCTAssertFalse(SupportNudge.isDue(now: firstRun + 29 * day, firstRun: firstRun, lastPutAway: nil, stopped: false))
        XCTAssertTrue(SupportNudge.isDue(now: firstRun + 30 * day, firstRun: firstRun, lastPutAway: nil, stopped: false))
    }

    func testLaterPutsItAwayForThreeMonths() {
        let later = firstRun + 40 * day
        XCTAssertFalse(SupportNudge.isDue(now: later + 89 * day, firstRun: firstRun, lastPutAway: later, stopped: false))
        XCTAssertTrue(SupportNudge.isDue(now: later + 90 * day, firstRun: firstRun, lastPutAway: later, stopped: false))
    }

    func testNeverAgainOnceStopped() {
        XCTAssertFalse(SupportNudge.isDue(now: firstRun + 1000 * day, firstRun: firstRun, lastPutAway: nil, stopped: true))
        XCTAssertFalse(SupportNudge.isDue(now: firstRun + 1000 * day, firstRun: firstRun,
                                          lastPutAway: firstRun + 40 * day, stopped: true))
    }
}
