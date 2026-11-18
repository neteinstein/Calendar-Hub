import XCTest
@testable import CalendarHubCore

final class HexColorTests: XCTestCase {
    func testReadsAndWritesHex() {
        XCTAssertEqual(HexColor("#1a2B3c")?.hex, "#1A2B3C")
        XCTAssertEqual(HexColor("FF0080")?.hex, "#FF0080")
        XCTAssertEqual(HexColor(red: 1, green: 0.5, blue: 0).hex, "#FF8000")
    }

    func testRejectsAnythingElse() {
        for text in ["#FFF", "#GG0000", "", "#FF00001", "blue"] {
            XCTAssertNil(HexColor(text), text)
        }
    }

    func testClampsComponents() {
        XCTAssertEqual(HexColor(red: 2, green: -1, blue: .nan).hex, "#FF0000")
    }

    func testSourceKeepsItsColor() throws {
        let source = SourceConfig(kind: .outlookWeb, calendarName: "Work", color: "#00AA55")
        XCTAssertEqual(try roundTrip(source).color, "#00AA55")
    }

    /// Settings saved before colors could be chosen, or with a color that can't be read.
    func testMissingOrBadColorIsNil() throws {
        let source = SourceConfig(kind: .eventKit(calendarID: "a"), calendarName: "A")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        object.removeValue(forKey: "color")
        XCTAssertNil(try decode(object).color)
        object["color"] = "blue"
        XCTAssertNil(try decode(object).color)
    }

    private func roundTrip(_ source: SourceConfig) throws -> SourceConfig {
        try JSONDecoder().decode(SourceConfig.self, from: JSONEncoder().encode(source))
    }

    private func decode(_ object: [String: Any]) throws -> SourceConfig {
        try JSONDecoder().decode(SourceConfig.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
