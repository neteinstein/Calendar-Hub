import AppKit
import CalendarHubCore
import SwiftUI
import UniformTypeIdentifiers

/// The menu's Time Tracking view: the timer, today's time per client with the time nobody
/// logged, and this week's, with an export for timesheets. Shown when Time Tracking is on.
struct TimeTrackingView: View {
    /// This week's events in the main calendar.
    let events: [SourceEvent]
    let calendar: Calendar
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController
    @EnvironmentObject private var tracker: TimeTracker
    @State private var showsEntries = false

    private var options: TimeTrackingOptions { settings.timeTracking }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            let today = calendar.dateInterval(of: .day, for: now) ?? DateInterval(start: now, duration: 0)
            let week = calendar.dateInterval(of: .weekOfYear, for: now) ?? today
            let weekEntries = tracker.entries(events: events, in: week, now: now)
            let todayEntries = TimeTracking.clip(weekEntries, to: today)
            VStack(alignment: .leading, spacing: 12) {
                if options.timerEnabled {
                    timerCard(now: now)
                }
                ForEach(tracker.lateStops) { entry in
                    lateStopCard(entry)
                }
                todaySection(todayEntries, now: now)
                Divider()
                weekSection(weekEntries)
            }
        }
        .onAppear { tracker.stopIfForgotten() }
    }

    // MARK: - Timer

    @ViewBuilder
    private func timerCard(now: Date) -> some View {
        if let running = tracker.running {
            let tint = color(of: running.clientID)
            HStack(spacing: 10) {
                Image(systemName: "stopwatch.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, options: .repeating)
                VStack(alignment: .leading, spacing: 1) {
                    Text(running.clientName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("Since \(running.start.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(TimeTracking.duration(now.timeIntervalSince(running.start)))
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .fixedSize()
                clientMenu(exclude: running.clientID) { tracker.start($0) } label: {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .help("Switch the timer to another client")
                Button {
                    tracker.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.85), in: Capsule())
                        .contentShape(Capsule())
                        .fixedSize()
                }
                .buttonStyle(PressableStyle())
                .pointingHandCursor()
                .help("Stop the timer and log its time")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
        } else {
            HStack(spacing: 8) {
                clientMenu { tracker.start($0) } label: {
                    Label("Start timer", systemImage: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .help("Start the timer for a client")
                Spacer()
                Text("Meetings count by themselves")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .opacity(options.countsMeetings ? 1 : 0)
            }
        }
    }

    /// A timer left running, stopped at the end of the working day, until the user decides.
    private func lateStopCard(_ entry: TimeEntry) -> some View {
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text("The timer for \(entry.clientName) was left running")
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("It stopped at \(entry.end.formatted(time)), the end of your working day, but ran until \((entry.stoppedLate ?? entry.end).formatted(time)).")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Keep It Stopped") { tracker.dismissLateStop(of: entry.id) }
                    Button("Keep Until \((entry.stoppedLate ?? entry.end).formatted(time))") { tracker.keepLateTime(of: entry.id) }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.orange.opacity(0.4), lineWidth: 0.5))
    }

    // MARK: - Today

    private func todaySection(_ entries: [TimeEntry], now: Date) -> some View {
        let totals = TimeTracking.totals(of: entries)
        let logged = entries.map(\.duration).reduce(0, +)
        let gaps = options.nudgesUntracked
            ? TimeTracking.untrackedGaps(on: now, entries: entries, workingHours: settings.menuCalendar.workingHours,
                                         now: now, calendar: calendar)
            : []
        return VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Today", total: logged)
            if totals.isEmpty && gaps.isEmpty {
                Text(emptyText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(totals) { total in
                clientRow(total, size: 12.5)
            }
            ForEach(gaps, id: \.start) { gap in
                gapRow(gap)
            }
            if !entries.isEmpty {
                entriesList(entries)
            }
        }
    }

    private var emptyText: String {
        if options.timerEnabled && options.countsMeetings { return "Nothing logged yet today. Meetings are logged as they happen; start the timer for the rest." }
        if options.timerEnabled { return "Nothing logged yet today. Start the timer when you start working for a client." }
        return "Nothing logged yet today. Meetings are logged as they happen."
    }

    private func sectionHeader(_ title: String, total: TimeInterval) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(TimeTracking.duration(total))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
            Text("logged").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func clientRow(_ total: TimeTracking.ClientTotal, size: CGFloat) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color(of: total.client.id)).frame(width: 7, height: 7)
            Text(total.client.name).lineLimit(1)
            if total.meetings > 0 {
                Text(total.meetings >= total.total - 30 ? "all meetings" : "\(TimeTracking.duration(total.meetings)) in meetings")
                    .font(.system(size: size - 2))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(TimeTracking.duration(total.total)).monospacedDigit()
        }
        .font(.system(size: size))
        .accessibilityElement(children: .combine)
    }

    private func gapRow(_ gap: DateInterval) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(.orange)
            Text("\(timeRange(gap.start, gap.end)) not logged")
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(TimeTracking.duration(gap.duration)).monospacedDigit().foregroundStyle(.secondary)
            clientMenu { tracker.assign(gap, to: $0) } label: {
                Text("Assign")
            }
            .help("Log this time to a client")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Entries

    /// Today's entries, folded away until opened, each with a menu to give it to another
    /// client or delete it.
    private func entriesList(_ entries: [TimeEntry]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                showsEntries.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showsEntries ? 90 : 0))
                    Text(showsEntries ? "Hide today's entries" : "Today's entries (\(entries.count))")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsEntries {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(entries) { entryRow($0) }
                    }
                }
                .frame(height: min(CGFloat(entries.count) * 24, 192))
            }
        }
    }

    private func entryRow(_ entry: TimeEntry) -> some View {
        HStack(spacing: 7) {
            Text(timeRange(entry.start, entry.end))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Circle().fill(color(of: entry.clientID)).frame(width: 6, height: 6)
            Text(entryTitle(entry)).lineLimit(1)
            Spacer(minLength: 4)
            Text(TimeTracking.duration(entry.duration)).monospacedDigit().foregroundStyle(.secondary)
            entryMenu(entry)
        }
        .font(.system(size: 11))
        .frame(height: 24)
        .help("\(entry.clientName) · \(sourceText(entry))")
    }

    private func entryTitle(_ entry: TimeEntry) -> String {
        switch entry.source {
        case .meeting: entry.title ?? "Meeting"
        case .timer: entry.id.hasPrefix(TimeTracker.runningID) ? "Timer, running" : "Timer"
        case .assigned: "Assigned"
        }
    }

    private func sourceText(_ entry: TimeEntry) -> String {
        switch entry.source {
        case .meeting: tracker.log.meetingClients[entry.meetingKey ?? ""] == nil ? "meeting" : "meeting, given to this client"
        case .timer: "timer"
        case .assigned: "assigned"
        }
    }

    @ViewBuilder
    private func entryMenu(_ entry: TimeEntry) -> some View {
        if !entry.id.hasPrefix(TimeTracker.runningID) {
            Menu {
                Section("Log to") {
                    ForEach(settings.timeClients) { client in
                        Button(client.name) { give(entry, to: client) }
                            .disabled(client.id == entry.clientID)
                    }
                }
                if let key = entry.meetingKey, tracker.log.meetingClients[key] != nil {
                    Button("Back to Its Own Calendar") { tracker.reassignMeeting(key: key, to: nil) }
                }
                if entry.source != .meeting {
                    Divider()
                    Button("Delete", role: .destructive) { tracker.delete(entry.id) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Log to another client")
        }
    }

    private func give(_ entry: TimeEntry, to client: TimeClient) {
        if let key = entry.meetingKey {
            tracker.reassignMeeting(key: key, to: client)
        } else {
            tracker.changeClient(of: entry.id, to: client)
        }
    }

    // MARK: - Week

    private func weekSection(_ entries: [TimeEntry]) -> some View {
        let totals = TimeTracking.totals(of: entries)
        let logged = entries.map(\.duration).reduce(0, +)
        return VStack(alignment: .leading, spacing: 6) {
            sectionHeader("This week", total: logged)
            if logged > 0 {
                GeometryReader { proxy in
                    HStack(spacing: 1.5) {
                        ForEach(totals) { total in
                            Rectangle()
                                .fill(color(of: total.client.id))
                                .frame(width: max(2, (proxy.size.width - 1.5 * CGFloat(totals.count - 1)) * total.total / logged))
                                .help("\(total.client.name): \(TimeTracking.duration(total.total))")
                        }
                    }
                }
                .frame(height: 6)
                .clipShape(Capsule())
                ForEach(totals) { total in
                    clientRow(total, size: 11.5)
                }
            }
            HStack {
                Spacer()
                Menu {
                    ForEach(TimeTracking.Period.allCases, id: \.self) { period in
                        Button(period.title) { export(period) }
                    }
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .help("Save a week or a month as CSV, for your timesheet")
            }
        }
    }

    /// Saves `period` as CSV where the user picks. Asked after the menu closes, so the save
    /// panel comes to the front.
    private func export(_ period: TimeTracking.Period) {
        let now = Date()
        guard let interval = period.interval(now: now, calendar: calendar) else { return }
        var periodEvents: [SourceEvent] = []
        if let targetID = settings.targetCalendarID,
           case .success(let fetched) = controller.eventKit.sourceEvents(calendarID: targetID,
                                                                       from: interval.start, to: interval.end) {
            periodEvents = fetched.filter { !$0.isCancelled }
        }
        let entries = tracker.entries(events: periodEvents, in: interval, now: now)
        let hidden = Set(settings.sources.filter(\.hideMeetingName).map(\.id.uuidString))
        let csv = TimeTracking.csv(entries, calendar: calendar, hiddenTitles: hidden)
        let name = "Calendar Hub time \(period.label(now: now, calendar: calendar)).csv"
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: - Helpers

    /// A menu of the clients, less `exclude`.
    private func clientMenu<Label: View>(exclude: String? = nil, pick: @escaping (TimeClient) -> Void,
                                         @ViewBuilder label: () -> Label) -> some View {
        Menu {
            ForEach(settings.timeClients.filter { $0.id != exclude }) { client in
                Button(client.name) { pick(client) }
            }
        } label: {
            label()
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }

    private func timeRange(_ start: Date, _ end: Date) -> String {
        "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }

    private func color(of clientID: String) -> Color {
        TimeClientColor.of(clientID, settings: settings, eventKit: controller.eventKit)
    }
}

/// A client's color: its calendar's, the main calendar's for Internal, and a soft one of its
/// own for a client added by hand.
enum TimeClientColor {
    @MainActor
    static func of(_ clientID: String, settings: SettingsStore, eventKit: EventKitBridge) -> Color {
        if clientID == TimeClient.internalID {
            return eventKit.calendar(id: settings.targetCalendarID).map { Color(cgColor: $0.cgColor) } ?? .gray
        }
        if let source = settings.sources.first(where: { $0.id.uuidString == clientID }) {
            return EventOrigin.of(source, settings: settings, eventKit: eventKit).color
        }
        if let index = settings.timeTracking.extraClients.firstIndex(where: { $0.id == clientID }) {
            let colors: [Color] = [.mint, .yellow, .cyan, .brown, .indigo]
            return colors[index % colors.count]
        }
        return .gray
    }
}
