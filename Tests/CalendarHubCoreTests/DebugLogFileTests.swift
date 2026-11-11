import XCTest
@testable import CalendarHubCore

final class DebugLogFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testWritesLinesAndMakesTheFolder() {
        let file = DebugLogFile(url: folder.appendingPathComponent("Logs/debug.log"))
        file.append("one")
        file.append("two")
        XCTAssertEqual(file.text(), "one\ntwo")
        XCTAssertEqual(try String(contentsOf: file.url, encoding: .utf8), "one\ntwo\n")
    }

    func testKeepsLinesFromAnEarlierLaunch() {
        let url = folder.appendingPathComponent("debug.log")
        DebugLogFile(url: url).append("before the crash")
        let next = DebugLogFile(url: url)
        next.append("after")
        XCTAssertEqual(next.text(), "before the crash\nafter")
    }

    func testMovesAFullFileAsideAndKeepsOnlyOneOldFile() {
        let file = DebugLogFile(url: folder.appendingPathComponent("debug.log"), maxBytes: 10)
        file.append("aaaa")  // 5 bytes
        file.append("bbbb")  // 10
        file.append("cccc")  // over: a, b move to the old file
        XCTAssertEqual(file.oldURL.lastPathComponent, "debug.old.log")
        XCTAssertEqual(file.text(), "aaaa\nbbbb\ncccc")
        file.append("dddd")
        file.append("eeee")  // over again: a, b are dropped
        XCTAssertEqual(file.text(), "cccc\ndddd\neeee")
    }

    func testRemoveDeletesBothFiles() {
        let file = DebugLogFile(url: folder.appendingPathComponent("debug.log"), maxBytes: 5)
        file.append("aaaa")
        file.append("bbbb")
        file.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.oldURL.path))
        XCTAssertEqual(file.text(), "")
        file.append("again")
        XCTAssertEqual(file.text(), "again")
    }
}
