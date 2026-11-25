import XCTest
@testable import CalendarHubCore

/// A Google main calendar may give a copy a Google Meet of its own, with a link that isn't
/// the meeting's, and adds its block about it to the copy's description.
final class GoogleMeetCopyTests: XCTestCase {
    let source = SourceConfig(kind: .eventKit(calendarID: "secondary-cal"), calendarName: "Calendar A")
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let meetingLink = URL(string: "https://meet.google.com/abc-defg-hij")!
    let googlesOwnLink = "https://meet.google.com/zzz-yyyy-xxx"
    let delimiter = "-::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-"

    func googleBlock(_ link: String) -> String {
        """
        \(delimiter)
        Join with Google Meet: \(link)
        Learn more about Meet at: https://support.google.com/a/users/answer/9282720

        Please do not edit this section.
        \(delimiter)
        """
    }

    func sourceEvent(notes: String? = nil) -> SourceEvent {
        SourceEvent(key: "1", title: "Sprint planning", start: base, end: base + 3600,
                    meetingURL: meetingLink, notes: notes)
    }

    func testJoinLinkIsTheCopiedOneNotGooglesOwnMeet() {
        let spec = CopyFormatter.spec(for: sourceEvent(), source: source)
        let stored = spec.notes + "\n\n" + googleBlock(googlesOwnLink)
        XCTAssertEqual(CopyFormatter.joinLink(in: stored), meetingLink)
        // Google may also put its block first.
        XCTAssertEqual(CopyFormatter.joinLink(in: googleBlock(googlesOwnLink) + "\n" + spec.notes), meetingLink)
    }

    func testJoinLinkReadsHTMLNotes() {
        let html = "Join: <a href=\"\(meetingLink)\">\(meetingLink)</a><br><br>Copied by Calendar Hub."
        XCTAssertEqual(CopyFormatter.joinLink(in: html), meetingLink)
    }

    func testNoJoinLinkWithoutAJoinLine() {
        XCTAssertNil(CopyFormatter.joinLink(in: "Copied by Calendar Hub.\n\n" + googleBlock(googlesOwnLink)))
        XCTAssertNil(CopyFormatter.joinLink(in: "Agenda\nJoin: \(meetingLink)"))
        XCTAssertNil(CopyFormatter.joinLink(in: nil))
    }

    func testCopyWithGooglesBlockAddedIsNotRewritten() {
        let spec = CopyFormatter.spec(for: sourceEvent(), source: source)
        let notes = spec.notes + "\n\n" + googleBlock(googlesOwnLink)
        let copy = ExistingCopy(eventID: "c", marker: spec.marker, title: spec.title, start: spec.start, end: spec.end,
                                isAllDay: false, url: CopyFormatter.joinLink(in: notes), notes: notes, location: nil)
        XCTAssertFalse(SyncPlanner.needsUpdate(copy, to: spec, calendar: .current))
    }

    func testSourcesGoogleBlockIsNotCopiedIntoDetails() {
        var config = source
        config.copyDetails = true
        let event = sourceEvent(notes: "Agenda: planning\n\n" + googleBlock(meetingLink.absoluteString))
        let spec = CopyFormatter.spec(for: event, source: config)
        XCTAssertTrue(spec.notes.contains("Agenda: planning"))
        XCTAssertFalse(spec.notes.contains("Please do not edit this section"))
        XCTAssertFalse(spec.notes.contains("-::~"))
    }

    func testUnclosedBlockIsDroppedToTheEnd() {
        XCTAssertEqual(CopyFormatter.withoutGoogleConferenceBlock("Agenda\n\(delimiter)\nJoin with Google Meet: x"), "Agenda\n")
        XCTAssertEqual(CopyFormatter.withoutGoogleConferenceBlock("No block here"), "No block here")
    }
}
