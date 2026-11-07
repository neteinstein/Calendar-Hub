import CalendarSyncCore
import EventKit
import Foundation
import WebKit

/// Runs syncs: on a timer (each secondary calendar on its own interval), when Calendar data
/// changes, and on demand.
@MainActor
final class SyncController: ObservableObject {
    @Published private(set) var hasCalendarAccess = false
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastSummary = "Not synced yet"
    @Published private(set) var problems: [String] = []
    /// What keeps syncing from starting at all, shown in the menu with its fix.
    @Published private(set) var setupProblem: SetupProblem?
    /// The secondary calendars the last sync couldn't read. Their reasons are in `problems` too.
    @Published private(set) var unreadSources: [UnreadSource] = []
    /// Per secondary calendar: when a sync last read it and how many copies it has.
    @Published private(set) var sourceStatus: [UUID: SourceStatus] = [:]
    @Published private(set) var preview: SyncPlan?
    /// Busy events the next sync would add to secondary calendars, per secondary calendar.
    @Published private(set) var busyPreview: [BusyPreview] = []

    struct BusyPreview: Identifiable {
        let id: UUID
        let calendarName: String
        let plan: SyncPlan
    }

    enum SetupProblem: Hashable {
        case noAccess, noMainCalendar, mainCalendarMissing
    }

    struct UnreadSource: Identifiable, Hashable {
        let id: UUID
        let name: String
        let reason: String

        /// As it appears in `problems`.
        var problem: String { "\(name): \(reason)" }
    }

    struct SourceStatus: Hashable {
        /// When a sync last read it without a problem.
        var lastRead: Date?
        /// Its copies in the main calendar, from today to the end of the sync window.
        var copies = 0
    }

    let settings: SettingsStore
    let eventKit: EventKitBridge
    private var outlookSources: [UUID: OutlookWebSource] = [:]
    private var timer: Timer?
    /// When each secondary calendar was last read by a sync that applied its changes.
    private var lastRead: [UUID: Date] = [:]
    private var storeObserver: NSObjectProtocol?
    private var pendingChangeSync: Task<Void, Never>?
    /// Our own writes also fire EKEventStoreChanged; ignore those. On a clock that setting
    /// the time doesn't move, so setting it back can't make that last for hours.
    private var ignoreStoreChangesUntil = ContinuousClock.now
    /// A sync asked for while another was running. It runs as soon as that one finishes, so
    /// a Calendar change or a settings change made meanwhile isn't lost.
    private var queuedSync: QueuedSync?

    private struct QueuedSync {
        /// nil syncs every source.
        var only: Set<UUID>?
    }

    /// With `demo`, it shows the sample calendars as just synced and never syncs anything.
    init(settings: SettingsStore, demo: DemoCalendars? = nil) {
        self.settings = settings
        eventKit = EventKitBridge(demo: demo)
        Task { await start() }
    }

