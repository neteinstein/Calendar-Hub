import Foundation

/// Reads iCalendar (.ics) data, as Google Calendar exports it, into events, with recurring
/// events expanded into their occurrences. Covers what calendar servers write: time zones by
/// their tz database name, all-day dates, DTEND or DURATION, RRULE (DAILY, WEEKLY, MONTHLY,
/// YEARLY with INTERVAL, COUNT, UNTIL, BYDAY, BYMONTHDAY, BYMONTH and BYSETPOS), RDATE,
/// EXDATE, and moved or cancelled occurrences (RECURRENCE-ID).
public enum ICalendar {
    /// One VEVENT as written: a single event, a recurring one, or one occurrence of a
    /// recurring one changed (`recurrenceID` set).
    public struct Event: Hashable, Sendable {
        public var uid: String
        public var summary: String
        public var description: String?
        public var location: String?
        public var url: URL?
        public var start: Date
        public var end: Date
        public var isAllDay: Bool
        public var timeZone: TimeZone?
        public var status: String?
        public var transparent: Bool
        public var rule: Rule?
        public var extraDates: [Date]
        public var exceptions: [Date]
        public var recurrenceID: Date?
        /// Each attendee's address (without `mailto:`), lower case, with their answer.
        public var attendees: [String: String]
        public var organizer: String?
        /// Google Meet's link, from `X-GOOGLE-CONFERENCE`.
        public var conference: URL?
    }

    public struct Rule: Hashable, Sendable {
        public enum Frequency: String, Sendable { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }
        public var frequency: Frequency
        public var interval = 1
        public var count: Int?
        public var until: Date?
        /// Weekdays, 1 = Sunday as `Calendar` numbers them, each with its ordinal in the month
        /// or year (2 for 2TU, -1 for -1FR), 0 for none.
        public var byDay: [(weekday: Int, ordinal: Int)] = []
        public var byMonthDay: [Int] = []
        public var byMonth: [Int] = []
        public var bySetPos: [Int] = []
        public var weekStart = 2

        public static func == (a: Rule, b: Rule) -> Bool {
            a.frequency == b.frequency && a.interval == b.interval && a.count == b.count && a.until == b.until
                && a.byDay.map { [$0.weekday, $0.ordinal] } == b.byDay.map { [$0.weekday, $0.ordinal] }
                && a.byMonthDay == b.byMonthDay && a.byMonth == b.byMonth && a.bySetPos == b.bySetPos
                && a.weekStart == b.weekStart
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(frequency)
            hasher.combine(interval)
            hasher.combine(count)
        }
    }

    // MARK: - Parsing

    struct Line {
        var name: String
        var params: [String: String]
        var value: String
    }

