import Foundation

/// The daily meeting limit: how many hours of meetings a day the user takes, and whether the
/// rest of a day that reaches it is marked Busy.
public struct MeetingLimitOptions: Codable, Hashable, Sendable {
    /// The limit is on: the menu says when a day reaches it.
    public var isEnabled: Bool
    /// Hours of meetings a day, counted as Meeting Stats counts them.
    public var hours: Double
    /// The free time left in a full day's working hours becomes Busy blocks in the main
    /// calendar, and, with two-way sync, in the secondary calendars that mark full days.
    public var marksBusy: Bool

    public init(isEnabled: Bool = false, hours: Double = 5, marksBusy: Bool = false) {
        self.isEnabled = isEnabled
        self.hours = hours
        self.marksBusy = marksBusy
    }

    /// Whether Busy blocks are wanted at all.
    public var writesBlocks: Bool { isEnabled && marksBusy }

    // Settings saved by older versions don't have every key yet.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MeetingLimitOptions()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        hours = try c.decodeIfPresent(Double.self, forKey: .hours) ?? defaults.hours
        marksBusy = try c.decodeIfPresent(Bool.self, forKey: .marksBusy) ?? defaults.marksBusy
    }
}

/// What the app remembers between syncs about the Busy blocks it wrote.
public struct MeetingLimitState: Codable, Hashable, Sendable {
    /// Days (`MeetingLimit.dayKey`) whose blocks the user deleted by hand: they get no new ones.
    public var skippedDays: Set<String>
    /// How many blocks each day had after the last sync, to notice one deleted by hand.
    public var written: [String: Int]

    public init(skippedDays: Set<String> = [], written: [String: Int] = [:]) {
        self.skippedDays = skippedDays
        self.written = written
    }

    /// Without the days before `today`, which nothing looks at again.
    public func pruned(before today: String) -> MeetingLimitState {
        MeetingLimitState(skippedDays: skippedDays.filter { $0 >= today },
                          written: written.filter { $0.key >= today })
    }
}

/// The daily meeting limit. Pure logic, unit tested.
///
/// Calendar Hub sees every calendar's meetings in the main calendar, so it can tell when a day
/// holds more meetings than the user wants. It can't stop invitations (they arrive in Outlook
/// or Google), so instead it can make that day look full: the free time left within working
/// hours becomes Busy blocks. A block never stops anyone from booking; meetings always win, and
/// the blocks around them are redrawn on the next sync.
public enum MeetingLimit {
    /// Starts the marker at the end of a block's description: `calsync:v1:limit:2026-11-18`.
    /// It isn't a `CopyMarker` (no source), but starts like one, so nothing ever copies a
    /// block back as a meeting.
    public static let markerPrefix = CopyMarker.prefix + "limit:"

    public static let title = "Busy"

    /// Gaps shorter than this between meetings get no block: nobody books ten minutes.
    public static let shortestBlock: TimeInterval = 15 * 60

    /// Whether `event` is a Busy block this app wrote for a full day.
    public static func isBlock(_ event: SourceEvent) -> Bool { isBlock(notes: event.notes) }

    public static func isBlock(notes: String?) -> Bool {
        notes?.contains(markerPrefix) ?? false
    }

    /// "2026-11-18": the day `date` falls on in `calendar`.
    public static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// A block's description. It says why it's there and how to keep the day open.
    public static func notes(dayKey: String) -> String {
        "Busy\n\nAdded by Calendar Hub: this day has reached your daily meeting limit. "
            + "It goes when the day drops below the limit. Delete it to stay bookable this day.\n\n"
            + markerPrefix + dayKey
    }

    public static func spec(for interval: DateInterval, calendar: Calendar) -> CopySpec {
        CopySpec(marker: nil, title: title, start: interval.start, end: interval.end, isAllDay: false,
                 timeZone: calendar.timeZone, url: nil,
                 notes: notes(dayKey: dayKey(interval.start, calendar: calendar)))
    }

    // MARK: - Full days

    /// A day whose meetings reach the limit.
    public struct FullDay: Hashable, Sendable {
        /// Its start.
        public var day: Date
        /// Hours of meetings, overlap counted once.
        public var hours: Double

