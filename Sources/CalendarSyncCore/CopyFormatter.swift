import Foundation

/// Turns a source event into the copy that should exist in the target calendar.
public enum CopyFormatter {
    public static func title(for event: SourceEvent, source: SourceConfig) -> String {
        let calendar = source.calendarName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = source.hideMeetingName ? "Busy" : event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let meeting = name.isEmpty ? "Busy" : name
        return calendar.isEmpty ? meeting : "[\(calendar)] \(meeting)"
    }

    /// A copy's title without the "[Calendar A] " prefix `title(for:source:)` adds, for places
    /// that show the calendar some other way. Titles without a prefix come back as they are.
    public static func originalTitle(_ copyTitle: String) -> String {
        guard copyTitle.hasPrefix("["), let close = copyTitle.firstIndex(of: "]") else { return copyTitle }
        let rest = copyTitle[copyTitle.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? copyTitle : rest
    }

    /// The meeting link (if any) goes first so it's visible and clickable in Calendar, then the
    /// meeting's description when the source copies details; the hidden marker goes last.
    public static func notes(meetingURL: URL?, details: String? = nil, marker: CopyMarker) -> String {
        var lines: [String] = []
        if let meetingURL { lines.append("Join: \(meetingURL.absoluteString)") }
        if let details, !details.isEmpty { lines.append(details) }
        lines.append("Copied by Calendar Sync. Changes here are overwritten.")
        lines.append(marker.encoded)
        return lines.joined(separator: "\n\n")
    }

    /// Longest description copied into a copy's notes.
    static let maxDetailsLength = 8000

    /// The description and location to copy, or nil for both when the source doesn't copy
    /// details (or hides meeting names, which would make the details give it away).
    static func details(for event: SourceEvent, source: SourceConfig) -> (notes: String?, location: String?) {
        guard source.copyDetails, !source.hideMeetingName else { return (nil, nil) }
        var notes = event.notes.map(HTMLText.normalize)
        if let text = notes, text.count > maxDetailsLength {
            notes = HTMLText.normalize(String(text.prefix(maxDetailsLength))) + "…"
        }
        let location = event.location.map(HTMLText.normalize)
        return (notes?.isEmpty == false ? notes : nil, location?.isEmpty == false ? location : nil)
    }

    /// A main-calendar event shown in a secondary calendar: the time and "Busy" (or "Out of
    /// office"), nothing else about the event. The description says "Busy" and carries a
    /// marker, so the app recognises its own Busy events for sure and never takes an event the
    /// user made for one, and so anyone reading the secondary calendar can see what wrote
    /// them. The marker's key is made from the times only, nothing from the original event.
    public static func busySpec(for event: SourceEvent, source: SourceConfig) -> CopySpec {
        let marker = busyMarker(sourceID: source.id, start: event.start, end: event.end, isAllDay: event.isAllDay)
        return CopySpec(
            marker: marker,
            title: source.busyStyle.title,
            start: event.start,
            end: event.end,
            isAllDay: event.isAllDay,
            timeZone: event.isAllDay ? nil : event.timeZone,
            url: nil,
            notes: busyNotes(marker: marker),
            isOutOfOffice: source.busyStyle == .outOfOffice
        )
    }

    /// The first line of every Busy event's description.
    public static let busyNotes = "Busy"

    /// A Busy event's whole description: "Busy", then its marker.
    public static func busyNotes(marker: CopyMarker) -> String {
        busyNotes + "\n\n" + marker.encoded
    }

    /// The marker of a Busy event, keyed by its times: a Busy event stands for whatever the
    /// main calendar has at that time, not for one event in it.
    static func busyMarker(sourceID: UUID, start: Date, end: Date, isAllDay: Bool) -> CopyMarker {
        let key = "\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)|\(isAllDay)"
        return CopyMarker(sourceID: sourceID, key: busyKeyPrefix + CopyMarker.hashKey(key, sourceID: sourceID))
    }

    /// Whether an event in a secondary calendar is a Busy event: carrying a Busy marker, or,
    /// as versions 2.0.0 to 2.0.5 made them, titled like one with "Busy" as its whole
    /// description.
    public static func isBusyEvent(title: String?, notes: String?) -> Bool {
        if let marker = CopyMarker.find(in: notes) { return marker.key.hasPrefix(busyKeyPrefix) }
        let title = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Calendar servers can hand the description back as HTML.
        return BusyStyle.allCases.contains { $0.title == title }
            && HTMLText.plainText(from: notes ?? "") == busyNotes
    }

    /// Starts the marker key of every Busy event.
    static let busyKeyPrefix = "busy-"

    public static func spec(for event: SourceEvent, source: SourceConfig) -> CopySpec {
        let marker = CopyMarker.hashed(sourceID: source.id, key: event.key)
        let details = details(for: event, source: source)
        // A Teams link names the organization and the organizer, a Zoom link can carry the
        // passcode: the link goes along only when the source says so.
        let meetingURL = source.copyMeetingLink ? event.meetingURL : nil
        return CopySpec(
            marker: marker,
            title: title(for: event, source: source),
            start: event.start,
            end: event.end,
            isAllDay: event.isAllDay,
            timeZone: event.isAllDay ? nil : event.timeZone,
            url: meetingURL,
            notes: notes(meetingURL: meetingURL, details: details.notes, marker: marker),
            location: details.location,
            // Kept when out-of-office events are copied, so the copy isn't taken for a meeting.
            isOutOfOffice: event.isOutOfOffice
        )
    }
}
