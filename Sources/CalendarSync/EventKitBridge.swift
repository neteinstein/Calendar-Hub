import CalendarSyncCore
import EventKit
import Foundation

/// Everything that touches Calendar.app's data goes through here.
@MainActor
final class EventKitBridge {
    let store = EKEventStore()
    /// Sample calendars read in place of Calendar.app's, with nothing written (see `DemoCalendars`).
    let demo: DemoCalendars?

    init(demo: DemoCalendars? = nil) {
        self.demo = demo
    }

    var hasAccess: Bool {
        demo != nil || EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func requestAccess() async -> Bool {
        if hasAccess { return true }
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    /// All event calendars, grouped by account then name.
    func calendars() -> [EKCalendar] {
        if let demo { return demo.calendars }
        return store.calendars(for: .event).sorted {
            ($0.source.title, $0.title) < ($1.source.title, $1.title)
        }
    }

    func calendar(id: String?) -> EKCalendar? {
        if let demo { return demo.calendars.first { $0.calendarIdentifier == id } }
        return id.flatMap { store.calendar(withIdentifier: $0) }
    }

    // MARK: - Reading

    func sourceEvents(calendarID: String, from start: Date, to end: Date) -> SourceFetchResult {
        if let demo { return .success(demo.events(calendarID: calendarID, from: start, to: end)) }
        guard let calendar = store.calendar(withIdentifier: calendarID) else {
            return .failure("Calendar not found in Calendar.app")
        }
        // EventKit expands recurring meetings into one EKEvent per occurrence.
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        return .success(store.events(matching: predicate).compactMap { Self.sourceEvent($0) })
    }

    /// Nil for an event without dates. EventKit declares them as never nil but doesn't
    /// promise it, and reading a missing one would crash the app on every sync.
    static func sourceEvent(_ event: EKEvent) -> SourceEvent? {
        guard let start = event.startDate as Date?, let end = event.endDate as Date? else { return nil }
        let id: String = event.calendarItemIdentifier
        // Occurrences of a recurring meeting share one identifier, so add the original
        // occurrence date (which stays the same when one occurrence is moved).
        let isRecurring = event.hasRecurrenceRules || event.isDetached
        let occurrence: Date = event.occurrenceDate ?? start
        let key = isRecurring ? "\(id)|\(occurrence.ISO8601Format())" : id

        let myStatus = event.attendees?.first(where: { $0.isCurrentUser })?.participantStatus

        return SourceEvent(
            key: key,
            title: event.title ?? "",
            start: start,
            end: end,
            isAllDay: event.isAllDay,
            timeZone: event.timeZone,
            isDeclined: myStatus == .declined,
            isCancelled: event.status == .canceled,
            // Exchange's "Out of office" comes through as unavailable.
            isOutOfOffice: event.availability == .unavailable,
            meetingURL: MeetingLink.find(url: event.url, location: event.location, notes: event.notes),
            notes: event.notes,
            location: event.location
        )
    }

    /// Copies this app made in the target calendar (recognised by the marker in their notes).
    func existingCopies(targetID: String, from start: Date, to end: Date) -> [ExistingCopy]? {
        guard let calendar = store.calendar(withIdentifier: targetID) else { return nil }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        return store.events(matching: predicate).compactMap { event in
            guard let marker = CopyMarker.find(in: event.notes), let eventID = event.eventIdentifier,
                  let start = event.startDate as Date?, let end = event.endDate as Date?
            else { return nil }
            // Exchange and Google may drop the event URL. Read it the way we wrote it, so
            // unchanged copies aren't rewritten on every sync.
            let notes = Self.storedNotes(event)
            return ExistingCopy(
                eventID: eventID,
                marker: marker,
                title: event.title ?? "",
                start: start,
                end: end,
                isAllDay: event.isAllDay,
                url: event.url ?? MeetingLink.firstMeetingLink(in: notes),
                notes: notes,
                location: event.location
            )
        }
    }

    /// The Busy events in a secondary calendar (see `CopyFormatter.isBusyEvent`). Ones made by
    /// older versions come with their marker.
    func busyEvents(calendarID: String, from start: Date, to end: Date) -> [ExistingCopy]? {
        guard let calendar = store.calendar(withIdentifier: calendarID) else { return nil }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        return store.events(matching: predicate).compactMap { event in
            // Busy events never have attendees or repeat, so a secondary-calendar meeting that only looks
            // like one is left alone.
            guard !event.hasAttendees, !event.hasRecurrenceRules,
                  CopyFormatter.isBusyEvent(title: event.title, notes: event.notes),
                  let eventID = event.eventIdentifier,
                  let start = event.startDate as Date?, let end = event.endDate as Date?
            else { return nil }
            return ExistingCopy(
                eventID: eventID,
                marker: CopyMarker.find(in: event.notes),
                title: event.title ?? "",
                start: start,
                end: end,
                isAllDay: event.isAllDay,
                url: event.url,
                notes: Self.storedNotes(event),
                location: event.location,
                hasAlerts: event.hasAlarms
            )
        }
    }

    /// Exchange and Google may change line endings. Read notes the way we wrote them, so
    /// unchanged events aren't rewritten on every sync.
    private static func storedNotes(_ event: EKEvent) -> String {
        (event.notes ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Writing

    /// Applies the plan in one commit. Returns a message per action that failed.
    func apply(_ plan: SyncPlan, targetID: String) -> [String] {
        guard let calendar = store.calendar(withIdentifier: targetID) else {
            return ["Target calendar not found in Calendar.app"]
        }
        guard calendar.allowsContentModifications else {
            return ["“\(calendar.title)” is read-only. Pick a calendar you can edit."]
        }

        var errors: [String] = []
        for action in plan.actions {
            do {
                switch action {
                case .create(let spec):
                    let event = EKEvent(eventStore: store)
                    event.calendar = calendar
                    fill(event, with: spec, calendar: calendar)
                    try store.save(event, span: .thisEvent, commit: false)
                case .update(let eventID, let spec):
                    guard let event = store.event(withIdentifier: eventID) else { continue }
                    fill(event, with: spec, calendar: calendar)
                    try store.save(event, span: .thisEvent, commit: false)
                case .delete(let eventID, _, _):
                    guard let event = store.event(withIdentifier: eventID) else { continue }
                    try store.remove(event, span: .thisEvent, commit: false)
                }
            } catch {
                errors.append("\(action.title): \(error.localizedDescription)")
            }
        }

        do {
            try store.commit()
        } catch {
            store.reset()
            errors.append("Saving to Calendar failed: \(error.localizedDescription)")
        }
        return errors
    }

    // MARK: - Tasks

    /// Tasks are reminders in Reminders, asked for separately from the calendars and only
    /// once the Tasks view is used.
    var reminderAccess: EKAuthorizationStatus {
        demo != nil ? .fullAccess : EKEventStore.authorizationStatus(for: .reminder)
    }

    func requestReminderAccess() async -> Bool {
        if reminderAccess == .fullAccess { return true }
        do {
            return try await store.requestFullAccessToReminders()
        } catch {
            return false
        }
    }

    /// The Reminders lists that can take new reminders, grouped by account then name.
    func reminderLists() -> [EKCalendar] {
        if let demo { return [demo.reminders] }
        return store.calendars(for: .reminder).filter(\.allowsContentModifications).sorted {
            ($0.source.title, $0.title) < ($1.source.title, $1.title)
        }
    }

    /// The list with `id`, or Reminders' list for new reminders when there's no `id` or the
    /// list is gone.
    func reminderList(id: String?) -> EKCalendar? {
        if let demo { return demo.reminders }
        if let id, let list = store.calendar(withIdentifier: id) { return list }
        return store.defaultCalendarForNewReminders()
    }

    /// The open tasks in `list`, and those done in the last week.
    func tasks(in list: EKCalendar) async -> [TaskItem] {
        if let demo { return demo.tasks }
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date())
        let predicates = [
            store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [list]),
            store.predicateForCompletedReminders(withCompletionDateStarting: weekAgo, ending: nil, calendars: [list]),
        ]
        var tasks: [TaskItem] = []
        for predicate in predicates {
            tasks += await withCheckedContinuation { continuation in
                // Called on a queue of EventKit's; the reminders don't leave it.
                store.fetchReminders(matching: predicate) { @Sendable reminders in
                    continuation.resume(returning: (reminders ?? []).map { Self.task($0, calendar: calendar) })
                }
            }
        }
        return tasks
    }

    nonisolated private static func task(_ reminder: EKReminder, calendar: Calendar) -> TaskItem {
        let dueParts = reminder.dueDateComponents
        let due = dueParts.flatMap { parts in
            (parts.calendar ?? calendar).date(from: parts).map { parts.hour == nil ? calendar.startOfDay(for: $0) : $0 }
        }
        // Alerts set by date, and those Reminders keeps relative to the due date. Location
        // alerts aren't nudges at a time, and are left as they are.
        let nudges = (reminder.alarms ?? []).compactMap { alarm in
            alarm.absoluteDate ?? (alarm.structuredLocation == nil ? due?.addingTimeInterval(alarm.relativeOffset) : nil)
        }
        return TaskItem(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            notes: reminder.notes,
            due: due,
            dueHasTime: dueParts?.hour != nil,
            isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate,
            creationDate: reminder.creationDate,
            nudges: nudges.sorted(),
            event: TaskEventLink(url: reminder.url)
        )
    }

    /// Saves `task` as a new reminder in `list`, or over the reminder it was read from.
    /// Returns the saved task, with its id when it was new.
    func save(_ task: TaskItem, in list: EKCalendar) throws -> TaskItem {
        var task = task
        if let demo {
            if task.id.isEmpty {
                task.id = UUID().uuidString
                task.creationDate = Date()
            }
            demo.save(task)
            return task
        }
        let existing = task.id.isEmpty ? nil : store.calendarItem(withIdentifier: task.id) as? EKReminder
        let reminder = existing ?? EKReminder(eventStore: store)
        // As it is now, so the due date and the alerts are only rewritten when they changed:
        // saving notes as they're typed mustn't set the alerts again each time.
        let current = existing.map { Self.task($0, calendar: .current) }
        if reminder.calendar == nil { reminder.calendar = list }
        reminder.title = task.title
        reminder.notes = task.notes
        if current?.due != task.due || current?.dueHasTime != task.dueHasTime {
            reminder.dueDateComponents = task.due.map { due in
                Calendar.current.dateComponents(
                    task.dueHasTime ? [.calendar, .year, .month, .day, .hour, .minute] : [.calendar, .year, .month, .day],
                    from: due)
            }
        }
        if current?.nudges != task.nudges {
            let locationAlarms = (reminder.alarms ?? []).filter { $0.structuredLocation != nil }
            reminder.alarms = locationAlarms + task.nudges.map { EKAlarm(absoluteDate: $0) }
        }
        // The link is ours; a URL put there some other way is kept unless the task has an event.
        if let event = task.event {
            reminder.url = event.url
        } else if TaskEventLink(url: reminder.url) != nil {
            reminder.url = nil
        }
        reminder.isCompleted = task.isCompleted
        try store.save(reminder, commit: true)
        return Self.task(reminder, calendar: .current)
    }

    func removeTask(_ task: TaskItem) throws {
        if let demo {
            demo.remove(task)
            return
        }
        guard let reminder = store.calendarItem(withIdentifier: task.id) as? EKReminder else { return }
        try store.remove(reminder, commit: true)
    }

    private func fill(_ event: EKEvent, with spec: CopySpec, calendar: EKCalendar) {
        event.title = spec.title
        event.isAllDay = spec.isAllDay
        if let timeZone = spec.timeZone { event.timeZone = timeZone }
        event.startDate = spec.start
        event.endDate = spec.end
        event.url = spec.url
        event.notes = spec.notes
        event.location = spec.location
        // A Busy event stands in for a main-calendar event that alerts already, so it has no
        // alerts of its own, and any the calendar added are taken off.
        if spec.marker == nil { event.alarms = nil }
        if spec.isOutOfOffice, calendar.supportedEventAvailabilities.contains(.unavailable) {
            event.availability = .unavailable
        } else if calendar.supportedEventAvailabilities.contains(.busy) {
            event.availability = .busy
        }
    }
}

extension SyncAction {
    var title: String {
        switch self {
        case .create(let spec), .update(_, let spec): spec.title
        case .delete(_, let title, _): title
        }
    }

    var start: Date {
        switch self {
        case .create(let spec), .update(_, let spec): spec.start
        case .delete(_, _, let start): start
        }
    }

    var verb: String {
        switch self {
        case .create: "Add"
        case .update: "Update"
        case .delete: "Remove"
        }
    }
}
