import AppKit
import CalendarHubCore

/// The menu bar item's right-click menu: Share availability in one click, with the panel's last
/// choices of time zone and slot length, or the panel itself.
///
/// `MenuBarExtra` has no right-click menu of its own, and opens its window on any click. So a
/// right-click (or Control-click) on the app's own status bar window is caught before it gets
/// there, and this menu pops up under the item instead.
@MainActor
final class MenuBarRightClickMenu: NSObject {
    private let settings: SettingsStore
    private let controller: SyncController
    private var monitor: Any?

    init(settings: SettingsStore, controller: SyncController) {
        self.settings = settings
        self.controller = controller
        super.init()
        // A local monitor sees only this app's events, so only our own menu bar item.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control) else { return event }
            let windowNumber = event.windowNumber
            let shown = MainActor.assumeIsolated { self?.popUp(inWindowNumber: windowNumber) ?? false }
            return shown ? nil : event
        }
    }

    /// Pops the menu up under the menu bar item, if the window is the item's. False otherwise.
    private func popUp(inWindowNumber number: Int) -> Bool {
        guard let window = NSApp.window(withWindowNumber: number), Self.isStatusItem(window),
              let view = window.contentView else { return false }
        menu().popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 5 : -5), in: view)
        return true
    }

    /// The window AppKit puts a menu bar item in.
    private static func isStatusItem(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).contains("StatusBarWindow")
    }

    private func menu() -> NSMenu {
        let menu = NSMenu()
        let share = AvailabilityShare(settings: settings, controller: controller)
        var header = "Share availability"
        if !share.place.isHere { header += " · \(share.place.name) time" }
        menu.addItem(.sectionHeader(title: header))
        let readable = settings.targetCalendarID != nil
        for span in Availability.Span.allCases {
            let item = NSMenuItem(title: "Copy \(span.title.prefix(1).lowercased() + span.title.dropFirst())",
                                  action: readable ? #selector(copy(_:)) : nil, keyEquivalent: "")
            item.target = self
            item.representedObject = span.rawValue
            item.toolTip = "Copies your free times in all your calendars, as Share availability last made them"
            menu.addItem(item)
        }
        let open = NSMenuItem(title: "Open Share availability…", action: #selector(openPanel(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        return menu
    }

    @objc private func copy(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let span = Availability.Span(rawValue: raw),
              let events = AvailabilityShare.events(settings: settings, controller: controller) else { return }
        var share = AvailabilityShare(settings: settings, controller: controller)
        share.span = span
        AvailabilityShare.copy(share.text(events))
    }

    /// Opens the menu at Share availability, as a click on the item would open it.
    @objc private func openPanel(_ item: NSMenuItem) {
        MenuPanel.shared.sharingAvailability = true
        // After this menu has closed, or the click goes nowhere.
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: Self.isStatusItem),
                  let button = Self.button(in: window.contentView) else { return }
            button.performClick(nil)
        }
    }

    private static func button(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        return view.subviews.lazy.compactMap { button(in: $0) }.first
    }
}
