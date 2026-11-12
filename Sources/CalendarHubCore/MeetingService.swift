import Foundation

/// The online meeting service a link is for, so the alert's Join button can take on its
/// colors and its app's icon.
public enum MeetingService: String, CaseIterable, Sendable {
    case zoom, teams, meet, webex, goTo, chime, whereby, jitsi

    /// The service for a meeting link, or nil for a host none of these use.
    public static func of(_ url: URL) -> MeetingService? {
        let host = url.host?.lowercased() ?? ""
        return allCases.first { service in
            service.hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }

    var hosts: [String] {
        switch self {
        case .zoom: ["zoom.us", "zoomgov.com"]
        case .teams: ["teams.microsoft.com", "teams.live.com"]
        case .meet: ["meet.google.com"]
        case .webex: ["webex.com"]
        case .goTo: ["gotomeeting.com", "meet.goto.com"]
        case .chime: ["chime.aws"]
        case .whereby: ["whereby.com"]
        case .jitsi: ["meet.jit.si"]
        }
    }

    /// The name on the Join button: "Join Zoom", "Join Google Meet".
    public var name: String {
        switch self {
        case .zoom: "Zoom"
        case .teams: "Teams"
        case .meet: "Google Meet"
        case .webex: "Webex"
        case .goTo: "GoTo Meeting"
        case .chime: "Chime"
        case .whereby: "Whereby"
        case .jitsi: "Jitsi"
        }
    }

    /// The service's brand color, as 0xRRGGBB.
    public var color: UInt32 {
        switch self {
        case .zoom: 0x0B5CFF
        case .teams: 0x5B5FC7
        case .meet: 0xFBBC04
        case .webex: 0x0072BB
        case .goTo: 0xF68D2E
        case .chime: 0x1F6FE0
        case .whereby: 0xD6336C
        case .jitsi: 0x1D76BA
        }
    }

    /// Whether black text has more contrast on `color` than white (WCAG): Meet's yellow and
    /// GoTo's orange are too light for white text.
    public var prefersDarkText: Bool {
        Self.relativeLuminance(color) > 0.179
    }

    /// The service's Mac apps, most likely first, whose icon goes on the button when one is
    /// installed. Google Meet has none of its own, only Chrome's installable web app.
    public var bundleIDs: [String] {
        switch self {
        case .zoom: ["us.zoom.xos"]
        case .teams: ["com.microsoft.teams2", "com.microsoft.teams"]
        case .meet: ["com.google.Chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"]
        case .webex: ["Cisco-Systems.Spark", "com.webex.meetingmanager"]
        case .goTo: ["com.logmein.goto", "com.logmein.GoToMeeting"]
        case .chime: ["com.amazon.Amazon-Chime"]
        case .whereby: []
        case .jitsi: ["org.jitsi.jitsi-meet"]
        }
    }

    /// The SF Symbol on the button when none of the service's apps is installed.
    public var symbol: String {
        switch self {
        case .zoom, .meet, .jitsi, .whereby: "video.fill"
        case .teams: "person.2.fill"
        case .webex, .chime: "video.circle.fill"
        case .goTo: "phone.fill"
        }
    }

    /// WCAG relative luminance of an 0xRRGGBB color, from 0 (black) to 1 (white).
    static func relativeLuminance(_ rgb: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let c = Double((rgb >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
}
