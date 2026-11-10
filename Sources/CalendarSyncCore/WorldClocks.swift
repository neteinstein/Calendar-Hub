import Foundation

/// A city whose time the menu's World Clocks view shows.
public struct WorldClock: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// The name shown, which the user can change: "San Francisco" for America/Los_Angeles.
    public var name: String
    public var timeZoneID: String

    public init(id: UUID = UUID(), name: String, timeZoneID: String) {
        self.id = id
        self.name = name
        self.timeZoneID = timeZoneID
    }

    /// Its time zone, or UTC if the identifier is no longer known.
    public var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? TimeZone(identifier: "UTC")! }
}

/// The menu's World Clocks view and the cities it shows.
public struct WorldClockOptions: Codable, Hashable, Sendable {
    /// The menu gets a World Clocks view, before Stats.
    public var showsInMenu: Bool
    public var clocks: [WorldClock]

    public init(showsInMenu: Bool = false, clocks: [WorldClock] = []) {
        self.showsInMenu = showsInMenu
        self.clocks = clocks
    }

    // Settings saved by older versions don't have every key yet.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showsInMenu = try c.decodeIfPresent(Bool.self, forKey: .showsInMenu) ?? false
        clocks = try c.decodeIfPresent([WorldClock].self, forKey: .clocks) ?? []
    }
}

/// Times around the world against the working day. Pure logic, unit tested.
public enum WorldClocks {
    /// Where a time falls in a city's day.
    public enum Period: String, CaseIterable, Sendable {
        /// Within the working hours, Monday to Friday.
        case working
        /// Awake, but outside the working hours or on a weekend.
        case free
        /// From 22:00 to 7:00, outside the working hours.
        case night
    }

    /// Night runs from this minute of the day…
    static let nightStart = 22 * 60
    /// …to this one.
    static let nightEnd = 7 * 60

    /// `calendar` set to `timeZone`.
    static func calendar(_ calendar: Calendar, in timeZone: TimeZone) -> Calendar {
        var calendar = calendar
        calendar.timeZone = timeZone
        return calendar
    }

