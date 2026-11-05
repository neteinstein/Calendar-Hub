import CalendarSyncCore
import SwiftUI

/// The popover shown from the menu bar icon.
struct MenuView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if compiler(>=6.0)
    // Not in the SDK of Xcode 15 and older toolchains, which build with the SettingsLink below.
    @Environment(\.openSettings) private var openSettings
    #endif
    /// Today's main-calendar events, for the Up next card.
    @State private var today: [SourceEvent] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !settings.menuCalendarEnabled {
                Text("Calendar Sync").font(.headline)
            }

            // A TimelineView is fine in the menu; only in the menu bar label does it loop.
            TimelineView(.everyMinute) { context in
                if let next = MenuCalendar.upNext(in: today, now: context.date, calendar: .current) {
                    UpNextCard(event: next, now: context.date,
                               origin: EventOrigin.of(next, settings: settings, eventKit: controller.eventKit))
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }

            if settings.menuCalendarEnabled {
                MenuCalendarView()
            }

            problemCards

            Divider()

            let outlookSources = settings.sources.filter { $0.kind == .outlookWeb }
            if !outlookSources.isEmpty {
                webCalendars(outlookSources)
            }

            footer
        }
        .padding(14)
        .frame(width: settings.menuCalendarEnabled ? 360 : 320)
        // The menu window's own material lets a white window behind it wash the text out; the
        // window background, nearly opaque, keeps it readable while still hinting at the desktop.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92).ignoresSafeArea())
        .background(WindowTopAnchor())
        // No animation on changes that resize the menu (problems coming and going, the Up next
        // card): the window must not resize inside one (see `WindowTopAnchor`).
        .onAppear(perform: reloadToday)
        .onChange(of: controller.lastSync) { _, _ in reloadToday() }
        .onChange(of: settings.targetCalendarID) { _, _ in reloadToday() }
    }

    /// Reads today's events from the main calendar.
    private func reloadToday() {
        let calendar = Calendar.current
        guard let targetID = settings.targetCalendarID,
              let day = calendar.dateInterval(of: .day, for: Date()),
              case .success(let events) = controller.eventKit.sourceEvents(calendarID: targetID, from: day.start, to: day.end)
        else {
            today = []
            return
        }
        today = events.filter { !$0.isCancelled }
    }

    // MARK: - Problems

    /// What went wrong, each with the button that fixes it when there is one. A sync's
    /// problems hide while a new sync runs, so they don't look current; it replaces them when
    /// it finishes.
    @ViewBuilder
    private var problemCards: some View {
        if let setup = controller.setupProblem {
            setupCard(setup)
        }
        if !controller.isSyncing {
            ForEach(controller.unreadSources) { unread in
                let source = settings.sources.first { $0.id == unread.id }
                ProblemCard(
                    title: "\(source.map { $0.name ?? $0.calendarName } ?? unread.name) wasn't read",
                    detail: unread.reason + (unread.reason.hasSuffix(".") ? "" : ".") + " Its copies are left as they are.",
                    actionTitle: source?.kind == .outlookWeb ? "Open Outlook" : nil
                ) {
                    if let source { controller.showOutlookWindow(for: source) }
                }
            }
            let others = controller.problems.filter { problem in
                !controller.unreadSources.contains { $0.problem == problem }
            }
            if !others.isEmpty {
                ProblemCard(title: others.count == 1 ? "The last sync had a problem" : "The last sync had \(others.count) problems",
                            detail: others.joined(separator: "\n"))
            }
        }
    }

    @ViewBuilder
    private func setupCard(_ problem: SyncController.SetupProblem) -> some View {
        switch problem {
        case .noAccess:
            ProblemCard(title: "Calendar Sync can't see your calendars",
                        detail: "Allow it in System Settings › Privacy & Security › Calendars.",
                        actionTitle: "Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .noMainCalendar:
            ProblemCard(title: "Choose your main calendar",
                        detail: "Meetings from your secondary calendars are copied into it.",
                        actionTitle: "Open Settings", action: showSettings)
        case .mainCalendarMissing:
            ProblemCard(title: "Your main calendar is gone",
                        detail: "It's no longer in Calendar.app. Choose another one in Settings.",
                        actionTitle: "Open Settings", action: showSettings)
        }
    }

    // MARK: - Web calendars and footer

    /// A chip per Outlook web calendar, named as in Settings, or by its prefix for copies while
    /// it has no name. An orange dot marks one the last sync couldn't read.
    private func webCalendars(_ sources: [SourceConfig]) -> some View {
        HStack(spacing: 6) {
            Text("Web calendars")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize()
            // In a row while they fit, the rest in a menu otherwise.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { chips(sources) }
                HStack(spacing: 6) {
                    chips(Array(sources.prefix(1)))
                    Menu("\(sources.count - 1) more") {
                        ForEach(sources.dropFirst()) { source in
                            Button(source.name ?? source.calendarName) { controller.showOutlookWindow(for: source) }
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                }
            }
        }
    }

    private func chips(_ sources: [SourceConfig]) -> some View {
        ForEach(sources) { source in
            WebCalendarChip(
                name: source.name ?? source.calendarName,
                color: EventOrigin.of(source, settings: settings, eventKit: controller.eventKit).color,
                needsAttention: controller.unreadSources.contains { $0.id == source.id }
            ) {
                controller.showOutlookWindow(for: source)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            SyncStatusPill()
            Spacer()
            IconButton("arrow.triangle.2.circlepath", help: "Sync now (⌘R)", shortcut: "r") {
                Task { await controller.syncNow() }
            }
            // Enabled without access too: a sync checks again whether access was granted.
            .disabled(controller.isSyncing)

            #if compiler(>=6.0)
            IconButton("gearshape", help: "Settings… (⌘,)", shortcut: ",", action: showSettings)
            #else
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 24)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings…")
            .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
            #endif

            IconButton("power", help: "Quit Calendar Sync (⌘Q)", shortcut: "q", action: confirmQuit)
        }
    }

    /// Quits once the user confirms, so a stray click next to Settings doesn't stop syncing.
    /// An alert of its own rather than a SwiftUI dialog: the menu window closes as soon as
    /// anything else takes focus, and would take a dialog of its own with it.
    private func confirmQuit() {
        // After the click is handled, so the menu has closed and the alert comes to the front.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Quit Calendar Sync?"
            alert.informativeText = "Your calendars stop syncing until you open it again."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                NSApp.terminate(nil)
            }
        }
    }

    /// Opens Settings and brings it in front of other apps. A `SettingsLink` with a tap gesture
    /// on top sometimes lost the click, and a menu bar app isn't always allowed to come to the
    /// front, so the window could open behind other windows, or stay there if it was already
    /// open: either way, nothing seemed to happen.
    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        #if compiler(>=6.0)
        openSettings()
        #else
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        #endif
        // The window exists only after `openSettings` returns.
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
            }) else { return }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

