import CalendarHubCore
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
        guard let source = settings.source(forCopiesOf: originID) else { return nil }
        return of(source, settings: settings, eventKit: eventKit)
    }

    /// A secondary calendar's name and color: the color chosen for it in Settings, else
    /// Calendar.app's, or for Outlook on the web the name given in Settings and one of the
    /// fallback colors.
    @MainActor
    static func of(_ source: SourceConfig, settings: SettingsStore, eventKit: EventKitBridge) -> EventOrigin {
        let origin = withoutChosenColor(source, settings: settings, eventKit: eventKit)
        guard let chosen = source.color.flatMap(HexColor.init) else { return origin }
        return EventOrigin(name: origin.name, color: Color(chosen))
    }

    /// `of(_:settings:eventKit:)` as it would be with no color chosen in Settings: what
    /// "Use default color" goes back to.
    @MainActor
    static func withoutChosenColor(_ source: SourceConfig, settings: SettingsStore, eventKit: EventKitBridge) -> EventOrigin {
        if case .eventKit(let calendarID) = source.kind, let calendar = eventKit.calendar(id: calendarID) {
            return EventOrigin(name: calendar.title, color: Color(cgColor: calendar.cgColor))
        }
        let index = settings.sources.firstIndex(where: { $0.id == source.id }) ?? 0
        return EventOrigin(name: source.name ?? source.calendarName,
                           color: fallbackColors[index % fallbackColors.count])
    }
}

extension Color {
    init(_ hex: HexColor) {
        self.init(.sRGB, red: hex.red, green: hex.green, blue: hex.blue)
    }
}

extension HexColor {
    /// The color in sRGB, without its opacity. Nil for a color that can't be put in sRGB.
    init?(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
    }
}
