import Foundation

/// Settings for the full-screen alert shown when a main-calendar event starts.
public struct EventAlertOptions: Codable, Hashable, Sendable {
    public var enabled: Bool
    /// How many minutes before the start the alert appears.
    public var leadMinutes: Int

    public init(enabled: Bool = true, leadMinutes: Int = 1) {
        self.enabled = enabled
        self.leadMinutes = leadMinutes
    }

    // Settings saved by older versions don't have these keys yet.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EventAlertOptions()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        leadMinutes = try c.decodeIfPresent(Int.self, forKey: .leadMinutes) ?? defaults.leadMinutes
    }
}

/// Decides which events deserve a full-screen alert right now. Pure logic, no calendar or
/// window access, so it can be unit tested.
public enum EventAlertPlanner {
    /// Events whose alert should be showing at `now`: from `leadMinutes` before the start
    /// until the event ends (so a meeting already under way still alerts, say after the Mac
    /// wakes), skipping all-day, declined and cancelled events and ones in `shown`.
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
                    && !shown.contains(event.key)
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
            .filter { !$0.isAllDay && !$0.isDeclined && !$0.isCancelled && !shown.contains($0.key) }
            .map { $0.start.addingTimeInterval(-60 * Double(max(0, leadMinutes))) }
            .filter { $0 > now }
            .min()
    }
}
