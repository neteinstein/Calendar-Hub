import AppKit
import CalendarHubCore
import Combine
import SwiftUI

/// Shows a full-screen alert when a main-calendar event starts, with buttons to join the
/// call, go to the room, or ignore it. Each occurrence alerts once.
@MainActor
final class EventAlertController: ObservableObject {
    private let settings: SettingsStore
    private let eventKit: EventKitBridge
    /// For the tasks to prepare a meeting, listed on its alert.
    private let tasks: TaskStore?
    /// Checks every 20 seconds, which catches up after sleep and calendar changes.
    private var timer: Timer?
    /// Fires on the second the next alert or snooze falls due, so it isn't left waiting for
    /// the 20-second check, which runs at whatever offset from the minute the app launched at.
    private var exactTimer: Timer?
    /// Occurrence keys already alerted, with when, so each event alerts once. Pruned daily.
    private var shown: [String: Date] = [:]
    /// Alerts put off with "Remind me in 1 minute", and when they come back.
    private var snoozed: [String: Date] = [:]
    private var window: NSWindow?
    /// The event the alert on screen is for.
    private var current: SourceEvent?
    /// Keeps App Nap away while alerts are on. A menu bar app with no window open naps, and
    /// then its timers fire minutes late or not at all, so alerts came late or never.
    private var activity: NSObjectProtocol?
    private var enabledObserver: AnyCancellable?
    private var screenObserver: NSObjectProtocol?
    /// The last reason `check` couldn't read the main calendar, so it's logged once, not
    /// every 20 seconds.
    private var lastReadFailure: String?

