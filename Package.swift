// swift-tools-version:5.9
import PackageDescription

var products: [Product] = [
    .library(name: "CalendarHubCore", targets: ["CalendarHubCore"]),
]

var targets: [Target] = [
    // Pure Foundation: sync rules, formatting, parsing. Builds and tests on Linux too.
    .target(name: "CalendarHubCore"),
    .testTarget(name: "CalendarHubCoreTests", dependencies: ["CalendarHubCore"]),
]

#if os(macOS)
// The menu bar app itself (EventKit, SwiftUI, WebKit). macOS only.
products.append(.executable(name: "CalendarHub", targets: ["CalendarHub"]))
targets.append(.executableTarget(name: "CalendarHub", dependencies: ["CalendarHubCore"]))
#endif

let package = Package(
    name: "CalendarHub",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
