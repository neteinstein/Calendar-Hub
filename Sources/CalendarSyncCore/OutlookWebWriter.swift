import Foundation

/// Builds the requests that write two way sync's Busy events to an Outlook on the web calendar,
/// and reads Outlook's answers. The requests go to the same service Outlook on the web saves
/// events through (`service.svc`), sent by `OutlookWebSource` with the sign-in of Outlook's own
/// requests, and use only the parts of a Busy event the app writes everywhere else: its
/// title, times, "Busy" description and free/busy status. No invitations go out, no reminder
/// is set, and deleted events go to Deleted Items, from where they can be restored.
///
/// EXPERIMENTAL: the format is Outlook's own, undocumented, and Microsoft can change it.
public enum OutlookWebWriter {
    /// One call to Outlook's service: the action and its JSON body.
    public struct Request: Hashable, Sendable {
        public var action: String
        public var body: String
    }

    /// The calls that carry out one change. An update is a delete and a create: a Busy event
    /// matches its main-calendar event by time only, so nothing else of it is worth keeping.
    ///
    /// - Parameter timeZone: this Mac's time zone, whose days all-day events are placed on.
    public static func requests(for action: SyncAction, timeZone: TimeZone = .current) -> [Request] {
        switch action {
        case .create(let spec):
            return [create(spec, timeZone: timeZone)]
        case .update(let eventID, let spec):
            return [delete(itemID: eventID), create(spec, timeZone: timeZone)]
        case .delete(let eventID, _, _):
            return [delete(itemID: eventID)]
        }
    }

    static func create(_ spec: CopySpec, timeZone: TimeZone) -> Request {
        let windowsZone = windowsZoneID(for: timeZone, near: spec.start)
        var item: [String: Any] = [
            "__type": "CalendarItem:#Exchange",
            "Subject": spec.title,
            "Body": ["__type": "BodyContentType:#Exchange", "BodyType": "Text", "Value": spec.notes],
            "IsAllDayEvent": spec.isAllDay,
            "LegacyFreeBusyStatus": spec.isOutOfOffice ? "OOF" : "Busy",
            "ReminderIsSet": false,
            "IsResponseRequested": false,
        ]
        if spec.isAllDay {
            let (start, end) = allDayDays(spec, timeZone: timeZone)
            item["Start"] = start
            item["End"] = end
        } else {
            item["Start"] = utc(spec.start)
            item["End"] = utc(max(spec.end, spec.start))
        }
        if let windowsZone {
            item["StartTimeZoneId"] = windowsZone
            item["EndTimeZoneId"] = windowsZone
        }
        let body: [String: Any] = [
            "__type": "CreateItemRequest:#Exchange",
            "Items": [item],
            "SendMeetingInvitations": "SendToNone",
        ]
        return Request(action: "CreateItem", body: json(request: "CreateItemJsonRequest", body: body, windowsZone: windowsZone))
    }

    static func delete(itemID: String) -> Request {
        let body: [String: Any] = [
            "__type": "DeleteItemRequest:#Exchange",
            "ItemIds": [["__type": "ItemId:#Exchange", "Id": itemID]],
            "DeleteType": "MoveToDeletedItems",
            "SendMeetingCancellations": "SendToNone",
        ]
        return Request(action: "DeleteItem", body: json(request: "DeleteItemJsonRequest", body: body, windowsZone: nil))
    }

    private static func json(request: String, body: [String: Any], windowsZone: String?) -> String {
        var header: [String: Any] = [
            "__type": "JsonRequestHeaders:#Exchange",
            "RequestServerVersion": "Exchange2013",
        ]
        if let windowsZone {
            header["TimeZoneContext"] = [
                "__type": "TimeZoneContext:#Exchange",
                "TimeZoneDefinition": ["__type": "TimeZoneDefinitionType:#Exchange", "Id": windowsZone],
            ]
        }
        let object: [String: Any] = ["__type": "\(request):#Exchange", "Header": header, "Body": body]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Answers

    /// What went wrong, from Outlook's answer to one request, or nil when it worked. No answer
    /// at all (signed out, network, Outlook refused the request) is a failure too.
    public static func problem(inResponse text: String?) -> String? {
        guard let text, let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return "Outlook didn't answer." }
        var results: [Obj] = []
        func walk(_ value: Any) {
            if let object = value as? [String: Any] {
                let obj = Obj(object)
                if obj.string("responseClass") != nil { results.append(obj) }
                object.values.forEach(walk)
            } else if let array = value as? [Any] {
                array.forEach(walk)
            }
        }
        walk(json)
        guard !results.isEmpty else { return "Outlook gave an answer this app doesn't recognise." }
        // The response as a whole says "Success" while an item in it can still have failed.
        guard let failed = results.first(where: { $0.string("responseClass")?.lowercased() != "success" }) else {
            return nil
        }
        return failed.string("messageText") ?? failed.string("responseCode") ?? "Outlook refused the change."
    }

    // MARK: - Dates

    private static func utc(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// An all-day event's first day and the day after its last, as midnights in `timeZone`
    /// written with their offset. An all-day event can end a second before midnight or at
    /// midnight itself, depending on who wrote it.
    static func allDayDays(_ spec: CopySpec, timeZone: TimeZone) -> (start: String, end: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let first = calendar.startOfDay(for: spec.start)
        let lastDay = calendar.startOfDay(for: max(spec.end.addingTimeInterval(-1), spec.start))
        let afterLast = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        return (f.string(from: first), f.string(from: max(afterLast, first)))
    }

    // MARK: - Time zones

    /// The Windows name Outlook knows `timeZone` by: from `OutlookWebParser.windowsZones`, or,
    /// for a zone that list doesn't name, the first one in it with the same offsets in summer
    /// and winter (e.g. "GMT Standard Time" for Europe/Lisbon). Nil when there is none.
    static func windowsZoneID(for timeZone: TimeZone, near date: Date) -> String? {
        if timeZone.identifier == "UTC" || timeZone.identifier == "GMT" { return "UTC" }
        let names = OutlookWebParser.windowsZones.keys.sorted()
        if let name = names.first(where: { OutlookWebParser.windowsZones[$0] == timeZone.identifier
                                            && $0 != "coordinated universal time" }) {
            return windowsCase(name)
        }
        let samples = [date, date.addingTimeInterval(182 * 86400)]
        func offsets(_ zone: TimeZone) -> [Int] { samples.map(zone.secondsFromGMT(for:)) }
        let wanted = offsets(timeZone)
        for name in names where name != "coordinated universal time" {
            if let zone = OutlookWebParser.windowsZones[name].flatMap(TimeZone.init(identifier:)),
               offsets(zone) == wanted {
                return windowsCase(name)
            }
        }
        return nil
    }

    /// `OutlookWebParser.windowsZones` keeps its names lowercased; Outlook spells them with
    /// capitals ("W. Europe Standard Time", "FLE Standard Time", "UTC+12").
    static func windowsCase(_ lowered: String) -> String {
        let acronyms: Set<String> = ["aus", "fle", "gmt", "gtb", "sa", "se", "us", "utc"]
        return lowered.split(separator: " ").map { word -> String in
            let word = String(word)
            if acronyms.contains(word) || word.hasPrefix("utc") { return word.uppercased() }
            guard let index = word.firstIndex(where: \.isLetter) else { return word }
            return word.replacingCharacters(in: index...index, with: word[index].uppercased())
        }.joined(separator: " ")
    }
}
