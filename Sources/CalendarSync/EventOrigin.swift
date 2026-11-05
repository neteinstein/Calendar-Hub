import CalendarSyncCore
import SwiftUI

/// The calendar a main-calendar event came from, as the menu and the alert show it: its name
/// and color.
struct EventOrigin: Hashable {
    let name: String
    let color: Color

    /// Soft colors for secondary calendars without one of their own (Outlook on the web).
    static let fallbackColors: [Color] = [.teal, .orange, .pink, .purple, .green, .blue]

    /// The secondary calendar `event` was copied from, or the main calendar for its own events.
    /// Nil for a copy from a secondary calendar that was removed.
    @MainActor
    static func of(_ event: SourceEvent, settings: SettingsStore, eventKit: EventKitBridge) -> EventOrigin? {
        guard let originID = MenuCalendar.originID(of: event) else {
            return eventKit.calendar(id: settings.targetCalendarID)
                .map { EventOrigin(name: $0.title, color: Color(cgColor: $0.cgColor)) }
        }
        guard let source = settings.sources.first(where: { $0.id == originID }) else { return nil }
        return of(source, settings: settings, eventKit: eventKit)
    }

    /// A secondary calendar's name and color: Calendar.app's, or for Outlook on the web the
    /// name given in Settings and one of the fallback colors.
    @MainActor
    static func of(_ source: SourceConfig, settings: SettingsStore, eventKit: EventKitBridge) -> EventOrigin {
        if case .eventKit(let calendarID) = source.kind, let calendar = eventKit.calendar(id: calendarID) {
            return EventOrigin(name: calendar.title, color: Color(cgColor: calendar.cgColor))
        }
        let index = settings.sources.firstIndex(where: { $0.id == source.id }) ?? 0
        return EventOrigin(name: source.name ?? source.calendarName,
                           color: fallbackColors[index % fallbackColors.count])
    }
}
