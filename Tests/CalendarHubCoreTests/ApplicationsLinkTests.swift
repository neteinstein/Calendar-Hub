import XCTest
@testable import CalendarHubCore

final class ApplicationsLinkTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplicationsLinkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testOptBundleForACellarBundle() {
        let bundle = URL(fileURLWithPath: "/opt/homebrew/Cellar/calendar-hub/1.1.2/Calendar Hub.app")
        XCTAssertEqual(
            ApplicationsLink.homebrewOptBundle(forResolvedBundle: bundle)?.path,
            "/opt/homebrew/opt/calendar-hub/Calendar Hub.app"
        )
        let intel = URL(fileURLWithPath: "/usr/local/Cellar/calendar-hub/1.1.2/Calendar Hub.app")
        XCTAssertEqual(
            ApplicationsLink.homebrewOptBundle(forResolvedBundle: intel)?.path,
            "/usr/local/opt/calendar-hub/Calendar Hub.app"
        )
    }

    func testNoOptBundleOutsideTheCellar() {
        for path in [
            "/Users/me/Calendar-Hub/build/Calendar Hub.app",
            "/Applications/Calendar Hub.app",
            "/opt/homebrew/opt/calendar-hub/Calendar Hub.app",
            "/opt/homebrew/Cellar/calendar-hub/1.1.2/Calendar Hub.app/Contents/MacOS/CalendarHub",
        ] {
            XCTAssertNil(ApplicationsLink.homebrewOptBundle(forResolvedBundle: URL(fileURLWithPath: path)), path)
        }
    }

    func testCreatesTheLinkAndItsFolder() throws {
        let target = folder.appendingPathComponent("opt/calendar-hub/Calendar Hub.app")
        let applications = folder.appendingPathComponent("home/Applications")
        XCTAssertEqual(try ApplicationsLink.ensure(linkTo: target, in: applications), .created)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: applications.appendingPathComponent("Calendar Hub.app").path),
            target.path
        )
        XCTAssertEqual(try ApplicationsLink.ensure(linkTo: target, in: applications), .alreadyThere)
    }

    func testLeavesWhatIsAlreadyThereAlone() throws {
        let target = folder.appendingPathComponent("opt/calendar-hub/Calendar Hub.app")
        let applications = folder.appendingPathComponent("Applications")
        let copy = applications.appendingPathComponent("Calendar Hub.app")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        XCTAssertEqual(try ApplicationsLink.ensure(linkTo: target, in: applications), .alreadyThere)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: copy.path), "the copy isn't replaced")
    }

    func testCountsADanglingLinkAsThere() throws {
        let target = folder.appendingPathComponent("opt/calendar-hub/Calendar Hub.app")
        let applications = folder.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let link = applications.appendingPathComponent("Calendar Hub.app").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/nowhere/Calendar Hub.app")
        XCTAssertEqual(try ApplicationsLink.ensure(linkTo: target, in: applications), .alreadyThere)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), "/nowhere/Calendar Hub.app")
    }

    func testSkipsWhenAnotherFolderHasIt() throws {
        let target = folder.appendingPathComponent("opt/calendar-hub/Calendar Hub.app")
        let home = folder.appendingPathComponent("home/Applications")
        let system = folder.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: system, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: system.appendingPathComponent("Calendar Hub.app").path, withDestinationPath: target.path
        )
        XCTAssertEqual(try ApplicationsLink.ensure(linkTo: target, in: home, unlessIn: [system]), .alreadyThere)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path), "nothing is made in the user's folder")
    }
}