    /// The content lines of `text`, unfolded.
    static func lines(_ text: String) -> [Line] {
        var unfolded: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                unfolded.append(String(raw))
            }
        }
        return unfolded.compactMap(line)
    }

    static func line(_ text: String) -> Line? {
        var inQuotes = false
        var colon: String.Index?
        for index in text.indices {
            let character = text[index]
            if character == "\"" { inQuotes.toggle() }
            if character == ":", !inQuotes { colon = index; break }
        }
        guard let colon else { return nil }
        let head = text[..<colon]
        let value = String(text[text.index(after: colon)...])
        var parts: [String] = []
        var current = ""
        inQuotes = false
        for character in head {
            if character == "\"" { inQuotes.toggle(); continue }
            if character == ";", !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        var params: [String: String] = [:]
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { params[pair[0].uppercased()] = String(pair[1]) }
        }
        return Line(name: parts[0].uppercased(), params: params, value: value)
    }

    static func unescape(_ text: String) -> String {
        var out = ""
        var escaped = false
        for character in text {
            if escaped {
                switch character {
                case "n", "N": out.append("\n")
                default: out.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// A date or date-time value. All-day dates are midnight in `fallback`'s time zone.
    static func date(_ value: String, params: [String: String], fallback: TimeZone) -> (date: Date, allDay: Bool, zone: TimeZone?)? {
        let value = value.trimmingCharacters(in: .whitespaces)
        let digits = value.filter(\.isNumber)
        var components = DateComponents()
        guard digits.count >= 8 else { return nil }
        components.year = Int(digits.prefix(4))
        components.month = Int(digits.dropFirst(4).prefix(2))
        components.day = Int(digits.dropFirst(6).prefix(2))
        var calendar = Calendar(identifier: .gregorian)
        if params["VALUE"]?.uppercased() == "DATE" || !value.contains("T") {
            calendar.timeZone = fallback
            return calendar.date(from: components).map { ($0, true, nil) }
        }
        guard digits.count >= 14 else { return nil }
        components.hour = Int(digits.dropFirst(8).prefix(2))
        components.minute = Int(digits.dropFirst(10).prefix(2))
        components.second = Int(digits.dropFirst(12).prefix(2))
        let zone: TimeZone?
        if value.hasSuffix("Z") {
            zone = TimeZone(identifier: "UTC")
        } else if let id = params["TZID"] {
            zone = TimeZone(identifier: id) ?? TimeZone(identifier: id.replacingOccurrences(of: "/Etc", with: ""))
        } else {
            zone = nil
        }
        calendar.timeZone = zone ?? fallback
        return calendar.date(from: components).map { ($0, false, zone) }
    }

    /// "PT1H30M", "P1D", "-PT15M".
    static func duration(_ value: String) -> TimeInterval? {
        var text = Substring(value.trimmingCharacters(in: .whitespaces).uppercased())
        var sign = 1.0
        if text.hasPrefix("-") { sign = -1; text = text.dropFirst() } else if text.hasPrefix("+") { text = text.dropFirst() }
        guard text.hasPrefix("P") else { return nil }
        text = text.dropFirst()
        var total = 0.0
        var number = ""
        for character in text {
            if character.isNumber { number.append(character); continue }
            let amount = Double(number) ?? 0
            number = ""
            switch character {
            case "W": total += amount * 7 * 86400
            case "D": total += amount * 86400
            case "H": total += amount * 3600
            case "M": total += amount * 60
            case "S": total += amount
            case "T": break
            default: return nil
            }
        }
        return sign * total
    }

    static let weekdays = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]

    static func rule(_ value: String, fallback: TimeZone) -> Rule? {
        var parts: [String: String] = [:]
        for part in value.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { parts[pair[0].uppercased()] = String(pair[1]).uppercased() }
        }
        guard let frequency = parts["FREQ"].flatMap(Rule.Frequency.init(rawValue:)) else { return nil }
        var rule = Rule(frequency: frequency)
        rule.interval = max(1, parts["INTERVAL"].flatMap { Int($0) } ?? 1)
        rule.count = parts["COUNT"].flatMap { Int($0) }
        rule.until = parts["UNTIL"].flatMap { date($0, params: [:], fallback: fallback)?.date }
        rule.byDay = (parts["BYDAY"] ?? "").split(separator: ",").compactMap { item in
            let code = String(item.suffix(2))
            guard let weekday = weekdays[code] else { return nil }
            return (weekday, Int(item.dropLast(2)) ?? 0)
        }
        rule.byMonthDay = (parts["BYMONTHDAY"] ?? "").split(separator: ",").compactMap { Int($0) }
        rule.byMonth = (parts["BYMONTH"] ?? "").split(separator: ",").compactMap { Int($0) }
        rule.bySetPos = (parts["BYSETPOS"] ?? "").split(separator: ",").compactMap { Int($0) }
        rule.weekStart = parts["WKST"].flatMap { weekdays[$0] } ?? 2
        return rule
    }

    /// The VEVENTs in `text`. Dates without a time zone are read in `timeZone`.
    public static func events(in text: String, timeZone: TimeZone = .current) -> [Event] {
        var events: [Event] = []
        var current: [Line]?
        var depth = 0
        for line in lines(text) {
            if line.name == "BEGIN" {
                if line.value.uppercased() == "VEVENT", current == nil {
                    current = []
                    depth = 0
                } else if current != nil {
                    depth += 1
                }
                continue
            }
            if line.name == "END" {
                if current != nil, depth > 0 { depth -= 1; continue }
                if line.value.uppercased() == "VEVENT", let lines = current {
                    if let event = event(from: lines, timeZone: timeZone) { events.append(event) }
                    current = nil
                }
                continue
            }
            if depth == 0 { current?.append(line) }
        }
        return events
    }

    static func event(from lines: [Line], timeZone: TimeZone) -> Event? {
        func first(_ name: String) -> Line? { lines.first { $0.name == name } }
        guard let uid = first("UID")?.value, let startLine = first("DTSTART"),
              let start = date(startLine.value, params: startLine.params, fallback: timeZone) else { return nil }
        let zone = start.zone ?? (start.allDay ? nil : timeZone)
        let fallback = zone ?? timeZone
        var end: Date
        if let line = first("DTEND"), let parsed = date(line.value, params: line.params, fallback: fallback) {
            end = parsed.date
        } else if let length = first("DURATION").flatMap({ duration($0.value) }) {
            end = start.date.addingTimeInterval(length)
        } else {
            end = start.allDay ? start.date.addingTimeInterval(86400) : start.date
        }
        if end < start.date { end = start.date }
        func dates(_ name: String) -> [Date] {
            lines.filter { $0.name == name }.flatMap { line in
                line.value.split(separator: ",").compactMap { date(String($0), params: line.params, fallback: fallback)?.date }
            }
        }
        var attendees: [String: String] = [:]
        for line in lines where line.name == "ATTENDEE" {
            attendees[address(line.value)] = (line.params["PARTSTAT"] ?? "NEEDS-ACTION").uppercased()
        }
        let recurrenceID = first("RECURRENCE-ID").flatMap { date($0.value, params: $0.params, fallback: fallback)?.date }
        return Event(
            uid: uid,
            summary: first("SUMMARY").map { unescape($0.value) } ?? "",
            description: first("DESCRIPTION").map { unescape($0.value) },
            location: first("LOCATION").map { unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 },
            url: first("URL").flatMap { URL(string: $0.value) },
            start: start.date, end: end, isAllDay: start.allDay, timeZone: zone,
            status: first("STATUS")?.value.uppercased(),
            transparent: first("TRANSP")?.value.uppercased() == "TRANSPARENT",
            rule: first("RRULE").flatMap { rule($0.value, fallback: fallback) },
            extraDates: dates("RDATE"), exceptions: dates("EXDATE"), recurrenceID: recurrenceID,
            attendees: attendees, organizer: first("ORGANIZER").map { address($0.value) },
            conference: first("X-GOOGLE-CONFERENCE").flatMap { URL(string: $0.value) })
    }

    static func address(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("mailto:") { text = String(text.dropFirst(7)) }
        return text.lowercased()
    }

    // MARK: - Recurrence

    /// The starts of `event`'s occurrences that begin before `end` and end after `start`:
    /// its own start, then the rule's and RDATE's, less EXDATE's.
    public static func occurrences(of event: Event, from start: Date, to end: Date, limit: Int = 5000) -> [Date] {
        let length = event.end.timeIntervalSince(event.start)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = event.timeZone ?? .current
        var starts: [Date] = [event.start]
        if let rule = event.rule {
            starts = expand(rule, from: event.start, before: end, calendar: calendar, limit: limit)
        }
        starts += event.extraDates
        let exceptions = Set(event.exceptions.map { $0.timeIntervalSince1970 })
        return Array(Set(starts)).filter {
            !exceptions.contains($0.timeIntervalSince1970) && $0 < end && $0.addingTimeInterval(max(length, 1)) > start
        }.sorted()
    }

    static func expand(_ rule: Rule, from first: Date, before windowEnd: Date, calendar: Calendar, limit: Int) -> [Date] {
        var calendar = calendar
        calendar.firstWeekday = rule.weekStart
        let time = calendar.dateComponents([.hour, .minute, .second], from: first)
        let firstDay = calendar.dateComponents([.year, .month, .day, .weekday], from: first)
        var found: [Date] = [first]
        var produced = 1
        var period = 0
        var periodsWithout = 0

        func at(_ day: DateComponents) -> Date? {
            var c = day
            c.hour = time.hour
            c.minute = time.minute
            c.second = time.second
            return calendar.date(from: c)
        }
        func done(_ date: Date) -> Bool {
            if let count = rule.count, produced >= count { return true }
            if let until = rule.until, date > until { return true }
            return date >= windowEnd
        }

        while period < limit {
            var candidates: [Date] = []
            switch rule.frequency {
            case .daily:
                guard let day = calendar.date(byAdding: .day, value: period * rule.interval, to: first) else { return found }
                let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
                if (rule.byDay.isEmpty || rule.byDay.contains { $0.weekday == c.weekday })
                    && (rule.byMonth.isEmpty || rule.byMonth.contains(c.month ?? 0))
                    && (rule.byMonthDay.isEmpty || rule.byMonthDay.contains(c.day ?? 0)) {
                    candidates = [day]
                }
            case .weekly:
                guard let weekDate = calendar.date(byAdding: .weekOfYear, value: period * rule.interval, to: first),
                      let week = calendar.dateInterval(of: .weekOfYear, for: weekDate) else { return found }
                let days = rule.byDay.isEmpty ? [firstDay.weekday ?? 2] : rule.byDay.map(\.weekday)
                for offset in 0..<7 {
                    guard let day = calendar.date(byAdding: .day, value: offset, to: week.start) else { continue }
                    let c = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
                    if days.contains(c.weekday ?? 0), rule.byMonth.isEmpty || rule.byMonth.contains(c.month ?? 0),
                       let date = at(c) {
                        candidates.append(date)
                    }
                }
            case .monthly:
                guard let monthDate = calendar.date(byAdding: .month, value: period * rule.interval,
                                                    to: calendar.date(from: DateComponents(year: firstDay.year, month: firstDay.month, day: 1))!)
                else { return found }
                let c = calendar.dateComponents([.year, .month], from: monthDate)
                if rule.byMonth.isEmpty || rule.byMonth.contains(c.month ?? 0) {
                    candidates = daysIn(month: c, rule: rule, defaultDay: firstDay.day ?? 1, calendar: calendar).compactMap(at)
                }
            case .yearly:
                let year = (firstDay.year ?? 2000) + period * rule.interval
                let months = rule.byMonth.isEmpty ? [firstDay.month ?? 1] : rule.byMonth
                for month in months {
                    let c = DateComponents(year: year, month: month)
                    candidates += daysIn(month: c, rule: rule, defaultDay: firstDay.day ?? 1, calendar: calendar).compactMap(at)
                }
            }
            candidates.sort()
            if !rule.bySetPos.isEmpty, rule.frequency != .daily {
                let all = candidates
                candidates = rule.bySetPos.compactMap { pos in
                    let index = pos > 0 ? pos - 1 : all.count + pos
                    return all.indices.contains(index) ? all[index] : nil
                }.sorted()
            }
            var any = false
            for date in candidates where date > first {
                if done(date) { return found }
                found.append(date)
                produced += 1
                any = true
            }
            // A rule that matches nothing (BYMONTHDAY=31 in a 30-day month, say) still ends.
            periodsWithout = any ? 0 : periodsWithout + 1
            if periodsWithout > 400 { return found }
            if let last = candidates.last, last >= windowEnd { return found }
            period += 1
        }
        return found
    }

    /// The days of `month` (year and month) a MONTHLY or YEARLY rule picks.
    static func daysIn(month: DateComponents, rule: Rule, defaultDay: Int, calendar: Calendar) -> [DateComponents] {
        guard let start = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: start) else { return [] }
        let count = range.count
        var days: [Int] = []
        if !rule.byMonthDay.isEmpty {
            days = rule.byMonthDay.map { $0 > 0 ? $0 : count + 1 + $0 }.filter { (1...count).contains($0) }
        }
        if !rule.byDay.isEmpty {
            var matching: [Int] = []
            for spec in rule.byDay {
                let all = (1...count).filter { day in
                    calendar.component(.weekday, from: calendar.date(byAdding: .day, value: day - 1, to: start)!) == spec.weekday
                }
                if spec.ordinal == 0 {
                    matching += all
                } else {
                    let index = spec.ordinal > 0 ? spec.ordinal - 1 : all.count + spec.ordinal
                    if all.indices.contains(index) { matching.append(all[index]) }
                }
            }
            days = rule.byMonthDay.isEmpty ? matching : days.filter(matching.contains)
        }
        if rule.byMonthDay.isEmpty && rule.byDay.isEmpty {
            days = defaultDay <= count ? [defaultDay] : []
        }
        return Array(Set(days)).sorted().map { DateComponents(year: month.year, month: month.month, day: $0) }
    }

    // MARK: - Events for a sync

    /// The occurrences of `events` between `start` and `end`, as a source calendar's events.
    /// `account` is the calendar owner's address, whose answer says whether a meeting is
    /// declined or unconfirmed.
    public static func sourceEvents(_ events: [Event], account: String?, from start: Date, to end: Date) -> [SourceEvent] {
        let account = account?.lowercased()
        let overrides = Dictionary(grouping: events.filter { $0.recurrenceID != nil }, by: \.uid)
        var result: [SourceEvent] = []
        for event in events where event.recurrenceID == nil {
            let changed = Dictionary((overrides[event.uid] ?? []).map { ($0.recurrenceID!.timeIntervalSince1970, $0) },
                                     uniquingKeysWith: { _, last in last })
            let recurring = event.rule != nil || !event.extraDates.isEmpty
            if !recurring {
                if event.start < end && max(event.end, event.start.addingTimeInterval(1)) > start {
                    result.append(sourceEvent(event, key: "gcal|" + event.uid, account: account))
                }
                continue
            }
            let length = event.end.timeIntervalSince(event.start)
            // Look back a day, so an occurrence moved into the window from just before it is found.
            for occurrence in occurrences(of: event, from: start.addingTimeInterval(-86400 * 7), to: end.addingTimeInterval(86400 * 7)) {
                let key = "gcal|\(event.uid)|\(occurrence.ISO8601Format())"
                var instance = changed[occurrence.timeIntervalSince1970] ?? event
                if changed[occurrence.timeIntervalSince1970] == nil {
                    instance.start = occurrence
                    instance.end = occurrence.addingTimeInterval(length)
                }
                guard instance.start < end, max(instance.end, instance.start.addingTimeInterval(1)) > start else { continue }
                result.append(sourceEvent(instance, key: key, account: account))
            }
            // An occurrence moved here from outside what the rule gives (or past its end).
            for (original, instance) in changed where !result.contains(where: { $0.key == "gcal|\(event.uid)|\(Date(timeIntervalSince1970: original).ISO8601Format())" }) {
                guard instance.start < end, max(instance.end, instance.start.addingTimeInterval(1)) > start,
                      !event.exceptions.contains(Date(timeIntervalSince1970: original)) else { continue }
                result.append(sourceEvent(instance, key: "gcal|\(event.uid)|\(Date(timeIntervalSince1970: original).ISO8601Format())",
                                          account: account))
            }
        }
        // Changed occurrences whose series isn't in the data (shared with only that one).
        let series = Set(events.filter { $0.recurrenceID == nil }.map(\.uid))
        for event in events where event.recurrenceID != nil && !series.contains(event.uid) {
            guard event.start < end, max(event.end, event.start.addingTimeInterval(1)) > start else { continue }
            result.append(sourceEvent(event, key: "gcal|\(event.uid)|\(event.recurrenceID!.ISO8601Format())", account: account))
        }
        return result.sorted { ($0.start, $0.key) < ($1.start, $1.key) }
    }

    static func sourceEvent(_ event: Event, key: String, account: String?) -> SourceEvent {
        let answer = account.flatMap { event.attendees[$0] }
        let isOrganizer = account != nil && event.organizer == account
        return SourceEvent(
            key: key,
            title: event.summary,
            start: event.start,
            end: event.end,
            isAllDay: event.isAllDay,
            timeZone: event.timeZone,
            isDeclined: !isOrganizer && answer == "DECLINED",
            isUnconfirmed: !isOrganizer && (answer == "NEEDS-ACTION" || answer == "TENTATIVE"),
            isCancelled: event.status == "CANCELLED" || SourceEvent.isCancelledTitle(event.summary),
            isOutOfOffice: false,
            meetingURL: event.conference ?? MeetingLink.find(url: event.url, location: event.location, notes: event.description),
            notes: event.description,
            location: event.location,
            inviteID: event.uid)
    }
}
