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
        panel.contentView = NSHostingView(rootView: EventAlertView(event: event) { [weak self] in
            self?.dismiss()
        })
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
    let dismiss: () -> Void

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

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                Text("\(Text(event.start, format: .dateTime.hour().minute())) – \(Text(event.end, format: .dateTime.hour().minute()))")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(event.title.isEmpty ? "Busy" : event.title)
                    .font(.system(size: 34, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                if let room {
                    Label(room, systemImage: "mappin.and.ellipse")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if let url = event.meetingURL {
                        Button {
                            NSWorkspace.shared.open(url)
                            dismiss()
                        } label: {
                            Label("Join call", systemImage: "video.fill").frame(minWidth: 120)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        if let room {
                            Button { dismiss() } label: {
                                Label("Go to \(room)", systemImage: "figure.walk").frame(minWidth: 120)
                            }
                            .buttonStyle(.bordered)
                        }
                    } else if let room {
                        Button { dismiss() } label: {
                            Label("Go to \(room)", systemImage: "figure.walk").frame(minWidth: 120)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                    Button("Ignore", action: dismiss)
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                }
                .controlSize(.large)
                .padding(.top, 12)
            }
            .padding(44)
            .frame(maxWidth: 640)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
    }
}
