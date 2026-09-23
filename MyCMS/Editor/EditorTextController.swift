import AppKit
import Observation

/// The bridge between the toolbar and the text view: what the caret is inside, and every formatting
/// command.
///
/// Holds the text view weakly and does nothing when nothing is attached, so a command from a stale
/// toolbar is a no op rather than a crash. Every edit goes through the text view's own undo, so ⌘Z
/// behaves as it would for typing.
@Observable final class EditorTextController {

    // AC-7. The page title is already the h1, so the body starts at ## exactly as Notes 5.1 says.
    enum BlockStyle: String, CaseIterable, Identifiable {
        case normal
        case heading
        case subheading

        var id: String { rawValue }

        var label: String {
            switch self {
            case .normal: "Normal"
            case .heading: "Heading"
            case .subheading: "Subheading"
            }
        }

        var hashes: String {
            switch self {
            case .normal: ""
            case .heading: "##"
            case .subheading: "###"
            }
        }
    }

    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var blockStyle: BlockStyle = .normal

    @ObservationIgnored private weak var textView: NSTextView?

    func attach(_ textView: NSTextView) {
        self.textView = textView
        refresh()
    }

    func refresh() {
        guard let textView else { return }
        canUndo = textView.undoManager?.canUndo ?? false
        canRedo = textView.undoManager?.canRedo ?? false
        blockStyle = Self.blockStyle(at: textView.selectedRange().location, in: textView.string)
    }

    // MARK: Inline controls

    func toggleBold() { wrap("**", placeholder: "bold") }
    func toggleItalic() { wrap("*", placeholder: "italic") }
    func toggleStrikethrough() { wrap("~~", placeholder: "struck") }
    func toggleInlineCode() { wrap("`", placeholder: "code") }

    func insertLink() {
        guard let textView else { return }
        let selection = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: selection)
        let label = selection.length > 0 ? selected : "text"

