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
    /// office"), nothing else about the event. The description says "Busy" and carries the
    /// calendar's token (`busyToken`), so the app recognises its own Busy events for sure and
    /// never takes an event the user made for one. The token is an opaque code: nothing in a
    /// Busy event names the app or the event it stands for.
    public static func busySpec(for event: SourceEvent, source: SourceConfig) -> CopySpec {
        CopySpec(
            marker: busyMarker(sourceID: source.id),
            title: source.busyStyle.title,
            start: event.start,
            end: event.end,
            isAllDay: event.isAllDay,
            timeZone: event.isAllDay ? nil : event.timeZone,
            url: nil,
            notes: busyNotes(sourceID: source.id),
            isOutOfOffice: source.busyStyle == .outOfOffice
        )
    }

    /// The first line of every Busy event's description.
    public static let busyNotes = "Busy"

    /// A Busy event's whole description: "Busy", then the calendar's token.
    public static func busyNotes(sourceID: UUID) -> String {
        busyNotes + "\n\n" + busyToken(sourceID: sourceID)
    }

    /// The code every Busy event in the calendar of `sourceID` carries: a hash of the source
    /// id, the same for the whole calendar, so it tells the app's Busy events from any other
    /// event titled Busy without saying what made them.
    public static func busyToken(sourceID: UUID) -> String {
        CopyMarker.hashKey("busy", sourceID: sourceID)
    }

    /// How a Busy event carrying the token is known in a plan: a marker in the form the
    /// Busy events of 1.x had. It is never written to the event; `busyNotes(sourceID:)` is.
    public static func busyMarker(sourceID: UUID) -> CopyMarker {
        CopyMarker(sourceID: sourceID, key: busyKeyPrefix + busyToken(sourceID: sourceID))
    }

    /// Whether `spec` is a Busy event rather than a copy.
    public static func isBusy(_ spec: CopySpec) -> Bool {
        spec.marker?.key.hasPrefix(busyKeyPrefix) ?? true
    }

    /// What a Busy event in the calendar of `sourceID` was made by.
    public enum BusyMatch: Equatable {
        /// Carries the calendar's token (2.0.6 on) or a Busy marker (1.x): the app's for sure.
        case tagged(CopyMarker)
        /// As versions 2.0.0 to 2.0.5 made them, with "Busy" as the whole description: the
        /// app's, or an event that happens to look just like one.
        case untagged
    }

    /// Whether an event in the calendar of `sourceID` is a Busy event, and how surely.
    public static func busyMatch(title: String?, notes: String?, sourceID: UUID) -> BusyMatch? {
        if let marker = CopyMarker.find(in: notes) {
            return marker.key.hasPrefix(busyKeyPrefix) ? .tagged(marker) : nil
        }
        let title = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard BusyStyle.allCases.contains(where: { $0.title == title }) else { return nil }
        // Calendar servers can hand the description back as HTML, with line breaks of their own.
        let words = HTMLText.words(of: HTMLText.plainText(from: notes ?? ""))
        if words == [busyNotes[...], busyToken(sourceID: sourceID)[...]] { return .tagged(busyMarker(sourceID: sourceID)) }
        return words == [busyNotes[...]] ? .untagged : nil
    }

    public static func isBusyEvent(title: String?, notes: String?, sourceID: UUID) -> Bool {
        busyMatch(title: title, notes: notes, sourceID: sourceID) != nil
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
