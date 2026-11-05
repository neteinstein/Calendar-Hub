import AppKit
import CalendarSyncCore
import Combine
import SwiftUI

/// Shows a full-screen alert when a main-calendar event starts, with buttons to join the
/// call, go to the room, or ignore it. Each occurrence alerts once.
@MainActor
final class EventAlertController: ObservableObject {
    private let settings: SettingsStore
    private let eventKit: EventKitBridge
    private var timer: Timer?
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

    init(settings: SettingsStore, eventKit: EventKitBridge) {
        self.settings = settings
        self.eventKit = eventKit
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
        let now = Date()
        if let window, let current {
            // An alert left up after its event ended would hold back every alert after it.
            guard now >= current.end else {
                keepOnScreen()
                return
            }
            NSLog("Calendar Sync: closing the alert for “\(current.title)”, which has ended")
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
            if reason != lastReadFailure { NSLog("Calendar Sync: can't check for alerts: \(reason)") }
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
        guard let event = due.first, show(event) else { return }
        shown[event.key] = now
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
        panel.ignoresKeysUntil = Date().addingTimeInterval(1.5)
        panel.contentView = NSHostingView(rootView: EventAlertView(
            event: event,
            origin: EventOrigin.of(event, settings: settings, eventKit: eventKit),
            dismiss: { [weak self] in self?.dismiss() },
            snooze: { [weak self] in self?.snooze(event) }))
        window = panel
        current = event
        bringForward(panel)
        NSLog("Calendar Sync: showing the alert for “\(event.title)” at \(event.start)")
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
    /// Return or Escape typed into another app just as the alert appears would otherwise
    /// dismiss it before it was seen.
    var ignoresKeysUntil = Date.distantPast

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        Date() < ignoresKeysUntil || super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if [.keyDown, .keyUp].contains(event.type), Date() < ignoresKeysUntil { return }
        super.sendEvent(event)
    }
}

private struct EventAlertView: View {
    let event: SourceEvent
    let origin: EventOrigin?
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
            ZStack {
                VisualEffectBackground()
                Color.black.opacity(0.28)
            }
            .ignoresSafeArea()
            .opacity(shown ? 1 : 0)

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

            StartProgress(start: event.start, tint: tint)
                .modifier(Entrance(shown: shown, delay: 0.22))

            HStack(spacing: 10) {
                if let url = event.meetingURL {
                    Button {
                        NSWorkspace.shared.open(url)
                        dismiss()
                    } label: {
                        Label("Join call", systemImage: "video.fill")
                        KeyCap("⏎")
                    }
                    .buttonStyle(AlertButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
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

/// The alert's large, rounded buttons: filled in the accent color for the main action, gray
/// for the others, and text only for Ignore.
private struct AlertButtonStyle: ButtonStyle {
    var prominent = false
    var plain = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) { configuration.label }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : plain ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .padding(.horizontal, plain ? 8 : 16)
            .padding(.vertical, 9)
            .background {
                if prominent {
                    Capsule().fill(Color.accentColor).shadow(color: Color.accentColor.opacity(0.45), radius: 8, y: 4)
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
