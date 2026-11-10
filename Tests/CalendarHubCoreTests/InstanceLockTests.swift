import XCTest
@testable import CalendarHubCore

final class InstanceLockTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstanceLockTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testOnlyOneHolderAtATime() throws {
        let url = folder.appendingPathComponent("instance.lock")
        let first = try XCTUnwrap(InstanceLock.acquire(at: url), "nobody holds it yet")
        XCTAssertNil(try InstanceLock.acquire(at: url), "a second copy can't take it while the first runs")
        withExtendedLifetime(first) {}
    }

    func testFreedWhenTheHolderGoesAway() throws {
        let url = folder.appendingPathComponent("instance.lock")
        var first = try InstanceLock.acquire(at: url)
        XCTAssertNotNil(first)
        first = nil
        XCTAssertNotNil(try InstanceLock.acquire(at: url), "a copy started after the first quit runs")
    }

    func testCreatesMissingFolders() throws {
        let url = folder.appendingPathComponent("a/b/instance.lock")
        XCTAssertNotNil(try InstanceLock.acquire(at: url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testThrowsWhenTheFileCantBeOpened() throws {
        // A plain file where the lock's folder should be.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let blocker = folder.appendingPathComponent("not-a-folder")
        try Data().write(to: blocker)
        XCTAssertThrowsError(try InstanceLock.acquire(at: blocker.appendingPathComponent("instance.lock")))
    }

    func testHolderIsReadBack() throws {
        let url = folder.appendingPathComponent("instance.lock")
        let lock = try XCTUnwrap(InstanceLock.acquire(at: url))
        XCTAssertNil(InstanceLock.holder(at: url), "an empty file, as older copies leave it")
        lock.record(.init(pid: 4242, version: "2.0.15"))
        XCTAssertEqual(InstanceLock.holder(at: url), .init(pid: 4242, version: "2.0.15"))
        // A shorter record leaves nothing of the longer one behind.
        lock.record(.init(pid: 7, version: "3.0"))
        XCTAssertEqual(InstanceLock.holder(at: url), .init(pid: 7, version: "3.0"))
        XCTAssertNil(try InstanceLock.acquire(at: url), "recording doesn't give the lock up")
    }

    func testUnreadableHolderIsNone() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("instance.lock")
        for text in ["", "hello", "12", "abc 2.0.15", "-3 2.0.15", "12 2.0.15 extra"] {
            try Data(text.utf8).write(to: url)
            XCTAssertNil(InstanceLock.holder(at: url), text)
        }
        XCTAssertNil(InstanceLock.holder(at: folder.appendingPathComponent("missing")))
    }

    func testOnlyANewerCopyTakesOver() {
        XCTAssertTrue(InstanceLock.replaces(.init(pid: 1, version: "2.0.14"), version: "2.0.15"))
        XCTAssertTrue(InstanceLock.replaces(.init(pid: 1, version: "2.0.9"), version: "2.0.10"))
        XCTAssertFalse(InstanceLock.replaces(.init(pid: 1, version: "2.0.15"), version: "2.0.15"), "the same version")
        XCTAssertFalse(InstanceLock.replaces(.init(pid: 1, version: "2.1.0"), version: "2.0.15"), "an older copy")
        XCTAssertTrue(InstanceLock.replaces(nil, version: "2.0.15"), "a copy from before it wrote itself down")
        XCTAssertFalse(InstanceLock.replaces(nil, version: ""), "a copy that doesn't know its own version")
    }
}