    /// Without `checks`, no alert is ever shown: the demo's meetings sit around the current time.
    init(settings: SettingsStore, eventKit: EventKitBridge, tasks: TaskStore? = nil, checks: Bool = true) {
        self.settings = settings
        self.eventKit = eventKit
        self.tasks = tasks
        guard checks else { return }
        // On the main run loop, so the block runs on the main actor; in the common modes, so
        // it keeps checking while the menu is open.
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        enabledObserver = settings.$alerts.map(\.enabled).removeDuplicates().sink { [weak self] enabled in
            MainActor.assumeIsolated { self?.preventAppNap(enabled) }
        }
        // A display unplugged or rearranged under the alert would leave it off screen.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOnScreen() }
        }
    }

    private func preventAppNap(_ prevent: Bool) {
        if prevent, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Showing a full-screen alert when an event starts")
        } else if !prevent, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func check() {
        exactTimer?.invalidate()
        exactTimer = nil
        let now = Date()
        if let window, let current {
            // An alert left up after its event ended would hold back every alert after it.
            guard now >= current.end else {
                keepOnScreen()
                return
            }
            AppLog.write("Calendar Hub: closing the alert for the meeting at \(current.start), which has ended")
            window.orderOut(nil)
            self.window = nil
            self.current = nil
        }
        guard settings.alerts.enabled, eventKit.hasAccess,
              let targetID = settings.targetCalendarID else { return }
        // Events overlapping this window: already under way, or starting within the lead time.
        let ahead = now.addingTimeInterval(60 * Double(settings.alerts.leadMinutes) + 60)
        let events: [SourceEvent]
        switch eventKit.sourceEvents(calendarID: targetID, from: now, to: ahead) {
        case .success(let read):
            events = read
            lastReadFailure = nil
        case .failure(let reason):
            if reason != lastReadFailure { AppLog.write("Calendar Hub: can't check for alerts: \(reason)") }
            lastReadFailure = reason
            return
        }

        shown = shown.filter { now.timeIntervalSince($0.value) < 24 * 3600 }
        // A snoozed alert is due again once its minute is up, if its event hasn't ended.
        for (key, until) in snoozed where until <= now {
            shown[key] = nil
            snoozed[key] = nil
        }
        let due = EventAlertPlanner.dueAlerts(
            events: events, shown: Set(shown.keys), now: now, leadMinutes: settings.alerts.leadMinutes)
        // Marked only once it's on screen, so an alert that couldn't show is tried again.
        if let event = due.first, show(event) {
            shown[event.key] = now
            return
        }
        // The events read reach a minute past the lead time and this runs every 20 seconds,
        // so the next alert is always in view before it falls due.
        let next = [EventAlertPlanner.nextAlertTime(
            events: events, shown: Set(shown.keys), now: now, leadMinutes: settings.alerts.leadMinutes),
                    snoozed.values.min()].compactMap { $0 }.min()
        if let next { scheduleExactCheck(at: next) }
    }

    private func scheduleExactCheck(at date: Date) {
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        exactTimer = timer
    }

    /// The screen the user is looking at, as best we can tell: the one with the pointer.
    private static func activeScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func show(_ event: SourceEvent) -> Bool {
        guard let screen = Self.activeScreen() else { return false }
        let panel = AlertPanel(contentRect: screen.frame, styleMask: [.borderless],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // Panels hide while their app isn't active by default, and this one must show over
        // whatever app is.
        panel.hidesOnDeactivate = false
        panel.ignoresInputUntil = Date().addingTimeInterval(1.5)
        panel.ignored = { [weak self] in self?.dismiss() }
        panel.contentView = NSHostingView(rootView: EventAlertView(
            event: event,
            origin: EventOrigin.of(event, settings: settings, eventKit: eventKit),
            prepare: tasks?.openTasks(forEvent: event.key).map(\.title) ?? [],
            dismiss: { [weak self] in self?.dismiss() },
            snooze: { [weak self] in self?.snooze(event) }))
        window = panel
        current = event
        bringForward(panel)
        AppLog.write("Calendar Hub: showing the alert for the meeting at \(event.start)")
        return true
    }

    private func bringForward(_ panel: NSWindow) {
        // A hidden app (⌘H in the Outlook window, or another app's Hide Others) shows none of
        // its windows, and macOS can turn down the activation below, so unhide it first.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Puts the alert back in front of the user if it was hidden or its screen went away.
    private func keepOnScreen() {
        guard let window else { return }
        if !NSScreen.screens.contains(where: { $0.frame == window.frame }), let screen = Self.activeScreen() {
            window.setFrame(screen.frame, display: true)
        }
        if NSApp.isHidden || !window.isVisible { bringForward(window) }
    }

    private func dismiss() {
        window?.orderOut(nil)
        window = nil
        current = nil
        // If another event is due at the same time, show it next.
        check()
    }

    /// Closes the alert and shows it again in a minute.
    private func snooze(_ event: SourceEvent) {
        snoozed[event.key] = Date().addingTimeInterval(60)
        dismiss()
    }
}

/// Borderless windows can't become key by default, but the alert's buttons need the keyboard
/// (Return joins, Escape ignores).
private final class AlertPanel: NSPanel {
    /// A key or click meant for another app just as the alert appears would otherwise dismiss
    /// it before it was seen.
    var ignoresInputUntil = Date.distantPast
    /// A key or click the buttons don't take, which ignores the alert the way Escape does.
    var ignored: () -> Void = {}
    /// A mouse button went down on the alert, so its release is a click on it.
    private var pressed = false

    private static let presses: Set<NSEvent.EventType> = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    private static let releases: Set<NSEvent.EventType> = [.leftMouseUp, .rightMouseUp, .otherMouseUp]

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        Date() < ignoresInputUntil || super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        let isInput = [.keyDown, .keyUp].contains(event.type) || Self.presses.contains(event.type)
            || Self.releases.contains(event.type)
        if isInput, Date() < ignoresInputUntil { return }
        if Self.presses.contains(event.type) { pressed = true }
        super.sendEvent(event)
        // Every button closes the alert, so a click it's still up after wasn't on one.
        if Self.releases.contains(event.type), pressed {
            pressed = false
            if isVisible { ignored() }
        }
    }

    /// Reached by the keys nothing in the alert took. Return and Escape get here too, and
    /// are tried as the buttons' shortcuts, the way the window would.
    override func keyDown(with event: NSEvent) {
        if !performKeyEquivalent(with: event) { ignored() }
    }
}

