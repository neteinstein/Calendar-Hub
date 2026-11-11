import XCTest
@testable import CalendarHubCore

final class DebugLogTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    func testKeepsTheNewestLinesUpToCapacity() {
        var log = DebugLog(capacity: 3)
        for n in 1...5 { log.append("line \(n)") }
        XCTAssertEqual(log.entries.map(\.message), ["line 3", "line 4", "line 5"])
        XCTAssertEqual(log.entries.map(\.id), [2, 3, 4])
    }

    func testClearKeepsCountingIDs() {
        var log = DebugLog()
        log.append("a")
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
        log.append("b")
        XCTAssertEqual(log.entries.first?.id, 1)
    }

    func testTextHasATimePerLine() {
        var log = DebugLog()
        log.append("first", at: Date(timeIntervalSince1970: 0))
        log.append("second", at: Date(timeIntervalSince1970: 1.25))
        XCTAssertEqual(log.text(timeZone: utc),
                       "1970-01-01 00:00:00.000 first\n1970-01-01 00:00:01.250 second")
    }

    func testFeedbackBodyKeepsAShortLogWhole() {
        let body = DebugLog.feedbackBody(version: "2.0.23", system: "macOS 15.1", log: "one\ntwo")
        XCTAssertTrue(body.contains("Calendar Hub 2.0.23, macOS 15.1"))
        XCTAssertTrue(body.contains("```\none\ntwo\n```"))
        XCTAssertFalse(body.contains("Earlier lines left out"))
    }

    func testFeedbackBodyKeepsTheNewestWholeLinesOfALongLog() {
        let log = (1...100).map { "line \($0)" }.joined(separator: "\n")
        let body = DebugLog.feedbackBody(version: "1", system: "macOS", log: log, maxLogLength: 30)
        XCTAssertTrue(body.contains("Earlier lines left out"))
        XCTAssertTrue(body.contains("```\nline 98\nline 99\nline 100\n```"))
        XCTAssertFalse(body.contains("line 1\n"))
    }

    func testNewIssueURLEncodesTheBody() {
        let url = DebugLog.newIssueURL(repo: URL(string: "https://github.com/owner/repo")!, body: "a+b & c\n#1")
        XCTAssertEqual(url.absoluteString, "https://github.com/owner/repo/issues/new?body=a%2Bb%20%26%20c%0A%231")
    }
}
