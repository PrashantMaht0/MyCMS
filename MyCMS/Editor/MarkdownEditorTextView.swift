import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The writing surface itself. The one thing it draws beyond the text is the block quote rule,
// which AC-1 asks for and no text attribute can express.
final class MarkdownEditorTextView: NSTextView {
    // The rule sits in the indent the quote's paragraph style already reserves.
    private static let ruleWidth: CGFloat = 2

    // A picture arriving by drop or paste, before the asset store has seen it.
    enum IncomingImage {
        case file(URL)
        case data(Data, name: String)
    }

    var quoteRanges: [NSRange] = [] {
        didSet {
            guard quoteRanges != oldValue else { return }
            needsDisplay = true
        }
    }

    // AC-28. Each verified suggestion is underlined at exactly its anchored range.
    var suggestionRanges: [NSRange] = [] {
        didSet {
            guard suggestionRanges != oldValue else { return }
            needsDisplay = true
        }
    }

    // AC-32. The Suggest rewrites item appears in the context menu only when there is a selection.
    var onRewrite: ((NSRange) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard onRewrite != nil, selectedRange().length > 0 else { return menu }
        let item = NSMenuItem(title: "Suggest rewrites", action: #selector(suggestRewrites), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func suggestRewrites() {
        onRewrite?(selectedRange())
    }

    // AC-9. Set by the editor; when present, pictures never land in the text as a path or a blob.
    var onImages: (([IncomingImage]) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawQuoteRules()
        drawSuggestionUnderlines()
    }

    // MARK: Pictures coming in

    private static let imageTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        Self.imageTypes + super.readablePasteboardTypes
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        Self.imageTypes + super.acceptableDragTypes
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if let onImages {
            let images = Self.images(on: pboard)
            if !images.isEmpty {
                onImages(images)
                return true
            }
        }
        return super.readSelection(from: pboard, type: type)
    }

    private static func images(on pboard: NSPasteboard) -> [IncomingImage] {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let files = urls.filter { url in
            (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true
        }
        if !files.isEmpty { return files.map { .file($0) } }

        if let png = pboard.data(forType: .png) { return [.data(png, name: "pasted.png")] }
        // A screenshot arrives as TIFF, which the site cannot show, so it is turned into PNG here.
        if let tiff = pboard.data(forType: .tiff),
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return [.data(png, name: "pasted.png")]
        }
        return []
    }

    private func drawSuggestionUnderlines() {
        guard !suggestionRanges.isEmpty,
            let layoutManager = textLayoutManager,
            let contentManager = layoutManager.textContentManager
        else { return }

        let origin = textContainerOrigin
        NSColor(Broadsheet.Colors.accentText).setStroke()

        for range in suggestionRanges {
            guard let textRange = contentManager.textRange(for: range) else { continue }
            layoutManager.enumerateTextSegments(in: textRange, type: .standard) { _, frame, baseline, _ in
                let y = frame.minY + origin.y + min(baseline + 3, frame.height - 1)
                let line = NSBezierPath()
                line.move(to: NSPoint(x: frame.minX + origin.x, y: y))
                line.line(to: NSPoint(x: frame.maxX + origin.x, y: y))
                line.lineWidth = 1.5
                line.setLineDash([2, 2], count: 2, phase: 0)
                line.stroke()
                return true
            }
        }
    }

    private func drawQuoteRules() {
        guard !quoteRanges.isEmpty,
            let layoutManager = textLayoutManager,
            let contentManager = layoutManager.textContentManager
        else { return }

        let origin = textContainerOrigin
        NSColor(Broadsheet.Colors.divider).setFill()

        for range in quoteRanges {
            guard let textRange = contentManager.textRange(for: range) else { continue }
            layoutManager.enumerateTextSegments(in: textRange, type: .standard) { _, frame, _, _ in
                NSRect(
                    x: origin.x + Broadsheet.Space.x1,
                    y: frame.minY + origin.y,
                    width: Self.ruleWidth,
                    height: frame.height
                ).fill()
                return true
            }
        }
    }
}

extension NSTextContentManager {
    // NSRange is what the rest of the app speaks, NSTextRange is what TextKit 2 wants.
    func textRange(for range: NSRange) -> NSTextRange? {
        guard let start = location(documentRange.location, offsetBy: range.location),
            let end = location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }
}
