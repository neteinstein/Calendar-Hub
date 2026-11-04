import CalendarSyncCore
import SwiftUI

/// The popover shown from the menu bar icon.
struct MenuView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController
    #if compiler(>=6.0)
    // Not in the SDK of Xcode 15 and older toolchains, which build with the SettingsLink below.
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if settings.menuCalendarEnabled {
                MenuCalendarView()
                Divider()
            } else {
                Text("Calendar Sync").font(.headline)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(controller.isSyncing ? "Syncing…" : controller.lastSummary)
                if let lastSync = controller.lastSync {
                    (Text("Last synced ") + Text(lastSync, style: .relative) + Text(" ago"))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            // Problems are from the last sync; hide them while a new one runs so they don't
            // look current. The sync replaces them with fresh results when it finishes.
            if !controller.isSyncing {
                ForEach(controller.problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            let outlookSources = settings.sources.filter { $0.kind == .outlookWeb }
            if !outlookSources.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Open web calendars")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    // In a row while they fit, one per line otherwise.
                    ViewThatFits(in: .horizontal) {
                        HStack { outlookButtons(outlookSources) }
                        VStack(alignment: .leading) { outlookButtons(outlookSources) }
                    }
                }
            }

            Divider()

            HStack {
                Button("Quit", action: confirmQuit)
                    .keyboardShortcut("q")

                Spacer()

                #if compiler(>=6.0)
                Button("Settings…", action: showSettings)
                    .keyboardShortcut(",")
                #else
                SettingsLink { Text("Settings…") }
                    .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
                #endif

                Button("Sync now") {
                    Task { await controller.syncNow() }
                }
                // Enabled without access too: a sync checks again whether access was granted.
                .disabled(controller.isSyncing)
                .keyboardShortcut("r")
            }
        }
        .padding(14)
        .frame(width: settings.menuCalendarEnabled ? 360 : 320)
        // The menu window's own material lets a white window behind it wash the text out; the
        // window background, nearly opaque, keeps it readable while still hinting at the desktop.
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.92).ignoresSafeArea())
        .background(WindowTopAnchor())
    }

    /// A button per Outlook web calendar, named as in Settings, or by its prefix for copies
    /// while it has no name.
    private func outlookButtons(_ sources: [SourceConfig]) -> some View {
        ForEach(sources) { source in
            Button(source.name ?? source.calendarName) {
                controller.showOutlookWindow(for: source)
            }
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

    #if compiler(>=6.0)
    /// Opens Settings and brings it in front of other apps. A `SettingsLink` with a tap gesture
    /// on top sometimes lost the click, and a menu bar app isn't always allowed to come to the
    /// front, so the window could open behind other windows, or stay there if it was already
    /// open: either way, nothing seemed to happen.
    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        // The window exists only after `openSettings` returns.
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window"
            }) else { return }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
    #endif
}
