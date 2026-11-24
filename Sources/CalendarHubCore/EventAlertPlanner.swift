import Foundation

/// How a meeting alert shows: one or the other, never both.
public enum EventAlertStyle: String, Codable, Hashable, Sendable, CaseIterable {
    /// Covers the screen, with buttons to join, go to the room, ignore or snooze.
    case fullScreen
    /// A macOS notification; clicking it joins the call.
    case notification
}

/// Settings for the alert shown when a main-calendar event starts.
public struct EventAlertOptions: Codable, Hashable, Sendable {
    public var enabled: Bool
    /// Full screen, or a notification.
    public var style: EventAlertStyle
    /// How many minutes before the start the alert appears.
    public var leadMinutes: Int
    /// A notification at the start of the working day with the day's meetings, tasks due and
    /// the meeting limit. Off until turned on.
    public var morningSummary: Bool
    /// Runs a shortcut when a meeting starts and another when the last one under way ends, to
    /// turn a Focus on and off. Off until turned on.
    public var focusDuringMeetings: Bool
    /// The shortcut run when a meeting starts.
    public var focusOnShortcut: String
    /// The shortcut run when no meeting is under way any more.
    public var focusOffShortcut: String

    public static let defaultFocusOnShortcut = "Calendar Hub Focus On"
    public static let defaultFocusOffShortcut = "Calendar Hub Focus Off"

    public init(enabled: Bool = true, style: EventAlertStyle = .fullScreen, leadMinutes: Int = 1, morningSummary: Bool = false,
                focusDuringMeetings: Bool = false, focusOnShortcut: String = Self.defaultFocusOnShortcut,
                focusOffShortcut: String = Self.defaultFocusOffShortcut) {
        self.enabled = enabled
        self.style = style
        self.leadMinutes = leadMinutes
        self.morningSummary = morningSummary
        self.focusDuringMeetings = focusDuringMeetings
        self.focusOnShortcut = focusOnShortcut
        self.focusOffShortcut = focusOffShortcut
    }

    // Settings saved by older versions don't have these keys yet.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EventAlertOptions()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        // A style a later version added reads as the default rather than losing every setting.
        style = (try? c.decodeIfPresent(EventAlertStyle.self, forKey: .style)) ?? defaults.style
        leadMinutes = try c.decodeIfPresent(Int.self, forKey: .leadMinutes) ?? defaults.leadMinutes
        morningSummary = try c.decodeIfPresent(Bool.self, forKey: .morningSummary) ?? defaults.morningSummary
        focusDuringMeetings = try c.decodeIfPresent(Bool.self, forKey: .focusDuringMeetings) ?? defaults.focusDuringMeetings
        focusOnShortcut = try c.decodeIfPresent(String.self, forKey: .focusOnShortcut) ?? defaults.focusOnShortcut
        focusOffShortcut = try c.decodeIfPresent(String.self, forKey: .focusOffShortcut) ?? defaults.focusOffShortcut
    }
}

/// Decides which events deserve an alert right now. Pure logic, no calendar or
/// window access, so it can be unit tested.
public enum EventAlertPlanner {
    /// Events whose alert should be showing at `now`: from `leadMinutes` before the start
    /// until the event ends (so a meeting already under way still alerts, say after the Mac
    /// wakes), skipping all-day, declined and cancelled events, a full day's Busy blocks, and
    /// ones in `shown`.
    /// Soonest start first.
    public static func dueAlerts(
        events: [SourceEvent],
        shown: Set<String>,
        now: Date,
        leadMinutes: Int
    ) -> [SourceEvent] {
        events
            .filter { event in
                !event.isAllDay && !event.isDeclined && !event.isCancelled
                    && !MeetingLimit.isBlock(event) && !shown.contains(event.key)
                    && now >= event.start.addingTimeInterval(-60 * Double(max(0, leadMinutes)))
                    && now < event.end
            }
            .sorted { $0.start < $1.start }
    }

    /// The next moment after `now` an alert falls due: the earliest start, less the lead
    /// time, of the events that will deserve one. A timer set for it shows the alert on the
    /// second, where waiting for the next periodic check could leave it up to 25 seconds late.
    public static func nextAlertTime(
        events: [SourceEvent],
        shown: Set<String>,
        now: Date,
        leadMinutes: Int
    ) -> Date? {
        events
            .filter { !$0.isAllDay && !$0.isDeclined && !$0.isCancelled && !MeetingLimit.isBlock($0) && !shown.contains($0.key) }
            .map { $0.start.addingTimeInterval(-60 * Double(max(0, leadMinutes))) }
            .filter { $0 > now }
            .min()
    }

    /// Whether a meeting is under way at `now`, for turning a Focus on: one that counts for an
    /// alert, started and not over.
    public static func meetingUnderway(events: [SourceEvent], now: Date) -> Bool {
        events.contains {
            !$0.isAllDay && !$0.isDeclined && !$0.isCancelled && !$0.isOutOfOffice && !MeetingLimit.isBlock($0)
                && $0.start <= now && now < $0.end
        }
    }
}
