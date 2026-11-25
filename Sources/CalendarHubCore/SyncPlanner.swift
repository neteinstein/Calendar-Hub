import Foundation

/// One change to make in the target calendar.
public enum SyncAction: Hashable, Sendable {
    case create(CopySpec)
    case update(eventID: String, CopySpec)
    case delete(eventID: String, title: String, start: Date)
}

public struct SyncPlan: Sendable {
    public var actions: [SyncAction]
    /// Sources that couldn't be read this run, with the reason. Their copies are untouched.
    public var failedSources: [UUID: String]
    public var unchangedCount: Int
    /// Meetings left out because the same invitation is already in the main calendar, or is
    /// copied from (or, for Busy events, already in) another calendar. See `SameInvite`.
    public var sameInviteCount = 0
    /// Ids another Mac gave the calendars read here, each with the id the calendar has here:
    /// found when a copy that Mac made is, for certain, a copy of a meeting read here. See
    /// `SyncPlanner.plan`.
    public var otherMacIDs: [UUID: UUID] = [:]

    public var creates: Int { actions.filter { if case .create = $0 { true } else { false } }.count }
    public var updates: Int { actions.filter { if case .update = $0 { true } else { false } }.count }
    public var deletes: Int { actions.filter { if case .delete = $0 { true } else { false } }.count }
    public var isEmpty: Bool { actions.isEmpty }
}

/// Decides what to create, update and delete. Pure logic, no calendar access, so it can be
/// unit tested and used for the dry-run preview.
public enum SyncPlanner {
    /// - Parameters:
    ///   - sources: every configured source with the result of reading it for the sync window.
    ///   - existing: copies currently in the target calendar for the same window (anything
    ///     carrying a marker).
    ///   - mainEvents: the main calendar's own events for the sync window. A meeting already
    ///     there, invited to both calendars, isn't copied (see `SameInvite`).
    ///   - lastRead: every enabled secondary calendar, in the order they're set up, with its
    ///     events as last read, also those not read this time. When one invitation reached
    ///     several of them, only the first one copies it. Nil uses `sources`.
    ///   - setUpHere: every secondary calendar set up on this Mac, also those not read this time.
    ///     Copies carrying any other id were made by another Mac (or for a calendar removed
    ///     here). Nil takes the ids in `sources`.
    ///   - calendar: whose days all-day events are compared by.
    ///
    /// Another Mac copying the same calendar into the same main calendar has its own id for
    /// it, so its copies carry markers this Mac never writes. A copy of a meeting read here
    /// that it made counts as this Mac's copy of that meeting, instead of getting a second one
    /// next to it, and is kept up to date with the marker it has (see `otherMacsCopies`).
    public static func plan(
        sources: [(config: SourceConfig, result: SourceFetchResult)],
        existing: [ExistingCopy],
        options: SyncOptions,
        mainEvents: [SourceEvent] = [],
        lastRead: [(config: SourceConfig, events: [SourceEvent])]? = nil,
        setUpHere: Set<UUID>? = nil,
        calendar: Calendar = .current
    ) -> SyncPlan {
        var desired: [CopyMarker: CopySpec] = [:]
        var desiredOrder: [CopyMarker] = []
        var syncedSourceIDs: Set<UUID> = []
        var read: [(config: SourceConfig, events: [SourceEvent])] = []
        var failed: [UUID: String] = [:]
        var sameInvite = 0

        let lastRead = (lastRead ?? sources.compactMap { source in
            guard case .success(let events) = source.result else { return nil }
            return (source.config, events)
        }).filter { $0.config.isEnabled }
        let mainOriginals = mainEvents.filter(SameInvite.isOriginal)

        for (config, result) in sources where config.isEnabled {
            switch result {
            case .failure(let reason):
                failed[config.id] = reason
            case .success(let events):
                syncedSourceIDs.insert(config.id)
                read.append((config, events))
                // What the calendars set up before this one copy: the same invitation is theirs.
                let index = lastRead.firstIndex { $0.config.id == config.id } ?? lastRead.count
                let copiedEarlier = lastRead[..<index].flatMap { earlier in
                    earlier.events.filter { shouldCopy($0, from: earlier.config, options: options) }
                }
                for event in events where shouldCopy(event, from: config, options: options) {
                    let isElsewhere = { (other: SourceEvent) in SameInvite.matches(event, other, calendar: calendar) }
                    if mainOriginals.contains(where: isElsewhere) || copiedEarlier.contains(where: isElsewhere) {
                        sameInvite += 1
                        continue
                    }
                    let spec = CopyFormatter.spec(for: event, source: config)
                    if let marker = spec.marker, desired[marker] == nil {
                        desired[marker] = spec
                        desiredOrder.append(marker)
                    }
                }
            }
        }

        let (actions, unchanged, otherMacIDs) = diff(
            desired: desired, order: desiredOrder, existing: existing, owners: syncedSourceIDs,
            read: read, setUp: setUpHere ?? Set(sources.map(\.config.id)), calendar: calendar)
        return SyncPlan(actions: actions, failedSources: failed, unchangedCount: unchanged,
                        sameInviteCount: sameInvite, otherMacIDs: otherMacIDs)
    }

