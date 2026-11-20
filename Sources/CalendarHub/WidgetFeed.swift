import CalendarHubCore
import Combine
import Foundation
import WidgetKit

/// Writes what the desktop widget shows (`WidgetSnapshot`) while the widget is on in Settings:
/// after each sync, and every few minutes, so meetings added in Calendar.app show up too. The
/// file is in the app's Application Support folder, readable only by the user, and is deleted
/// when the widget is turned off.
@MainActor
final class WidgetFeed {
    private let settings: SettingsStore
    private let controller: SyncController
    private var observers: [AnyCancellable] = []
    private var timer: Timer?
    private var lastWritten: Data?

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.neteinstein.calendarhub")
            .appendingPathComponent(WidgetSnapshot.fileName)
    }

    init(settings: SettingsStore, controller: SyncController) {
        self.settings = settings
        self.controller = controller
        observers.append(controller.$lastSync.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        })
        observers.append(settings.$widgetEnabled.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        })
        let timer = Timer(timeInterval: 5 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard settings.widgetEnabled else {
            if FileManager.default.fileExists(atPath: Self.fileURL.path) {
                try? FileManager.default.removeItem(at: Self.fileURL)
                lastWritten = nil
                WidgetCenter.shared.reloadAllTimelines()
            }
            return
        }
        let now = Date()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        guard let targetID = settings.targetCalendarID,
              let end = calendar.date(byAdding: .day, value: 2, to: start),
              case .success(let events) = controller.eventKit.sourceEvents(calendarID: targetID, from: start, to: end)
        else { return }
        let snapshot = WidgetSnapshot.make(
            events: events, now: now,
            limitHours: settings.meetingLimit.isEnabled ? settings.meetingLimit.hours : nil,
            calendar: calendar
        ) { [settings, controller] event in
            // Only copies get a calendar of their own; the main calendar's meetings use the accent.
            guard MenuCalendar.originID(of: event) != nil,
                  let origin = EventOrigin.of(event, settings: settings, eventKit: controller.eventKit) else { return nil }
            return (origin.name, HexColor(origin.color)?.hex)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Written only when what the widget shows changed (not `written`), so its timeline isn't
        // reloaded every five minutes for nothing.
        var comparable = snapshot
        comparable.written = .distantPast
        guard let data = try? encoder.encode(snapshot), let key = try? encoder.encode(comparable), key != lastWritten else { return }
        do {
            let folder = Self.fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: Self.fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
            lastWritten = key
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            AppLog.write("Calendar Hub: couldn't write the widget's data: \(error)")
        }
    }
}
