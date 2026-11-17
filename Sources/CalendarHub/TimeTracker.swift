import AppKit
import CalendarHubCore

/// Time Tracking's log: the timer, the time assigned to clients, and the meetings given to
/// another client. Kept in a file of its own in Application Support, on this Mac only, and
/// only once something is logged: with nothing logged, there's no file. Meetings are read
/// from the main calendar each time and never copied into it.
@MainActor
final class TimeTracker: ObservableObject {
    @Published private(set) var log: TimeLog

    private let settings: SettingsStore
    /// Nil for the demo, which keeps its sample log in memory.
    let fileURL: URL?
    /// When the Mac went to sleep, to ask on waking whether the timer keeps that time.
    private var sleptAt: Date?
    private var checks: Timer?
    private var observers: [NSObjectProtocol] = []

    /// Sleep shorter than this doesn't ask about the timer.
    private static let sleepWorthAsking: TimeInterval = 10 * 60

    static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("org.neteinstein.calendarhub/time-tracking.json")
    }

    init(settings: SettingsStore, fileURL: URL?, log: TimeLog? = nil) {
        self.settings = settings
        self.fileURL = fileURL
        self.log = log ?? fileURL.flatMap(Self.read) ?? TimeLog()
        stopIfForgotten()

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleptAt = Date() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        })
        // Now and then, so a timer left running overnight stops at the end of the working day
        // even while the menu stays closed. In the common modes, so it runs with the menu open.
        let timer = Timer(timeInterval: 5 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopIfForgotten() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        checks = timer
    }

    // MARK: - Timer

    /// The running timer, while Time Tracking and its timer are on.
    var running: RunningTimer? {
        settings.timeTracking.timerAvailable ? log.running : nil
    }

    /// Starts the timer for `client`, stopping the one running first.
    func start(_ client: TimeClient, at date: Date = Date()) {
        guard settings.timeTracking.timerAvailable else { return }
        if log.running != nil { stop(at: date) }
        log.running = RunningTimer(client: client, start: date)
        save()
    }

    /// Stops the timer and logs its time. Less than a minute isn't logged.
    func stop(at date: Date = Date()) {
        guard let running = log.running else { return }
        log.running = nil
        if date.timeIntervalSince(running.start) >= 60 {
            log.entries.append(TimeEntry(client: running.client, start: running.start, end: date, source: .timer))
        }
        save()
    }

    /// A timer still running long after the working day it started in stops at the end of that
    /// day, flagged so the user can keep the rest.
    func stopIfForgotten(now: Date = Date()) {
        guard let running = log.running,
              let end = TimeTracking.forgottenTimerEnd(start: running.start, now: now,
                                                       workingHours: settings.menuCalendar.workingHours,
                                                       calendar: .current) else { return }
        log.running = nil
        if end.timeIntervalSince(running.start) >= 60 {
            var entry = TimeEntry(client: running.client, start: running.start, end: end, source: .timer)
            entry.stoppedLate = now
            log.entries.append(entry)
        }
        AppLog.write("Time Tracking: a timer left running was stopped at the end of the working day.")
        save()
    }

    /// After a sleep with the timer running, asks whether the timer keeps the time the Mac slept.
    private func didWake() {
        let wake = Date()
        defer { sleptAt = nil }
        stopIfForgotten(now: wake)
        guard let slept = sleptAt, let running, running.start < slept,
              wake.timeIntervalSince(slept) >= Self.sleepWorthAsking else { return }
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Keep the time your Mac was asleep?"
        alert.informativeText = "The timer for \(running.clientName) was running while your Mac slept, from "
            + "\(slept.formatted(time)) to \(wake.formatted(time)). Leave it out, and the timer goes on from now."
        alert.addButton(withTitle: "Leave It Out")
        alert.addButton(withTitle: "Keep It")
        guard alert.runModal() == .alertFirstButtonReturn, log.running == running else { return }
        if slept.timeIntervalSince(running.start) >= 60 {
            log.entries.append(TimeEntry(client: running.client, start: running.start, end: slept, source: .timer))
        }
        log.running?.start = wake
        save()
    }

    // MARK: - Entries

    /// Gives untracked time to `client`.
    func assign(_ gap: DateInterval, to client: TimeClient) {
        log.entries.append(TimeEntry(client: client, start: gap.start, end: gap.end, source: .assigned))
        save()
    }

    /// Logs a meeting to `client`, or back to its own calendar's client with nil.
    func reassignMeeting(key: String, to client: TimeClient?) {
        log.meetingClients[key] = client
        save()
    }

    /// Gives a timer entry or assigned time to another client.
    func changeClient(of entryID: String, to client: TimeClient) {
        guard let index = index(of: entryID) else { return }
        log.entries[index].clientID = client.id
        log.entries[index].clientName = client.name
        save()
    }

    func delete(_ entryID: String) {
        guard let index = index(of: entryID) else { return }
        log.entries.remove(at: index)
        save()
    }

    /// Keeps the time a forgotten timer ran past the end of the working day.
    func keepLateTime(of entryID: String) {
        guard let index = index(of: entryID), let late = log.entries[index].stoppedLate else { return }
        log.entries[index].end = late
        log.entries[index].stoppedLate = nil
        save()
    }

    /// Keeps a forgotten timer stopped at the end of the working day.
    func dismissLateStop(of entryID: String) {
        guard let index = index(of: entryID) else { return }
        log.entries[index].stoppedLate = nil
        save()
    }

    /// The timer's entries stopped at the end of the working day, not looked at yet.
    var lateStops: [TimeEntry] { log.entries.filter { $0.stoppedLate != nil } }

    /// Deletes everything logged, the running timer too, and the file with it.
    func deleteAll() {
        log = TimeLog()
        save()
    }

    /// A piece of an entry (`id#1`) belongs to the entry it was cut from.
    private func index(of entryID: String) -> Int? {
        let id = entryID.split(separator: "#").first.map(String.init) ?? entryID
        return log.entries.firstIndex { $0.id == id }
    }

    /// The id of the running timer's entry, which isn't in the log until it stops.
    static let runningID = "running"

    /// The timer's entries and assigned time, with the running timer up to `now`.
    func loggedEntries(now: Date) -> [TimeEntry] {
        var entries = log.entries
        if let running, now > running.start {
            entries.append(TimeEntry(id: Self.runningID, clientID: running.clientID, clientName: running.clientName,
                                     start: running.start, end: now, source: .timer))
        }
        return entries
    }

    /// Everything logged within `interval`, without overlaps: the meetings in `events` while
    /// they're counted, the timer and the time assigned.
    func entries(events: [SourceEvent], in interval: DateInterval, now: Date) -> [TimeEntry] {
        let options = settings.timeTracking
        let meetings = options.countsMeetings
            ? TimeTracking.meetingEntries(events: events, clients: settings.timeClients,
                                          internalClient: options.internalClient,
                                          reassigned: log.meetingClients, now: now)
            : []
        return TimeTracking.clip(TimeTracking.combine(meetings: meetings, logged: loggedEntries(now: now)), to: interval)
    }

    // MARK: - File

    private static func read(_ url: URL) -> TimeLog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(TimeLog.self, from: data)
        } catch {
            AppLog.write("Time Tracking couldn't read its log: \(error)")
            return nil
        }
    }

    /// Writes the log, readable by this user only, or removes the file when nothing is logged.
    private func save() {
        guard let fileURL else { return }
        let fileManager = FileManager.default
        do {
            if log.isEmpty {
                if fileManager.fileExists(atPath: fileURL.path) { try fileManager.removeItem(at: fileURL) }
                return
            }
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(log).write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            AppLog.write("Time Tracking couldn't save its log: \(error)")
        }
    }
}
