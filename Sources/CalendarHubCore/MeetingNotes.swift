import Foundation

/// A meeting's notes, kept as a task for the meeting: "Notes: Design review", with the notes in
/// Markdown. Its open checklist items can each become a task of their own for the meeting.
public enum MeetingNotes {
    public static let titlePrefix = "Notes: "

    /// "Notes: Design review".
    public static func title(for event: SourceEvent) -> String {
        titlePrefix + MenuCalendar.displayTitle(of: event)
    }

    /// The notes task for the event with `key`, if there is one, done or not.
    public static func task(forEvent key: String, in tasks: [TaskItem]) -> TaskItem? {
        tasks.first { $0.event?.key == key && $0.title.hasPrefix(titlePrefix) }
    }

    /// What new notes start with: the date, and headings for notes and action items.
    public static func template(for event: SourceEvent, locale: Locale = .current, calendar: Calendar = .current) -> String {
        let style = Date.FormatStyle(date: .complete, time: event.isAllDay ? .omitted : .shortened, locale: locale,
                                     calendar: calendar, timeZone: calendar.timeZone)
        return event.start.formatted(style) + "\n\n## Notes\n\n- \n\n## Action items\n\n- [ ] "
    }

    /// The open checklist items in `notes`, as task titles: "- [ ] Send the slides" gives
    /// "Send the slides". Empty items, and ones already among `existing`, are left out.
    public static func actionItems(in notes: String, existing: [String] = []) -> [String] {
        let known = Set(existing.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        var seen: Set<String> = []
        var items: [String] = []
        for line in notes.split(whereSeparator: \.isNewline) {
            var text = line.trimmingCharacters(in: .whitespaces)
            guard let marker = ["- [ ]", "* [ ]", "+ [ ]"].first(where: { text.hasPrefix($0) }) else { continue }
            text = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            let folded = text.lowercased()
            guard !text.isEmpty, !known.contains(folded), seen.insert(folded).inserted else { continue }
            items.append(text)
        }
        return items
    }
}
