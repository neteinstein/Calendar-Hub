import CalendarSyncCore
import Combine
import EventKit
import Foundation

/// The tasks of the menu's Tasks view, kept as reminders in Reminders (see `TaskItem`). Reads
/// them again whenever Reminders changes, and after each sync brings the tasks for an event in
/// step with it, so their due dates and nudges follow when it moves.
@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var access: EKAuthorizationStatus
    /// The last save or delete that failed, shown in the Tasks view until one works.
    @Published private(set) var problem: String?
    /// Keys of the linked events the main calendar no longer has: removed, cancelled, or moved
    /// out of reach.
    @Published private(set) var missingEvents: Set<String> = []
    /// A task the Tasks view opens in its editor when it next shows: a new one for an event
    /// picked in the List.
    @Published var draft: TaskItem?

    private let settings: SettingsStore
    private let eventKit: EventKitBridge
    private var observers: [AnyCancellable] = []
    private var storeObserver: NSObjectProtocol?
    private var pendingReload: Task<Void, Never>?

    init(settings: SettingsStore, controller: SyncController) {
        self.settings = settings
        eventKit = controller.eventKit
        access = controller.eventKit.reminderAccess
        // Reminders changed: here, in Reminders.app or on another device. One change can come
        // as several notifications, so they're read once they stop.
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: eventKit.store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSoon() }
        }
        observers.append(settings.$taskOptions.map(\.listID).removeDuplicates().dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadSoon() }
        })
        observers.append(controller.$lastSync.compactMap { $0 }.sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.realign() }
            }
        })
        Task { await reload() }
    }

    /// The Reminders list tasks are kept in.
    var list: EKCalendar? { eventKit.reminderList(id: settings.taskOptions.listID) }

    /// Asks for access to Reminders, then reads the tasks.
    func requestAccess() async {
        _ = await eventKit.requestReminderAccess()
        await reload()
    }

    /// Reads the tasks again, if Reminders can be read.
    func reload() async {
        let status = eventKit.reminderAccess
        // An event store made before access was granted can go on seeing no reminders.
        if status == .fullAccess, access != .fullAccess, eventKit.demo == nil { eventKit.store.reset() }
        access = status
        guard status == .fullAccess, let list else {
            tasks = []
            return
        }
        tasks = await eventKit.tasks(in: list)
    }

    private func reloadSoon() {
        pendingReload?.cancel()
        pendingReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    // MARK: - Changes

    /// Saves a new task, or the changes to one.
    func save(_ task: TaskItem) {
        guard let list else {
            problem = "There's no Reminders list to keep tasks in. Make one in Reminders."
            return
        }
        do {
            let saved = try eventKit.save(task, in: list)
            if let index = tasks.firstIndex(where: { $0.id == saved.id }) {
                tasks[index] = saved
            } else {
                tasks.append(saved)
            }
            problem = nil
        } catch {
            problem = "“\(task.title)” wasn't saved: \(error.localizedDescription)"
        }
    }

    /// Saves a new title and notes for the task with `id`, from its notes window. An empty
    /// title keeps the one it had; blank notes are none.
    func updateText(of id: String, title: String, notes: String) {
        guard var task = tasks.first(where: { $0.id == id }) else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes
        guard (!title.isEmpty && title != task.title) || notes != task.notes else { return }
        if !title.isEmpty { task.title = title }
        task.notes = notes
        save(task)
    }

    func toggleDone(_ task: TaskItem) {
        var task = task
        task.isCompleted.toggle()
        task.completionDate = task.isCompleted ? Date() : nil
        save(task)
    }

    func delete(_ task: TaskItem) {
        do {
            try eventKit.removeTask(task)
            tasks.removeAll { $0.id == task.id }
            problem = nil
        } catch {
            problem = "“\(task.title)” wasn't deleted: \(error.localizedDescription)"
        }
    }

    /// A new task, for `event` when there is one: due when it starts, with the nudge new
    /// tasks for an event get.
    func newTask(for event: SourceEvent? = nil) -> TaskItem {
        var task = TaskItem(title: "")
        guard let event else { return task }
        let calendar = Calendar.current
        task.event = TaskEventLink(event)
        task.due = event.isAllDay ? calendar.startOfDay(for: event.start) : event.start
        task.dueHasTime = !event.isAllDay
        if let nudge = settings.taskOptions.eventNudge?.date(anchor: task.due, anchorHasTime: task.dueHasTime, calendar: calendar),
           nudge > Date() {
            task.nudges = [nudge]
        }
        return task
    }

    /// The open tasks for the event with `key`.
    func openTasks(forEvent key: String) -> [TaskItem] {
        TaskPlanner.openTasks(forEvent: key, in: tasks)
    }

    // MARK: - Keeping up with events

    /// Brings the open tasks for an event in step with it, after a sync that may have moved,
    /// renamed or removed it.
    func realign() async {
        await reload()
        let linked = tasks.filter { !$0.isCompleted && $0.event != nil }
        let starts = linked.compactMap { $0.event?.start }
        let calendar = Calendar.current
        guard let earliest = starts.min(), let latest = starts.max(), let targetID = settings.targetCalendarID,
              let from = calendar.date(byAdding: .day, value: -1, to: min(earliest, Date())),
              let to = calendar.date(byAdding: .day, value: 60, to: max(latest, Date()))
        else {
            missingEvents = []
            return
        }
        guard case .success(let events) = eventKit.sourceEvents(calendarID: targetID, from: from, to: to) else { return }
        let byKey = Dictionary(events.filter { !$0.isCancelled }.map { ($0.key, $0) }) { first, _ in first }
        var missing: Set<String> = []
        for task in linked {
            guard let link = task.event else { continue }
            guard let event = byKey[link.key] else {
                missing.insert(link.key)
                continue
            }
            if let realigned = TaskPlanner.realigned(task, to: event, calendar: calendar) {
                NSLog("Calendar Sync: a task follows its event to \(event.start)")
                save(realigned)
            }
        }
        missingEvents = missing
    }
}
