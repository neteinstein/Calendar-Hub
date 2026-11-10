import AppKit
import CalendarHubCore
import Combine
import SwiftUI

/// Opens a task's notes in a window of its own. In the environment, so the menu's task rows
/// can open one; it does nothing where no window can open, like in screenshots.
struct OpenTaskNotesAction: Sendable {
    let action: @MainActor @Sendable (TaskItem) -> Void

    @MainActor func callAsFunction(_ task: TaskItem) { action(task) }
}

private struct OpenTaskNotesKey: EnvironmentKey {
    static let defaultValue = OpenTaskNotesAction { _ in }
}

extension EnvironmentValues {
    var openTaskNotes: OpenTaskNotesAction {
        get { self[OpenTaskNotesKey.self] }
        set { self[OpenTaskNotesKey.self] = newValue }
    }
}

/// The open notes windows, one per task. AppKit windows rather than a SwiftUI scene, so none
/// opens at launch or comes back after a restart. Each saves what's typed in it when it closes.
@MainActor
final class TaskNotesWindows: ObservableObject {
    private let settings: SettingsStore
    private let controller: SyncController
    private let tasks: TaskStore
    private var open: [String: (window: NSWindow, draft: TaskNotesDraft, observer: NSObjectProtocol)] = [:]
    private var quitObserver: NSObjectProtocol?