        // The URL is the part you always have to fill in, so that is what ends up selected.
        let urlStart = selection.location + (label as NSString).length + 3
        replace(
            selection, with: "[\(label)](url)",
            select: NSRange(location: urlStart, length: 3))
    }

    // AC-9. The Image control opens a picker; the editor copies the file and asks for alt text.
    @ObservationIgnored var onPickImage: (() -> Void)?

    func insertImage() {
        onPickImage?()
    }

    var selection: NSRange {
        textView?.selectedRange() ?? NSRange(location: 0, length: 0)
    }

    // An image reference always gets a line of its own, so the site lays it out as a block.
    func insertImageBlock(_ markdown: String, at range: NSRange) {
        guard let textView else { return }
        let length = (textView.string as NSString).length
        let location = min(max(range.location, 0), length)
        textView.setSelectedRange(NSRange(location: location, length: min(range.length, length - location)))
        insertBlock(markdown + "\n", caretOffset: (markdown as NSString).length + 1)
    }

    // MARK: Block controls

    func setBlockStyle(_ style: BlockStyle) {
        rewriteLines { row in
            let stripped = Self.strip(Self.headingPattern, from: row)
            return style.hashes.isEmpty ? stripped : "\(style.hashes) \(stripped)"
        }
        refresh()
    }

    func toggleQuote() {
        toggleLinePrefix(pattern: Self.quotePattern) { _ in "> " }
    }

    func toggleBulletList() {
        toggleLinePrefix(pattern: Self.bulletPattern) { _ in "- " }
    }

    func toggleNumberedList() {
        toggleLinePrefix(pattern: Self.numberPattern) { number in "\(number). " }
    }

    func insertDivider() {
        insertBlock("---\n", caretOffset: 4)
    }

    func insertCodeBlock() {
        insertBlock("```\n\n```\n", caretOffset: 4)
    }

    // MARK: Suggestions

    // AC-29. Replaces a range only while it still holds exactly what the suggestion was made on,
    // through the same path as typing so undo can take it back.
    func replace(_ range: NSRange, expecting original: String, with replacement: String) -> Bool {
        guard let textView else { return false }
        let text = textView.string as NSString
        guard range.upperBound <= text.length, text.substring(with: range) == original else { return false }
        replace(
            range, with: replacement,
            select: NSRange(location: range.location + (replacement as NSString).length, length: 0))
        return true
    }

    func select(_ range: NSRange) {
        guard let textView, range.upperBound <= (textView.string as NSString).length else { return }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.window?.makeFirstResponder(textView)
    }

    // Where a popover should point, in the text view's own coordinates.
    func anchorView() -> NSView? { textView }

    func rect(for range: NSRange) -> NSRect {
        guard let textView, let window = textView.window else { return .zero }
        let screen = textView.firstRect(forCharacterRange: range, actualRange: nil)
        return textView.convert(window.convertFromScreen(screen), from: nil)
    }

    // MARK: Undo

    func undo() {
        textView?.undoManager?.undo()
        refresh()
    }

    func redo() {
        textView?.undoManager?.redo()
        refresh()
    }

    // MARK: Editing

    // The one place this type changes text. shouldChangeText and didChangeText are what register
    // the undo step and tell the binding the body moved.
    private func replace(_ range: NSRange, with replacement: String, select: NSRange?) {
        guard let textView, let storage = textView.textStorage else { return }
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }

        storage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()

        if let select {
            let length = storage.length
            let location = min(max(select.location, 0), length)
            textView.setSelectedRange(
                NSRange(location: location, length: min(select.length, length - location)))
        }
        refresh()
    }

    private func wrap(_ marker: String, placeholder: String) {
        guard let textView else { return }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let markerLength = (marker as NSString).length

        // Already wrapped from just outside the selection, so the control takes the markers off.
        let outer = NSRange(
            location: selection.location - markerLength, length: selection.length + markerLength * 2)
        if outer.location >= 0, outer.upperBound <= text.length,
            text.substring(with: outer).hasPrefix(marker),
            text.substring(with: outer).hasSuffix(marker)
        {
            let inner = text.substring(with: selection)
            replace(
                outer, with: inner,
                select: NSRange(location: outer.location, length: (inner as NSString).length))
            return
        }

        // Or wrapped inside the selection, which is what happens when you select the whole word.
        let selected = text.substring(with: selection)
        if (selected as NSString).length >= markerLength * 2, selected.hasPrefix(marker),
            selected.hasSuffix(marker)
        {
            let inner = (selected as NSString).substring(
                with: NSRange(
                    location: markerLength, length: (selected as NSString).length - markerLength * 2))
            replace(
                selection, with: inner,
                select: NSRange(location: selection.location, length: (inner as NSString).length))
            return
        }

        let body = selection.length > 0 ? selected : placeholder
        replace(
            selection, with: marker + body + marker,
            select: NSRange(
                location: selection.location + markerLength, length: (body as NSString).length))
    }

    private func toggleLinePrefix(pattern: String, prefix: (Int) -> String) {
        var number = 0
        let hasPrefix = allSelectedLinesMatch(pattern)

        rewriteLines { row in
            let stripped = Self.strip(pattern, from: row)
            guard !hasPrefix else { return stripped }
            guard !stripped.trimmingCharacters(in: .whitespaces).isEmpty || self.selectionIsOneEmptyLine
            else { return row }

            number += 1
            return prefix(number) + stripped
        }
        refresh()
    }

    // Rewrites every line the selection touches, keeping the caret where it was on its own line.
    private func rewriteLines(_ transform: (String) -> String) {
        guard let textView else { return }
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let lineRange = text.lineRange(for: selection)
        let block = text.substring(with: lineRange)

        let endsWithNewline = block.hasSuffix("\n")
        let rows = (endsWithNewline ? String(block.dropLast()) : block).components(separatedBy: "\n")
        let rewritten = rows.map(transform)

        let replacement = rewritten.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        guard replacement != block else { return }

        let select: NSRange
        if selection.length == 0, let first = rows.first, let firstNew = rewritten.first {
            let shift = (firstNew as NSString).length - (first as NSString).length
            select = NSRange(location: max(selection.location + shift, lineRange.location), length: 0)
        } else {
            select = NSRange(location: lineRange.location, length: (replacement as NSString).length)
        }
        replace(lineRange, with: replacement, select: select)
    }

    private func insertBlock(_ block: String, caretOffset: Int) {
        guard let textView else { return }
        let text = textView.string as NSString
        let selection = textView.selectedRange()

        let atLineStart =
            selection.location == 0
            || text.substring(with: NSRange(location: selection.location - 1, length: 1)) == "\n"
        let atLineEnd =
            selection.upperBound >= text.length
            || text.substring(with: NSRange(location: selection.upperBound, length: 1)) == "\n"

        let lead = atLineStart ? "" : "\n"
        let trail = atLineEnd ? "" : "\n"
        let caret = selection.location + (lead as NSString).length + caretOffset

        replace(
            selection, with: lead + block + trail, select: NSRange(location: caret, length: 0))
    }

    // MARK: Reading the selection

    private var selectionIsOneEmptyLine: Bool {
        guard let textView else { return false }
        let text = textView.string as NSString
        let lineRange = text.lineRange(for: textView.selectedRange())
        return text.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func allSelectedLinesMatch(_ pattern: String) -> Bool {
        guard let textView else { return false }
        let text = textView.string as NSString
        let block = text.substring(with: text.lineRange(for: textView.selectedRange()))
        let rows = (block.hasSuffix("\n") ? String(block.dropLast()) : block)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        return !rows.isEmpty && rows.allSatisfy { Self.strip(pattern, from: $0) != $0 }
    }

    static func blockStyle(at offset: Int, in text: String) -> BlockStyle {
        let string = text as NSString
        guard string.length > 0 else { return .normal }

        let line = string.substring(
            with: string.lineRange(
                for: NSRange(location: min(max(offset, 0), string.length - 1), length: 0)))
        let hashes = line.drop(while: { $0 == " " || $0 == "\t" }).prefix(while: { $0 == "#" }).count

        switch hashes {
        case 0: return .normal
        case 1, 2: return .heading
        default: return .subheading
        }
    }

    // MARK: Line prefixes

    private static let headingPattern = #"^[ \t]{0,3}#{1,6}[ \t]+"#
    private static let quotePattern = #"^[ \t]{0,3}>[ \t]?"#
    private static let bulletPattern = #"^[ \t]*[-*+][ \t]+"#
    private static let numberPattern = #"^[ \t]*\d+[.)][ \t]+"#

    private static func strip(_ pattern: String, from row: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return row }
        return regex.stringByReplacingMatches(
            in: row, range: NSRange(location: 0, length: (row as NSString).length), withTemplate: "")
    }
}
