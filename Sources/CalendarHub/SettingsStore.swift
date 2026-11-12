import CalendarHubCore
import Foundation

/// User settings, saved to UserDefaults as JSON.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var sources: [SourceConfig] { didSet { save(sources, "sources") } }
    @Published var options: SyncOptions { didSet { save(options, "options") } }
    @Published var alerts: EventAlertOptions { didSet { save(alerts, "alerts") } }
    /// The menu's Month view. On until turned off.
    @Published var menuShowsMonth: Bool { didSet { defaults.set(menuShowsMonth, forKey: "menuShowsMonth") } }
    /// The menu's List view, a scrolling list of events. On until turned off.
    @Published var menuShowsList: Bool { didSet { defaults.set(menuShowsList, forKey: "menuShowsList") } }
    /// What the icon shows next to today's date while the menu shows a calendar.
    @Published var menuBar: MenuBarOptions { didSet { save(menuBar, "menuBar") } }
    /// How the menu's month view lays out a week.
    @Published var menuCalendar: MenuCalendarOptions { didSet { save(menuCalendar, "menuCalendar") } }
    /// The menu's Tasks view, where tasks are kept, and the nudges new tasks get.
    @Published var taskOptions: TaskOptions { didSet { save(taskOptions, "taskOptions") } }
    /// The menu's World Clocks view and its cities.
    @Published var worldClocks: WorldClockOptions { didSet { save(worldClocks, "worldClocks") } }
    @Published var targetCalendarID: String? { didSet { defaults.set(targetCalendarID, forKey: "targetCalendarID") } }
    @Published var intervalMinutes: Int { didSet { defaults.set(intervalMinutes, forKey: "intervalMinutes") } }
    /// The main calendar is also shown as Busy in the secondary calendars, in each one whose
    /// `showBusyInSecondary` is on.
    @Published var twoWaySync: Bool { didSet { defaults.set(twoWaySync, forKey: "twoWaySync") } }
    /// While syncing both ways, Outlook on the web calendars get Busy events too, written
    /// through Outlook's own web service. Experimental, so off until turned on.
    @Published var twoWaySyncOutlookWeb: Bool {
        didSet { defaults.set(twoWaySyncOutlookWeb, forKey: "twoWaySyncOutlookWeb") }
    }
    /// Not a setting: the secondary calendars Busy events were added to. Only in these are
    /// events that look like Busy events taken back when they're no longer wanted. Outlook on
    /// the web calendars are in it as `outlookBusyKey(_:)`.
    var busyCalendarIDs: Set<String> {
        didSet { if busyCalendarIDs != oldValue { defaults.set(busyCalendarIDs.sorted(), forKey: "busyCalendarIDs") } }
    }
    /// Not a setting: whether the alerts on Busy events saved by older versions were taken off.
    /// Done once, so a calendar that adds its default alerts back isn't rewritten on every sync.
    var busyAlertsCleared: Bool {
        didSet { if busyAlertsCleared != oldValue { defaults.set(busyAlertsCleared, forKey: "busyAlertsCleared") } }
    }

    /// Sources not set up here whose copies the user chose to keep (another Mac's, say), so
    /// they aren't offered for removal again.
    @Published var keptOrphanSourceIDs: Set<UUID> {
        didSet {
            if keptOrphanSourceIDs != oldValue {
                defaults.set(keptOrphanSourceIDs.map(\.uuidString).sorted(), forKey: "keptOrphanSourceIDs")
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let sources = Self.load([SourceConfig].self, "sources", defaults) ?? []
        self.sources = sources
        options = Self.load(SyncOptions.self, "options", defaults) ?? SyncOptions()
        alerts = Self.load(EventAlertOptions.self, "alerts", defaults) ?? EventAlertOptions()
        menuShowsMonth = defaults.object(forKey: "menuShowsMonth") as? Bool ?? true
        menuShowsList = defaults.object(forKey: "menuShowsList") as? Bool ?? true
        menuBar = Self.load(MenuBarOptions.self, "menuBar", defaults) ?? MenuBarOptions()
        menuCalendar = Self.load(MenuCalendarOptions.self, "menuCalendar", defaults) ?? MenuCalendarOptions()
        taskOptions = Self.load(TaskOptions.self, "taskOptions", defaults) ?? TaskOptions()
        worldClocks = Self.load(WorldClockOptions.self, "worldClocks", defaults) ?? WorldClockOptions()
        targetCalendarID = defaults.string(forKey: "targetCalendarID")
        let interval = defaults.integer(forKey: "intervalMinutes")
        intervalMinutes = interval > 0 ? interval : 15
        // Older versions had only the per-calendar choice; keep the calendars that made it.
        twoWaySync = defaults.object(forKey: "twoWaySync") as? Bool ?? sources.contains(where: \.showBusyInSecondary)
        twoWaySyncOutlookWeb = defaults.bool(forKey: "twoWaySyncOutlookWeb")
        busyCalendarIDs = Set(defaults.stringArray(forKey: "busyCalendarIDs") ?? [])
        busyAlertsCleared = defaults.bool(forKey: "busyAlertsCleared")
        keptOrphanSourceIDs = Set((defaults.stringArray(forKey: "keptOrphanSourceIDs") ?? []).compactMap(UUID.init(uuidString:)))
    }

    /// The menu shows Month or List, and the menu bar icon today's date.
    var menuShowsCalendar: Bool { menuShowsMonth || menuShowsList }

    /// The menu has at least one view: Month, List, Tasks, World Clocks or Stats.
    var menuHasViews: Bool {
        menuShowsCalendar || taskOptions.showsInMenu || worldClocks.showsInMenu || menuCalendar.showsMeetingStats
    }

    /// How an Outlook on the web calendar is kept in `busyCalendarIDs`.
    static func outlookBusyKey(_ sourceID: UUID) -> String {
        "outlookWeb:" + sourceID.uuidString
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