struct EventAlertView: View {
    let event: SourceEvent
    let origin: EventOrigin?
    /// The open tasks for the meeting, under "To prepare".
    var prepare: [String] = []
    /// Off for screenshots, which draw a blurred desktop of their own.
    var blursDesktop = true
    let dismiss: () -> Void
    let snooze: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Off until the alert is on screen: the desktop blurs in, then the card springs up.
    @State private var shown = false

    /// The first line of the location, for the "Go to …" button. Room names are short;
    /// addresses pasted into the location field are not.
    private var room: String? {
        guard let line = event.location?
            .components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespaces),
            !line.isEmpty
        else { return nil }
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }

    private var tint: Color { origin?.color ?? .accentColor }

    var body: some View {
        ZStack {
            if blursDesktop {
                ZStack {
                    VisualEffectBackground()
                    Color.black.opacity(0.28)
                }
                .ignoresSafeArea()
                .opacity(shown ? 1 : 0)
            }

            card
                .frame(maxWidth: 620)
                .scaleEffect(shown || reduceMotion ? 1 : 0.95)
                .offset(y: shown || reduceMotion ? 0 : 18)
                .opacity(shown ? 1 : 0)
                .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.78).delay(0.05),
                           value: shown)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) { shown = true }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if let origin {
                    HStack(spacing: 6) {
                        Circle().fill(tint).frame(width: 8, height: 8)
                        Text(origin.name)
                    }
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.16), in: Capsule())
                }
                Spacer()
                Countdown(start: event.start)
            }
            .modifier(Entrance(shown: shown, delay: 0.12))

            VStack(alignment: .leading, spacing: 6) {
                Text(MenuCalendar.displayTitle(of: event))
                    .font(.system(size: 34, weight: .bold))
                    .lineLimit(3)
                HStack(spacing: 8) {
                    Text("\(Text(event.start, format: .dateTime.hour().minute())) – \(Text(event.end, format: .dateTime.hour().minute()))")
                    if let room {
                        Text("·").foregroundStyle(.tertiary)
                        Label(room, systemImage: "mappin.and.ellipse").lineLimit(1)
                    }
                    if let url = event.meetingURL, let service = MeetingLink.serviceName(of: url) {
                        Text("·").foregroundStyle(.tertiary)
                        Text(service)
                    }
                }
                .font(.title3)
                .foregroundStyle(.secondary)
            }
            .modifier(Entrance(shown: shown, delay: 0.17))

            if !prepare.isEmpty {
                PrepareList(titles: prepare, tint: tint)
                    .modifier(Entrance(shown: shown, delay: 0.2))
            }

            StartProgress(start: event.start, tint: tint)
                .modifier(Entrance(shown: shown, delay: 0.22))

            HStack(spacing: 10) {
                if let url = event.meetingURL {
                    AlertJoinButton(url: url, dismiss: dismiss)
                    if let room {
                        Button(action: dismiss) {
                            Label("Go to \(room)", systemImage: "figure.walk").lineLimit(1)
                        }
                        .buttonStyle(AlertButtonStyle())
                    }
                } else if let room {
                    Button(action: dismiss) {
                        Label("Go to \(room)", systemImage: "figure.walk").lineLimit(1)
                        KeyCap("⏎")
                    }
                    .buttonStyle(AlertButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                }
                Spacer(minLength: 0)
                Button(action: dismiss) {
                    Text("Ignore")
                    KeyCap("esc")
                }
                .buttonStyle(AlertButtonStyle(plain: true))
                .keyboardShortcut(.cancelAction)
            }
            .modifier(Entrance(shown: shown, delay: 0.27))

            Button("Remind me in 1 minute", action: snooze)
                .buttonStyle(.link)
                .modifier(Entrance(shown: shown, delay: 0.3))
        }
        .padding(.horizontal, 38)
        .padding(.top, 30)
        .padding(.bottom, 26)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 40, y: 18)
    }

    /// Fades a part of the card in a little after the card, from slightly below.
    private struct Entrance: ViewModifier {
        let shown: Bool
        let delay: Double
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func body(content: Content) -> some View {
            content
                .opacity(shown ? 1 : 0)
                .offset(y: shown || reduceMotion ? 0 : 6)
                .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.8).delay(delay),
                           value: shown)
        }
    }
}

