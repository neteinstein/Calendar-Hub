import Foundation

/// Turns a source event into the copy that should exist in the target calendar.
public enum CopyFormatter {
    public static func title(for event: SourceEvent, source: SourceConfig) -> String {
        let name = source.hideMeetingName ? "Busy" : event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return titlePrefix(of: source) + (name.isEmpty ? "Busy" : name)
    }

    /// What every copy of `source` is titled with first: "[Calendar A] ", or nothing for a
    /// calendar without a name.
    public static func titlePrefix(of source: SourceConfig) -> String {
        let calendar = source.calendarName.trimmingCharacters(in: .whitespacesAndNewlines)
        return calendar.isEmpty ? "" : "[\(calendar)] "
    }

    /// `spec` carrying `marker` instead of its own, for a copy that keeps the marker it has:
    /// one another Mac made (see `SyncPlanner.plan`), rewritten here without taking it over.
    public static func spec(_ spec: CopySpec, taggedWith marker: CopyMarker) -> CopySpec {
        var spec = spec
        if let old = spec.marker, spec.notes.hasSuffix(old.encoded) {
            spec.notes = String(spec.notes.dropLast(old.encoded.count)) + marker.encoded
        }
        spec.marker = marker
        return spec
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
        if let meetingURL { lines.append(joinPrefix + meetingURL.absoluteString) }
        if let details, !details.isEmpty { lines.append(details) }
        lines.append("Copied by Calendar Hub. Changes here are overwritten.")
        lines.append(marker.encoded)
        return lines.joined(separator: "\n\n")
    }

    /// The meeting link on a copy's "Join:" line, the first line `notes(meetingURL:details:marker:)`
    /// writes. A copy's own URL, location and the end of its notes can't be trusted for it: a
    /// Google main calendar may give the copy a Google Meet of its own, with a different link
    /// than the meeting's. Nil when the copy was made without a link.
    public static func joinLink(in notes: String?) -> URL? {
        guard let notes else { return nil }
        let text = HTMLText.plainText(from: withoutGoogleConferenceBlock(notes))
        guard text.hasPrefix(joinPrefix) else { return nil }
        let line = text.prefix { $0 != "\n" }
        return MeetingLink.firstMeetingLink(in: String(line))
    }

    static let joinPrefix = "Join: "

    /// Google Calendar's own block about an event's Google Meet, as Google adds it to the
    /// description: between two `-::~:~::~…::-` lines, ending with "Please do not edit this
    /// section." It carries the Meet of the event it came from, so it isn't copied (the copy
    /// has its "Join:" line), and a block Google adds to a copy isn't taken for a change.
    private static let googleConferenceBlock = try! NSRegularExpression(
        pattern: #"-::~[:~]*::-[\s\S]*?(-::~[:~]*::-|$)"#)

    public static func withoutGoogleConferenceBlock(_ text: String) -> String {
        guard text.contains("-::~") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return googleConferenceBlock.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// Longest description copied into a copy's notes.
    static let maxDetailsLength = 8000

    /// The description and location to copy, or nil for both when the source doesn't copy
    /// details (or hides meeting names, which would make the details give it away).
    static func details(for event: SourceEvent, source: SourceConfig) -> (notes: String?, location: String?) {
        guard source.copyDetails, !source.hideMeetingName else { return (nil, nil) }
        var notes = event.notes.map { HTMLText.normalize(withoutGoogleConferenceBlock($0)) }
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
        busyNotes(token: busyToken(sourceID: sourceID))
    }

    static func busyNotes(token: String) -> String {
        busyNotes + "\n\n" + token
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

    /// The token a Busy event's marker stands for, mine or another Mac's: nil for one without
    /// a token (made by 1.x, or by 2.0.0 to 2.0.5).
    public static func busyToken(of marker: CopyMarker?) -> String? {
        guard let key = marker?.key, key.hasPrefix(busyKeyPrefix) else { return nil }
        let token = String(key.dropFirst(busyKeyPrefix.count))
        return isToken(token) ? token : nil
    }

    /// Whether `word` has the form of a token: 32 lowercase hex digits.
    static func isToken<S: StringProtocol>(_ word: S) -> Bool {
        word.count == 32 && word.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// The Busy event `spec` describes, carrying `token` (another Mac's) instead of this
    /// Mac's: one that Mac made, kept up to date here without being taken over.
    public static func busySpec(_ spec: CopySpec, token: String) -> CopySpec {
        var spec = spec
        spec.marker = spec.marker.map { CopyMarker(sourceID: $0.sourceID, key: busyKeyPrefix + token) }
        spec.notes = busyNotes(token: token)
        return spec
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
    ///
    /// One carrying another token is too: another Mac's, which gave the calendar an id of its
    /// own (or this Mac's, under an id the calendar had before it was set up again). Only a
    /// Mac syncing this calendar both ways adds Busy events to it, so they're the calendar's.
    /// Its marker then has `sourceID` and that token (see `busyToken(of:)`).
    public static func busyMatch(title: String?, notes: String?, sourceID: UUID) -> BusyMatch? {
        if let marker = CopyMarker.find(in: notes) {
            return marker.key.hasPrefix(busyKeyPrefix) ? .tagged(marker) : nil
        }
        let title = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard BusyStyle.allCases.contains(where: { $0.title == title }) else { return nil }
        // Calendar servers can hand the description back as HTML, with line breaks of their own.
        let words = HTMLText.words(of: HTMLText.plainText(from: notes ?? ""))
        if words.count == 2, words[0] == busyNotes, isToken(words[1]) {
            return .tagged(CopyMarker(sourceID: sourceID, key: busyKeyPrefix + words[1]))
        }
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
