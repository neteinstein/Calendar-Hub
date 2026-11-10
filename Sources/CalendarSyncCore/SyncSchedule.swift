import Foundation

/// Decides which secondary calendars are due to be read. Each calendar uses its own interval
/// when it has one, otherwise the app-wide interval.
public enum SyncSchedule {
    public static let minMinutes = 1
    public static let maxMinutes = 24 * 60

    /// Minutes between reads of `source`.
    public static func interval(for source: SourceConfig, defaultMinutes: Int) -> Int {
        min(max(source.intervalMinutes ?? defaultMinutes, minMinutes), maxMinutes)
    }

    /// Enabled sources never read yet, or whose interval has passed since `lastRead`.
    /// Timers drift, so a source is due up to 30 seconds early rather than a whole tick late.
    /// A read after `now` means the clock was set back since: that source is due too, rather
    /// than waiting for the clock to catch up.
    public static func dueSources(
        _ sources: [SourceConfig],
        lastRead: [UUID: Date],
        defaultMinutes: Int,
        now: Date
    ) -> Set<UUID> {
        Set(sources.filter { source in
            guard source.isEnabled else { return false }
            guard let last = lastRead[source.id], last <= now else { return true }
            let seconds = TimeInterval(interval(for: source, defaultMinutes: defaultMinutes) * 60)
            return now.timeIntervalSince(last) >= seconds - 30
        }.map(\.id))
    }

    /// The sources a sync left unread, out of `previous`, that a sync reading only `read`
    /// says nothing about: still there, still enabled, and not read this time. Their problem
    /// stands until they're read again; a sync of the other calendars mustn't clear it.
    public static func stillUnread(_ previous: [UUID], read: Set<UUID>, sources: [SourceConfig]) -> Set<UUID> {
        let enabled = Set(sources.filter(\.isEnabled).map(\.id))
        return Set(previous).subtracting(read).intersection(enabled)
    }
}