    /// Plans the "Busy" events that show the main calendar inside one secondary calendar.
    ///
    /// Busy events carry nothing but their times, so they're matched to the main calendar by
    /// time: one per distinct time, and a meeting that moves gets its Busy event removed and
    /// another added at the new time.
    ///
    /// A meeting the secondary calendar has itself, invited to both calendars, gets no Busy
    /// event there: the meeting already shows that time as taken.
    ///
    /// - Parameters:
    ///   - source: the secondary calendar to write into.
    ///   - mainEvents: the main calendar's events for the sync window.
    ///   - existing: the Busy events currently in the secondary calendar.
    ///   - clearingAlerts: whether Busy events that have alerts are rewritten, which takes the
    ///     alerts off. Done once, for Busy events saved by older versions: a calendar that adds
    ///     its default alerts back would otherwise have them rewritten on every sync.
    ///   - known: the secondary calendars' events as last read, this one's included. This one's
    ///     are its own meetings; the others' tell which meeting a copy in the main calendar
    ///     stands for.
    ///   - otherMacIDs: ids another Mac gave the calendars set up here (see `SyncPlan.otherMacIDs`),
    ///     whose copies in the main calendar are copies of the same meetings.
    ///   - calendar: whose days all-day events are compared by.
    public static func planBusy(
        for source: SourceConfig,
        mainEvents: SourceFetchResult,
        existing: [ExistingCopy],
        options: SyncOptions,
        clearingAlerts: Bool = false,
        known: [(config: SourceConfig, events: [SourceEvent])] = [],
        otherMacIDs: [UUID: UUID] = [:],
        calendar: Calendar = .current
    ) -> SyncPlan {
        let events: [SourceEvent]
        switch mainEvents {
        case .failure(let reason):
            // Leave existing Busy events alone rather than deleting them.
            return SyncPlan(actions: [], failedSources: [source.id: reason], unchangedCount: 0)
        case .success(let list):
            events = list
        }

        // This calendar's own meetings, and the meeting behind each copy in the main calendar.
        let own = (known.first { $0.config.id == source.id }?.events ?? []).filter {
            SameInvite.isOriginal($0) && !CopyFormatter.isBusyEvent(title: $0.title, notes: $0.notes, sourceID: source.id)
        }
        var originals: [CopyMarker: SourceEvent] = [:]
        if !own.isEmpty {
            for (config, list) in known {
                let ids = [config.id] + otherMacIDs.filter { $0.value == config.id }.map(\.key)
                for id in ids {
                    for event in list { originals[CopyMarker.hashed(sourceID: id, key: event.key)] = event }
                }
            }
        }

        var desired: [CopySpec] = []
        var sameInvite = 0
        for event in events where shouldShowBusy(event, in: source, options: options, otherMacIDs: otherMacIDs) {
            if !own.isEmpty {
                let original: SourceEvent? = if let marker = CopyMarker.find(in: event.notes) {
                    originals[marker] ?? originals[marker.hashedIfLegacy]
                } else {
                    event
                }
                if let original, own.contains(where: { SameInvite.matches(original, $0, calendar: calendar) }) {
                    sameInvite += 1
                    continue
                }
            }
            let spec = CopyFormatter.busySpec(for: event, source: source)
            if !desired.contains(where: { $0.start == spec.start && $0.end == spec.end && $0.isAllDay == spec.isAllDay }) {
                desired.append(spec)
            }
        }
        desired.sort { $0.start < $1.start }

        // Another Mac syncing this calendar both ways adds Busy events with its own token. Of
        // two at one time, both Macs keep the same one: the first by token, and one without a
        // token (an older version's, or a look-alike) last.
        let ownToken = CopyFormatter.busyToken(sourceID: source.id)
        let order = { (busy: ExistingCopy) in (busy.start, CopyFormatter.busyToken(of: busy.marker) ?? "~") }
        let sorted = existing.sorted { order($0) < order($1) }
        var actions: [SyncAction] = []
        var unchanged = 0
        var taken: [CopySpec] = []
        for busy in sorted {
            let isAt = { (spec: CopySpec) in spec.isAllDay == busy.isAllDay && sameTimes(busy, spec, calendar: calendar) }
            let token = CopyFormatter.busyToken(of: busy.marker)
            let othersToken = token.flatMap { $0 == ownToken ? nil : $0 }
            guard let index = desired.firstIndex(where: isAt) else {
                // Another Mac's, at the time of a main-calendar event this Mac shows no Busy for
                // (its settings leave it out): that Mac's to keep or take back.
                let othersWanted = othersToken != nil && !taken.contains(where: isAt) && events.contains {
                    $0.isAllDay == busy.isAllDay
                        && sameTimes(busy, start: $0.start, end: $0.end, isAllDay: $0.isAllDay, calendar: calendar)
                }
                if !othersWanted {
                    // Nothing in the main calendar at that time any more, or a duplicate.
                    actions.append(.delete(eventID: busy.eventID, title: busy.title, start: busy.start))
                }
                continue
            }
            var spec = desired.remove(at: index)
            taken.append(spec)
            // Kept with its own token, so the other Mac doesn't write its back.
            if let othersToken { spec = CopyFormatter.busySpec(spec, token: othersToken) }
            if needsBusyUpdate(busy, to: spec) || (clearingAlerts && busy.hasAlerts) {
                actions.append(.update(eventID: busy.eventID, spec))
            } else {
                unchanged += 1
            }
        }
        actions += desired.map { .create($0) }
        return SyncPlan(actions: actions, failedSources: [:], unchangedCount: unchanged, sameInviteCount: sameInvite)
    }

