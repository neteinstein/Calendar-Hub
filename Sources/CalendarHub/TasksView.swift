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
    /// The category the list shows, or empty for all of them.
    @AppStorage("tasksCategory") private var filter = ""
    /// The category a task added from the field goes in: the one shown, until another is picked.
    @State private var newCategory: String?
    /// The editor opens on its category, for a new one.
    @State private var namesCategory = false
    /// How much taller than usual the menu was dragged for Tasks.
    @Environment(\.menuExtraHeight) private var extraHeight

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
                           categories: tasks.categories, focusesCategory: namesCategory,
                           save: { tasks.save($0) },
                           delete: { tasks.delete(editing) },
                           close: {
                               namesCategory = false
                               withAnimation(motion) { self.editing = nil }
                           })
                    .id(editing)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                    .zIndex(1)
            } else {
                list.transition(.opacity)
            }
        }
        .frame(height: Self.height + extraHeight, alignment: .top)
        .clipped()
        .onAppear {
            newCategory = shownCategory
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
        .onChange(of: filter) { _, _ in newCategory = shownCategory }
    }

    /// The category the list is filtered by, or nil for all: none once no task is in it.
    private var shownCategory: String? {
        TaskPlanner.category(filter, matching: tasks.categories).flatMap { shown in
            tasks.categories.contains(shown) ? shown : nil
        }
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
        let shown = shownCategory
        let sections = TaskPlanner.sections(TaskPlanner.tasks(tasks.tasks, in: shown), now: now, calendar: calendar)
        let open = sections.filter { $0.kind != .done }
        let done = sections.first { $0.kind == .done }?.tasks ?? []
        return VStack(spacing: 6) {
            if !tasks.categories.isEmpty {
                CategoryBar(categories: tasks.categories, selected: shown, options: settings.taskOptions,
                            select: { category in withAnimation(motion) { filter = category ?? "" } },
                            setColor: { tasks.setColor($0, of: $1) })
            }
            addField
            if let problem = tasks.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if sections.isEmpty {
                EmptyTasks(category: shown).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: .sectionHeaders) {
                        if open.isEmpty {
                            EmptyTasks(allDone: true).padding(.vertical, 8)
                        }
                        ForEach(open, id: \.kind) { section in
                            Section {
                                VStack(spacing: 2) {
                                    ForEach(section.tasks) { row($0, now: now, showsCategory: shown == nil) }
                                }
                                .padding(.bottom, 6)
                            } header: {
                                header(section)
                            }
                        }
                        if !done.isEmpty {
                            DoneRow(tasks: done, isOpen: showsDone) {
                                withAnimation(motion) { showsDone.toggle() }
                            } deleteAll: {
                                withAnimation(motion) {
                                    tasks.delete(all: done)
                                    showsDone = false
                                }
                            }
                            if showsDone {
                                ForEach(done) { row($0, now: now, showsCategory: shown == nil) }
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
                    task.category = newCategory
                    tasks.save(task)
                    newTitle = ""
                }
            categoryMenu
            if !trimmedTitle.isEmpty {
                IconButton("calendar.badge.clock", help: "Add with a date, an event or nudges") {
                    var task = tasks.newTask()
                    task.title = trimmedTitle
                    task.category = newCategory
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

    /// The category a task added from the field goes in: a tag, with the category's name once
    /// there is one. A new category is named in the editor.
    private var categoryMenu: some View {
        Menu {
            Button {
                newCategory = nil
            } label: {
                if newCategory == nil { Label("No Category", systemImage: "checkmark") } else { Text("No Category") }
            }
            if !tasks.categories.isEmpty {
                Divider()
                ForEach(tasks.categories, id: \.self) { category in
                    Button {
                        newCategory = category
                    } label: {
                        if newCategory == category { Label(category, systemImage: "checkmark") } else { Text(category) }
                    }
                }
            }
            Divider()
            Button("New Category…") {
                var task = tasks.newTask()
                task.title = trimmedTitle
                newTitle = ""
                namesCategory = true
                withAnimation(motion) { editing = task }
            }
        } label: {
            HStack(spacing: 4) {
                if let newCategory {
                    Circle().fill(settings.taskOptions.color(of: newCategory).color).frame(width: 7, height: 7)
                    Text(newCategory)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                } else {
                    Image(systemName: "tag")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .frame(maxWidth: 110)
            .background(newCategory == nil ? .clear : Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(newCategory.map { "Added to \($0)" } ?? "Pick a category for new tasks")
        .accessibilityLabel(newCategory.map { "Category: \($0)" } ?? "Category")
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

    private func row(_ task: TaskItem, now: Date, showsCategory: Bool) -> some View {
        let event = task.event.flatMap { link in events.first { $0.key == link.key } }
        let tint = event.flatMap { event in
            settings.menuCalendar.colorsByCalendar
                ? EventOrigin.of(event, settings: settings, eventKit: controller.eventKit)?.color : nil
        }
        return TaskRow(task: task, now: now, calendar: calendar, eventStart: event?.start ?? task.event?.start, tint: tint,
                       eventMissing: task.event.map { tasks.missingEvents.contains($0.key) } ?? false,
                       showsCategory: showsCategory,
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
    /// Its category shows, unless the list only has that category's tasks.
    var showsCategory = true
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
                             eventMissing: eventMissing, showsCategory: showsCategory)
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

/// What a task is for and when: its category, its event, its due date and its next nudge, and
/// a mark when it has notes. Red once it's overdue.
struct TaskMetaLine: View {
    let task: TaskItem
    let now: Date
    let calendar: Calendar
    var eventStart: Date?
    var tint: Color?
    var eventMissing = false
    var showsCategory = true
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        let overdue = TaskPlanner.isOverdue(task, now: now, calendar: calendar)
        let nudge = TaskPlanner.nextNudge(of: task, now: now)
        let hasNotes = task.notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let category = showsCategory ? TaskPlanner.cleanCategory(task.category) : nil
        if category != nil || task.event != nil || task.due != nil || nudge != nil || hasNotes {
            HStack(spacing: 4) {
                if let category {
                    CategoryTag(name: category, color: settings.taskOptions.color(of: category).color)
                        .padding(.trailing, 2)
                }
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
    /// Deletes every done task from Reminders, from a bin shown while the pointer is on the row.
    let deleteAll: () -> Void
    @State private var hovering = false
    @State private var hoveringBin = false

    var body: some View {
        HStack(spacing: 0) {
            foldButton
            Button(action: deleteAll) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hoveringBin ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .frame(width: 22, height: 20)
                    .background(hoveringBin ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(PressableStyle())
            .onHover { hoveringBin = $0 }
            .help(tasks.count == 1 ? "Delete the done task" : "Delete the \(tasks.count) done tasks")
            .accessibilityLabel(tasks.count == 1 ? "Delete the done task" : "Delete the \(tasks.count) done tasks")
            // Kept in place while hidden, so the titles don't shift when it shows.
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .padding(.trailing, 4)
        }
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    private var foldButton: some View {
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
    /// The category the list shows, if not all of them.
    var category: String?

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: allDone ? "checkmark.circle.fill" : "checklist")
                .font(.title3)
                .foregroundStyle(allDone ? Color.green : Color.accentColor)
                .padding(.bottom, 2)
            Text(allDone ? "All done" : category.map { "Nothing to do in \($0)" } ?? "Nothing to do")
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

// MARK: - Categories

extension TaskCategoryColor {
    var color: Color {
        switch self {
        case .blue: .blue
        case .orange: .orange
        case .green: .green
        case .purple: .purple
        case .pink: .pink
        case .teal: .teal
        case .red: .red
        case .yellow: .yellow
        case .indigo: .indigo
        case .mint: .mint
        case .brown: .brown
        case .gray: .gray
        }
    }
}

/// A category's name in a capsule of its color, on a task's line.
struct CategoryTag: View {
    let name: String
    let color: Color

    var body: some View {
        Text(name)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.16), in: Capsule())
            .fixedSize()
            .accessibilityLabel("Category: \(name)")
    }
}

/// Picks the color of `category`, from its right-click menu.
struct CategoryColorMenu: View {
    let category: String
    let current: TaskCategoryColor
    let setColor: (TaskCategoryColor, String) -> Void

    var body: some View {
        Menu("Color") {
            ForEach(TaskCategoryColor.allCases, id: \.self) { color in
                Button {
                    setColor(color, category)
                } label: {
                    if color == current { Label(color.title, systemImage: "checkmark") } else { Text(color.title) }
                }
            }
        }
    }
}

/// Above the tasks: All, then a chip for each category, to show only its tasks. Right-click a
/// category for its color.
private struct CategoryBar: View {
    let categories: [String]
    /// The category shown, or nil for all.
    let selected: String?
    let options: TaskOptions
    let select: (String?) -> Void
    let setColor: (TaskCategoryColor, String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                chip("All", color: nil, isSelected: selected == nil) { select(nil) }
                ForEach(categories, id: \.self) { category in
                    let color = options.color(of: category)
                    chip(category, color: color.color, isSelected: selected == category) { select(category) }
                        .contextMenu {
                            CategoryColorMenu(category: category, current: color, setColor: setColor)
                        }
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 24)
    }

    private func chip(_ title: String, color: Color?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let color {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(isSelected ? (color ?? Color.accentColor).opacity(0.2) : Color.primary.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? (color ?? Color.accentColor).opacity(0.5) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .pointingHandCursor()
        .help(color == nil ? "Show every task" : "Show the tasks in \(title); right-click for its color")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
    /// The categories there are, to pick from.
    let categories: [String]
    /// Opens with the cursor in the category, to name a new one.
    let focusesCategory: Bool
    let save: (TaskItem) -> Void
    let delete: () -> Void
    let close: () -> Void
    @State private var task: TaskItem
    @State private var nudges: [EditedNudge]
    @FocusState private var titleFocused: Bool
    @FocusState private var categoryFocused: Bool
    @Environment(\.openTaskNotes) private var openTaskNotes

    private struct EditedNudge: Identifiable, Hashable {
        let id = UUID()
        var nudge: Nudge
    }

    init(task: TaskItem, events: [SourceEvent], calendar: Calendar, options: TaskOptions,
         categories: [String], focusesCategory: Bool,
         save: @escaping (TaskItem) -> Void, delete: @escaping () -> Void, close: @escaping () -> Void) {
        original = task
        self.events = events
        self.calendar = calendar
        self.options = options
        self.categories = categories
        self.focusesCategory = focusesCategory
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
                            label("Category")
                            categoryField
                        }
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
        .onAppear {
            if focusesCategory {
                categoryFocused = true
            } else if original.title.isEmpty {
                titleFocused = true
            }
        }
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

    // MARK: Category

    /// The category as typed, as it will be saved: spelled like the one it matches.
    private var typedCategory: String? { TaskPlanner.category(task.category, matching: categories) }

    /// Type a category, new or not, or pick one from the menu beside it.
    private var categoryField: some View {
        HStack(spacing: 4) {
            if let typedCategory {
                let colors = TaskPlanner.colors(for: categories + [typedCategory], given: options.categoryColors)
                Circle()
                    .fill((colors[typedCategory.lowercased()] ?? options.color(of: typedCategory)).color)
                    .frame(width: 8, height: 8)
            }
            TextField("None", text: Binding(get: { task.category ?? "" }, set: { task.category = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($categoryFocused)
                .onSubmit(commit)
                .frame(maxWidth: 160)
            if !categories.isEmpty {
                Menu {
                    Button("No Category") { task.category = nil }
                    Divider()
                    ForEach(categories, id: \.self) { category in
                        Button(category) { task.category = category }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Pick a category")
            }
        }
        .frame(height: 22)
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
        saved.category = typedCategory
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