    init(settings: SettingsStore, controller: SyncController, tasks: TaskStore) {
        self.settings = settings
        self.controller = controller
        self.tasks = tasks
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.open.values.forEach { $0.draft.save() } }
        }
    }

    /// Opens `task`'s notes, or brings its window forward when they're open already.
    func show(_ task: TaskItem) {
        guard !task.id.isEmpty else { return }
        if let window = open[task.id]?.window {
            bringForward(window)
            return
        }
        let draft = TaskNotesDraft(task: task, tasks: tasks)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 540),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = task.title
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = NSSize(width: 380, height: 320)
        let host = NSHostingView(rootView: TaskNotesView(draft: draft)
            .environmentObject(settings)
            .environmentObject(controller)
            .environmentObject(tasks))
        // The window sets the size; the view only says how small it can get.
        host.sizingOptions = [.minSize]
        window.contentView = host
        if let last = open.values.map(\.window).last(where: \.isVisible) {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else {
            window.center()
        }
        let id = task.id
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closed(id) }
        }
        open[id] = (window, draft, observer)
        bringForward(window)
    }

    private func closed(_ id: String) {
        guard let closing = open.removeValue(forKey: id) else { return }
        closing.draft.save()
        NotificationCenter.default.removeObserver(closing.observer)
    }

    /// A menu bar app isn't always in front, and a window it opens can land behind others.
    private func bringForward(_ window: NSWindow) {
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

/// What's typed in a notes window, saved to the reminder a moment after typing stops. A
/// change made elsewhere (Reminders, another device) comes in unless it's being edited here.
@MainActor
final class TaskNotesDraft: ObservableObject {
    let taskID: String
    @Published var title: String
    @Published var notes: String
    @Published private(set) var lastSaved: Date?
    /// The title and notes as the reminder has them.
    private var saved: (title: String, notes: String)
    private var pendingSave: Task<Void, Never>?
    private let tasks: TaskStore
    private var observer: AnyCancellable?

    init(task: TaskItem, tasks: TaskStore) {
        taskID = task.id
        title = task.title
        notes = task.notes ?? ""
        saved = (task.title, task.notes ?? "")
        self.tasks = tasks
        observer = tasks.$tasks.sink { [weak self] list in
            MainActor.assumeIsolated {
                guard let self, let task = list.first(where: { $0.id == self.taskID }) else { return }
                self.merge(task)
            }
        }
    }

    private var isChanged: Bool { title != saved.title || notes != saved.notes }

    /// Saves once typing stops for a moment.
    func edited() {
        guard isChanged else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard isChanged else { return }
        let (title, notes) = (title, notes)
        tasks.updateText(of: taskID, title: title, notes: notes)
        saved = (title, notes)
        lastSaved = Date()
    }

    private func merge(_ task: TaskItem) {
        let incoming = (title: task.title, notes: task.notes ?? "")
        if title == saved.title { title = incoming.title }
        if notes == saved.notes { notes = incoming.notes }
        saved = incoming
    }
}

/// A task's notes, in a window: its title, what it's for and when, and its notes in Markdown,
/// styled as they're typed and saved in the reminder's notes.
struct TaskNotesView: View {
    @ObservedObject var draft: TaskNotesDraft
    @EnvironmentObject private var tasks: TaskStore
    @State private var proxy = MarkdownEditorProxy()

    private var task: TaskItem? { tasks.tasks.first { $0.id == draft.taskID } }

    var body: some View {
        VStack(spacing: 0) {
            if let task {
                header(task)
                Divider()
                formatBar
                Divider()
                MarkdownEditor(text: $draft.notes, proxy: proxy)
                Divider()
                footer
            } else {
                gone
            }
        }
        .frame(minWidth: 380, minHeight: 320)
        .background(Color(nsColor: .textBackgroundColor))
        .background(WindowTitle(title: draft.title.isEmpty ? "Task" : draft.title))
        .onChange(of: draft.notes) { _, _ in draft.edited() }
        .onChange(of: draft.title) { _, _ in draft.edited() }
        .onAppear { proxy.focus() }
    }

    private func header(_ task: TaskItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                tasks.toggleDone(task)
            } label: {
                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(task.isCompleted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableStyle())
            .help(task.isCompleted ? "Mark as not done" : "Mark as done")
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title", text: $draft.title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1...3)
                TaskMetaLine(task: task, now: Date(), calendar: .current,
                             eventMissing: task.event.map { tasks.missingEvents.contains($0.key) } ?? false)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var formatBar: some View {
        HStack(spacing: 1) {
            Menu {
                Button("Title") { proxy.toggle(.heading(1)) }
                Button("Heading") { proxy.toggle(.heading(2)) }
                Button("Subheading") { proxy.toggle(.heading(3)) }
            } label: {
                Image(systemName: "textformat.size")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 30)
            .help("Heading")
            IconButton("bold", help: "Bold (⌘B)", shortcut: "b") { proxy.toggle(.bold) }
            IconButton("italic", help: "Italic (⌘I)", shortcut: "i") { proxy.toggle(.italic) }
            IconButton("strikethrough", help: "Strikethrough") { proxy.toggle(.strikethrough) }
            IconButton("chevron.left.forwardslash.chevron.right", help: "Code (⌘E)", shortcut: "e") { proxy.toggle(.code) }
            IconButton("link", help: "Link (⌘K)", shortcut: "k") { proxy.link() }
            Divider().frame(height: 16).padding(.horizontal, 5)
            IconButton("list.bullet", help: "Bulleted list") { proxy.toggle(.bullet) }
            IconButton("list.number", help: "Numbered list") { proxy.toggle(.numbered) }
            IconButton("checklist", help: "Checklist") { proxy.toggle(.checklist) }
            IconButton("text.quote", help: "Quote") { proxy.toggle(.quote) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 5) {
            Image(systemName: "checklist")
            Text("Kept in the reminder's notes in Reminders, as Markdown")
                .lineLimit(1)
            Spacer(minLength: 8)
            if draft.lastSaved != nil {
                Label("Saved", systemImage: "checkmark")
                    .transition(.opacity)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var gone: some View {
        VStack(spacing: 4) {
            Image(systemName: "checklist")
                .font(.title2)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Text("This task isn't in Reminders anymore")
                .font(.headline)
            Text("It was deleted, moved to another list, or done more than a week ago.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Keeps the window's title the task's.
private struct WindowTitle: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.title = title }
    }
}
