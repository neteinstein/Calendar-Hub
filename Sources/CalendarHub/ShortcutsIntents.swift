import AppIntents
import CalendarHubCore
import Foundation

// Actions for the Shortcuts app and Siri. Each runs in the app, which Shortcuts starts if it
// isn't running, through `AppActions`.

private func actions() throws -> AppActions {
    guard let actions = AppActions.shared else { throw AppActions.Failure.noMainCalendar }
    return actions
}

struct NextMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Next Meeting"
    static let description = IntentDescription("The meeting under way, or the next one, with its time and how soon it starts.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = try actions().nextMeetingText()
        return .result(value: text, dialog: "\(text)")
    }
}

struct JoinNextMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Join Next Meeting"
    static let description = IntentDescription("Opens the call link of the meeting under way, or of the next one today.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let title = try actions().joinNextMeeting()
        return .result(dialog: "Joining \(title)")
    }
}

enum AvailabilitySpanEntity: String, AppEnum {
    case nextDays, thisWeek, nextWeek

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Days"
    static let caseDisplayRepresentations: [AvailabilitySpanEntity: DisplayRepresentation] = [
        .nextDays: "Next 3 working days",
        .thisWeek: "This week",
        .nextWeek: "Next week",
    ]

    var span: Availability.Span {
        switch self {
        case .nextDays: .nextDays
        case .thisWeek: .thisWeek
        case .nextWeek: .nextWeek
        }
    }
}

struct CopyAvailabilityIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Availability"
    static let description = IntentDescription("Copies your free times in all your calendars, as Share availability last made them, and returns them as text.")

    @Parameter(title: "Days", default: .nextDays)
    var days: AvailabilitySpanEntity

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try actions().copyAvailability(days.span))
    }
}

struct StartTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Time Tracking Timer"
    static let description = IntentDescription("Starts Time Tracking's timer for a client. Without one, for the client it last ran for.")

    @Parameter(title: "Client")
    var client: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try actions().startTimer(client: client)
        return .result(dialog: "Timer started for \(name)")
    }
}

struct StopTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Time Tracking Timer"
    static let description = IntentDescription("Stops Time Tracking's timer.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = try actions().stopTimer()
        return .result(dialog: "Timer stopped for \(name)")
    }
}

struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Task"
    static let description = IntentDescription("Adds a task to Calendar Hub's Tasks, kept in Reminders.")

    @Parameter(title: "Title")
    var title: String

    @Parameter(title: "Due")
    var due: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try actions().addTask(title: title, due: due)
        return .result(dialog: "Added \(title)")
    }
}

struct SyncNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Calendars Now"
    static let description = IntentDescription("Copies your secondary calendars' meetings into your main calendar now.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await actions().syncNow()
        return .result()
    }
}

struct CalendarHubShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NextMeetingIntent(), phrases: ["What's my next meeting in \(.applicationName)"],
                    shortTitle: "Next Meeting", systemImageName: "calendar")
        AppShortcut(intent: JoinNextMeetingIntent(), phrases: ["Join my next meeting with \(.applicationName)"],
                    shortTitle: "Join Meeting", systemImageName: "video")
        AppShortcut(intent: CopyAvailabilityIntent(), phrases: ["Copy my availability with \(.applicationName)"],
                    shortTitle: "Copy Availability", systemImageName: "calendar.badge.clock")
        AppShortcut(intent: StopTimerIntent(), phrases: ["Stop the \(.applicationName) timer"],
                    shortTitle: "Stop Timer", systemImageName: "stopwatch")
    }
}
