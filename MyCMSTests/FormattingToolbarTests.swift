import AppKit
import Foundation
import Testing
@testable import MyCMS

@MainActor
private func editor(_ text: String, selecting selection: NSRange? = nil)
    -> (MarkdownEditorTextView, EditorTextController, NSWindow) {
    let textView = MarkdownEditorTextView(usingTextLayoutManager: true)
    textView.allowsUndo = true
    textView.string = text

    // A window, because that is where an NSTextView finds its undo manager.
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = textView

    textView.setSelectedRange(selection ?? NSRange(location: (text as NSString).length, length: 0))

    let controller = EditorTextController()
    controller.attach(textView)
    return (textView, controller, window)
}

@Suite("Formatting toolbar")
@MainActor
struct FormattingToolbarTests {

    @Test("Bold wraps the selection and leaves the words selected")
    func boldWrapsSelection() {
        let (textView, controller, _) = editor(
            "Some bold words.", selecting: NSRange(location: 5, length: 4))
        controller.toggleBold()

        #expect(textView.string == "Some **bold** words.")
        #expect((textView.string as NSString).substring(with: textView.selectedRange()) == "bold")
    }

    @Test("Bold with nothing selected drops in a placeholder ready to be typed over")
    func boldInsertsPlaceholder() {
        let (textView, controller, _) = editor("Start ")
        controller.toggleBold()

        #expect(textView.string == "Start **bold**")
        #expect((textView.string as NSString).substring(with: textView.selectedRange()) == "bold")
    }

    @Test("Bold on something already bold takes the markers off again")
    func boldUnwraps() {
        let (textView, controller, _) = editor(
            "Some **bold** words.", selecting: NSRange(location: 7, length: 4))
        controller.toggleBold()

        #expect(textView.string == "Some bold words.")
    }

    @Test("Italic, strikethrough and inline code each insert their own Markdown")
    func theOtherInlineControls() {
        let (italic, italicController, _) = editor("a ")
        italicController.toggleItalic()
        #expect(italic.string == "a *italic*")

        let (struck, struckController, _) = editor("a ")
        struckController.toggleStrikethrough()
        #expect(struck.string == "a ~~struck~~")

        let (code, codeController, _) = editor("a ")
        codeController.toggleInlineCode()
        #expect(code.string == "a `code`")
    }

    @Test("Link inserts the whole shape and selects the part you have to fill in")
    func linkSelectsTheUrl() {
        let (textView, controller, _) = editor(
            "Read the docs here.", selecting: NSRange(location: 9, length: 4))
        controller.insertLink()

        #expect(textView.string == "Read the [docs](url) here.")
        #expect((textView.string as NSString).substring(with: textView.selectedRange()) == "url")
    }

    @Test("Image opens the picker rather than typing a made up path")
    func imageOpensThePicker() {
        let (textView, controller, _) = editor("Text")
        var asked = false
        controller.onPickImage = { asked = true }
        controller.insertImage()

        #expect(asked)
        #expect(textView.string == "Text")
    }

    @Test("A stored picture goes in on a line of its own, so the editor can draw it")
    func imageBlockGetsItsOwnLine() {
        let (textView, controller, _) = editor("Before after", selecting: NSRange(location: 7, length: 0))
        controller.insertImageBlock("![a](../../assets/blog/p/a.png)", at: NSRange(location: 7, length: 0))

        #expect(textView.string == "Before \n![a](../../assets/blog/p/a.png)\n\nafter")
    }

    @Test("A bullet list prefixes every selected line, and prefixes come off on a second press")
    func bulletListTogglesBothWays() {
        let (textView, controller, _) = editor(
            "One\nTwo\nThree\n", selecting: NSRange(location: 0, length: 13))
        controller.toggleBulletList()
        #expect(textView.string == "- One\n- Two\n- Three\n")

        controller.toggleBulletList()
        #expect(textView.string == "One\nTwo\nThree\n")
    }

    @Test("A numbered list counts from one down the selection")
    func numberedListNumbersInOrder() {
        let (textView, controller, _) = editor(
            "One\nTwo\nThree\n", selecting: NSRange(location: 0, length: 13))
        controller.toggleNumberedList()

        #expect(textView.string == "1. One\n2. Two\n3. Three\n")
    }

    @Test("Quote prefixes the line and takes the prefix off again")
    func quoteToggles() {
        let (textView, controller, _) = editor("Said it.\n", selecting: NSRange(location: 2, length: 0))
        controller.toggleQuote()
        #expect(textView.string == "> Said it.\n")

        controller.toggleQuote()
        #expect(textView.string == "Said it.\n")
    }

    @Test("The Style control writes ## and ###, per Notes 5.1")
    func styleControlWritesHeadings() {
        let (textView, controller, _) = editor("A line\n", selecting: NSRange(location: 2, length: 0))

        controller.setBlockStyle(.heading)
        #expect(textView.string == "## A line\n")

        controller.setBlockStyle(.subheading)
        #expect(textView.string == "### A line\n")

        controller.setBlockStyle(.normal)
        #expect(textView.string == "A line\n")
    }

