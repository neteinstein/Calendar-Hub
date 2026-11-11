import Foundation

/// The debug log the user can turn on in Settings › About: the app's log lines, kept in memory
/// while logging is on, shown live in Settings › Logs and attached to feedback.
public struct DebugLog: Equatable, Sendable {
    public struct Entry: Equatable, Identifiable, Sendable {
        /// Counts up from the first line, so lines keep their identity once older ones are dropped.
        public let id: Int
        public let date: Date
        public let message: String
    }

    /// The most lines kept: the oldest go first.
    public let capacity: Int
    public private(set) var entries: [Entry] = []
    private var nextID = 0

    public init(capacity: Int = 2000) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ message: String, at date: Date = Date()) {
        entries.append(Entry(id: nextID, date: date, message: message))
        nextID += 1
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    public mutating func clear() {
        entries.removeAll()
    }

    /// One line per entry, with its local time to the millisecond.
    public func text(timeZone: TimeZone = .current) -> String {
        entries.map { Self.line($0, timeZone: timeZone) }.joined(separator: "\n")
    }

    public static func line(_ entry: Entry, timeZone: TimeZone = .current) -> String {
        "\(time(entry.date, timeZone: timeZone)) \(entry.message)"
    }

    public static func time(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    /// The text of a new GitHub issue carrying `log`. GitHub refuses links much over 8 KB, so a long log
    /// keeps its newest lines (the ones nearest the problem) and says the rest were left out.
    public static func feedbackBody(version: String, system: String, log: String, maxLogLength: Int = 3000) -> String {
        var log = log
        var cut = false
        if log.count > maxLogLength {
            log = String(log.suffix(maxLogLength))
            // Start on a whole line.
            if let newline = log.firstIndex(of: "\n") { log = String(log[log.index(after: newline)...]) }
            cut = true
        }
        var body = """
        **What happened?**


        **What did you expect?**


        ---
        Calendar Hub \(version), \(system)

        <details><summary>Debug log</summary>


        """
        if cut { body += "(Earlier lines left out. The whole log was copied to the clipboard: paste it here.)\n\n" }
        body += "```\n\(log.isEmpty ? "(empty)" : log)\n```\n\n</details>\n"
        return body
    }

    /// The page for a new issue on `repo`, with `body` filled in.
    public static func newIssueURL(repo: URL, body: String) -> URL {
        var components = URLComponents(url: repo.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        // `+` would be read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}
