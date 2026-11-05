import XCTest
@testable import CalendarSyncCore

final class MarkdownTests: XCTestCase {
    /// The text of each span of `style` in `text`.
    func styled(_ style: MarkdownStyler.Style, in text: String) -> [String] {
        MarkdownStyler.spans(in: text).filter { $0.style == style }.map { (text as NSString).substring(with: $0.range) }
    }

    /// `text` after `edit`, with the selection after it marked: "|" for a cursor, "«…»" around
    /// a selection.
    func applied(_ edit: MarkdownEditing.Edit, to text: String) -> String {
        let changed = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        let selection = edit.selection
        if selection.length == 0 { return changed.replacingCharacters(in: selection, with: "|") }
        return changed.replacingCharacters(in: selection, with: "«" + changed.substring(with: selection) + "»")
    }

    /// `marked` without its selection marks ("|" or "«…»"), and the selection.
    func selecting(_ marked: String) -> (String, NSRange) {
        let string = marked as NSString
        let open = string.range(of: "«")
        if open.location != NSNotFound {
            let close = string.range(of: "»")
            let text = (string.replacingCharacters(in: close, with: "") as NSString).replacingCharacters(in: open, with: "")
            return (text, NSRange(location: open.location, length: close.location - open.upperBound))
        }
        let cursor = string.range(of: "|")
        return (string.replacingCharacters(in: cursor, with: ""), NSRange(location: cursor.location, length: 0))
    }

    // MARK: - Styling

    func testHeadings() {
        let text = "# Title\n### Small\n#Not a heading"
        XCTAssertEqual(styled(.heading(level: 1), in: text), ["# Title"])
        XCTAssertEqual(styled(.heading(level: 3), in: text), ["### Small"])
        XCTAssertTrue(styled(.syntax, in: text).contains("# "))
        XCTAssertFalse(MarkdownStyler.spans(in: text).contains { $0.style == .heading(level: 1) && $0.range.location > 10 })
    }

    func testInlineStyles() {
        let text = "Some **bold**, *italic*, _also_, ~~gone~~ and `code`."
        XCTAssertEqual(styled(.bold, in: text), ["**bold**"])
        XCTAssertEqual(styled(.italic, in: text), ["*italic*", "_also_"])
        XCTAssertEqual(styled(.strikethrough, in: text), ["~~gone~~"])
        XCTAssertEqual(styled(.code, in: text), ["`code`"])
        XCTAssertEqual(styled(.syntax, in: text).sorted(), ["*", "*", "**", "**", "_", "_", "`", "`", "~~", "~~"])
    }

    func testNothingInsideCodeIsStyled() {
        let text = "Run `make **all**` now"
        XCTAssertEqual(styled(.code, in: text), ["`make **all**`"])
        XCTAssertEqual(styled(.bold, in: text), [])
    }

    func testUnderscoresInsideWordsAreNotItalic() {
        XCTAssertEqual(styled(.italic, in: "snake_case_name and 2*3*4"), [])
    }

    func testLinks() {
        let text = "See [the doc](https://example.com/a_b) or https://example.com/x."
        XCTAssertEqual(styled(.link, in: text), ["the doc", "https://example.com/x."])
        XCTAssertTrue(styled(.syntax, in: text).contains("](https://example.com/a_b)"))
        XCTAssertEqual(styled(.italic, in: text), [], "underscores in a URL")
    }

    func testListsQuotesAndRules() {
        let text = "- one\n* two\n12. three\n> quoted\n---\n- [ ] open\n- [x] closed"
        XCTAssertEqual(styled(.listMarker, in: text), ["-", "*", "12.", "-", "-"])
        XCTAssertEqual(styled(.quote, in: text), ["> quoted"])
        XCTAssertEqual(styled(.rule, in: text), ["---"])
        XCTAssertEqual(styled(.checkbox(done: false), in: text), ["[ ]"])
        XCTAssertEqual(styled(.checkbox(done: true), in: text), ["[x]"])
        XCTAssertEqual(styled(.done, in: text), [" closed"])
    }

    func testFencedCode() {
        let text = "Before\n```\nlet **x** = 1\n```\nAfter **bold**"
        XCTAssertEqual(styled(.codeBlock, in: text), ["```\nlet **x** = 1\n```"])
        XCTAssertEqual(styled(.bold, in: text), ["**bold**"], "only outside the block")
        XCTAssertEqual(styled(.codeBlock, in: "```\nunclosed"), ["```\nunclosed"])
    }

    func testRangesCountUTF16() {
        let text = "😀 **ok**"
        XCTAssertEqual(styled(.bold, in: text), ["**ok**"])
    }

    func testPlainTextHasNoSpans() {
        XCTAssertEqual(MarkdownStyler.spans(in: "Just a note.\nAnother line."), [])
        XCTAssertEqual(MarkdownStyler.spans(in: ""), [])
    }

    // MARK: - Wrapping

    func wrap(_ wrap: MarkdownEditing.Wrap, _ marked: String) -> String {
        let (text, selection) = selecting(marked)
        return applied(MarkdownEditing.toggle(wrap, in: text, selection: selection), to: text)
    }