    func start() async {
        if let demo = eventKit.demo {
            hasCalendarAccess = true
            lastSync = Date().addingTimeInterval(-2 * 60)
            lastSummary = "Up to date (27 copied meetings)"
            sourceStatus = demo.sourceStatus
            return
        }
        // The status, not the request's answer, so `hasCalendarAccess` always matches what
        // sync() compares it with, and the two can't keep sending each other back here.
        _ = await eventKit.requestAccess()
        hasCalendarAccess = eventKit.hasAccess
        // Runs without access too, so access granted later in System Settings is noticed.
        if timer == nil { startTimer() }
        guard hasCalendarAccess else {
            lastSummary = "No calendar access. Allow it in System Settings › Privacy & Security › Calendars."
            problems = []
            unreadSources = []
            setupProblem = .noAccess
            return
        }
        if storeObserver == nil {
            storeObserver = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: eventKit.store, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.calendarDataChanged() }
            }
        }
        await sync()
    }

    /// Calendar access was granted or revoked in System Settings since it was last checked.
    private func accessChanged() async {
        // An event store made before access was granted can go on seeing no calendars.
        if eventKit.hasAccess { eventKit.store.reset() }
        await start()
    }

    /// Checks every minute which secondary calendars are due, so each can have its own interval
    /// and interval changes apply without restarting anything.
    private func startTimer() {
        timer?.invalidate()
        // Scheduled on the main run loop, so the block runs on the main actor.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.timerFired() }
            }
        }
        timer?.tolerance = 10
    }

    private func timerFired() async {
        if hasCalendarAccess != eventKit.hasAccess {
            await accessChanged()
        } else if hasCalendarAccess {
            await syncDueSources()
        }
    }

    private func syncDueSources() async {
        let due = SyncSchedule.dueSources(
            settings.sources, lastRead: lastRead, defaultMinutes: settings.intervalMinutes, now: Date())
        guard !due.isEmpty else { return }
        await sync(only: due)
    }

    /// Calendar.app changed (e.g. a secondary-calendar meeting moved): resync the Calendar.app sources
    /// after a short pause. Outlook web sources wait for their interval, since reading them is slow.
    private func calendarDataChanged() {
        guard ContinuousClock.now > ignoreStoreChangesUntil else { return }
        pendingChangeSync?.cancel()
        pendingChangeSync = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let calendarApp = self.settings.sources.filter {
                if case .eventKit = $0.kind { true } else { false }
            }
            await self.sync(only: Set(calendarApp.map(\.id)))
        }
    }

    // MARK: - Sync

    var window: (start: Date, end: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: settings.options.daysAhead + 1, to: start)!
        return (start, end)
    }

    /// Reads the sources and works out the changes. With `apply == false` nothing is written
    /// (used for the preview). With `only`, just those sources are read; copies of the others
    /// are left as they are.
    @discardableResult
    func sync(apply: Bool = true, only: Set<UUID>? = nil) async -> SyncPlan? {
        // Calendar access can be granted or revoked in System Settings while the app runs.
        // start() then syncs, if it can.
        if hasCalendarAccess != eventKit.hasAccess {
            await accessChanged()
            return nil
        }
        guard hasCalendarAccess, eventKit.demo == nil else { return nil }
        guard !isSyncing else {
            if apply { queue(only: only) }
            return nil
        }
        guard let targetID = settings.targetCalendarID, eventKit.calendar(id: targetID) != nil else {
            lastSummary = "Choose your main calendar to copy into in Settings."
            setupProblem = settings.targetCalendarID == nil ? .noMainCalendar : .mainCalendarMissing
            return nil
        }
        isSyncing = true
        defer {
            isSyncing = false
            runQueuedSync()
        }

        let (start, end) = window
        let selected = settings.sources.filter { $0.isEnabled && only?.contains($0.id) != false }
        // All marked read up front: a timer tick while an earlier one is read (Outlook takes a
        // minute) mustn't queue another read of the ones still to come.
        if apply { for source in selected { lastRead[source.id] = Date() } }
        var results: [(config: SourceConfig, result: SourceFetchResult)] = []
        /// Outlook on the web calendars read this time, whose Busy events can be updated now.
        var outlookRead: [SourceConfig] = []
        for source in selected {
            switch source.kind {
            case .eventKit(let calendarID):
                if calendarID == targetID { continue } // never copy a calendar into itself
                // Copies are prefixed with the calendar's current name, even if it was renamed.
                var source = source
                if let calendar = eventKit.calendar(id: calendarID) { source.calendarName = calendar.title }
                results.append((source, eventKit.sourceEvents(calendarID: calendarID, from: start, to: end)))
            case .outlookWeb:
                let result = await outlookSource(for: source.id).fetch(from: start, to: end)
                results.append((source, result))
                if case .success = result { outlookRead.append(source) }
            }
        }

        guard let existing = eventKit.existingCopies(targetID: targetID, from: start, to: end) else {
            lastSummary = "Target calendar not found."
            setupProblem = .mainCalendarMissing
            return nil
        }
        setupProblem = nil
        let plan = SyncPlanner.plan(sources: results, existing: existing, options: settings.options)

        let unread = plan.failedSources.map { id, reason in
            UnreadSource(id: id, name: settings.sources.first { $0.id == id }?.calendarName ?? "Source", reason: reason)
        }
        var problems = unread.map(\.problem)
        if apply {
            ignoreStoreChangesUntil = .now + .seconds(5)
            problems += eventKit.apply(plan, targetID: targetID)
            ignoreStoreChangesUntil = .now + .seconds(5)
        }

        // Then, when syncing both ways, show the main calendar (now including the new copies)
        // as Busy in the secondary calendars that ask for it, and take the Busy events back from
        // ones that no longer do.
        var busyPlans: [BusyPreview] = []
        for source in settings.sources where source.isEnabled {
            guard case .eventKit(let calendarID) = source.kind, calendarID != targetID,
                  let calendar = eventKit.calendar(id: calendarID) else { continue }
            let showsBusy = settings.twoWaySync && source.showBusyInSecondary
            guard calendar.allowsContentModifications else {
                if showsBusy { problems.append("\(calendar.title): read-only, so Busy events can't be added.") }
                continue
            }
            let existingBusy = eventKit.busyEvents(calendarID: calendarID, from: start, to: end) ?? []
            let busy = showsBusy
                ? SyncPlanner.planBusy(
                    for: source,
                    mainEvents: eventKit.sourceEvents(calendarID: targetID, from: start, to: end),
                    existing: existingBusy,
                    options: settings.options,
                    clearingAlerts: !settings.busyAlertsCleared)
                : SyncPlanner.planBusyRemoval(
                    existing: existingBusy, addedHere: settings.busyCalendarIDs.contains(calendarID))
            problems += busy.failedSources.values.map { "\(calendar.title) (Busy): \($0)" }
            if apply {
                // Recorded before writing, so the Busy events are taken back later even if
                // some of them fail to save now.
                if showsBusy { settings.busyCalendarIDs.insert(calendarID) }
                var errors: [String] = []
                if !busy.isEmpty {
                    ignoreStoreChangesUntil = .now + .seconds(5)
                    errors = eventKit.apply(busy, targetID: calendarID)
                    ignoreStoreChangesUntil = .now + .seconds(5)
                }
                problems += errors.map { "\(calendar.title) (Busy): \($0)" }
                if !showsBusy && errors.isEmpty { settings.busyCalendarIDs.remove(calendarID) }
            }
            if showsBusy || !busy.isEmpty {
                busyPlans.append(BusyPreview(id: source.id, calendarName: calendar.title, plan: busy))
            }
        }
        // Busy events are saved without alerts from now on, so older ones need clearing only once.
        if apply { settings.busyAlertsCleared = true }

        // Outlook on the web calendars, when that's turned on too. Only the ones read just now:
        // their Busy events are found while reading, and written through the page that read them.
        for source in outlookRead {
            if let busy = await syncOutlookBusy(source, targetID: targetID, from: start, to: end,
                                                apply: apply, problems: &problems) {
                busyPlans.append(busy)
            }
        }

        if apply {
            updateSourceStatus(read: selected, plan: plan, existing: existing)
            lastSync = Date()
            // Counts copies of every secondary calendar, including ones not read this time.
            let copies = existing.count + plan.creates - plan.deletes
            lastSummary = plan.isEmpty
                ? "Up to date (\(copies) copied meetings)"
                : "Added \(plan.creates), updated \(plan.updates), removed \(plan.deletes)"
            let busyChanges = busyPlans.reduce(0) { $0 + $1.plan.actions.count }
            if busyChanges > 0 {
                lastSummary += ". Busy events: \(busyChanges) changed"
            }
        } else {
            preview = plan
            busyPreview = busyPlans
        }
        self.problems = problems.sorted()
        unreadSources = unread.sorted { $0.name < $1.name }
        return plan
    }

    /// Counts each secondary calendar's copies once `plan` is applied, and notes the time for
    /// the ones read without a problem.
    private func updateSourceStatus(read: [SourceConfig], plan: SyncPlan, existing: [ExistingCopy]) {
        var copies: [UUID: Int] = [:]
        var owner: [String: UUID] = [:]
        for copy in existing {
            guard let sourceID = copy.marker?.sourceID else { continue }
            copies[sourceID, default: 0] += 1
            owner[copy.eventID] = sourceID
        }
        for action in plan.actions {
            switch action {
            case .create(let spec):
                if let sourceID = spec.marker?.sourceID { copies[sourceID, default: 0] += 1 }
            case .delete(let eventID, _, _):
                if let sourceID = owner[eventID] { copies[sourceID, default: 0] -= 1 }
            case .update:
                break
            }
        }
        var status = sourceStatus
        for source in settings.sources {
            status[source.id, default: SourceStatus()].copies = max(copies[source.id] ?? 0, 0)
        }
        for source in read where plan.failedSources[source.id] == nil {
            status[source.id, default: SourceStatus()].lastRead = Date()
        }
        sourceStatus = status
    }

    /// The main calendar's meeting for the menu bar at `now`: one about to start, or one under way.
    func menuBarMeeting(now: Date) -> SourceEvent? {
        guard hasCalendarAccess, let targetID = settings.targetCalendarID,
              case .success(let events) = eventKit.sourceEvents(
                  calendarID: targetID, from: now.addingTimeInterval(-12 * 3600),
                  to: now.addingTimeInterval(MenuCalendar.menuBarLead + 60))
        else { return nil }
        return MenuCalendar.menuBarMeeting(in: events, now: now)
    }

    /// "Sync now": closes the Outlook windows first, since a calendar whose window is open
    /// isn't read, then syncs every calendar.
    func syncNow() async {
        for source in outlookSources.values { source.closeWindow() }
        await sync()
    }

    /// Shows the main calendar as Busy in one Outlook on the web calendar, or takes the Busy
    /// events back from one that no longer asks for them. Returns its preview, if there's
    /// anything to show.
    private func syncOutlookBusy(
        _ source: SourceConfig, targetID: String, from start: Date, to end: Date,
        apply: Bool, problems: inout [String]
    ) async -> BusyPreview? {
        let key = SettingsStore.outlookBusyKey(source.id)
        let showsBusy = settings.twoWaySync && settings.twoWaySyncOutlookWeb && source.showBusyInSecondary
        let addedHere = settings.busyCalendarIDs.contains(key)
        guard showsBusy || addedHere else { return nil }
        let name = source.calendarName
        let outlook = outlookSource(for: source.id)
        guard let existingBusy = outlook.busyEvents else {
            problems.append("\(name) (Busy): \(outlook.busyProblem ?? "Outlook wasn't read.")")
            return nil
        }
        let busy = showsBusy
            ? SyncPlanner.planBusy(
                for: source,
                mainEvents: eventKit.sourceEvents(calendarID: targetID, from: start, to: end),
                existing: existingBusy,
                options: settings.options)
            // Busy events made before 2.0.6 carry no marker, and only ones added to this
            // calendar are recognised at all.
            : SyncPlanner.planBusyRemoval(existing: existingBusy, addedHere: true)
        problems += busy.failedSources.values.map { "\(name) (Busy): \($0)" }
        if apply {
            // Recorded before writing, so the Busy events are taken back later even if some
            // of them fail to save now.
            if showsBusy { settings.busyCalendarIDs.insert(key) }
            let errors = await outlook.applyBusy(busy)
            problems += errors.map { "\(name) (Busy): \($0)" }
            if !showsBusy && errors.isEmpty { settings.busyCalendarIDs.remove(key) }
        }
        return showsBusy || !busy.isEmpty ? BusyPreview(id: source.id, calendarName: name, plan: busy) : nil
    }

    private func queue(only: Set<UUID>?) {
        guard let queued = queuedSync else {
            queuedSync = QueuedSync(only: only)
            return
        }
        // Either one syncing every source means syncing every source.
        queuedSync = QueuedSync(only: queued.only.flatMap { earlier in only.map { earlier.union($0) } })
    }

    private func runQueuedSync() {
        guard let queued = queuedSync else { return }
        queuedSync = nil
        Task { await sync(only: queued.only) }
    }

    // MARK: - Outlook web

    func outlookSource(for sourceID: UUID) -> OutlookWebSource {
        if let existing = outlookSources[sourceID] { return existing }
        let source = OutlookWebSource(sourceID: sourceID)
        source.onWindowClosed = { [weak self] in
            Task { await self?.sync(only: [sourceID]) }
        }
        outlookSources[sourceID] = source
        return source
    }

    func showOutlookWindow(for source: SourceConfig) {
        outlookSource(for: source.id).showWindow(title: source.calendarName)
    }

    func forgetOutlookSession(for sourceID: UUID) {
        outlookSources[sourceID]?.tearDown()
        outlookSources[sourceID] = nil
        Task {
            // Give WebKit a moment to release the store; it can't be removed while in use.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: sourceID)
            } catch {
                NSLog("Calendar Sync: couldn't delete Outlook sign-in data: \(error)")
            }
        }
    }
}