    @Test("The Style control reflects what the caret is inside, which is AC-7")
    func styleControlFollowsTheCaret() {
        let text = "## A heading\n\nBody.\n\n### A subheading\n"
        let (textView, controller, _) = editor(text, selecting: NSRange(location: 3, length: 0))
        #expect(controller.blockStyle == .heading)

        textView.setSelectedRange(NSRange(location: (text as NSString).range(of: "Body.").location, length: 0))
        controller.refresh()
        #expect(controller.blockStyle == .normal)

        textView.setSelectedRange(
            NSRange(location: (text as NSString).range(of: "A subheading").location, length: 0))
        controller.refresh()
        #expect(controller.blockStyle == .subheading)
    }

    @Test("More holds the divider and the fenced code block, each on its own line")
    func moreMenuInserts() {
        let (divider, dividerController, _) = editor("Text.")
        dividerController.insertDivider()
        #expect(divider.string == "Text.\n---\n")

        let (fence, fenceController, _) = editor("Text.")
        fenceController.insertCodeBlock()
        #expect(fence.string == "Text.\n```\n\n```\n")
        #expect(fence.selectedRange().location == 10)
    }

    @Test("Undo puts back what a toolbar control changed, which is AC-6")
    func undoWorksAfterAToolbarEdit() throws {
        let (textView, controller, _) = editor(
            "Some bold words.", selecting: NSRange(location: 5, length: 4))
        try #require(textView.undoManager != nil)

        controller.toggleBold()
        #expect(textView.string == "Some **bold** words.")
        #expect(controller.canUndo)

        controller.undo()
        #expect(textView.string == "Some bold words.")
    }
}

@Suite("Styling the text view")
@MainActor
struct MarkdownStylerTests {

    private func styled(_ text: String, showMarkers: Bool = true)
        -> (MarkdownEditorTextView, MarkdownStyler) {
        let textView = MarkdownEditorTextView(usingTextLayoutManager: true)
        textView.string = text

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.documentView = textView

        let styler = MarkdownStyler(fontSize: Broadsheet.TypeScale.body, showMarkers: showMarkers)
        styler.attach(to: textView, in: scrollView)
        styler.restyle()
        return (textView, styler)
    }

    @Test("Styling changes how the text is drawn and never what it says, which is AC-2")
    func stylingLeavesTheStringAlone() {
        let text = "## A heading\n\nSome **bold** words.\n"
        let (textView, _) = styled(text)

        #expect(textView.string == text)
        #expect(textView.textStorage?.length == (text as NSString).length)
    }

    @Test("A heading is drawn larger than body text and bold is drawn heavier, which is AC-1")
    func headingsAndBoldAreDrawnDifferently() throws {
        let text = "## A heading\n\nSome **bold** words.\n"
        let (textView, _) = styled(text)
        let storage = try #require(textView.textStorage)
        let string = text as NSString

        let heading = try #require(
            storage.attribute(.font, at: string.range(of: "A heading").location, effectiveRange: nil)
                as? NSFont)
        let body = try #require(
            storage.attribute(.font, at: string.range(of: "words").location, effectiveRange: nil)
                as? NSFont)
        let bold = try #require(
            storage.attribute(.font, at: string.range(of: "bold").location, effectiveRange: nil)
                as? NSFont)

        #expect(heading.pointSize > body.pointSize)
        #expect(bold != body)
    }

    @Test("Markers are drawn dimmed by default, and the setting hides them, which is AC-3")
    func markersAreDimmedOrHidden() throws {
        let text = "## A heading\n"
        let markerOffset = 0

        let (shown, _) = styled(text, showMarkers: true)
        let dimmed = try #require(
            shown.textStorage?.attribute(.foregroundColor, at: markerOffset, effectiveRange: nil)
                as? NSColor)
        let bodyColor = try #require(
            shown.textStorage?.attribute(
                .foregroundColor, at: (text as NSString).range(of: "A heading").location,
                effectiveRange: nil) as? NSColor)
        #expect(dimmed != bodyColor)
        #expect(dimmed.alphaComponent > 0)

        let (hidden, _) = styled(text, showMarkers: false)
        let cleared = try #require(
            hidden.textStorage?.attribute(.foregroundColor, at: markerOffset, effectiveRange: nil)
                as? NSColor)
        #expect(cleared.alphaComponent == 0)
        // Hiding a marker changes its colour and nothing else, so every character is still there.
        #expect(hidden.string == text)
    }

    @Test("Typing restyles without waiting for the parse, and the parse catches up after the pause")
    func typingKeepsTheStylingAligned() async throws {
        let text = "Intro.\n\n"
        let (textView, styler) = styled(text)

        textView.insertText("## New heading", replacementRange: NSRange(location: 8, length: 0))
        try await eventually("the debounced parse to catch up") { styler.structure.text == textView.string }

        let storage = try #require(textView.textStorage)
        let headingOffset = (textView.string as NSString).range(of: "New heading").location
        let heading = try #require(
            storage.attribute(.font, at: headingOffset, effectiveRange: nil) as? NSFont)
        let body = try #require(
            storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)

        #expect(heading.pointSize > body.pointSize)
    }
}