    func testWrapTheSelection() {
        XCTAssertEqual(wrap(.bold, "a «word» here"), "a **«word»** here")
        XCTAssertEqual(wrap(.italic, "a «word» here"), "a *«word»* here")
        XCTAssertEqual(wrap(.code, "a «word» here"), "a `«word»` here")
    }

    func testWrapWithoutASelectionPutsTheCursorBetween() {
        XCTAssertEqual(wrap(.bold, "a | here"), "a **|** here")
    }

    func testUnwrap() {
        XCTAssertEqual(wrap(.bold, "a **«word»** here"), "a «word» here")
        XCTAssertEqual(wrap(.bold, "a «**word**» here"), "a «word» here")
        XCTAssertEqual(wrap(.strikethrough, "~~«gone»~~"), "«gone»")
    }

    // MARK: - Line prefixes

    func prefix(_ prefix: MarkdownEditing.Prefix, _ marked: String) -> String {
        let (text, selection) = selecting(marked)
        return applied(MarkdownEditing.toggle(prefix, in: text, selection: selection), to: text)
    }

    func testPrefixTheCurrentLine() {
        XCTAssertEqual(prefix(.bullet, "Buy |milk"), "- Buy |milk")
        XCTAssertEqual(prefix(.heading(2), "Title|"), "## Title|")
        XCTAssertEqual(prefix(.checklist, "|"), "- [ ] |")
        XCTAssertEqual(prefix(.quote, "a\nsay |it\nb"), "a\n> say |it\nb")
    }

    func testPrefixReplacesAnotherOne() {
        XCTAssertEqual(prefix(.checklist, "- Buy |milk"), "- [ ] Buy |milk")
        XCTAssertEqual(prefix(.heading(1), "### Ti|tle"), "# Ti|tle")
    }

    func testPrefixComesOffWhenAllLinesHaveIt() {
        XCTAssertEqual(prefix(.bullet, "- Buy |milk"), "Buy |milk")
        XCTAssertEqual(prefix(.heading(2), "## |Title"), "|Title")
    }

    func testNumberedLinesCountUp() {
        XCTAssertEqual(prefix(.numbered, "«one\n\ntwo\nthree»"), "«1. one\n\n2. two\n3. three»")
    }

    func testPrefixKeepsTheIndent() {
        XCTAssertEqual(prefix(.bullet, "  nested|"), "  - nested|")
    }

    // MARK: - Links, checkboxes, Return

    func testLink() {
        let (text, selection) = selecting("see «the doc» now")
        XCTAssertEqual(applied(MarkdownEditing.link(in: text, selection: selection), to: text), "see [the doc](«https://») now")
        let (url, urlSelection) = selecting("go to «https://example.com»")
        XCTAssertEqual(applied(MarkdownEditing.link(in: url, selection: urlSelection), to: url), "go to [«link»](https://example.com)")
    }

    func testToggleCheckbox() {
        let text = "Prep:\n- [ ] Slides\n- [x] Notes"
        let open = (text as NSString).range(of: "[ ]").location
        XCTAssertEqual(MarkdownEditing.toggleCheckbox(in: text, at: open + 1).map {
            (text as NSString).replacingCharacters(in: $0.range, with: $0.replacement)
        }, "Prep:\n- [x] Slides\n- [x] Notes")
        let ticked = (text as NSString).range(of: "[x]").location
        XCTAssertEqual(MarkdownEditing.toggleCheckbox(in: text, at: ticked).map {
            (text as NSString).replacingCharacters(in: $0.range, with: $0.replacement)
        }, "Prep:\n- [ ] Slides\n- [ ] Notes")
        XCTAssertNil(MarkdownEditing.toggleCheckbox(in: text, at: open + 5), "on the text, not the box")
        XCTAssertNil(MarkdownEditing.toggleCheckbox(in: text, at: 2), "not a checklist line")
    }

    func newline(_ marked: String) -> String? {
        let (text, selection) = selecting(marked)
        return MarkdownEditing.newline(in: text, selection: selection).map { applied($0, to: text) }
    }

    func testReturnContinuesAList() {
        XCTAssertEqual(newline("- milk|"), "- milk\n- |")
        XCTAssertEqual(newline("  * eggs|"), "  * eggs\n  * |")
        XCTAssertEqual(newline("9) nine|"), "9) nine\n10) |")
        XCTAssertEqual(newline("- [x] done|"), "- [x] done\n- [ ] |")
        XCTAssertEqual(newline("> quote|"), "> quote\n> |")
    }

    func testReturnOnAnEmptyItemEndsTheList() {
        XCTAssertEqual(newline("- milk\n- |"), "- milk\n|")
        XCTAssertEqual(newline("- milk\n- [ ] |"), "- milk\n|")
    }

    func testReturnElsewhereIsPlain() {
        XCTAssertNil(newline("Just text|"))
        XCTAssertNil(newline("# Heading|"))
        XCTAssertNil(newline("-| milk"), "inside the marker")
    }
}
