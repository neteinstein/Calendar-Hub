import CalendarHubCore
import XCTest

final class MeetingServiceTests: XCTestCase {
    private func service(_ string: String) -> MeetingService? {
        MeetingService.of(URL(string: string)!)
    }

    func testRecognizesTheCommonServices() {
        XCTAssertEqual(service("https://acme.zoom.us/j/123"), .zoom)
        XCTAssertEqual(service("https://zoomgov.com/j/123"), .zoom)
        XCTAssertEqual(service("https://teams.microsoft.com/l/meetup-join/19%3a"), .teams)
        XCTAssertEqual(service("https://teams.live.com/meet/123"), .teams)
        XCTAssertEqual(service("https://meet.google.com/abc-defg-hij"), .meet)
        XCTAssertEqual(service("https://acme.webex.com/meet/pat"), .webex)
        XCTAssertEqual(service("https://global.gotomeeting.com/join/123"), .goTo)
        XCTAssertEqual(service("https://meet.goto.com/123"), .goTo)
        XCTAssertEqual(service("https://app.chime.aws/meetings/123"), .chime)
        XCTAssertEqual(service("https://whereby.com/room"), .whereby)
        XCTAssertEqual(service("https://meet.jit.si/room"), .jitsi)
    }

    func testOtherHostsGetTheDefaultButton() {
        XCTAssertNil(service("https://notzoom.us/j/1"))
        XCTAssertNil(service("https://example.com/meeting"))
    }

    func testTextColorFollowsTheBrandColor() {
        XCTAssertTrue(MeetingService.meet.prefersDarkText)
        XCTAssertTrue(MeetingService.goTo.prefersDarkText)
        XCTAssertFalse(MeetingService.zoom.prefersDarkText)
        XCTAssertFalse(MeetingService.teams.prefersDarkText)
    }
}