    /// Minutes after midnight at `date` in `timeZone`.
    public static func minuteOfDay(_ date: Date, in timeZone: TimeZone, calendar: Calendar = Calendar(identifier: .gregorian)) -> Int {
        let parts = Self.calendar(calendar, in: timeZone).dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Whether `date` is on a Saturday or Sunday in `timeZone`.
    public static func isWeekend(_ date: Date, in timeZone: TimeZone, calendar: Calendar = Calendar(identifier: .gregorian)) -> Bool {
        let weekday = Self.calendar(calendar, in: timeZone).component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    /// Where `date` falls in the day of `timeZone`, against `workingHours` (the same in every city).
    public static func period(at date: Date, in timeZone: TimeZone, workingHours: WorkingHours,
                              calendar: Calendar = Calendar(identifier: .gregorian)) -> Period {
        let minute = minuteOfDay(date, in: timeZone, calendar: calendar)
        if !isWeekend(date, in: timeZone, calendar: calendar),
           workingHours.end > workingHours.start,
           minute >= workingHours.start, minute < workingHours.end {
            return .working
        }
        return minute >= nightStart || minute < nightEnd ? .night : .free
    }

    /// A stretch of the local day, in minutes after its midnight, in one period.
    public struct Segment: Hashable, Sendable {
        public var start: Int
        public var end: Int
        public var period: Period

        public init(start: Int, end: Int, period: Period) {
            self.start = start
            self.end = end
            self.period = period
        }

        public var minutes: Int { end - start }
    }

    /// Every time zone's offset is a multiple of 15 minutes, so the day is read in steps of that.
    static let step = 15

    /// The local day of `day` (in `calendar`'s time zone), cut where `timeZone`'s period changes.
    /// Minutes count from the local midnight, 0 to 1440 (more or less on a day the clocks change).
    public static func segments(on day: Date, for timeZone: TimeZone, workingHours: WorkingHours,
                                calendar: Calendar) -> [Segment] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        let length = Int(interval.duration / 60)
        var segments: [Segment] = []
        for minute in stride(from: 0, to: length, by: step) {
            let period = period(at: interval.start.addingTimeInterval(Double(minute) * 60), in: timeZone,
                                workingHours: workingHours, calendar: calendar)
            let end = min(minute + step, length)
            if let last = segments.last, last.period == period {
                segments[segments.count - 1].end = end
            } else {
                segments.append(Segment(start: minute, end: end, period: period))
            }
        }
        return segments
    }

    /// The stretches of the local day of `day` when it's working time in every one of
    /// `timeZones`, in minutes after the local midnight.
    public static func overlap(on day: Date, of timeZones: [TimeZone], workingHours: WorkingHours,
                               calendar: Calendar) -> [Range<Int>] {
        guard !timeZones.isEmpty, let interval = calendar.dateInterval(of: .day, for: day) else { return [] }
        let length = Int(interval.duration / 60)
        var ranges: [Range<Int>] = []
        for minute in stride(from: 0, to: length, by: step) {
            let date = interval.start.addingTimeInterval(Double(minute) * 60)
            guard timeZones.allSatisfy({ period(at: date, in: $0, workingHours: workingHours, calendar: calendar) == .working })
            else { continue }
            let end = min(minute + step, length)
            if let last = ranges.last, last.upperBound == minute {
                ranges[ranges.count - 1] = last.lowerBound..<end
            } else {
                ranges.append(minute..<end)
            }
        }
        return ranges
    }

    /// "Same time", "+5h", "−3h30": how far `timeZone` is ahead of `local` at `date`.
    public static func offsetText(_ timeZone: TimeZone, from local: TimeZone, at date: Date) -> String {
        let minutes = (timeZone.secondsFromGMT(for: date) - local.secondsFromGMT(for: date)) / 60
        guard minutes != 0 else { return "Same time" }
        let sign = minutes > 0 ? "+" : "−"
        let hours = abs(minutes) / 60, rest = abs(minutes) % 60
        return rest == 0 ? "\(sign)\(hours)h" : "\(sign)\(hours)h\(String(format: "%02d", rest))"
    }

    /// "Tomorrow" or "Yesterday" when `date` in `timeZone` is on another day than in `local`.
    public static func dayText(_ timeZone: TimeZone, from local: TimeZone, at date: Date,
                               calendar: Calendar = Calendar(identifier: .gregorian)) -> String? {
        let there = Self.calendar(calendar, in: timeZone).dateComponents([.year, .month, .day], from: date)
        let here = Self.calendar(calendar, in: local).dateComponents([.year, .month, .day], from: date)
        let utc = TimeZone(identifier: "UTC")!
        guard there != here, let thereDay = Self.calendar(calendar, in: utc).date(from: there),
              let hereDay = Self.calendar(calendar, in: utc).date(from: here) else { return nil }
        return thereDay > hereDay ? "Tomorrow" : "Yesterday"
    }

    /// "1h", "2h30", "45m".
    public static func durationText(minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest)m"
        case (_, 0): return "\(hours)h"
        default: return "\(hours)h\(String(format: "%02d", rest))"
        }
    }

    // MARK: - Cities

    /// A city to pick, from a time zone's identifier: Europe/Lisbon is Lisbon, in Europe.
    public struct Place: Hashable, Sendable {
        public var city: String
        public var region: String
        public var timeZoneID: String
    }

    /// The city a time zone's identifier names: "New York" for America/New_York.
    public static func cityName(of timeZoneID: String) -> String {
        (timeZoneID.split(separator: "/").last.map(String.init) ?? timeZoneID).replacingOccurrences(of: "_", with: " ")
    }

    /// Every city with a time zone of its own.
    public static let places: [Place] = TimeZone.knownTimeZoneIdentifiers
        .filter { $0.contains("/") && !$0.hasPrefix("Etc/") && !$0.hasPrefix("SystemV/") }
        .map { id in
            Place(city: cityName(of: id),
                  region: String(id.split(separator: "/").first ?? "").replacingOccurrences(of: "_", with: " "),
                  timeZoneID: id)
        }
        .sorted { $0.city < $1.city }

    /// The places that match `query`: by city or region, or every city of a time zone
    /// abbreviation such as PST. Cities starting with it come first.
    public static func search(_ query: String, limit: Int = 8) -> [Place] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        func matches(_ text: String, prefix: Bool) -> Bool {
            let options: String.CompareOptions = prefix ? [.caseInsensitive, .diacriticInsensitive, .anchored]
                : [.caseInsensitive, .diacriticInsensitive]
            return text.range(of: query, options: options) != nil
        }
        let abbreviated = TimeZone.abbreviationDictionary.first { $0.key.caseInsensitiveCompare(query) == .orderedSame }?.value
        let starting = places.filter { matches($0.city, prefix: true) }
        let containing = places.filter { !matches($0.city, prefix: true) && (matches($0.city, prefix: false) || matches($0.region, prefix: true)) }
        let byAbbreviation = places.filter { $0.timeZoneID == abbreviated }
        var seen = Set<String>()
        return (byAbbreviation + starting + containing).filter { seen.insert($0.timeZoneID).inserted }.prefix(limit).map { $0 }
    }
}