        public init(day: Date, hours: Double) {
            self.day = day
            self.hours = hours
        }
    }

    /// The working hours the limit applies to on `day`: none on a weekend, without working
    /// hours, or when the user is out of office for part of them.
    static func workingInterval(on day: Date, events: [SourceEvent], calendar: Calendar,
                                workingHours: WorkingHours) -> DateInterval? {
        guard !calendar.isDateInWeekend(day),
              let working = workingHours.interval(on: day, calendar: calendar) else { return nil }
        let away = events.contains { event in
            MeetingStats.countsAsAway(event) && event.start < working.end && event.end > working.start
        }
        return away ? nil : working
    }

    /// Hours of meetings on `day`, counted as Meeting Stats counts them: timed meetings over the
    /// whole day, overlap once, blocks left out.
    public static func hours(on day: Date, in events: [SourceEvent], calendar: Calendar) -> Double {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return 0 }
        return MeetingStats.hours(of: events, in: DateInterval(start: start, end: end)).hours
    }

    /// Whether `day` has reached the limit. A minute's slack, so 4:59:30 of meetings reads as 5h.
    static func isFull(_ day: Date, events: [SourceEvent], options: MeetingLimitOptions,
                       calendar: Calendar, workingHours: WorkingHours) -> Bool {
        options.isEnabled && options.hours > 0
            && workingInterval(on: day, events: events, calendar: calendar, workingHours: workingHours) != nil
            && hours(on: day, in: events, calendar: calendar) >= options.hours - 1.0 / 60
    }

    /// The days among `days` (each a day's start) that reach the limit.
    public static func fullDays(_ days: [Date], events: [SourceEvent], options: MeetingLimitOptions,
                                calendar: Calendar, workingHours: WorkingHours) -> [FullDay] {
        days.filter { isFull($0, events: events, options: options, calendar: calendar, workingHours: workingHours) }
            .map { FullDay(day: calendar.startOfDay(for: $0), hours: hours(on: $0, in: events, calendar: calendar)) }
    }

    /// The days from `start`'s up to (not including) `end`'s, each as its start.
    public static func days(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        var days: [Date] = []
        var day = calendar.startOfDay(for: start)
        while day < end {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    /// The gaps between meetings within `day`'s working hours, at least `shortestBlock` long.
    /// Meetings are what Meeting Stats counts; blocks don't take time.
    public static func freeIntervals(in events: [SourceEvent], on day: Date, calendar: Calendar,
                                     workingHours: WorkingHours) -> [DateInterval] {
        guard let working = workingInterval(on: day, events: events, calendar: calendar,
                                            workingHours: workingHours) else { return [] }
        var free: [DateInterval] = []
        var cursor = working.start
        for meeting in events.filter(MeetingStats.counts).sorted(by: { $0.start < $1.start }) where meeting.end > cursor {
            guard meeting.start < working.end else { break }
            if meeting.start > cursor { free.append(DateInterval(start: cursor, end: meeting.start)) }
            cursor = max(cursor, meeting.end)
        }
        if cursor < working.end { free.append(DateInterval(start: cursor, end: working.end)) }
        return free.filter { $0.duration >= shortestBlock }
    }

    // MARK: - Blocks

    /// Days among `existing` blocks that have fewer than the last sync left: the user deleted
    /// one by hand, so that day gets no new ones.
    public static func deletedByHand(existing: [ExistingCopy], written: [String: Int],
                                     calendar: Calendar) -> Set<String> {
        let counts = blockCounts(existing, calendar: calendar)
        return Set(written.filter { day, count in (counts[day] ?? 0) < count }.keys)
    }

    /// How many blocks each day has.
    public static func blockCounts(_ blocks: [ExistingCopy], calendar: Calendar) -> [String: Int] {
        blocks.reduce(into: [:]) { counts, block in counts[dayKey(block.start, calendar: calendar), default: 0] += 1 }
    }

    /// Plans the Busy blocks in the main calendar for `days`.
    ///
    /// A full day's free time within working hours gets blocks; blocks already there are kept,
    /// moved to a gap that changed, or removed. A day below the limit, or with the limit or its
    /// blocks turned off, loses its blocks. Blocks already over (before `now`) stay as they
    /// are on a full day: there's nothing to book there any more. A skipped day (the user
    /// deleted one of its blocks) keeps what it has while full, and gets nothing new.
    ///
    /// - Parameters:
    ///   - mainEvents: the main calendar's events for `days`, blocks included.
    ///   - existing: the blocks in the main calendar. Ones on days not in `days` are removed.
    public static func planBlocks(
        mainEvents: [SourceEvent],
        existing: [ExistingCopy],
        days: [Date],
        now: Date,
        options: MeetingLimitOptions,
        workingHours: WorkingHours,
        skippedDays: Set<String> = [],
        calendar: Calendar
    ) -> SyncPlan {
        var actions: [SyncAction] = []
        var unchanged = 0
        var remaining = existing.sorted { $0.start < $1.start }
        func delete(_ block: ExistingCopy) {
            actions.append(.delete(eventID: block.eventID, title: block.title, start: block.start))
        }

        for day in days {
            let key = dayKey(day, calendar: calendar)
            let blocks = remaining.filter { dayKey($0.start, calendar: calendar) == key }
            remaining.removeAll { dayKey($0.start, calendar: calendar) == key }

            guard options.writesBlocks,
                  isFull(day, events: mainEvents, options: options, calendar: calendar, workingHours: workingHours)
            else {
                blocks.forEach(delete)
                continue
            }
            if skippedDays.contains(key) {
                unchanged += blocks.count
                continue
            }

            let past = blocks.filter { $0.end <= now }
            unchanged += past.count
            var current = blocks.filter { $0.end > now }
            var wanted = freeIntervals(in: mainEvents, on: day, calendar: calendar, workingHours: workingHours)
                .filter { $0.end > now }

            // Blocks already where they belong stay.
            current.removeAll { block in
                guard let index = wanted.firstIndex(where: { sameTimes(block, $0) }) else { return false }
                wanted.remove(at: index)
                if needsUpdate(block, to: spec(for: DateInterval(start: block.start, end: block.end), calendar: calendar)) {
                    actions.append(.update(eventID: block.eventID,
                                           spec(for: DateInterval(start: block.start, end: block.end), calendar: calendar)))
                } else {
                    unchanged += 1
                }
                return true
            }
            // The others move to the gaps left, in order; any left over go.
            for block in current {
                if wanted.isEmpty {
                    delete(block)
                } else {
                    actions.append(.update(eventID: block.eventID, spec(for: wanted.removeFirst(), calendar: calendar)))
                }
            }
            actions += wanted.map { .create(spec(for: $0, calendar: calendar)) }
        }
        // Days outside the window: nothing keeps them up to date any more.
        remaining.forEach(delete)
        return SyncPlan(actions: actions, failedSources: [:], unchangedCount: unchanged)
    }

    static func sameTimes(_ block: ExistingCopy, _ interval: DateInterval) -> Bool {
        abs(block.start.timeIntervalSince(interval.start)) < 1 && abs(block.end.timeIntervalSince(interval.end)) < 1
    }

    /// A block in the right place, but titled or described differently: an older version's,
    /// or one the user edited.
    static func needsUpdate(_ block: ExistingCopy, to spec: CopySpec) -> Bool {
        block.title != spec.title || HTMLText.words(of: HTMLText.plainText(from: block.notes)) != HTMLText.words(of: spec.notes)
    }

    // MARK: - Text

    /// "5h", "5h 30m".
    public static func format(hours: Double) -> String {
        MenuCalendar.shortDuration(minutes: Int((hours * 60).rounded()))
    }

    /// The menu's line for a full day: "Tomorrow: 5h 20m of meetings, over your 5h limit".
    public static func message(for full: FullDay, limit: Double, now: Date, calendar: Calendar) -> String {
        let name: String
        if calendar.isDate(full.day, inSameDayAs: now) {
            name = "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
                  calendar.isDate(full.day, inSameDayAs: tomorrow) {
            name = "Tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEEE"
            name = formatter.string(from: full.day)
        }
        let over = full.hours > limit + 1.0 / 60
        return "\(name): \(format(hours: full.hours)) of meetings, \(over ? "over" : "at") your \(format(hours: limit)) limit"
    }
}
