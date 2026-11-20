import CalendarHubCore
import SwiftUI
import WidgetKit

// The desktop widget: the next meeting, and today's meetings and hours. It can't read the
// calendars itself (a widget is sandboxed), so it reads what the app writes for it, see
// `WidgetSnapshot`.

struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// Nil while the app hasn't written one: the widget is off in its Settings, or it never ran.
    let snapshot: WidgetSnapshot?
}

/// Reads the app's snapshot from its Application Support folder in the user's real home: the
/// sandbox's own home is the widget's container.
enum SnapshotFile {
    static var url: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/org.neteinstein.calendarhub")
            .appendingPathComponent(WidgetSnapshot.fileName)
    }

    static func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview ? Self.sample : SnapshotFile.read() ?? Self.sample))
    }

    /// An entry now, and one at each meeting's start and end, so the countdown and the list
    /// move on without the app. The app reloads the timeline when the calendar changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let snapshot = SnapshotFile.read()
        var dates = [now]
        // Each minute for the next 15, so "in 12 min" counts down.
        dates += (1...15).map { now.addingTimeInterval(Double($0) * 60) }
        dates += (snapshot?.changes(after: now) ?? []).prefix(30)
        let entries = Array(Set(dates)).sorted().map { SnapshotEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }

    static var sample: WidgetSnapshot {
        let now = Date()
        return WidgetSnapshot(written: now, meetings: [
            .init(id: "1", title: "Design review", start: now.addingTimeInterval(12 * 60), end: now.addingTimeInterval(42 * 60),
                  color: "#2563EB", calendarName: "Calendar A"),
            .init(id: "2", title: "Sprint planning", start: now.addingTimeInterval(2 * 3600), end: now.addingTimeInterval(3 * 3600),
                  color: "#16A34A", calendarName: "Client X"),
        ], hoursToday: 3.5, limitHours: 5)
    }
}

struct WidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(snapshot)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Calendar Hub", systemImage: "calendar").font(.headline)
                    Text("Turn on the widget in Calendar Hub's Settings › Menu bar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private func content(_ snapshot: WidgetSnapshot) -> some View {
        let calendar = Calendar.current
        let upcoming = snapshot.upcoming(at: entry.date, calendar: calendar)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.date, format: .dateTime.weekday(.wide).day())
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
                Spacer()
                Text(hoursText(snapshot)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let next = upcoming.first {
                meetingCard(next)
                if family != .systemSmall {
                    ForEach(upcoming.dropFirst().prefix(family == .systemLarge ? 8 : 2)) { meeting in
                        row(meeting)
                    }
                }
            } else {
                Spacer()
                Text("No more meetings today").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                if let tomorrow = snapshot.meetings.first(where: { !calendar.isDate($0.start, inSameDayAs: entry.date) && $0.start > entry.date }) {
                    Text("Tomorrow \(tomorrow.start.formatted(date: .omitted, time: .shortened)): \(tomorrow.title)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func meetingCard(_ meeting: WidgetSnapshot.Meeting) -> some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color(meeting)).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Text(countdown(meeting)).font(.system(size: 12, weight: .medium)).foregroundStyle(color(meeting))
                Text("\(meeting.start.formatted(date: .omitted, time: .shortened)) – \(meeting.end.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(meeting.url)
    }

    private func row(_ meeting: WidgetSnapshot.Meeting) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color(meeting)).frame(width: 6, height: 6)
            Text(meeting.start, format: .dateTime.hour().minute()).font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(.secondary)
            Text(meeting.title).font(.system(size: 11.5)).lineLimit(1)
        }
    }

    private func countdown(_ meeting: WidgetSnapshot.Meeting) -> String {
        let event = SourceEvent(key: meeting.id, title: meeting.title, start: meeting.start, end: meeting.end)
        return MenuCalendar.countdown(to: event, now: entry.date)
    }

    private func hoursText(_ snapshot: WidgetSnapshot) -> String {
        let minutes = Int((snapshot.hoursToday * 60).rounded())
        var text = MenuCalendar.shortDuration(minutes: minutes)
        if let limit = snapshot.limitHours { text += " of \(MenuCalendar.shortDuration(minutes: Int(limit * 60)))" }
        return text
    }

    private func color(_ meeting: WidgetSnapshot.Meeting) -> Color {
        guard let hex = meeting.color.flatMap(HexColor.init) else { return .accentColor }
        return Color(red: hex.red, green: hex.green, blue: hex.blue)
    }
}

struct NextMeetingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "org.neteinstein.calendarhub.next-meeting", provider: Provider()) { entry in
            WidgetView(entry: entry)
        }
        .configurationDisplayName("Next Meeting")
        .description("Your next meeting with a countdown, and today's meetings across all your calendars.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct CalendarHubWidgets: WidgetBundle {
    var body: some Widget {
        NextMeetingWidget()
    }
}
