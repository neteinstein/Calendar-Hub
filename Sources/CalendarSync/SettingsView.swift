import CalendarSyncCore
import EventKit
import ServiceManagement
import SwiftUI

/// Settings, one pane per part of the app, picked from a sidebar.
struct SettingsView: View {
    @EnvironmentObject private var controller: SyncController
    /// The pane shown, kept between openings. The menu sets it to open Settings at a given pane.
    @AppStorage(SettingsPane.defaultsKey) private var pane: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(get: { pane }, set: { if let picked = $0 { pane = picked } })) { pane in
                HStack(spacing: 4) {
                    Label {
                        Text(pane.title)
                    } icon: {
                        Image(systemName: pane.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(pane.color.gradient, in: RoundedRectangle(cornerRadius: 5))
                    }
                    Spacer(minLength: 0)
                    // The secondary calendars the last sync couldn't read.
                    if pane == .calendars, !controller.unreadSources.isEmpty {
                        ProblemBadge(count: controller.unreadSources.count)
                    }
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(215)
            // Wide enough for "Secondary Calendars" wherever the split view sizes the sidebar.
            .frame(minWidth: 215)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            pane.content
                .navigationTitle(pane.title)
        }
        .frame(width: 780, height: 540)
        .toggleStyle(AccentSwitchStyle())
        // Not while rendering the README's screenshots, which must leave the user's app in front.
        .onAppear { if Snapshots.folder == nil { NSApp.activate(ignoringOtherApps: true) } }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, calendars, twoWaySync, menuBar, alerts, tasks, worldClocks, preview, about

    /// Where the shown pane is kept.
    static let defaultsKey = "settingsPane"

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .calendars: "Secondary Calendars"
        case .twoWaySync: "Two way sync"
        case .menuBar: "Menu bar"
        case .alerts: "Meeting alerts"
        case .tasks: "Tasks"
        case .worldClocks: "World Clocks"
        case .preview: "Preview"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .calendars: "calendar"
        case .twoWaySync: "arrow.left.arrow.right"
        case .menuBar: "menubar.rectangle"
        case .alerts: "bell.fill"
        case .tasks: "checklist"
        case .worldClocks: "globe"
        case .preview: "eye.fill"
        case .about: "info"
        }
    }

    var color: Color {
        switch self {
        case .general, .about: .gray
        case .calendars: .blue
        case .twoWaySync: .teal
        case .menuBar: .purple
        case .alerts: .red
        case .tasks: .green
        case .worldClocks: .indigo
        case .preview: .orange
        }
    }

    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .general: GeneralTab()
        case .calendars: SourcesTab()
        case .twoWaySync: TwoWaySyncTab()
        case .menuBar: MenuBarTab()
        case .alerts: AlertsTab()
        case .tasks: TasksTab()
        case .worldClocks: WorldClocksTab()
        case .preview: PreviewTab()
        case .about: AboutTab()
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            UpdateBanner()

            Section {
                Picker("Main calendar", selection: $settings.targetCalendarID) {
                    Text("Choose a calendar…").tag(String?.none)
                    ForEach(controller.eventKit.calendars().filter(\.allowsContentModifications), id: \.calendarIdentifier) { calendar in
                        CalendarLabel(calendar: calendar).tag(Optional(calendar.calendarIdentifier))
                    }
                }
                .onChange(of: settings.targetCalendarID) { _, _ in Task { await controller.sync() } }
                if !controller.hasCalendarAccess {
                    Text("Calendar Sync doesn't have calendar access. Allow it in System Settings › Privacy & Security › Calendars.")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Main calendar")
            } footer: {
                Text("Meetings from your secondary calendars are copied into this calendar. It must be added to Calendar.app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Stepper("Today plus the next \(settings.options.daysAhead) days",
                        value: $settings.options.daysAhead, in: 0...30)
                IntervalField(label: "Sync every", minutes: $settings.intervalMinutes)
            } header: {
                Text("Syncing")
            } footer: {
                Text("Each secondary calendar can use its own interval instead (Secondary Calendars). Calendar.app calendars also sync about 10 seconds after a change.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("What's copied") {
                Toggle("Skip meetings I declined", isOn: $settings.options.skipDeclined)
                Toggle("Skip all-day events", isOn: $settings.options.skipAllDay)
                Toggle("Skip out-of-office events", isOn: $settings.options.skipOutOfOffice)
            }

            Section("Startup") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Menu bar

private struct MenuBarTab: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Show a calendar in the menu", isOn: $settings.menuCalendarEnabled)
                if settings.menuCalendarEnabled {
                    Toggle("Show the week day in the menu bar", isOn: $settings.menuBar.showsWeekday)
                }
                Toggle("Show the next meeting in the menu bar", isOn: $settings.menuBar.showsNextMeeting)
                // Off and greyed out until the meeting is shown: the bar sits under its title.
                Toggle("Show the meeting's progress under its title", isOn: Binding(
                    get: { settings.menuBar.drawsMeetingProgress },
                    set: { settings.menuBar.showsMeetingProgress = $0 }
                ))
                .disabled(!settings.menuBar.showsNextMeeting)
            } header: {
                Text("Menu bar")
            } footer: {
                Text("The menu bar button opens a month view — click a day for its events — or a scrolling list of your main calendar's events, and the menu bar icon shows today's date, with the week day next to it when that's on. With the next meeting on, from 15 minutes before a meeting until it ends, its title and the minutes left take the date's place, and with the progress on, a bar under them fills as the meeting runs.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if settings.menuCalendarEnabled {
                Section("Menu calendar") {
                    Picker("Week starts on", selection: $settings.menuCalendar.weekStart) {
                        Text("Same as macOS").tag(MenuCalendarOptions.WeekStart.system)
                        Text("Sunday").tag(MenuCalendarOptions.WeekStart.sunday)
                        Text("Monday").tag(MenuCalendarOptions.WeekStart.monday)
                    }
                    Toggle("Show weekends in the month view", isOn: $settings.menuCalendar.showsWeekends)
                    Toggle("Shade all-day events", isOn: $settings.menuCalendar.shadesAllDay)
                    Toggle("Color events by the calendar they came from", isOn: $settings.menuCalendar.colorsByCalendar)
                    Toggle("Show mornings and afternoons as colored blocks", isOn: $settings.menuCalendar.shadesTimeOfDay)
                }

                Section {
                    Toggle("Show Meeting Stats in the menu", isOn: $settings.menuCalendar.showsMeetingStats)
                    if settings.menuCalendar.showsMeetingStats {
                        LabeledContent("Working hours") {
                            HStack(spacing: 4) {
                                WorkingHoursPicker(hours: $settings.menuCalendar.workingHours)
                            }
                        }
                    }
                } header: {
                    Text("Meeting Stats")
                } footer: {
                    Text("Adds a Stats view to the menu with the hours you spend in meetings, measured against your working hours.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// From and to, in half hours: the working day Meeting Stats and World Clocks use.
private struct WorkingHoursPicker: View {
    @Binding var hours: WorkingHours

    var body: some View {
        timePicker($hours.start, in: 0..<hours.end)
        Text("to")
        timePicker($hours.end, in: (hours.start + 30)..<(24 * 60 + 1))
    }

    /// A time of day in half hours, from the times in `range` (minutes after midnight).
    private func timePicker(_ minutes: Binding<Int>, in range: Range<Int>) -> some View {
        Picker("", selection: minutes) {
            ForEach(Array(stride(from: range.lowerBound, to: range.upperBound, by: 30)), id: \.self) { time in
                Text(WorkingHours.text(time)).tag(time)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - Meeting alerts

private struct AlertsTab: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Show a full-screen alert when an event starts", isOn: $settings.alerts.enabled)
                if settings.alerts.enabled {
                    Stepper(settings.alerts.leadMinutes == 0
                            ? "Show it when the event starts"
                            : "Show it \(settings.alerts.leadMinutes) \(settings.alerts.leadMinutes == 1 ? "minute" : "minutes") before the start",
                            value: $settings.alerts.leadMinutes, in: 0...15)
                }
            } footer: {
                Text("Covers the screen when a meeting in your main calendar begins, with buttons to join the call, go to the room, ignore it, or be reminded a minute later. Each meeting alerts once; a meeting already under way alerts until it ends.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if settings.alerts.enabled {
                Section("What it looks like") {
                    AlertSketch(leadMinutes: settings.alerts.leadMinutes)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A small drawing of the full-screen alert: the card over a blurred desktop.
private struct AlertSketch: View {
    let leadMinutes: Int

    var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo.opacity(0.5), .teal.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Main calendar").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.accentColor)
                    Spacer()
                    Text(leadMinutes == 0 ? "Starting now" : "Starts in \(leadMinutes):00")
                        .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                }
                Text("Meeting name").font(.system(size: 15, weight: .bold))
                Text("10:00 – 10:30 · Room").font(.system(size: 9)).foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    Capsule().fill(Color.accentColor).frame(width: 64, height: 16)
                        .overlay(Text("Join call").font(.system(size: 8, weight: .semibold)).foregroundStyle(.white))
                    Capsule().fill(.primary.opacity(0.1)).frame(width: 58, height: 16)
                    Spacer()
                    Text("Ignore").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.top, 3)
            }
            .padding(12)
            .frame(width: 250)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
}

// MARK: - Tasks

private struct TasksTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController
    @EnvironmentObject private var tasks: TaskStore

    var body: some View {
        Form {
            Section {
                Toggle("Show Tasks in the menu", isOn: $settings.taskOptions.showsInMenu)
                if !settings.menuCalendarEnabled {
                    Text("Turn on Show a calendar in the menu (Menu bar) to see it.")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("Adds a Tasks view to the menu, next to List, for tasks and reminders, and shows each day's tasks in Month and List. Right-click a meeting in the List for a task to prepare it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if tasks.access == .fullAccess {
                    Picker("Keep tasks in", selection: $settings.taskOptions.listID) {
                        Text(defaultListName).tag(String?.none)
                        ForEach(controller.eventKit.reminderLists(), id: \.calendarIdentifier) { list in
                            CalendarLabel(calendar: list).tag(Optional(list.calendarIdentifier))
                        }
                    }
                } else {
                    LabeledContent("Calendar Sync can't see your reminders") {
                        Button(tasks.access == .notDetermined ? "Allow Access" : "Open System Settings") {
                            if tasks.access == .notDetermined {
                                Task { await tasks.requestAccess() }
                            } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            } header: {
                Text("Reminders")
            } footer: {
                Text("Each task is a reminder in this list, so it's on your iPhone and other devices too, and stays in Reminders if you remove Calendar Sync. A task for an event links to it, and moves with it when the event moves.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                nudgePicker("For an event", selection: $settings.taskOptions.eventNudge, forEvent: true)
                nudgePicker("With a due date", selection: $settings.taskOptions.dueNudge, forEvent: false)
            } header: {
                Text("Nudges for new tasks")
            } footer: {
                Text("Nudges are the reminder's alerts: Reminders shows them as notifications on all your devices, even while Calendar Sync isn't running. Each task can have its own, set in the task.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await tasks.reload() }
    }

    /// "Default list (Reminders)", naming the list Reminders adds new reminders to.
    private var defaultListName: String {
        guard tasks.access == .fullAccess, let list = controller.eventKit.reminderList(id: nil) else { return "Default list" }
        return "Default list (\(list.title))"
    }

    private func nudgePicker(_ title: String, selection: Binding<Nudge?>, forEvent: Bool) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag(Nudge?.none)
            ForEach(Nudge.presets(anchorHasTime: true), id: \.self) { nudge in
                Text(nudge.title(forEvent: forEvent) ?? "").tag(Optional(nudge))
            }
        }
    }
}

// MARK: - World Clocks

private struct WorldClocksTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var query = ""

    var body: some View {
        Form {
            Section {
                Toggle("Show World Clocks in the menu", isOn: $settings.worldClocks.showsInMenu)
                if settings.worldClocks.showsInMenu && !settings.menuCalendarEnabled {
                    Text("Turn on Show a calendar in the menu (Menu bar) to see it.")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("Adds a World Clocks view to the menu, before Stats: the time here and in each city below, green while it's working time there, and a chart of today showing when everyone's at work. Type a time, or drag across the chart, to see it on every clock.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Working hours") {
                    HStack(spacing: 4) {
                        WorkingHoursPicker(hours: $settings.menuCalendar.workingHours)
                    }
                }
            } footer: {
                Text("Yours, Monday to Friday, and the same as Meeting Stats uses. Every city below works them too, in its own time, until you give it its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HereRow(name: localName, timeZone: .current)
                ForEach($settings.worldClocks.clocks) { $clock in
                    CityRow(clock: $clock,
                            sharedHours: settings.menuCalendar.workingHours,
                            isFirst: clock.id == settings.worldClocks.clocks.first?.id,
                            isLast: clock.id == settings.worldClocks.clocks.last?.id,
                            move: { offset in move(clock.id, by: offset) },
                            remove: { settings.worldClocks.clocks.removeAll { $0.id == clock.id } })
                }
                TextField("Add a city", text: $query, prompt: Text("Search for a city, a country or a time zone, such as Tokyo, Brazil or PST"))
                ForEach(results, id: \.timeZoneID) { place in
                    Button {
                        settings.worldClocks.clocks.append(WorldClock(name: place.city, timeZoneID: place.timeZoneID))
                        query = ""
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                            Text(place.city)
                            Text(place.countryName()).foregroundStyle(.secondary)
                            Spacer()
                            Text(Date().formatted(Date.FormatStyle(date: .omitted, time: .shortened,
                                                                   timeZone: TimeZone(identifier: place.timeZoneID) ?? .current)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Cities")
            } footer: {
                Text("A country gives a city for each of its time zones. Each city has its time zone's name until you rename it: a city that shares a time zone, such as San Francisco with Los Angeles, can be added that way. Where you are can be renamed too, and keeps that name while your Mac is in that time zone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The name given to where we are in the current time zone; empty for its time zone's city.
    private var localName: Binding<String> {
        let id = TimeZone.current.identifier
        return Binding(get: { settings.worldClocks.localNames[id] ?? "" },
                       set: { settings.worldClocks.localNames[id] = $0.isEmpty ? nil : $0 })
    }

    /// The cities matching the search, less those already added.
    private var results: [WorldClocks.Place] {
        let added = Set(settings.worldClocks.clocks.map(\.timeZoneID))
        return WorldClocks.search(query, limit: 20).filter { !added.contains($0.timeZoneID) }.prefix(8).map { $0 }
    }

    private func move(_ id: UUID, by offset: Int) {
        var clocks = settings.worldClocks.clocks
        guard let index = clocks.firstIndex(where: { $0.id == id }), clocks.indices.contains(index + offset) else { return }
        clocks.swapAt(index, index + offset)
        settings.worldClocks.clocks = clocks
    }
}

/// Where we are, first in the World Clocks list: its name, which can be changed, and its time zone
/// and time.
private struct HereRow: View {
    @Binding var name: String
    let timeZone: TimeZone

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "location.fill").foregroundStyle(.secondary)
            TextField("Name of where you are", text: $name, prompt: Text(WorldClocks.cityName(of: timeZone.identifier)))
                .labelsHidden()
                .textFieldStyle(.plain)
                .fontWeight(.medium)
                .help("Click to rename where you are")
            Text("\(timeZone.identifier.replacingOccurrences(of: "_", with: " ")) · Here")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(Date().formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: timeZone)))
                .monospacedDigit()
        }
    }
}

/// A city in the World Clocks list: its name, which can be changed, its time zone and time,
/// buttons to move it and remove it, and its working hours, ours or its own.
private struct CityRow: View {
    @Binding var clock: WorldClock
    /// Our working hours, which the city works until it has its own.
    let sharedHours: WorkingHours
    let isFirst: Bool
    let isLast: Bool
    let move: (Int) -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            nameLine
            hoursLine
        }
    }

    /// "Its own working hours", and what they are: ours, or the pickers to set them.
    private var hoursLine: some View {
        HStack(spacing: 4) {
            Toggle("Its own working hours", isOn: Binding(
                get: { clock.workingHours != nil },
                set: { clock.workingHours = $0 ? sharedHours : nil }))
                .toggleStyle(.checkbox)
            Spacer(minLength: 8)
            if clock.workingHours != nil {
                WorkingHoursPicker(hours: Binding(get: { clock.workingHours ?? sharedHours },
                                                  set: { clock.workingHours = $0 }))
            } else {
                Text("\(WorkingHours.text(sharedHours.start)) to \(WorkingHours.text(sharedHours.end)), the same as yours")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.leading, 24)
    }

    private var nameLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe").foregroundStyle(.secondary)
            TextField("Name", text: $clock.name)
                .labelsHidden()
                .textFieldStyle(.plain)
                .fontWeight(.medium)
                .help("Click to rename")
            Text("\(clock.timeZoneID.replacingOccurrences(of: "_", with: " ")) · \(WorldClocks.offsetText(clock.timeZone, from: .current, at: Date()))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(Date().formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: clock.timeZone)))
                .monospacedDigit()
            Button { move(-1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(isFirst).help("Move up")
            Button { move(1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(isLast).help("Move down")
            Button(action: remove) { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                .buttonStyle(.borderless).help("Remove \(clock.name)")
        }
    }
}

// MARK: - Sources

private struct SourcesTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController
    @State private var showingLinkSheet = false
    @State private var showingOutlookNameSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if settings.sources.isEmpty {
                ContentUnavailableView(
                    "No secondary calendars yet",
                    systemImage: "calendar.badge.plus",
                    description: Text("Add a secondary calendar to start copying its meetings."))
            } else {
                Form {
                    UnreadSourcesSection()
                    ForEach($settings.sources) { $source in
                        SourceRow(source: $source)
                    }
                }
                .formStyle(.grouped)
            }

            HStack {
                Menu("Add secondary calendar") {
                    Section("From Calendar.app") {
                        ForEach(availableCalendars, id: \.calendarIdentifier) { calendar in
                            Button(calendar.source.map { "\(calendar.title) (\($0.title))" } ?? calendar.title) {
                                settings.sources.append(SourceConfig(
                                    kind: .eventKit(calendarID: calendar.calendarIdentifier),
                                    calendarName: calendar.title,
                                    showBusyInSecondary: settings.twoWaySync && calendar.allowsContentModifications))
                            }
                        }
                    }
                    Section("Not in Calendar.app") {
                        Button("Outlook on the web (sign in)…") { showingOutlookNameSheet = true }
                        Button("Calendar link (.ics)…") { showingLinkSheet = true }
                    }
                }
                .fixedSize()
                Spacer()
            }
            .padding()
        }
        .sheet(isPresented: $showingLinkSheet) { CalendarLinkSheet() }
        .sheet(isPresented: $showingOutlookNameSheet) {
            // Named first, so the sign-in window and the copies go by that name from the start.
            CalendarNameSheet(
                title: "Add Outlook on the web",
                message: "What do you call this calendar? It's also the prefix for its copies, like “[Work] Standup”, which you can change later.",
                confirm: "Continue"
            ) { name in
                // Names hidden from the start: a browser-only work calendar is the one whose
                // organization is least likely to expect its meeting names on another server.
                let source = SourceConfig(
                    kind: .outlookWeb, calendarName: name, name: name, hideMeetingName: true,
                    showBusyInSecondary: settings.twoWaySync && settings.twoWaySyncOutlookWeb)
                settings.sources.append(source)
                controller.showOutlookWindow(for: source)
            }
        }
    }

    private var availableCalendars: [EKCalendar] {
        let used = Set(settings.sources.compactMap { source -> String? in
            if case .eventKit(let id) = source.kind { return id } else { return nil }
        })
        return controller.eventKit.calendars().filter {
            !used.contains($0.calendarIdentifier) && $0.calendarIdentifier != settings.targetCalendarID
        }
    }
}

/// A red warning badge with a count: things to check, in the sidebar.
private struct ProblemBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("\(count)")
        }
        .font(.system(size: 10.5, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.red, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
        .help(count == 1 ? "A secondary calendar wasn't read" : "\(count) secondary calendars weren't read")
        .accessibilityLabel(count == 1 ? "1 calendar needs attention" : "\(count) calendars need attention")
    }
}

/// The secondary calendars the last sync couldn't read, at the top of Secondary Calendars, so
/// they're seen without scrolling to them. Each with its fix when there is one.
private struct UnreadSourcesSection: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController

    var body: some View {
        if !controller.unreadSources.isEmpty {
            Section {
                ForEach(controller.unreadSources) { unread in
                    let source = settings.sources.first { $0.id == unread.id }
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(source.map { $0.name ?? $0.calendarName } ?? unread.name) wasn't read")
                                .fontWeight(.semibold)
                            Text(unread.reason + (unread.reason.hasSuffix(".") ? "" : ".") + " Its copies are left as they are.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if let source, source.kind == .outlookWeb {
                            Button("Open Outlook") { controller.showOutlookWindow(for: source) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Label("Needs attention", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct SourceRow: View {
    @Binding var source: SourceConfig
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController
    @State private var renaming = false

    /// Calendar.app sources use the calendar's current name; Outlook web sources use the typed one.
    private var displayName: String {
        if case .eventKit(let calendarID) = source.kind, let calendar = controller.eventKit.calendar(id: calendarID) {
            return calendar.title
        }
        return source.calendarName
    }

    /// A copy's title as CopyFormatter builds it: no brackets when the name is empty.
    private func copyTitle(_ meeting: String) -> String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? meeting : "[\(name)] \(meeting)"
    }

    var body: some View {
        Section {
            health
            if source.kind == .outlookWeb {
                // Bordered and named after what it changes: as a plain form row it read as a fixed value.
                TextField("Prefix for copies", text: $source.calendarName, prompt: Text("e.g. Work"))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 240)
                    // The value is saved as it's typed; Return just leaves the field.
                    .onSubmit { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
            Toggle("Hide meeting names (copy as “\(copyTitle("Busy"))”)", isOn: $source.hideMeetingName)
            Toggle("Copy the meeting link (Join from the main calendar)", isOn: $source.copyMeetingLink)
            Toggle("Copy location and description", isOn: $source.copyDetails)
                .disabled(source.hideMeetingName)
            Toggle("Copy meetings I haven't accepted", isOn: $source.copyUnaccepted)
            Toggle("Use its own sync interval", isOn: Binding(
                get: { source.intervalMinutes != nil },
                set: { source.intervalMinutes = $0 ? settings.intervalMinutes : nil }))
            if source.intervalMinutes != nil {
                IntervalField(label: "Sync this calendar every", minutes: Binding(
                    get: { source.intervalMinutes ?? settings.intervalMinutes },
                    set: { source.intervalMinutes = $0 }))
            }
            HStack {
                if source.kind == .outlookWeb {
                    Button("Open Outlook window") { controller.showOutlookWindow(for: source) }
                }
                Spacer()
                Button("Remove", role: .destructive) {
                    if source.kind == .outlookWeb { controller.forgetOutlookSession(for: source.id) }
                    let id = source.id
                    // Removed on the next run loop so SwiftUI isn't still reading this row's binding.
                    DispatchQueue.main.async { settings.sources.removeAll { $0.id == id } }
                }
            }
        } header: {
            // Whether it syncs at all sits with the calendar's name, apart from how it syncs.
            HStack {
                switch source.kind {
                case .eventKit(let calendarID):
                    if let calendar = controller.eventKit.calendar(id: calendarID) {
                        CalendarLabel(calendar: calendar)
                    } else {
                        Label("Calendar no longer in Calendar.app", systemImage: "exclamationmark.triangle")
                    }
                case .outlookWeb:
                    HStack(spacing: 6) {
                        Label(outlookTitle, systemImage: "globe")
                        Button { renaming = true } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                            .help("Rename")
                    }
                    .sheet(isPresented: $renaming) {
                        CalendarNameSheet(
                            title: "Rename calendar",
                            message: "The name shown for this calendar here. The prefix for its copies doesn't change.",
                            confirm: "Rename", name: source.name ?? ""
                        ) { name in
                            source.name = name
                        }
                    }
                }
                Spacer()
                // At its own width: the switch style puts a spacer between label and switch,
                // which would otherwise take up the header's free space.
                Toggle("Sync this calendar", isOn: $source.isEnabled)
                    .fixedSize()
            }
        } footer: {
            Text(footer).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// How the last sync went for this calendar: when it was read and how many copies it has,
    /// or why it wasn't read, with the fix for a signed-out Outlook calendar.
    @ViewBuilder
    private var health: some View {
        let unread = controller.unreadSources.first { $0.id == source.id }
        let status = controller.sourceStatus[source.id]
        HStack(spacing: 6) {
            if !source.isEnabled {
                Circle().fill(.secondary).frame(width: 6, height: 6)
                Text("Not syncing").foregroundStyle(.secondary)
            } else if let unread {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(unread.reason).foregroundStyle(.orange).lineLimit(2)
                Spacer()
                if source.kind == .outlookWeb {
                    Button("Open Outlook") { controller.showOutlookWindow(for: source) }
                        .controlSize(.small)
                }
            } else if let lastRead = status?.lastRead {
                Circle().fill(.green).frame(width: 6, height: 6)
                (Text("Synced ") + Text(lastRead, format: .relative(presentation: .named))
                    + Text(" · \(status?.copies ?? 0) \(status?.copies == 1 ? "copy" : "copies")"))
                    .foregroundStyle(.secondary)
                    .help("Copies in your main calendar from today to the end of the days synced ahead")
            } else {
                Circle().fill(.secondary).frame(width: 6, height: 6)
                Text("Not read yet").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }

    /// "Sainsbury's – Outlook on the web": the name given when it was added, then the kind of
    /// calendar. "N/A" for calendars added before names were asked for.
    private var outlookTitle: String {
        "\(source.name ?? "N/A") – Outlook on the web"
    }

    private var footer: String {
        var text = "Copies are titled “\(copyTitle(source.hideMeetingName ? "Busy" : "Meeting name"))”"
        text += source.copyMeetingLink
            ? " and include the meeting link when there is one."
            : " without the meeting link, so Join isn't offered for them. A Teams link names the organization and the organizer, and a Zoom link can carry the passcode."
        if source.copyDetails {
            text += source.hideMeetingName
                ? " Location and description aren't copied while meeting names are hidden."
                : " The location and description are copied too."
        }
        if !source.copyUnaccepted {
            text += " Meetings you haven't answered, accepted tentatively or declined aren't copied."
        }
        let minutes = SyncSchedule.interval(for: source, defaultMinutes: settings.intervalMinutes)
        text += " Synced every \(minutes) \(minutes == 1 ? "minute" : "minutes")"
        if case .eventKit = source.kind { text += " and about 10 seconds after a change" }
        return text + "."
    }
}

// MARK: - Two way sync

/// Pushes the main calendar into the secondary calendars, as Busy events with no other details.
private struct TwoWaySyncTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController

    var body: some View {
        Form {
            Section {
                Toggle("Sync both ways", isOn: $settings.twoWaySync)
                    .onChange(of: settings.twoWaySync) { _, on in
                        if on { showBusyInEverySecondaryIfNoneChosen() }
                        Task { await controller.sync() }
                    }
            } footer: {
                Text("Your main calendar's events are also added to your secondary calendars as “Busy”, with nothing else: no title, link, location, attendees or alerts. Their description says “Busy” and carries a code, the same for the whole calendar, so the app never mistakes an event you made for one of its own. Nothing in them names Calendar Sync or the meeting. Copies of a calendar's own meetings aren't added back to it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if settings.twoWaySync {
                if settings.sources.isEmpty {
                    Section {
                        Text("Add a secondary calendar in Secondary Calendars first.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach($settings.sources) { $source in
                    if case .eventKit(let calendarID) = source.kind {
                        BusyRow(source: $source, calendarID: calendarID)
                    }
                }
                if settings.sources.contains(where: { $0.kind == .outlookWeb }) {
                    Section {
                        Toggle(isOn: $settings.twoWaySyncOutlookWeb) {
                            HStack(spacing: 6) {
                                Text("Also sync Outlook on the web calendars")
                                ExperimentalBadge()
                            }
                        }
                            .onChange(of: settings.twoWaySyncOutlookWeb) { _, on in
                                if on { showBusyInEveryOutlookIfNoneChosen() }
                                Task { await controller.sync() }
                            }
                    } header: {
                        HStack(spacing: 6) {
                            Text("Outlook on the web")
                            ExperimentalBadge()
                        }
                    } footer: {
                        Text("Busy events are saved through Outlook's own web service, the way Outlook on the web saves an event you make: no invitations go out and no reminder is set. They're updated each time the calendar is read, on its sync interval, and removed ones go to Deleted Items. This depends on how Outlook works inside, which Microsoft can change without notice, and writing to a work calendar this way may go against its organization's IT policy, so check with them first.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if settings.twoWaySyncOutlookWeb {
                        ForEach($settings.sources) { $source in
                            if source.kind == .outlookWeb {
                                BusyRow(source: $source, calendarID: nil)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Turned on before any secondary calendar was chosen: choose every one Busy events can be
    /// added to. Choices made earlier are kept. Outlook on the web calendars have their own
    /// toggle (`showBusyInEveryOutlookIfNoneChosen`).
    private func showBusyInEverySecondaryIfNoneChosen() {
        guard !settings.sources.contains(where: { $0.kind != .outlookWeb && $0.showBusyInSecondary }) else { return }
        settings.sources = settings.sources.map { source in
            var source = source
            if case .eventKit(let calendarID) = source.kind,
               controller.eventKit.calendar(id: calendarID)?.allowsContentModifications == true {
                source.showBusyInSecondary = true
            }
            return source
        }
    }

    /// Outlook on the web turned on before any Outlook calendar was chosen: choose them all.
    private func showBusyInEveryOutlookIfNoneChosen() {
        let outlook = settings.sources.filter { $0.kind == .outlookWeb }
        guard !outlook.contains(where: \.showBusyInSecondary) else { return }
        settings.sources = settings.sources.map { source in
            var source = source
            if source.kind == .outlookWeb { source.showBusyInSecondary = true }
            return source
        }
    }
}

/// Whether, and as what, the main calendar is shown in one secondary calendar.
private struct BusyRow: View {
    @Binding var source: SourceConfig
    /// Nil for an Outlook on the web calendar.
    let calendarID: String?
    @EnvironmentObject private var controller: SyncController

    var body: some View {
        let calendar = calendarID.flatMap { controller.eventKit.calendar(id: $0) }
        let writable = calendarID == nil || (calendar?.allowsContentModifications ?? false)
        Section {
            Toggle("Show my main calendar here as “\(source.busyStyle.title)”", isOn: $source.showBusyInSecondary)
                .disabled(!writable && !source.showBusyInSecondary)
                .onChange(of: source.showBusyInSecondary) { _, _ in Task { await controller.sync() } }
            if source.showBusyInSecondary {
                Picker("Show it as", selection: $source.busyStyle) {
                    ForEach(BusyStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: source.busyStyle) { _, _ in Task { await controller.sync() } }
            }
            if !writable {
                Text("This calendar is read-only, so Busy events can't be added to it.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !source.isEnabled {
                Text("Syncing this calendar is off, so its Busy events are left as they are.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            if calendarID == nil {
                HStack(spacing: 6) {
                    Label("\(source.calendarName) (Outlook on the web)", systemImage: "globe")
                    ExperimentalBadge()
                }
            } else if let calendar {
                CalendarLabel(calendar: calendar)
            } else {
                Label("Calendar no longer in Calendar.app", systemImage: "exclamationmark.triangle")
            }
        }
    }
}

/// Marks a feature that depends on how another service works inside, which can change
/// without notice.
private struct ExperimentalBadge: View {
    var body: some View {
        Text("Experimental")
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.orange.opacity(0.15)))
            .overlay(Capsule().strokeBorder(.orange.opacity(0.5), lineWidth: 0.5))
            .help("Depends on how Outlook on the web works inside, which Microsoft can change without notice.")
            .accessibilityLabel("Experimental")
    }
}

/// "Sync every [15] minutes": type any value, or step through common ones.
private struct IntervalField: View {
    let label: String
    @Binding var minutes: Int

    private static let steps = [1, 2, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 360, 480, 720, 1440]

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(label, value: $minutes, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Text(minutes == 1 ? "minute" : "minutes")
                Stepper(label, onIncrement: {
                    minutes = Self.steps.first { $0 > minutes } ?? SyncSchedule.maxMinutes
                }, onDecrement: {
                    minutes = Self.steps.last { $0 < minutes } ?? SyncSchedule.minMinutes
                })
                .labelsHidden()
            }
        }
        .onChange(of: minutes) { _, value in
            let clamped = min(max(value, SyncSchedule.minMinutes), SyncSchedule.maxMinutes)
            if clamped != value { minutes = clamped }
        }
    }
}

/// Subscribes to a secondary calendar link through Calendar.app, which then keeps it updated.
/// Asks for a secondary calendar's name: when an Outlook web calendar is added, and to rename it.
private struct CalendarNameSheet: View {
    let title: String
    let message: String
    let confirm: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(title: String, message: String, confirm: String, name: String = "",
         onSave: @escaping (String) -> Void) {
        self.title = title
        self.message = message
        self.confirm = confirm
        self.onSave = onSave
        _name = State(initialValue: name)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name, prompt: Text("e.g. Work"))
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(confirm, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}

private struct CalendarLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a calendar link").font(.headline)
            Text("""
                In Outlook on the web: Settings › Calendar › Shared calendars › Publish a calendar, \
                then copy the ICS link. In Google Calendar: Settings › your calendar › \
                Secret address in iCal format.
                """)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://…/calendar.ics", text: $link)
            Text("Calendar.app will ask how to add it. Once it's added, choose it here under “From Calendar.app”.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Open in Calendar") {
                    if let url = Self.webcalURL(link) { NSWorkspace.shared.open(url) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(Self.webcalURL(link) == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    static func webcalURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "webcal", "webcals"].contains(scheme),
              components.host != nil
        else { return nil }
        components.scheme = "webcal"
        return components.url
    }
}

// MARK: - Preview

/// A scrolling form like the other panes: in the Settings sidebar, a pane without a scroll
/// view of its own left the sidebar blank.
private struct PreviewTab: View {
    @EnvironmentObject private var controller: SyncController

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("See what the next sync would change, without changing anything.")
                    Spacer()
                    Button("Preview") { Task { await controller.sync(apply: false) } }
                        .disabled(controller.isSyncing)
                }
            }
            if let plan = controller.preview {
                Section {
                    Text(plan.isEmpty
                         ? "Nothing to change (\(plan.unchangedCount) copies up to date)."
                         : "\(plan.creates) to add, \(plan.updates) to update, \(plan.deletes) to remove, \(plan.unchangedCount) unchanged.")
                        .foregroundStyle(.secondary)
                    ForEach(controller.busyPreview) { busy in
                        Text("Busy in \(busy.calendarName): \(busy.plan.creates) to add, \(busy.plan.updates) to update, \(busy.plan.deletes) to remove.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(previewRows(plan), id: \.offset) { row in
                        HStack {
                            Text(row.element.action.verb).frame(width: 60, alignment: .leading).foregroundStyle(.secondary)
                            Text(row.element.title)
                            Spacer()
                            Text(row.element.action.start, format: .dateTime.weekday().day().month().hour().minute())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !controller.problems.isEmpty {
                Section {
                    ForEach(controller.problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Main-calendar changes first, then the Busy events per secondary calendar.
    private func previewRows(_ plan: SyncPlan) -> [EnumeratedSequence<[(action: SyncAction, title: String)]>.Element] {
        var rows = plan.actions.map { (action: $0, title: $0.title) }
        for busy in controller.busyPreview {
            rows += busy.plan.actions.map { (action: $0, title: "Busy in \(busy.calendarName)") }
        }
        return Array(rows.enumerated())
    }
}

// MARK: - About

/// In a scroll view, like the other panes: without one, the Settings sidebar went blank.
private struct AboutTab: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var updates: UpdateChecker

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
        }
    }

    private var content: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
            VStack(spacing: 2) {
                Text("Calendar Sync").font(.title2.bold())
                Text("Version \(updates.currentVersion)").foregroundStyle(.secondary)
            }

            UpdateStatus()

            VStack(spacing: 4) {
                Text("Made by Pedro Vicente").font(.headline)
                Link("pedrovicente.pt", destination: URL(string: "https://pedrovicente.pt")!)
            }

            Button {
                openURL(UpdateChecker.repoPage.appendingPathComponent("issues"))
            } label: {
                Label("Send feedback or report a bug", systemImage: "ladybug")
            }

            Divider().frame(width: 280)

            Text("If Calendar Sync saves you time, a donation helps me keep developing open source and free software.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button {
                    openURL(URL(string: "https://revolut.me/neteinstein")!)
                } label: {
                    Label("Donate with Revolut", systemImage: "heart.fill")
                }
                Button {
                    openURL(URL(string: "https://www.buymeacoffee.com/neteinstein")!)
                } label: {
                    Label("Buy me a coffee", systemImage: "cup.and.saucer.fill")
                }
            }
            .controlSize(.large)
        }
    }
}

// MARK: - Updates

/// A warning row shown in General while a newer version is published.
private struct UpdateBanner: View {
    @EnvironmentObject private var updates: UpdateChecker
    @State private var showingInstructions = false

    var body: some View {
        if let latest = updates.available {
            Section {
                HStack {
                    Label("Version \(latest.version) is available — you have \(updates.currentVersion).",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Update…") { showingInstructions = true }
                }
            }
            .sheet(isPresented: $showingInstructions) { UpdateInstructionsSheet(latest: latest) }
        }
    }
}

/// The update line in About: the warning when a newer version is out, otherwise a
/// manual check.
private struct UpdateStatus: View {
    @EnvironmentObject private var updates: UpdateChecker
    @State private var showingInstructions = false

    var body: some View {
        HStack(spacing: 10) {
            if let latest = updates.available {
                Label("Version \(latest.version) is available", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Update…") { showingInstructions = true }
                    .sheet(isPresented: $showingInstructions) { UpdateInstructionsSheet(latest: latest) }
            } else {
                Button("Check for updates") { Task { await updates.check() } }
                    .disabled(updates.isChecking)
                if updates.isChecking {
                    ProgressView().controlSize(.small)
                } else if updates.lastCheckFailed {
                    Text("Couldn't reach GitHub.").foregroundStyle(.secondary)
                } else if updates.lastChecked != nil {
                    Text("Up to date.").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// How to update: Calendar Sync is built from source, so the "update" is a pull and a rebuild.
/// The commands to run by hand, or Terminal runs them.
private struct UpdateInstructionsSheet: View {
    let latest: UpdateCheck.Latest
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var updateError: String?

    private var homebrew: UpdateCheck.Homebrew? { UpdateChecker.installation.homebrew }
    private var isHomebrewInstall: Bool { homebrew != nil }
    private var brewOwner: String? { homebrew?.owner }
    /// `brew upgrade` doesn't restart services.
    private var isBrewService: Bool { homebrew?.serviceLabel != nil }

    private let upgradeCommands = "brew update\nbrew upgrade calendar-sync"
    private let restartCommand = "brew services restart calendar-sync"

    private let sourceCommands = """
        cd Calendar-Sync
        git pull
        scripts/build-app.sh
        open "build/Calendar Sync.app"
        """

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update to version \(latest.version)").font(.headline)
            if !isHomebrewInstall {
                instruction("Calendar Sync is built from source. Quit the app, then run this in Terminal, from the folder you cloned it into:")
                CommandBox(commands: sourceCommands)
                note("That pulls the new version, rebuilds the app and opens it. Your settings are kept. Local builds are ad-hoc signed, so macOS asks for calendar access again after the rebuild. Installed with Homebrew instead? Run “brew update && brew upgrade calendar-sync”.")
            } else if let brewOwner {
                instruction("Calendar Sync was installed with Homebrew from the “\(brewOwner)” account, so the upgrade runs there. Quit the app, then in Terminal, logged in as \(brewOwner) (for example with “su - \(brewOwner)”), run:")
                CommandBox(commands: upgradeCommands)
                if isBrewService {
                    instruction("Then, back in this account (\(NSUserName())), the one that runs the app, restart it:")
                    CommandBox(commands: restartCommand)
                } else {
                    instruction("Then open Calendar Sync again from this account (\(NSUserName())).")
                }
                note("Only the account that owns Homebrew can upgrade it, but “brew services” has to run from the account logged in to the desktop: from the admin account it fails with “Domain does not support specified action”. From this account brew may also print a “Permission denied” error about a lock file in /opt/homebrew/var: it can't refresh the admin account's download cache, which is harmless, and the restart still happens. Your settings are kept. The build is ad-hoc signed, so macOS asks for calendar access again after the upgrade.")
            } else {
                instruction("Calendar Sync was installed with Homebrew. Quit the app, then run this in Terminal:")
                CommandBox(commands: upgradeCommands + (isBrewService ? "\n" + restartCommand : ""))
                note("Homebrew in a separate admin account? Run “brew update” and “brew upgrade calendar-sync” from the admin account, and “\(restartCommand)” from the account that runs the app. Your settings are kept. The build is ad-hoc signed, so macOS asks for calendar access again after the upgrade.")
            }
            if let updateError {
                Label(updateError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack {
                if let url = latest.url {
                    Button("What's new on GitHub") { openURL(url) }
                }
                Spacer()
                if UpdateChecker.canUpdateInTerminal {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Update in Terminal", action: updateInTerminal).keyboardShortcut(.defaultAction)
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    /// Runs the commands above in Terminal, then restarts the app.
    private func updateInTerminal() {
        Task {
            do {
                try await UpdateChecker.updateInTerminal()
                dismiss()
            } catch {
                updateError = "Couldn't open Terminal: \(error.localizedDescription)"
            }
        }
    }

    private func instruction(_ text: String) -> some View {
        Text(text).fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Commands to run in Terminal, selectable and with their own copy button, so that commands meant
/// for different accounts are copied separately.
private struct CommandBox: View {
    let commands: String

    var body: some View {
        GroupBox {
            HStack(alignment: .top) {
                Text(commands)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commands, forType: .string)
                }
            }
            .padding(4)
        }
    }
}

private struct CalendarLabel: View {
    let calendar: EKCalendar

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(cgColor: calendar.cgColor)).frame(width: 9, height: 9)
            Text(calendar.title)
            if let account = calendar.source?.title { Text(account).foregroundStyle(.secondary) }
        }
    }
}

/// A switch that stays in the accent color when it's on. The system switch turns gray whenever
/// the Settings window isn't the key window, which happens often for a menu bar app, and makes
/// it hard to tell which options are on.
private struct AccentSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            Capsule()
                .fill(configuration.isOn ? Color.accentColor : Color.secondary.opacity(0.25))
                .overlay(Capsule().strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
                .frame(width: 26, height: 15)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
                        .frame(width: 13, height: 13)
                        .padding(1)
                }
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(Capsule())
                .onTapGesture { configuration.isOn.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}