/// The next meeting, or the one under way: a countdown, its calendar's color, the room and the
/// call service, and a Join button. A thin bar along the bottom fills as the start nears, then
/// as the meeting runs.
private struct UpNextCard: View {
    let event: SourceEvent
    let now: Date
    let origin: EventOrigin?

    private var tint: Color { origin?.color ?? .accentColor }

    /// Half an hour before the start fills to the start; then the meeting fills to its end.
    private var progress: Double {
        if event.start > now {
            return max(0.03, 1 - event.start.timeIntervalSince(now) / 1800)
        }
        let length = event.end.timeIntervalSince(event.start)
        return length > 0 ? min(1, now.timeIntervalSince(event.start) / length) : 1
    }

    private var meta: [String] {
        var parts = ["\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))"]
        if let location = event.location?.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespaces), !location.isEmpty {
            parts.append(location)
        }
        if let url = event.meetingURL, let service = MeetingLink.serviceName(of: url) { parts.append(service) }
        return parts
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text(event.start > now ? "Up next" : "Now")
                        .font(.system(size: 10.5, weight: .bold))
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .foregroundStyle(tint)
                    Text(MenuCalendar.countdown(to: event, now: now))
                        .font(.system(size: 10.5, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Text(MenuCalendar.displayTitle(of: event))
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text(meta.joined(separator: " · "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let url = event.meetingURL {
                JoinButton(url: url, large: true)
            }
        }
        .padding(.leading, 15)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            Rectangle().fill(tint).frame(width: 3)
        }
        .overlay(alignment: .bottom) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(tint.opacity(0.15))
                    Rectangle().fill(tint).frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.6), value: progress)
        .accessibilityElement(children: .combine)
    }
}

/// The last sync at a glance: a green dot when it went fine, an orange one with the number
/// of problems when it didn't, spinning arrows while syncing, and a check for a moment when a
/// sync finishes. The summary is in the tooltip.
private struct SyncStatusPill: View {
    @EnvironmentObject private var controller: SyncController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var justSynced = false

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 6) {
                icon
                    .frame(width: 12, height: 12)
                    .transition(.scale.combined(with: .opacity))
                Text(text(now: context.date))
                    .contentTransition(.opacity)
                if !controller.isSyncing, !controller.problems.isEmpty {
                    Text("\(controller.problems.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(.orange, in: Capsule())
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(controller.isSyncing ? .primary : .secondary)
            .padding(.leading, 7)
            .padding(.trailing, 9)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.05), in: Capsule())
        }
        .help(controller.lastSummary)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: controller.isSyncing)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: justSynced)
        .onChange(of: controller.lastSync) { _, _ in
            justSynced = true
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                justSynced = false
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if controller.isSyncing {
            Spinner()
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        } else if justSynced {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: justSynced)
        } else {
            let color: Color = controller.setupProblem != nil || !controller.problems.isEmpty ? .orange
                : controller.lastSync == nil ? .secondary : .green
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .background(Circle().fill(color.opacity(0.22)).frame(width: 13, height: 13))
        }
    }

    /// "Synced 2 min ago" in whole minutes, so it doesn't tick every second.
    private func text(now: Date) -> String {
        if controller.isSyncing { return "Syncing…" }
        guard let lastSync = controller.lastSync else { return "Not synced yet" }
        let minutes = Int(now.timeIntervalSince(lastSync) / 60)
        switch minutes {
        case ..<1: return "Synced just now"
        case ..<60: return "Synced \(minutes) min ago"
        default: return "Synced \(MenuCalendar.shortDuration(minutes: minutes)) ago"
        }
    }
}

/// What went wrong, what it means, and the button that fixes it.
private struct ProblemCard: View {
    let title: String
    var detail: String?
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle {
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.orange.opacity(0.4), lineWidth: 0.5))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// An Outlook web calendar: a chip with its color that opens its window.
private struct WebCalendarChip: View {
    let name: String
    let color: Color
    let needsAttention: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(name).lineLimit(1)
                if needsAttention {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                }
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.leading, 7)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(hovering ? 0.11 : 0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .pointingHandCursor()
        .help(needsAttention ? "Open the Outlook window for \(name) to sign in again" : "Open the Outlook window for \(name)")
    }
}
