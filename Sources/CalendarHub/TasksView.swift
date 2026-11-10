import AppKit
import CalendarHubCore
import EventKit
import SwiftUI

/// The menu's Tasks view: tasks and reminders kept in Reminders, each for an event or not,
/// with nudges (the reminder's alerts) to get them done. A task opens in an editor in the
/// view's place.
struct TasksView: View {
    /// The main calendar's events around today, to link a task to and to color linked tasks.
    let events: [SourceEvent]
    let calendar: Calendar
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var controller: SyncController
    @EnvironmentObject private var tasks: TaskStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var newTitle = ""
    /// The task open in the editor.
    @State private var editing: TaskItem?
    /// The done tasks, folded into one row until opened.
    @State private var showsDone = false

    /// As tall as the List view, so the menu window doesn't resize going from one to the
    /// other, or into the editor (see `WindowTopAnchor`).
    static let height: CGFloat = 300

    private var motion: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.32) }

    var body: some View {
        ZStack(alignment: .top) {
            if tasks.access != .fullAccess {
                RemindersAccessCard(denied: tasks.access != .notDetermined) {
                    if tasks.access == .notDetermined {
                        Task { await tasks.requestAccess() }
                    } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else if let editing {
                TaskEditor(task: editing, events: events, calendar: calendar, options: settings.taskOptions,
                           save: { tasks.save($0) },
                           delete: { tasks.delete(editing) },
                           close: { withAnimation(motion) { self.editing = nil } })
                    .id(editing)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                    .zIndex(1)
            } else {
                list.transition(.opacity)
            }
        }
        .frame(height: Self.height, alignment: .top)
        .clipped()
        .onAppear {
            openDraft()
            // Reminders is asked for the first time the view shows, not at launch, so nobody who
            // doesn't use tasks is asked. The card's button asks again if the answer didn't come.
            Task {
                if tasks.access == .notDetermined {
                    await tasks.requestAccess()
                } else {
                    await tasks.reload()
                }
            }
        }
        .onChange(of: tasks.draft) { _, _ in openDraft() }
    }

    /// Opens the task the List asked for, if any.
    private func openDraft() {
        guard let draft = tasks.draft else { return }
        tasks.draft = nil
        withAnimation(motion) { editing = draft }
    }

    // MARK: - List

    private var list: some View {
        let now = Date()
        let sections = TaskPlanner.sections(tasks.tasks, now: now, calendar: calendar)
        let open = sections.filter { $0.kind != .done }
        let done = sections.first { $0.kind == .done }?.tasks ?? []
        return VStack(spacing: 6) {
            addField
            if let problem = tasks.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if sections.isEmpty {
                EmptyTasks().frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: .sectionHeaders) {
                        if open.isEmpty {
                            EmptyTasks(allDone: true).padding(.vertical, 8)
                        }
                        ForEach(open, id: \.kind) { section in
                            Section {
                                VStack(spacing: 2) {
                                    ForEach(section.tasks) { row($0, now: now) }
                                }
                                .padding(.bottom, 6)
                            } header: {
                                header(section)
                            }
                        }
                        if !done.isEmpty {
                            DoneRow(tasks: done, isOpen: showsDone) {
                                withAnimation(motion) { showsDone.toggle() }
                            }
                            if showsDone {
                                ForEach(done) { row($0, now: now) }
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var trimmedTitle: String { newTitle.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Type and press Return for a task without a date; the clock button opens it in the
    /// editor for a date, an event or nudges.
    private var addField: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.accentColor)
            TextField("Add a task", text: $newTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit {
                    guard !trimmedTitle.isEmpty else { return }
                    var task = tasks.newTask()
                    task.title = trimmedTitle
                    tasks.save(task)
                    newTitle = ""
                }
            if !trimmedTitle.isEmpty {
                IconButton("calendar.badge.clock", help: "Add with a date, an event or nudges") {
                    var task = tasks.newTask()
                    task.title = trimmedTitle
                    newTitle = ""
                    withAnimation(motion) { editing = task }
                }
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: 30)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func header(_ section: TaskPlanner.Section) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(section.kind.title)
                .font(.system(size: 11, weight: .bold))
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(section.kind == .overdue ? AnyShapeStyle(Color.red)
                                 : section.kind == .today ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
            Spacer(minLength: 4)
            Text("\(section.tasks.count)")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func row(_ task: TaskItem, now: Date) -> some View {
        let event = task.event.flatMap { link in events.first { $0.key == link.key } }
        let tint = event.flatMap { event in
            settings.menuCalendar.colorsByCalendar
                ? EventOrigin.of(event, settings: settings, eventKit: controller.eventKit)?.color : nil
        }
        return TaskRow(task: task, now: now, calendar: calendar, eventStart: event?.start ?? task.event?.start, tint: tint,
                       eventMissing: task.event.map { tasks.missingEvents.contains($0.key) } ?? false,
                       toggle: { withAnimation(motion) { tasks.toggleDone(task) } },
                       open: { withAnimation(motion) { editing = task } },
                       delete: { withAnimation(motion) { tasks.delete(task) } })
    }
}

// MARK: - Rows

/// "14:00", "Tomorrow 9:00", "Thu 14:00" or "12 Nov 14:00", relative to `now`; the day alone
/// for a whole day.
func shortWhen(_ date: Date, hasTime: Bool = true, now: Date, calendar: Calendar) -> String {
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    let day: String? = switch days {
    case 0: hasTime ? nil : "Today"
    case 1: "Tomorrow"
    case -1: "Yesterday"
    case 2...6: date.formatted(.dateTime.weekday(.abbreviated))
    default: date.formatted(.dateTime.day().month(.abbreviated))
    }
    guard hasTime else { return day ?? "Today" }
    let time = date.formatted(date: .omitted, time: .shortened)
    return day.map { "\($0) \(time)" } ?? time
}

/// One task: a round check button, its title, then what it's for or when it's due, and its
/// next nudge. Click it to edit it, or open its notes in a window; right-click for more.
struct TaskRow: View {
    let task: TaskItem
    let now: Date
    let calendar: Calendar
    /// When its event starts: as the main calendar has it now, which may be ahead of the next
    /// sync that moves the task along.
    var eventStart: Date?
    /// The color of the calendar the task's event came from.
    var tint: Color?
    /// Its event is no longer in the main calendar.
    var eventMissing = false
    let toggle: () -> Void
    let open: () -> Void
    let delete: () -> Void
    @Environment(\.openTaskNotes) private var openTaskNotes
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: toggle) {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(task.isCompleted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableStyle())
            .help(task.isCompleted ? "Mark as not done" : "Mark as done")
            .accessibilityLabel(task.isCompleted ? "Done" : "Not done")

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title.isEmpty ? "Untitled" : task.title)
                    .font(.system(size: 13, weight: .medium))
                    .strikethrough(task.isCompleted)
                    .foregroundStyle(task.isCompleted ? .secondary : .primary)
                    .lineLimit(2)
                TaskMetaLine(task: task, now: now, calendar: calendar, eventStart: eventStart, tint: tint,
                             eventMissing: eventMissing)
            }
            Spacer(minLength: 0)
            if hovering {
                IconButton("doc.text", help: "Open the notes in a window") { openTaskNotes(task) }
                    .padding(.top, -3)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Edit…", action: open)
            Button("Open Notes in a Window") { openTaskNotes(task) }
            Button(task.isCompleted ? "Mark as Not Done" : "Mark as Done", action: toggle)
            Divider()
            Button("Delete", role: .destructive, action: delete)
        }
        .opacity(task.isCompleted ? 0.6 : 1)
    }
}

/// What a task is for and when: its event, its due date and its next nudge, and a mark when
/// it has notes. Red once it's overdue.
struct TaskMetaLine: View {
    let task: TaskItem
    let now: Date
    let calendar: Calendar
    var eventStart: Date?
    var tint: Color?
    var eventMissing = false

    var body: some View {
        let overdue = TaskPlanner.isOverdue(task, now: now, calendar: calendar)
        let nudge = TaskPlanner.nextNudge(of: task, now: now)
        let hasNotes = task.notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if task.event != nil || task.due != nil || nudge != nil || hasNotes {
            HStack(spacing: 4) {
                if let event = task.event {
                    Circle().fill(tint ?? Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                    Text(event.title.isEmpty ? "Event" : event.title).lineLimit(1)
                    if eventMissing {
                        Text("· removed").foregroundStyle(.orange)
                    } else if task.due == nil || task.due == event.start {
                        Text("· " + shortWhen(eventStart ?? event.start, hasTime: !event.isAllDay, now: now, calendar: calendar))
                            .foregroundStyle(overdue ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                            .fixedSize()
                    }
                }
                if let due = task.due, due != task.event?.start {
                    Image(systemName: "calendar")
                    Text(shortWhen(due, hasTime: task.dueHasTime, now: now, calendar: calendar))
                        .fixedSize()
                        .foregroundStyle(overdue ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                }
                if let nudge {
                    Image(systemName: "bell.fill")
                        .padding(.leading, task.event != nil || task.due != nil ? 3 : 0)
                    Text(shortWhen(nudge, now: now, calendar: calendar)).fixedSize()
                }
                if hasNotes {
                    Image(systemName: "doc.text")
                        .padding(.leading, 3)
                        .help("Has notes")
                        .accessibilityLabel("Has notes")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .imageScale(.small)
        }
    }
}

/// The done tasks, folded: "2 done · Review the roadmap, Book flights".
private struct DoneRow: View {
    let tasks: [TaskItem]
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                Text("\(tasks.count) done")
                    .font(.system(size: 11, weight: .semibold))
                if !isOpen {
                    Text(tasks.map(\.title).joined(separator: ", "))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Fold the done tasks" : "Show the tasks done this week")
    }
}

/// "Nothing to do", with where tasks come from.
private struct EmptyTasks: View {
    var allDone = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: allDone ? "checkmark.circle.fill" : "checklist")
                .font(.title3)
                .foregroundStyle(allDone ? Color.green : Color.accentColor)
                .padding(.bottom, 2)
            Text(allDone ? "All done" : "Nothing to do")
                .font(.callout.weight(.semibold))
            Text("Add a task above, or right-click a meeting in the List for a task to prepare it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, minHeight: 90)
    }
}

/// Asks for access to Reminders, where tasks are kept, or where to allow it once turned down.
private struct RemindersAccessCard: View {
    let denied: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "checklist")
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
                .padding(.bottom, 2)
            Text("Keep your tasks in Reminders")
                .font(.system(size: 14, weight: .semibold))
            Text("Each task is a reminder, so it's on your other devices too and stays in Reminders if you remove Calendar Hub. Nudges come as Reminders notifications.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(denied ? "Open System Settings" : "Allow Access to Reminders", action: action)
                .controlSize(.small)
                .padding(.top, 4)
            if denied {
                Text("Allow it in Privacy & Security › Reminders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Editor

/// One task, new or saved: its title and notes, the event it's for, when it's due, and its
/// nudges. Nudges timed by the due date (or the event) follow it as it changes here, and are
/// saved as the reminder's alerts at those times.
private struct TaskEditor: View {
    let original: TaskItem
    let events: [SourceEvent]
    let calendar: Calendar
    let options: TaskOptions
    let save: (TaskItem) -> Void
    let delete: () -> Void
    let close: () -> Void
    @State private var task: TaskItem
    @State private var nudges: [EditedNudge]
    @FocusState private var titleFocused: Bool
    @Environment(\.openTaskNotes) private var openTaskNotes

    private struct EditedNudge: Identifiable, Hashable {
        let id = UUID()
        var nudge: Nudge
    }

    init(task: TaskItem, events: [SourceEvent], calendar: Calendar, options: TaskOptions,
         save: @escaping (TaskItem) -> Void, delete: @escaping () -> Void, close: @escaping () -> Void) {
        original = task
        self.events = events
        self.calendar = calendar
        self.options = options
        self.save = save
        self.delete = delete
        self.close = close
        _task = State(initialValue: task)
        _nudges = State(initialValue: task.nudges.map {
            EditedNudge(nudge: Nudge.matching($0, anchor: task.anchor, anchorHasTime: task.anchorHasTime, calendar: calendar))
        })
    }

    private var trimmedTitle: String { task.title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Nudges are timed by the event's start while the task is due then.
    private var timedByEvent: Bool { task.event != nil && (task.due == nil || task.due == task.event?.start) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                IconButton("chevron.left", help: "Back to the tasks", action: close)
                Text(original.id.isEmpty ? "New task" : "Task")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Save", action: commit)
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedTitle.isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("What to do", text: $task.title, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1...3)
                        .focused($titleFocused)
                        .onSubmit(commit)
                    HStack(alignment: .top, spacing: 4) {
                        TextField("Notes", text: Binding(get: { task.notes ?? "" }, set: { task.notes = $0 }), axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .lineLimit(1...4)
                        if !original.id.isEmpty {
                            IconButton("arrow.up.left.and.arrow.down.right", help: "Open the notes in a window, with Markdown") {
                                guard let saved = finished() else { return }
                                save(saved)
                                close()
                                openTaskNotes(saved)
                            }
                            .padding(.top, -4)
                        }
                    }
                    Divider()
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
                        GridRow {
                            label("For")
                            eventMenu
                        }
                        GridRow {
                            label("Due")
                            dueControls
                        }
                        GridRow(alignment: .top) {
                            label("Nudges").padding(.top, 3)
                            nudgeList
                        }
                    }
                    if !original.id.isEmpty {
                        Button("Delete Task") {
                            delete()
                            close()
                        }
                        .buttonStyle(.link)
                        .foregroundStyle(.red)
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if original.title.isEmpty { titleFocused = true } }
        .onChange(of: task) { old, new in
            // Without a date, nudges timed by it keep the time they had.
            guard new.anchor == nil, old.anchor != nil else { return }
            nudges = nudges.map { edited in
                if case .at = edited.nudge { return edited }
                let date = edited.nudge.date(anchor: old.anchor, anchorHasTime: old.anchorHasTime, calendar: calendar)
                return EditedNudge(nudge: .at(date ?? nextHour))
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private var nextHour: Date {
        let now = Date()
        return calendar.dateInterval(of: .hour, for: now)?.end ?? now.addingTimeInterval(3600)
    }

    // MARK: Event

    /// The events still to come, to pick from.
    private var upcoming: [SourceEvent] {
        events.filter { $0.end > Date() && !$0.isDeclined }
    }

    private var eventMenu: some View {
        Menu {
            Button("No Event") { link(nil) }
            ForEach(MenuCalendar.sections(for: upcoming, calendar: calendar), id: \.day) { section in
                Section(dayTitle(section.day)) {
                    ForEach(section.events, id: \.key) { event in
                        Button(event.isAllDay
                               ? "All day  \(MenuCalendar.displayTitle(of: event))"
                               : "\(event.start.formatted(date: .omitted, time: .shortened))  \(MenuCalendar.displayTitle(of: event))") {
                            link(event)
                        }
                    }
                }
            }
        } label: {
            Text(task.event.map { $0.title.isEmpty ? "Event" : $0.title } ?? "No event")
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .frame(maxWidth: 230, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "Today", "Tomorrow", or "Thursday 12 November".
    private func dayTitle(_ day: Date) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInTomorrow(day) { return "Tomorrow" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// For `event`, due when it starts, with the nudge new tasks for an event get if it has none.
    private func link(_ event: SourceEvent?) {
        task.event = event.map { TaskEventLink($0) }
        guard let event else { return }
        task.due = event.isAllDay ? calendar.startOfDay(for: event.start) : event.start
        task.dueHasTime = !event.isAllDay
        if nudges.isEmpty, let nudge = options.eventNudge {
            nudges = [EditedNudge(nudge: nudge)]
        }
    }

    // MARK: Due

    @ViewBuilder
    private var dueControls: some View {
        if let due = task.due {
            HStack(spacing: 6) {
                DatePicker("Due", selection: Binding(get: { due }, set: {
                    task.due = task.dueHasTime ? $0 : calendar.startOfDay(for: $0)
                }), displayedComponents: task.dueHasTime ? [.date, .hourAndMinute] : [.date])
                .labelsHidden()
                .datePickerStyle(.field)
                .fixedSize()
                Toggle("Time", isOn: Binding(get: { task.dueHasTime }, set: { hasTime in
                    let day = calendar.startOfDay(for: due)
                    task.due = hasTime ? calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) : day
                    task.dueHasTime = hasTime
                }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
                IconButton("xmark.circle.fill", help: "No due date") { task.due = nil }
            }
            // A field date picker in a grid otherwise takes far more height than it draws.
            .frame(height: 24)
        } else {
            Button("Add a date") {
                task.due = task.event?.start ?? nextHour
                task.dueHasTime = task.event?.isAllDay != true
                if nudges.isEmpty, let nudge = options.dueNudge {
                    nudges = [EditedNudge(nudge: nudge)]
                }
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
    }

    // MARK: Nudges

    private var nudgeList: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach($nudges) { $edited in
                HStack(spacing: 4) {
                    nudgeMenu($edited.nudge)
                    if case .at(let date) = edited.nudge {
                        DatePicker("Nudge", selection: Binding(get: { date }, set: { edited.nudge = .at($0) }),
                                   displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .datePickerStyle(.field)
                            .fixedSize()
                    } else if let date = edited.nudge.date(anchor: task.anchor, anchorHasTime: task.anchorHasTime, calendar: calendar) {
                        Text(shortWhen(date, now: Date(), calendar: calendar))
                            .font(.system(size: 11))
                            .foregroundStyle(date < Date() ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                            .help(date < Date() ? "This time has passed, so it won't nudge you" : "")
                    }
                    Spacer(minLength: 0)
                    IconButton("minus.circle", help: "Remove this nudge") {
                        nudges.removeAll { $0.id == edited.id }
                    }
                }
                .frame(height: 24)
            }
            Button {
                nudges.append(EditedNudge(nudge: nextNudgeToAdd))
            } label: {
                Label("Add a nudge", systemImage: "bell.badge")
            }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
    }

    /// The default nudge for the task, or the first preset it doesn't have yet; without a
    /// date, in an hour's time.
    private var nextNudgeToAdd: Nudge {
        guard task.anchor != nil else { return .at(nextHour) }
        let taken = Set(nudges.map(\.nudge))
        let preferred = timedByEvent ? options.eventNudge : options.dueNudge
        return ([preferred].compactMap { $0 } + Nudge.presets(anchorHasTime: task.anchorHasTime))
            .first { !taken.contains($0) } ?? .at(nextHour)
    }

    private func nudgeMenu(_ nudge: Binding<Nudge>) -> some View {
        Menu {
            if task.anchor != nil {
                ForEach(Nudge.presets(anchorHasTime: task.anchorHasTime), id: \.self) { preset in
                    Button(preset.title(forEvent: timedByEvent) ?? "") { nudge.wrappedValue = preset }
                }
                Divider()
            }
            Button("At a Set Time…") {
                let date = nudge.wrappedValue.date(anchor: task.anchor, anchorHasTime: task.anchorHasTime, calendar: calendar)
                nudge.wrappedValue = .at(date ?? nextHour)
            }
        } label: {
            Label(nudge.wrappedValue.title(forEvent: timedByEvent) ?? "At", systemImage: "bell")
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
    }

    /// The task as edited, ready to save, or nil without a title.
    private func finished() -> TaskItem? {
        guard !trimmedTitle.isEmpty else { return nil }
        var saved = task
        saved.title = trimmedTitle
        let notes = saved.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.notes = notes?.isEmpty == false ? saved.notes : nil
        saved.nudges = Set(nudges.compactMap {
            $0.nudge.date(anchor: saved.anchor, anchorHasTime: saved.anchorHasTime, calendar: calendar)
        }).sorted()
        return saved
    }

    private func commit() {
        guard let saved = finished() else { return }
        save(saved)
        close()
    }
}
