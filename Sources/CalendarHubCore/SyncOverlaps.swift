import Foundation

/// A copy a sync adds, or moves, to a time that overlaps another meeting in the main calendar.
public struct SyncOverlap: Hashable, Sendable, Identifiable {
    /// The copy's marker key, so the same copy isn't reported twice for one sync.
    public var id: String
    /// The copy's title, as `[Calendar A] Sprint planning`.
    public var title: String
    public var start: Date
    public var end: Date
    /// The titles of the meetings it overlaps, soonest first.
    public var others: [String]

    public init(id: String, title: String, start: Date, end: Date, others: [String]) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.others = others
    }
}

/// Finds the overlaps a sync is about to make: only for the copies it adds or moves, never
/// for meetings that already overlapped and stayed where they were.
public enum SyncOverlaps {
    /// - Parameters:
    ///   - plan: the sync's plan for the main calendar.
    ///   - existing: the copies in the main calendar before the plan is applied.
    ///   - mainEvents: the main calendar's events before the plan is applied, copies included.
    ///   - now: copies that have already ended aren't reported.
    public static func find(plan: SyncPlan, existing: [ExistingCopy], mainEvents: [SourceEvent],
                            now: Date) -> [SyncOverlap] {
        struct Slot {
            var id: String
            var title: String
            var start: Date
            var end: Date
        }
        let byID = Dictionary(existing.map { ($0.eventID, $0) }, uniquingKeysWith: { first, _ in first })
        var deleted: Set<String> = []
        var updated: [String: CopySpec] = [:]
        var changed: [Slot] = []
        var slots: [Slot] = []

        for action in plan.actions {
            switch action {
            case .create(let spec):
                guard counts(spec) else { continue }
                let slot = Slot(id: id(of: spec), title: spec.title, start: spec.start, end: spec.end)
                changed.append(slot)
                slots.append(slot)
            case .update(let eventID, let spec):
                updated[eventID] = spec
                guard counts(spec) else { continue }
                let slot = Slot(id: id(of: spec), title: spec.title, start: spec.start, end: spec.end)
                slots.append(slot)
                // Only a copy that moved can make a new overlap.
                if let before = byID[eventID], before.start == spec.start, before.end == spec.end { continue }
                changed.append(slot)
            case .delete(let eventID, _, _):
                deleted.insert(eventID)
            }
        }
        guard !changed.isEmpty else { return [] }

        // Copies the plan leaves as they are.
        for copy in existing where !deleted.contains(copy.eventID) && updated[copy.eventID] == nil && !copy.isAllDay {
            guard !MeetingLimit.isBlock(notes: copy.notes) else { continue }
            slots.append(Slot(id: copy.marker.map { "\($0.sourceID):\($0.key)" } ?? copy.eventID,
                              title: copy.title, start: copy.start, end: copy.end))
        }
        // The main calendar's own meetings: not copies, not a full day's Busy blocks.
        for event in mainEvents where CopyMarker.find(in: event.notes) == nil {
            guard !event.isAllDay, !event.isDeclined, !event.isCancelled, !event.isOutOfOffice,
                  !MeetingLimit.isBlock(event) else { continue }
            slots.append(Slot(id: "main:" + event.key, title: event.title, start: event.start, end: event.end))
        }

        var found: [SyncOverlap] = []
        var reported: Set<Set<String>> = []
        for copy in changed where copy.end > now {
            let others = slots
                .filter { $0.id != copy.id && $0.start < copy.end && copy.start < $0.end }
                .sorted { $0.start < $1.start }
            // Two copies moved onto each other are one overlap, not two.
            let fresh = others.filter { reported.insert([copy.id, $0.id]).inserted }
            guard !fresh.isEmpty else { continue }
            found.append(SyncOverlap(id: copy.id, title: copy.title, start: copy.start, end: copy.end,
                                     others: fresh.map(\.title)))
        }
        return found.sorted { $0.start < $1.start }
    }

    /// One line for a notification or the menu: "Thu 14:00: [Calendar A] Sprint planning
    /// overlaps Design review".
    public static func text(_ overlap: SyncOverlap, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                     timeZone: calendar.timeZone)
        if !calendar.isDate(overlap.start, inSameDayAs: Date()) { style = style.weekday(.abbreviated) }
        let others = overlap.others.count > 2
            ? overlap.others.prefix(2).joined(separator: ", ") + " and \(overlap.others.count - 2) more"
            : overlap.others.count == 2 ? overlap.others.joined(separator: " and ") : overlap.others.joined()
        return "\(overlap.start.formatted(style)): \(overlap.title) overlaps \(others)"
    }

    private static func counts(_ spec: CopySpec) -> Bool {
        !spec.isAllDay && !spec.isOutOfOffice && !MeetingLimit.isBlock(notes: spec.notes)
    }

    private static func id(of spec: CopySpec) -> String {
        spec.marker.map { "\($0.sourceID):\($0.key)" } ?? "\(spec.title)|\(spec.start.timeIntervalSince1970)"
    }
}
