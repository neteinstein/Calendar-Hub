import CalendarSyncCore
import SwiftUI

/// The popover shown from the menu bar icon.
struct MenuView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController
    @Environment(\.openSettings) private var openSettings

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
                ForEach(outlookSources) { source in
                    Button("Open Outlook – \(source.calendarName)") {
                        controller.showOutlookWindow(for: source)
                    }
                }
            }

            Divider()

            HStack {
                Button("Sync now") {
                    Task { await controller.sync() }
                }
                // Enabled without access too: a sync checks again whether access was granted.
                .disabled(controller.isSyncing)
                .keyboardShortcut("r")

                Spacer()

                Button("Settings…", action: showSettings)
                    .keyboardShortcut(",")
            }

            Button("Quit Calendar Sync") { NSApp.terminate(nil) }
                .buttonStyle(.link)
                .font(.callout)
        }
        .padding(14)
        .frame(width: settings.menuCalendarEnabled ? 360 : 320)
        .background(WindowTopAnchor())
    }

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
}