    /// Takes back the Busy events in a secondary calendar that no longer asks for them. Left
    /// there, they'd go on showing the main calendar as it was when they were last updated.
    ///
    /// Another Mac's Busy events (with another token) stay: that Mac may still show the main
    /// calendar here.
    ///
    /// - Parameters:
    ///   - source: the secondary calendar the Busy events are in.
    ///   - addedHere: whether Busy events were added to this calendar since they stopped
    ///     carrying a marker. If not, only the ones with a marker are taken back, so an event the
    ///     user made that just looks like a Busy event is left alone.
    public static func planBusyRemoval(for source: SourceConfig, existing: [ExistingCopy], addedHere: Bool) -> SyncPlan {
        let ownToken = CopyFormatter.busyToken(sourceID: source.id)
        let actions = existing
            .filter { addedHere || $0.marker != nil }
            .filter { CopyFormatter.busyToken(of: $0.marker).map { $0 == ownToken } ?? true }
            .sorted { $0.start < $1.start }
            .map { SyncAction.delete(eventID: $0.eventID, title: $0.title, start: $0.start) }
        return SyncPlan(actions: actions, failedSources: [:], unchangedCount: 0)
    }

    /// Copies whose secondary calendar isn't set up here any more: removed, or set up again
    /// under a new id (a calendar added back, or one lost in a move between versions). No sync
    /// touches them again, so they'd stay next to the new copies, and never follow the
    /// meeting's changes. Sorted by start.
    ///
    /// They're only ever removed when the user asks: another Mac copying into the same main
    /// calendar has its own sources, whose copies look just the same from here.
    ///
    /// - Parameter known: the sources set up here, and any whose copies the user chose to keep.
    public static func orphanedCopies(in existing: [ExistingCopy], known: Set<UUID>) -> [ExistingCopy] {
        existing
            .filter { copy in copy.marker.map { !known.contains($0.sourceID) } ?? false }
            .sorted { $0.start < $1.start }
    }

