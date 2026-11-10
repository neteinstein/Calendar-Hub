import Foundation

/// Markdown as a task's notes window shows it: which parts of the text are headings, bold,
/// lists and so on, so they can be styled as they're typed while the Markdown stays in the
/// text. Ranges are `NSString` ranges, as text views use them. Pure logic, unit tested.
public enum MarkdownStyler {
    public enum Style: Hashable, Sendable {
        case heading(level: Int)
        case bold, italic, strikethrough
        /// Inline code, backticks included.
        case code
        /// A fenced code block, fences included.
        case codeBlock
        /// A link's text, or a bare URL.
        case link
        /// A quoted line, ">" included.
        case quote
        /// A list item's "-", "*", "+" or "1.".
        case listMarker
        /// A checklist item's "[ ]" or "[x]".
        case checkbox(done: Bool)
        /// The text of a ticked checklist item.
        case done
        /// A line that is only "---", "***" or "___".
        case rule
        /// The Markdown marks themselves: "**", "# ", "`", a link's "(url)".
        case syntax
    }

    public struct Span: Hashable, Sendable {
        public var range: NSRange
        public var style: Style

        public init(_ range: NSRange, _ style: Style) {
            self.range = range
            self.style = style
        }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are fixed, so a failure is a typo caught by the tests.
        try! NSRegularExpression(pattern: pattern)
    }

