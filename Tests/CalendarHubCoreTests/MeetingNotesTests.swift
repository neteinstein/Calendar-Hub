import XCTest
@testable import CalendarHubCore

final class MeetingNotesTests: XCTestCase {
    func testActionItems() {
        let notes = """
        ## Notes
        - Budget is fine

        ## Action items
        - [ ] Send the slides
        - [x] Book the room
        * [ ]   Ask Ana about dates
        - [ ] 
        - [ ] send the slides
        - [ ] Already a task
        """
        XCTAssertEqual(MeetingNotes.actionItems(in: notes, existing: ["Already a task"]),
                       ["Send the slides", "Ask Ana about dates"])
    }

    func testNotesTaskIsFoundByItsEvent() {
        let link = TaskEventLink(key: "e1", title: "Design review", start: Date(timeIntervalSince1970: 0))
        let tasks = [TaskItem(title: "Prepare", event: link), TaskItem(title: "Notes: Design review", event: link)]
        XCTAssertEqual(MeetingNotes.task(forEvent: "e1", in: tasks)?.title, "Notes: Design review")
        XCTAssertNil(MeetingNotes.task(forEvent: "e2", in: tasks))
    }

    func testTitleAndTemplate() {
        let event = SourceEvent(key: "e1", title: "Design review", start: Date(timeIntervalSince1970: 0),
                                end: Date(timeIntervalSince1970: 3600))
        XCTAssertEqual(MeetingNotes.title(for: event), "Notes: Design review")
        XCTAssertTrue(MeetingNotes.template(for: event).contains("## Action items\n\n- [ ] "))
    }
}