    /// Removes the copies of `sourceIDs` among `existing`: those of a secondary calendar being
    /// removed, or orphaned ones the user chose to remove.
    public static func planCopyRemoval(existing: [ExistingCopy], sourceIDs: Set<UUID>) -> SyncPlan {
        let actions = existing
            .filter { copy in copy.marker.map { sourceIDs.contains($0.sourceID) } ?? false }
            .sorted { $0.start < $1.start }
            .map { SyncAction.delete(eventID: $0.eventID, title: $0.title, start: $0.start) }
        return SyncPlan(actions: actions, failedSources: [:], unchangedCount: 0)
    }

    /// For a Busy event already matched by time. The description is compared word by word,
    /// so one a calendar server stored as HTML, with its own idea of line breaks and paragraph
    /// spacing, isn't rewritten on every sync, while a Busy event made by an older version
    /// gets its marker (or its new one) written.
    static func needsBusyUpdate(_ busy: ExistingCopy, to spec: CopySpec) -> Bool {
        busy.title != spec.title
            || HTMLText.words(of: HTMLText.plainText(from: busy.notes)) != HTMLText.words(of: spec.notes)
            || busy.url != nil
            || !(busy.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func shouldShowBusy(_ event: SourceEvent, in source: SourceConfig, options: SyncOptions,
                               otherMacIDs: [UUID: UUID] = [:]) -> Bool {
        if event.isCancelled { return false }
        if options.skipDeclined && event.isDeclined { return false }
        if options.skipAllDay && event.isAllDay { return false }
        // A full day's Busy blocks reach only the calendars that mark full days: some clients
        // shouldn't see the user as unavailable.
        if MeetingLimit.isBlock(event) { return source.marksFullDays && event.end > event.start }
        // Copies of this calendar's own meetings are already in its calendar. Copies from other
        // secondary calendars are shown, so each one sees time booked by the others.
        if let id = CopyMarker.find(in: event.notes)?.sourceID, id == source.id || otherMacIDs[id] == source.id {
            return false
        }
        return event.end >= event.start
    }

    /// Matches desired copies against existing ones. Only copies owned by `owners` are
    /// touched, so copies of sources that failed, are disabled or were removed stay as they are.
    /// Copies of sources not in `setUp` are another Mac's: see `otherMacsCopies`.
    ///
    /// When one meeting has two copies, one stays and the other goes. Which one is the same on
    /// every Mac: the copy whose source id comes first, so two Macs never each remove the
    /// other's and leave none.
    static func diff(
        desired: [CopyMarker: CopySpec],
        order: [CopyMarker],
        existing: [ExistingCopy],
        owners: Set<UUID>,
        read: [(config: SourceConfig, events: [SourceEvent])] = [],
        setUp: Set<UUID> = [],
        calendar: Calendar
    ) -> (actions: [SyncAction], unchanged: Int, otherMacIDs: [UUID: UUID]) {
        let sorted = existing.sorted { $0.start < $1.start }
        // The copies standing for each desired copy, with the marker each one keeps.
        var standIns: [CopyMarker: [(index: Int, keeps: CopyMarker)]] = [:]
        var deleted: Set<Int> = []
        var foreign: [(index: Int, copy: ExistingCopy)] = []

        for (index, copy) in sorted.enumerated() {
            guard var marker = copy.marker else { continue }
            if owners.contains(marker.sourceID) {
                // A copy made before markers were hashed matches by its hashed key, and the
                // rewrite that follows (its notes differ) gives it the hashed marker.
                if desired[marker] == nil, desired[marker.hashedIfLegacy] != nil { marker = marker.hashedIfLegacy }
                if desired[marker] != nil {
                    standIns[marker, default: []].append((index, marker))
                } else {
                    // Source occurrence is gone (cancelled, declined, deleted).
                    deleted.insert(index)
                }
            } else if !setUp.contains(marker.sourceID), !marker.key.hasPrefix(CopyFormatter.busyKeyPrefix) {
                foreign.append((index, copy))
            }
        }

        let others = otherMacsCopies(foreign, read: read, desired: desired, claimed: Set(standIns.keys),
                                     calendar: calendar)
        for standIn in others.standIns {
            standIns[standIn.desired, default: []].append((standIn.index, standIn.keeps))
        }
        deleted.formUnion(others.gone)

        var keepers: [Int: (desired: CopyMarker, keeps: CopyMarker)] = [:]
        for (marker, copies) in standIns {
            let keeper = copies.min {
                ($0.keeps.sourceID.uuidString, $0.index) < ($1.keeps.sourceID.uuidString, $1.index)
            }!
            // The others are duplicates.
            for copy in copies where copy.index != keeper.index { deleted.insert(copy.index) }
            keepers[keeper.index] = (marker, keeper.keeps)
        }

        var actions: [SyncAction] = []
        var unchanged = 0
        for (index, copy) in sorted.enumerated() {
            if deleted.contains(index) {
                actions.append(.delete(eventID: copy.eventID, title: copy.title, start: copy.start))
            } else if let keeper = keepers[index], var spec = desired[keeper.desired] {
                if keeper.keeps != keeper.desired { spec = CopyFormatter.spec(spec, taggedWith: keeper.keeps) }
                if needsUpdate(copy, to: spec, calendar: calendar) {
                    actions.append(.update(eventID: copy.eventID, spec))
                } else {
                    unchanged += 1
                }
            }
        }
        for marker in order where standIns[marker] == nil {
            actions.append(.create(desired[marker]!))
        }
        return (actions, unchanged, others.otherMacIDs)
    }

    /// Finds, among copies carrying an id not set up here, the ones another Mac made of a
    /// meeting read here. Each is matched to that meeting:
    ///
    /// - For certain, when the meeting's key hashed with that Mac's id is the copy's marker.
    ///   That needs a key both Macs agree on, as Outlook on the web's are. The id is then known
    ///   to be that Mac's for the calendar (`otherMacIDs`).
    /// - Otherwise by its title (calendar prefix included) and times, which is how a copy of a
    ///   Calendar.app calendar is found: Calendar.app keys each event differently on each Mac.
    ///
    /// A match only counts for a calendar of the same name, so both Macs write the same title
    /// and neither keeps rewriting the other's copies. A copy of a meeting copied here stands
    /// for this Mac's copy (`standIns`); one of a meeting not copied here (one this Mac's
    /// settings leave out) is left to the other Mac. A copy of a calendar known to be the same,
    /// matching no meeting read here, is of a meeting that's gone: cancelled or deleted, or
    /// moved where the other Mac may never move its copy to, if that Mac stopped syncing.
    /// Those go (`gone`). Anything else stays: it may be another calendar that Mac copies.
    static func otherMacsCopies(
        _ copies: [(index: Int, copy: ExistingCopy)],
        read: [(config: SourceConfig, events: [SourceEvent])],
        desired: [CopyMarker: CopySpec],
        claimed: Set<CopyMarker>,
        calendar: Calendar
    ) -> (standIns: [(index: Int, desired: CopyMarker, keeps: CopyMarker)], gone: [Int], otherMacIDs: [UUID: UUID]) {
        guard !copies.isEmpty else { return ([], [], [:]) }
        struct Meeting {
            let source: SourceConfig
            let event: SourceEvent
            let marker: CopyMarker
            let title: String
        }
        let meetings = read.flatMap { config, events in
            events.filter { !$0.isCancelled }.map {
                Meeting(source: config, event: $0, marker: .hashed(sourceID: config.id, key: $0.key),
                        title: CopyFormatter.title(for: $0, source: config))
            }
        }

        var claimed = claimed
        var standIns: [(index: Int, desired: CopyMarker, keeps: CopyMarker)] = []
        var matched: Set<Int> = []
        var otherMacIDs: [UUID: UUID] = [:]
        func take(_ index: Int, _ meeting: Meeting, keeps: CopyMarker) {
            matched.insert(index)
            guard desired[meeting.marker] != nil else { return }
            standIns.append((index, meeting.marker, keeps))
            claimed.insert(meeting.marker)
        }

        for (otherID, list) in Dictionary(grouping: copies, by: { $0.copy.marker!.sourceID }) {
            var byKey: [String: Meeting] = [:]
            for meeting in meetings { byKey[CopyMarker.hashKey(meeting.event.key, sourceID: otherID)] = meeting }
            for (index, copy) in list {
                guard let meeting = byKey[copy.marker!.key],
                      copy.title.hasPrefix(CopyFormatter.titlePrefix(of: meeting.source)) else { continue }
                take(index, meeting, keeps: CopyMarker(sourceID: otherID, key: copy.marker!.key))
                otherMacIDs[otherID] = meeting.source.id
            }
        }

        for (index, copy) in copies where !matched.contains(index) {
            let alike = meetings.filter {
                $0.title == copy.title && $0.event.isAllDay == copy.isAllDay
                    && sameTimes(copy, start: $0.event.start, end: $0.event.end, isAllDay: $0.event.isAllDay, calendar: calendar)
            }
            // Two meetings alike (hidden names, at one time) each get one of the copies.
            guard let meeting = alike.first(where: { !claimed.contains($0.marker) }) ?? alike.first else { continue }
            take(index, meeting, keeps: copy.marker!)
        }

        let gone = copies.filter { index, copy in
            guard !matched.contains(index), let sourceID = otherMacIDs[copy.marker!.sourceID],
                  let source = read.first(where: { $0.config.id == sourceID })?.config else { return false }
            return copy.title.hasPrefix(CopyFormatter.titlePrefix(of: source))
        }
        return (standIns, gone.map(\.index), otherMacIDs)
    }

    static func shouldCopy(_ event: SourceEvent, from source: SourceConfig, options: SyncOptions) -> Bool {
        if event.isCancelled { return false }
        if options.skipDeclined && event.isDeclined { return false }
        if !source.copyUnaccepted && !event.isAccepted { return false }
        if options.skipAllDay && event.isAllDay { return false }
        if options.skipOutOfOffice && event.isOutOfOffice { return false }
        // Never copy our own copies or Busy events back (two-way setups would loop forever).
        if CopyMarker.isCopy(event.notes) || CopyFormatter.isBusyEvent(title: event.title, notes: event.notes, sourceID: source.id) {
            return false
        }
        return event.end >= event.start
    }

    /// Notes and location are compared after tidying whitespace, since calendar servers
    /// (Exchange, Google) change line endings and spacing when they store them, and without
    /// the Google Meet block a Google calendar may add to a copy.
    static func needsUpdate(_ copy: ExistingCopy, to spec: CopySpec, calendar: Calendar) -> Bool {
        copy.title != spec.title
            || !sameTimes(copy, spec, calendar: calendar)
            || copy.isAllDay != spec.isAllDay
            || copy.url != spec.url
            || HTMLText.normalize(CopyFormatter.withoutGoogleConferenceBlock(copy.notes)) != HTMLText.normalize(spec.notes)
            || HTMLText.normalize(copy.location ?? "") != HTMLText.normalize(spec.location ?? "")
    }

    /// All-day events are compared by their first and last day: an all-day event's end can
    /// be a second before midnight or midnight itself, depending on who wrote it.
    static func sameTimes(_ copy: ExistingCopy, _ spec: CopySpec, calendar: Calendar) -> Bool {
        sameTimes(copy, start: spec.start, end: spec.end, isAllDay: spec.isAllDay, calendar: calendar)
    }

    static func sameTimes(_ copy: ExistingCopy, start: Date, end: Date, isAllDay: Bool, calendar: Calendar) -> Bool {
        if copy.isAllDay && isAllDay {
            return calendar.isDate(copy.start, inSameDayAs: start) && calendar.isDate(copy.end - 1, inSameDayAs: end - 1)
        }
        return abs(copy.start.timeIntervalSince(start)) < 1 && abs(copy.end.timeIntervalSince(end)) < 1
    }
}
