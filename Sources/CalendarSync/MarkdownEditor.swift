import AppKit
import CalendarSyncCore
import SwiftUI

/// A plain-text Markdown editor that styles the text as it's typed: headings, bold, italic,
/// code, links, lists, quotes and checklists, with the Markdown marks dimmed but kept, since
/// the text is saved as it is. Return continues a list and a click ticks a checklist box.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    /// For the formatting buttons, which change the text the way typing would.
    let proxy: MarkdownEditorProxy

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1: the checkbox clicks ask the layout manager where the glyphs are.
        let textView = MarkdownTextView(usingTextLayoutManager: false)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.font = MarkdownTheme.font
        textView.typingAttributes = MarkdownTheme.base
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        proxy.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        // A change from elsewhere: Reminders, or another device.
        guard let textView = scrollView.documentView as? MarkdownTextView, textView.string != text else { return }
        let selection = textView.selectedRange()
        textView.string = text
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }

        // Styled once the characters changed, before they're laid out. Notes are short, so
        // the whole text is styled again each time.
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            MarkdownTheme.style(textStorage)
        }
    }
}

/// Lets the formatting buttons reach the text view.
@MainActor
final class MarkdownEditorProxy {
    fileprivate weak var textView: MarkdownTextView?

    func toggle(_ wrap: MarkdownEditing.Wrap) {
        apply { MarkdownEditing.toggle(wrap, in: $0, selection: $1) }
    }

    func toggle(_ prefix: MarkdownEditing.Prefix) {
        apply { MarkdownEditing.toggle(prefix, in: $0, selection: $1) }
    }

    func link() {
        apply { MarkdownEditing.link(in: $0, selection: $1) }
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    private func apply(_ edit: (String, NSRange) -> MarkdownEditing.Edit) {
        guard let textView else { return }
        textView.apply(edit(textView.string, textView.selectedRange()))
        focus()
    }
}

/// The text view: Return continues lists, and a click on a checklist box ticks it.
final class MarkdownTextView: NSTextView {
    /// Makes `edit` the way typing would, so it can be undone.
    func apply(_ edit: MarkdownEditing.Edit) {
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        textStorage?.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
    }

    override func insertNewline(_ sender: Any?) {
        if !hasMarkedText(), let edit = MarkdownEditing.newline(in: string, selection: selectedRange()) {
            apply(edit)
        } else {
            super.insertNewline(sender)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let index = characterIndex(under: event), let edit = MarkdownEditing.toggleCheckbox(in: string, at: index) {
            apply(edit)
        } else {
            super.mouseDown(with: event)
        }
    }

    /// The character drawn under the pointer, if there's one right there.
    private func characterIndex(under event: NSEvent) -> Int? {
        guard let layoutManager, let textContainer, !string.isEmpty else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
        let bounds = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard bounds.contains(inContainer) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }
}

/// How the notes window draws Markdown.
enum MarkdownTheme {
    static let size: CGFloat = 13.5
    static let font = NSFont.systemFont(ofSize: size)
    static let mono = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)

    static let base: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 3
        return [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }()

    /// Styles all of `storage` from its Markdown.
    static func style(_ storage: NSTextStorage) {
        let all = NSRange(location: 0, length: storage.length)
        storage.setAttributes(base, range: all)
        let spans = MarkdownStyler.spans(in: storage.string)
        // Fonts first, then the traits that go on top of them, then colors, then the marks.
        for span in spans.sorted(by: { order($0.style) < order($1.style) }) {
            apply(span.style, to: span.range, in: storage)
        }
    }

    private static func order(_ style: MarkdownStyler.Style) -> Int {
        switch style {
        case .heading, .codeBlock, .code, .checkbox: 0
        case .bold, .italic: 1
        case .syntax: 3
        default: 2
        }
    }

    private static func apply(_ style: MarkdownStyler.Style, to range: NSRange, in storage: NSTextStorage) {
        switch style {
        case .heading(let level):
            let sizes: [CGFloat] = [21, 17.5, 15]
            let size = level <= sizes.count ? sizes[level - 1] : self.size
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .bold), range: range)
        case .bold:
            addTrait(.boldFontMask, to: range, in: storage)
        case .italic:
            addTrait(.italicFontMask, to: range, in: storage)
        case .strikethrough:
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                   .foregroundColor: NSColor.secondaryLabelColor], range: range)
        case .code, .codeBlock:
            storage.addAttributes([.font: mono, .backgroundColor: NSColor.labelColor.withAlphaComponent(0.07)], range: range)
        case .link:
            storage.addAttributes([.foregroundColor: NSColor.linkColor,
                                   .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        case .quote:
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            addTrait(.italicFontMask, to: range, in: storage)
        case .listMarker:
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
        case .checkbox:
            storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: size, weight: .bold),
                                   .foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand], range: range)
        case .done:
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                   .foregroundColor: NSColor.tertiaryLabelColor], range: range)
        case .rule, .syntax:
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        }
    }

    /// Adds a trait to the fonts already in `range`, so bold stays bold inside a heading.
    private static func addTrait(_ trait: NSFontTraitMask, to range: NSRange, in storage: NSTextStorage) {
        storage.enumerateAttribute(.font, in: range) { value, part, _ in
            guard let font = value as? NSFont else { return }
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: part)
        }
    }
}