/// The meeting's open tasks, three at most: what's left to prepare.
private struct PrepareList: View {
    let titles: [String]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("To prepare", systemImage: "checklist")
                .font(.system(size: 11.5, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(tint)
            ForEach(titles.prefix(3), id: \.self) { title in
                Label {
                    Text(title).lineLimit(1)
                } icon: {
                    Image(systemName: "circle").foregroundStyle(.secondary)
                }
                .font(.system(size: 15))
            }
            if titles.count > 3 {
                Text("and \(titles.count - 3) more")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// "Starts in 1:42", then "Started 0:30 ago" in red, to the second.
private struct Countdown: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = Int(start.timeIntervalSince(context.date).rounded(.up))
            let started = seconds <= 0
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(started ? "Started" : "Starts in")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(Self.clock(abs(seconds)) + (started ? " ago" : ""))
                    .font(.system(size: 24, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(started ? .red : .primary)
                    .contentTransition(.numericText(countsDown: !started))
            }
        }
    }

    /// "1:42", "12:05", "1:02:03".
    static func clock(_ seconds: Int) -> String {
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// A thin bar that fills over the last minutes before the start.
private struct StartProgress: View {
    let start: Date
    let tint: Color
    /// The stretch the bar covers: the alert shows up to 15 minutes before.
    private let span: TimeInterval = 15 * 60

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = start.timeIntervalSince(context.date)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule().fill(tint)
                        .frame(width: proxy.size.width * min(1, max(0.02, 1 - left / span)))
                        .animation(.linear(duration: 1), value: left)
                }
            }
            .frame(height: 4)
        }
    }
}

/// A key's name printed on a button, so its shortcut can be seen.
private struct KeyCap: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
    }
}

/// Join, in the colors of the meeting's service (Zoom blue, Teams purple, Meet yellow, …) with
/// its app's icon, or in the accent color with a camera for any other link.
private struct AlertJoinButton: View {
    let url: URL
    let dismiss: () -> Void

    private var service: MeetingService? { MeetingService.of(url) }

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
            dismiss()
        } label: {
            Label {
                Text(service.map { "Join \($0.name)" } ?? "Join call")
            } icon: {
                MeetingServiceIcon(service: service, size: 20)
            }
            KeyCap("⏎")
        }
        .buttonStyle(AlertButtonStyle(prominent: true, fill: service?.fill ?? .accentColor,
                                      text: service?.textColor ?? .white))
        .keyboardShortcut(.defaultAction)
    }

}

/// The alert's large, rounded buttons: filled for the main action (in the accent color unless
/// given another), gray for the others, and text only for Ignore.
private struct AlertButtonStyle: ButtonStyle {
    var prominent = false
    var plain = false
    var fill: Color = .accentColor
    var text: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) { configuration.label }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(prominent ? AnyShapeStyle(text) : plain ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .padding(.horizontal, plain ? 8 : 16)
            .padding(.vertical, 9)
            .background {
                if prominent {
                    Capsule().fill(fill).shadow(color: fill.opacity(0.45), radius: 8, y: 4)
                } else if !plain {
                    Capsule().fill(Color.primary.opacity(0.09))
                }
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Blurs whatever is behind the alert's window: the desktop and the apps on it.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .fullScreenUI
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
