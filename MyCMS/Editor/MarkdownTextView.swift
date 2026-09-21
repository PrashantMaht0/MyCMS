import AppKit
import SwiftUI

// The writing surface. NSTextView with TextKit 2, because features 9 and 11 need exact
// character ranges and a click target on one, which SwiftUI's TextEditor cannot give.
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    var styler: MarkdownStyler
    var controller: EditorTextController
    var onImages: (([MarkdownEditorTextView.IncomingImage]) -> Void)?
    var suggestionRanges: [NSRange] = []
    var onRewrite: ((NSRange) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownEditorTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.isRichText = false
        // Substitution stays off, because AC-2 says the Markdown is stored exactly as typed.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        // Checking only underlines, it never rewrites, so it is safe alongside that rule.
        // AC-5 then stops it marking anything inside code.
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: Broadsheet.Space.x2, height: Broadsheet.Space.x4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.setAccessibilityLabel("Body")
        textView.setAccessibilityRoleDescription("Markdown editor")

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        textView.onImages = onImages
        textView.onRewrite = onRewrite
        styler.attach(to: textView, in: scrollView)
        controller.attach(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MarkdownEditorTextView else { return }
        textView.suggestionRanges = suggestionRanges

        // AC-20. A value that came out of this view's own delegate callback never goes back in,
        // because writing it back would reset the caret on every keystroke.
        guard !context.coordinator.isApplyingLocalEdit, textView.string != text else { return }

        textView.string = text
        styler.textReplaced()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: MarkdownTextView
        // Set while a local edit is being forwarded, so the update pass can tell an echo apart.
        private(set) var isApplyingLocalEdit = false

        init(_ parent: MarkdownTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                textView.string != parent.text
            else { return }

            isApplyingLocalEdit = true
            parent.text = textView.string
            isApplyingLocalEdit = false
            parent.controller.refresh()
        }

        // AC-7. The Style control has to follow the caret, so it is refreshed as the caret moves.
        func textViewDidChangeSelection(_ notification: Notification) {
            parent.controller.refresh()
        }
    }
}
