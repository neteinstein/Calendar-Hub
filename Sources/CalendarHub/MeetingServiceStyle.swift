import AppKit
import CalendarHubCore
import SwiftUI

/// How a meeting service's Join buttons look, in the alert and in the menu: its brand color,
/// the text color that reads best on it, and its app's icon.
extension MeetingService {
    /// The fill of its Join buttons.
    var fill: Color { Color(rgb: color) }

    /// The text on `fill`.
    var textColor: Color { prefersDarkText ? .black : .white }

    /// The icon of the first of the service's apps that's installed, looked up once per service.
    @MainActor
    var appIcon: NSImage? {
        if let cached = Self.iconCache[self] { return cached }
        let icon = bundleIDs.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        Self.iconCache[self] = .some(icon)
        return icon
    }

    @MainActor private static var iconCache: [MeetingService: NSImage?] = [:]
}

extension Color {
    /// A color from 0xRRGGBB.
    init(rgb: UInt32) {
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}

/// The service's app icon at `size`, or its symbol (a camera for any other link).
struct MeetingServiceIcon: View {
    let service: MeetingService?
    let size: CGFloat

    var body: some View {
        if let service, let icon = service.appIcon {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: service?.symbol ?? "video.fill")
        }
    }
}