    private static let heading = regex(#"^(#{1,6}[ \t]+)(.*)$"#)
    private static let rule = regex(#"^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let quote = regex(#"^[ \t]*>[ \t]?"#)
    private static let checkbox = regex(#"^[ \t]*([-*+])[ \t]+(\[[ xX]\])(?=[ \t]|$)"#)
    private static let listItem = regex(#"^[ \t]*([-*+]|\d{1,9}[.)])[ \t]+"#)
    private static let code = regex(#"(`+)([^`\n]+?)\1"#)
    private static let link = regex(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    private static let bareURL = regex(#"(?<![(\[<\w])https?://[^\s)\]>]+"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = regex(#"(?<![*_\w])([*_])(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![*_\w])"#)
    private static let strikethrough = regex(#"(~~)(?=\S)(.+?)(?<=\S)~~"#)

    /// The styled parts of `text`, line by line: blocks first, then what's inside a line.
    /// Nothing inside code is styled further.
    public static func spans(in text: String) -> [Span] {
        let string = text as NSString
        var spans: [Span] = []
        var fenceStart: Int?
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            let content = string.substring(with: line)
            if content.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                spans.append(Span(line, .syntax))
                if let start = fenceStart {
                    spans.append(Span(NSRange(location: start, length: line.upperBound - start), .codeBlock))
                    fenceStart = nil
                } else {
                    fenceStart = line.location
                }
                return
            }
            guard fenceStart == nil else { return }
            spans += blockSpans(in: content, at: line.location)
            spans += inlineSpans(in: content, at: line.location)
        }
        if let start = fenceStart {
            spans.append(Span(NSRange(location: start, length: string.length - start), .codeBlock))
        }
        return spans
    }

    private static func firstMatch(_ regex: NSRegularExpression, in line: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
    }

    private static func blockSpans(in line: String, at offset: Int) -> [Span] {
        func shifted(_ range: NSRange) -> NSRange { NSRange(location: range.location + offset, length: range.length) }
        let whole = NSRange(location: offset, length: (line as NSString).length)
        if let match = firstMatch(heading, in: line) {
            let level = (line as NSString).substring(with: match.range(at: 1)).filter { $0 == "#" }.count
            return [Span(whole, .heading(level: level)), Span(shifted(match.range(at: 1)), .syntax)]
        }
        if firstMatch(rule, in: line) != nil {
            return [Span(whole, .rule)]
        }
        if let match = firstMatch(quote, in: line) {
            return [Span(whole, .quote), Span(shifted(match.range), .syntax)]
        }
        if let match = firstMatch(checkbox, in: line) {
            let box = match.range(at: 2)
            let done = (line as NSString).substring(with: box).lowercased() == "[x]"
            var spans = [Span(shifted(match.range(at: 1)), .listMarker), Span(shifted(box), .checkbox(done: done))]
            if done, whole.upperBound > box.upperBound + offset {
                spans.append(Span(NSRange(location: box.upperBound + offset, length: whole.upperBound - box.upperBound - offset), .done))
            }
            return spans
        }
        if let match = firstMatch(listItem, in: line) {
            return [Span(shifted(match.range(at: 1)), .listMarker)]
        }
        return []
    }

    private static func inlineSpans(in line: String, at offset: Int) -> [Span] {
        let all = NSRange(location: 0, length: (line as NSString).length)
        func shifted(_ range: NSRange) -> NSRange { NSRange(location: range.location + offset, length: range.length) }
        var spans: [Span] = []
        // Code first: nothing inside it is styled, and nothing else may overlap it.
        var taken: [NSRange] = []
        func isFree(_ range: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, range).length > 0 } }

        for match in code.matches(in: line, range: all) {
            let ticks = match.range(at: 1).length
            spans.append(Span(shifted(match.range), .code))
            spans.append(Span(shifted(NSRange(location: match.range.location, length: ticks)), .syntax))
            spans.append(Span(shifted(NSRange(location: match.range.upperBound - ticks, length: ticks)), .syntax))
            taken.append(match.range)
        }
        var links: [NSRange] = []
        for match in link.matches(in: line, range: all) where isFree(match.range) {
            let text = match.range(at: 1)
            spans.append(Span(shifted(text), .link))
            spans.append(Span(shifted(NSRange(location: match.range.location, length: 1)), .syntax))
            spans.append(Span(shifted(NSRange(location: text.upperBound, length: match.range.upperBound - text.upperBound)), .syntax))
            links.append(match.range)
        }
        for match in bareURL.matches(in: line, range: all)
        where isFree(match.range) && !links.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
            spans.append(Span(shifted(match.range), .link))
            taken.append(match.range)
        }
        taken += links
        for (regex, style) in [(bold, Style.bold), (strikethrough, .strikethrough), (italic, .italic)] {
            for match in regex.matches(in: line, range: all) where isFree(match.range) {
                let marks = match.range(at: 1).length
                spans.append(Span(shifted(match.range), style))
                spans.append(Span(shifted(NSRange(location: match.range.location, length: marks)), .syntax))
                spans.append(Span(shifted(NSRange(location: match.range.upperBound - marks, length: marks)), .syntax))
            }
        }
        return spans
    }
}

/// The changes the notes window's formatting buttons and keys make to Markdown. Each returns
/// the range to replace, what replaces it and the selection after, so the text view can make
/// the change as one undoable edit. Ranges are `NSString` ranges. Pure logic, unit tested.
public enum MarkdownEditing {
    public struct Edit: Hashable, Sendable {
        public var range: NSRange
        public var replacement: String
        /// The selection after the edit, in the changed text.
        public var selection: NSRange

        public init(range: NSRange, replacement: String, selection: NSRange) {
            self.range = range
            self.replacement = replacement
            self.selection = selection
        }
    }

    /// Marks that go around the selection.
    public enum Wrap: String, Sendable {
        case bold = "**", italic = "*", strikethrough = "~~", code = "`"
    }

    /// Wraps the selection in `wrap`'s marks, or takes them off when it has them already,
    /// inside or just outside it. Without a selection, puts the cursor between new marks.
    public static func toggle(_ wrap: Wrap, in text: String, selection: NSRange) -> Edit {
        let string = text as NSString
        let mark = wrap.rawValue
        let length = (mark as NSString).length
        let selected = string.substring(with: selection)
        let before = NSRange(location: selection.location - length, length: length)
        let after = NSRange(location: selection.upperBound, length: length)
        if before.location >= 0, after.upperBound <= string.length,
           string.substring(with: before) == mark, string.substring(with: after) == mark {
            let range = NSRange(location: before.location, length: after.upperBound - before.location)
            return Edit(range: range, replacement: selected, selection: NSRange(location: range.location, length: selection.length))
        }
        if selection.length >= 2 * length, selected.hasPrefix(mark), selected.hasSuffix(mark) {
            let inner = string.substring(with: NSRange(location: selection.location + length, length: selection.length - 2 * length))
            return Edit(range: selection, replacement: inner,
                        selection: NSRange(location: selection.location, length: (inner as NSString).length))
        }
        return Edit(range: selection, replacement: mark + selected + mark,
                    selection: NSRange(location: selection.location + length, length: selection.length))
    }

    /// What a line can start with.
    public enum Prefix: Hashable, Sendable {
        case heading(Int)
        case bullet, numbered, checklist, quote
    }

    private static let linePrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*)(#{1,6}[ \t]+|>[ \t]?|[-*+][ \t]+\[[ xX]\][ \t]+|[-*+][ \t]+|\d{1,9}[.)][ \t]+)?"#)

    /// The indent and the prefix a line starts with, and which kind of prefix it is.
    private static func prefix(of line: String) -> (indent: String, prefix: String, kind: Prefix?) {
        let string = line as NSString
        guard let match = linePrefix.firstMatch(in: line, range: NSRange(location: 0, length: string.length)) else {
            return ("", "", nil)
        }
        let indent = string.substring(with: match.range(at: 1))
        guard match.range(at: 2).location != NSNotFound else { return (indent, "", nil) }
        let prefix = string.substring(with: match.range(at: 2))
        let kind: Prefix
        if prefix.hasPrefix("#") {
            kind = .heading(prefix.filter { $0 == "#" }.count)
        } else if prefix.hasPrefix(">") {
            kind = .quote
        } else if prefix.contains("[") {
            kind = .checklist
        } else if prefix.first?.isNumber == true {
            kind = .numbered
        } else {
            kind = .bullet
        }
        return (indent, prefix, kind)
    }

    private static func marks(of prefix: Prefix, number: Int) -> String {
        switch prefix {
        case .heading(let level): String(repeating: "#", count: max(1, min(level, 6))) + " "
        case .bullet: "- "
        case .numbered: "\(number). "
        case .checklist: "- [ ] "
        case .quote: "> "
        }
    }

    /// Starts the lines the selection touches with `prefix`, in place of any other they had,
    /// or takes it off when they all have it already. Blank lines are left alone, unless the
    /// selection is just one. Numbered lines count up from 1.
    public static func toggle(_ prefix: Prefix, in text: String, selection: NSRange) -> Edit {
        let string = text as NSString
        let block = string.lineRange(for: selection)
        var lines = string.substring(with: block).components(separatedBy: "\n")
        // A block that ends in a newline gives an empty last part that isn't a line.
        let endsInNewline = lines.count > 1 && lines.last == ""
        if endsInNewline { lines.removeLast() }
        let parsed = lines.map { self.prefix(of: $0) }
        let counted = lines.count == 1 ? [0] : lines.indices.filter { !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        let removing = !counted.isEmpty && counted.allSatisfy { parsed[$0].kind == prefix }

        var number = 0
        var firstLineShift = 0
        var changed: [String] = []
        for (index, line) in lines.enumerated() {
            let (indent, old, _) = parsed[index]
            guard counted.contains(index) else {
                changed.append(line)
                continue
            }
            let rest = String(line.dropFirst(indent.count + old.count))
            number += 1
            let new = removing ? "" : marks(of: prefix, number: number)
            if index == 0 { firstLineShift = (new as NSString).length - (old as NSString).length }
            changed.append(indent + new + rest)
        }
        let replacement = changed.joined(separator: "\n") + (endsInNewline ? "\n" : "")
        let selectionAfter: NSRange
        if selection.length == 0 {
            let lineStart = block.location + (parsed[0].indent as NSString).length
            let location = max(lineStart, selection.location + firstLineShift)
            selectionAfter = NSRange(location: location, length: 0)
        } else {
            let length = (replacement as NSString).length - (endsInNewline ? 1 : 0)
            selectionAfter = NSRange(location: block.location, length: length)
        }
        return Edit(range: block, replacement: replacement, selection: selectionAfter)
    }

    /// Makes the selection a link: its text with the URL to fill in selected, or for a
    /// selected URL, the URL with the text to fill in selected.
    public static func link(in text: String, selection: NSRange) -> Edit {
        let selected = (text as NSString).substring(with: selection)
        if selected.hasPrefix("http://") || selected.hasPrefix("https://") {
            return Edit(range: selection, replacement: "[link](\(selected))",
                        selection: NSRange(location: selection.location + 1, length: 4))
        }
        let label = selected.isEmpty ? "link" : selected
        let labelLength = (label as NSString).length
        return Edit(range: selection, replacement: "[\(label)](https://)",
                    selection: NSRange(location: selection.location + labelLength + 3, length: 8))
    }

    /// Ticks or unticks the checklist box at `location`, if there's one there.
    public static func toggleCheckbox(in text: String, at location: Int) -> Edit? {
        let string = text as NSString
        guard location >= 0, location <= string.length else { return nil }
        let line = string.lineRange(for: NSRange(location: min(location, max(string.length - 1, 0)), length: 0))
        let content = string.substring(with: line)
        let (indent, prefix, kind) = self.prefix(of: content)
        guard kind == .checklist, let open = prefix.firstIndex(of: "[") else { return nil }
        // The indent and the prefix are ASCII, so characters and UTF-16 units count alike.
        let boxStart = line.location + indent.count + prefix.distance(from: prefix.startIndex, to: open)
        guard (boxStart..<boxStart + 3).contains(location) else { return nil }
        let inside = NSRange(location: boxStart + 1, length: 1)
        let ticked = string.substring(with: inside).lowercased() == "x"
        return Edit(range: inside, replacement: ticked ? " " : "x", selection: NSRange(location: boxStart + 3, length: 0))
    }

    /// Return at the end of a list item, quote or checklist item starts the next one; on an
    /// empty one, ends the list. Nil where Return should just break the line.
    public static func newline(in text: String, selection: NSRange) -> Edit? {
        guard selection.length == 0 else { return nil }
        let string = text as NSString
        let line = string.lineRange(for: selection)
        var content = string.substring(with: line)
        if content.hasSuffix("\n") { content.removeLast() }
        let (indent, prefix, kind) = self.prefix(of: content)
        guard let kind, !prefix.isEmpty else { return nil }
        if case .heading = kind { return nil }
        let prefixEnd = line.location + (indent as NSString).length + (prefix as NSString).length
        guard selection.location >= prefixEnd else { return nil }
        let rest = String(content.dropFirst(indent.count + prefix.count))
        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            // An empty item ends the list.
            let range = NSRange(location: line.location, length: prefixEnd - line.location)
            return Edit(range: range, replacement: "", selection: NSRange(location: line.location, length: 0))
        }
        var next: String
        switch kind {
        case .numbered:
            let digits = prefix.prefix { $0.isNumber }
            let delimiter = prefix.dropFirst(digits.count).first ?? "."
            next = "\((Int(digits) ?? 0) + 1)\(delimiter) "
        case .checklist:
            next = "\(prefix.first ?? "-") [ ] "
        case .bullet:
            next = "\(prefix.first ?? "-") "
        default:
            next = "> "
        }
        next = "\n" + indent + next
        return Edit(range: selection, replacement: next,
                    selection: NSRange(location: selection.location + (next as NSString).length, length: 0))
    }
}
