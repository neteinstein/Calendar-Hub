import CalendarSyncCore
import EventKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            SourcesTab().tabItem { Label("Secondary Calendars", systemImage: "calendar") }
            TwoWaySyncTab().tabItem { Label("Two way sync", systemImage: "arrow.left.arrow.right") }
            PreviewTab().tabItem { Label("Preview", systemImage: "eye") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 620, height: 460)
        .toggleStyle(AccentSwitchStyle())
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
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
                Text("Each secondary calendar can use its own interval instead (Secondary Calendars tab). Calendar.app calendars also sync about 10 seconds after a change.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("What's copied") {
                Toggle("Skip meetings I declined", isOn: $settings.options.skipDeclined)
                Toggle("Skip all-day events", isOn: $settings.options.skipAllDay)
                Toggle("Skip out-of-office events", isOn: $settings.options.skipOutOfOffice)
            }

            Section {
                Toggle("Show a calendar in the menu", isOn: $settings.menuCalendarEnabled)
                if settings.menuCalendarEnabled {
                    Toggle("Show the week day in the menu bar", isOn: $settings.menuBar.showsWeekday)
                }
            } header: {
                Text("Menu bar")
            } footer: {
                Text("The menu bar button opens a month view — click a day for its events — or a scrolling list of your main calendar's events, and the menu bar icon shows today's date, with the week day next to it when that's on.")
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
                                timePicker($settings.menuCalendar.workingHours.start, in: 0..<(settings.menuCalendar.workingHours.end))
                                Text("to")
                                timePicker($settings.menuCalendar.workingHours.end,
                                           in: (settings.menuCalendar.workingHours.start + 30)..<(24 * 60 + 1))
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

            Section {
                Toggle("Show a full-screen alert when an event starts", isOn: $settings.alerts.enabled)
                if settings.alerts.enabled {
                    Stepper(settings.alerts.leadMinutes == 0
                            ? "Show it when the event starts"
                            : "Show it \(settings.alerts.leadMinutes) \(settings.alerts.leadMinutes == 1 ? "minute" : "minutes") before the start",
                            value: $settings.alerts.leadMinutes, in: 0...15)
                }
            } header: {
                Text("Meeting alerts")
            } footer: {
                Text("Covers the screen when a meeting in your main calendar begins, with buttons to join the call, go to the room, or ignore it. Each meeting alerts once; a meeting already under way alerts until it ends.")
                    .font(.caption).foregroundStyle(.secondary)
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
                            Button("\(calendar.title) (\(calendar.source.title))") {
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
                let source = SourceConfig(
                    kind: .outlookWeb, calendarName: name, name: name,
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
            Toggle("Copy location and description", isOn: $source.copyDetails)
                .disabled(source.hideMeetingName)
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

    /// "Sainsbury's – Outlook on the web": the name given when it was added, then the kind of
    /// calendar. "N/A" for calendars added before names were asked for.
    private var outlookTitle: String {
        "\(source.name ?? "N/A") – Outlook on the web"
    }

    private var footer: String {
        var text = "Copies are titled “\(copyTitle(source.hideMeetingName ? "Busy" : "Meeting name"))” and include the meeting link when there is one."
        if source.copyDetails {
            text += source.hideMeetingName
                ? " Location and description aren't copied while meeting names are hidden."
                : " The location and description are copied too."
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
                Text("Your main calendar's events are also added to your secondary calendars as “Busy”, with nothing else: no title, link, location or attendees. Their description is “Busy” too, so you can tell what was added automatically. Copies of a calendar's own meetings aren't added back to it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if settings.twoWaySync {
                if settings.sources.isEmpty {
                    Section {
                        Text("Add a secondary calendar in the Secondary Calendars tab first.")
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

private struct PreviewTab: View {
    @EnvironmentObject private var controller: SyncController

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("See what the next sync would change, without changing anything.")
                Spacer()
                Button("Preview") { Task { await controller.sync(apply: false) } }
                    .disabled(controller.isSyncing)
            }
            if let plan = controller.preview {
                Text(plan.isEmpty
                     ? "Nothing to change (\(plan.unchangedCount) copies up to date)."
                     : "\(plan.creates) to add, \(plan.updates) to update, \(plan.deletes) to remove, \(plan.unchangedCount) unchanged.")
                    .foregroundStyle(.secondary)
                ForEach(controller.busyPreview) { busy in
                    Text("Busy in \(busy.calendarName): \(busy.plan.creates) to add, \(busy.plan.updates) to update, \(busy.plan.deletes) to remove.")
                        .foregroundStyle(.secondary)
                }
                List(previewRows(plan), id: \.offset) { row in
                    HStack {
                        Text(row.element.action.verb).frame(width: 60, alignment: .leading).foregroundStyle(.secondary)
                        Text(row.element.title)
                        Spacer()
                        Text(row.element.action.start, format: .dateTime.weekday().day().month().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Spacer()
            }
            ForEach(controller.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .padding()
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

private struct AboutTab: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var updates: UpdateChecker

    var body: some View {
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
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Updates

/// A warning row shown in the General tab while a newer version is published.
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

/// The update line in the About tab: the warning when a newer version is out, otherwise a
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
private struct UpdateInstructionsSheet: View {
    let latest: UpdateCheck.Latest
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Running from Homebrew's cellar means it was installed with `brew`. `brew services` starts it
    /// through the opt symlink, which the bundle path keeps, so resolve that first.
    private var cellarPath: String? {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        guard let range = path.range(of: "/Cellar/") else { return nil }
        return String(path[..<range.upperBound])
    }

    private var isHomebrewInstall: Bool { cellarPath != nil }

    /// The account that owns Homebrew when it isn't the one running the app: Homebrew installed
    /// from a separate admin account. Only that account can run `brew update` and `brew upgrade`.
    private var brewOwner: String? {
        guard let cellarPath,
              let owner = try? FileManager.default.attributesOfItem(atPath: cellarPath)[.ownerAccountName] as? String,
              owner != NSUserName()
        else { return nil }
        return owner
    }

    /// launchd sets XPC_SERVICE_NAME to the job's label: sh.brew.calendar-sync under `brew services`
    /// (homebrew.mxcl.calendar-sync in older Homebrew). `brew upgrade` doesn't restart services.
    private var isBrewService: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]?.hasSuffix(".calendar-sync") == true
    }

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
            HStack {
                if let url = latest.url {
                    Button("What's new on GitHub") { openURL(url) }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
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
            Text(calendar.source.title).foregroundStyle(.secondary)
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
