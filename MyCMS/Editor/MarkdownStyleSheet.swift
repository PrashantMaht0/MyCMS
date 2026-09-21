import AppKit
import SwiftUI

// Turns the styles a run carries into the attributes the text view draws with.
// Styles arrive combined, because a bold word inside a heading is both at once.
final class MarkdownStyleSheet {
    // Code reads a shade smaller than the prose around it, which is what the site does too.
    private static let codeScale: CGFloat = 0.92

    let fontSize: CGFloat
    let showMarkers: Bool

    private var fonts: [FontKey: NSFont] = [:]

    private struct FontKey: Hashable {
        let size: CGFloat
        let bold: Bool
        let italic: Bool
        let mono: Bool
    }

    init(fontSize: CGFloat, showMarkers: Bool) {
        self.fontSize = fontSize
        self.showMarkers = showMarkers
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        attributes(for: [])
    }

    func attributes(for styles: [MarkdownStyle]) -> [NSAttributedString.Key: Any] {
        var size = fontSize
        var bold = false
        var italic = false
        var mono = false
        var struckThrough = false
        var isMarker = false
        var color = NSColor(Broadsheet.Colors.text)
        var paragraph = bodyParagraph()

        for style in styles.sorted(by: { $0.precedence < $1.precedence }) {
            switch style {
            case .heading(let level):
                size = headingSize(level)
                bold = true
                paragraph = headingParagraph(size: size)
            case .blockQuote:
                italic = true
                color = NSColor(Broadsheet.Colors.secondaryText)
                paragraph = quoteParagraph()
            case .listItem(let markerWidth):
                paragraph = listParagraph(markerWidth: markerWidth, size: size)
            case .codeBlock:
                mono = true
                size *= Self.codeScale
                paragraph = codeParagraph()
            case .link:
                color = NSColor(Broadsheet.Colors.accentText)
            case .strikethrough:
                struckThrough = true
            case .strong:
                bold = true
            case .emphasis:
                italic = true
            case .inlineCode:
                mono = true
                size *= Self.codeScale
            case .marker:
                isMarker = true
            }
        }

        // AC-3. Hiding a marker changes its colour and nothing else, so the caret still crosses it.
        if isMarker {
            color = showMarkers ? NSColor(Broadsheet.Colors.secondaryText) : .clear
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(FontKey(size: size, bold: bold, italic: italic, mono: mono)),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        if struckThrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = color
        }
        return attributes
    }

    // MARK: Type

    // Broadsheet's own scale, kept in proportion so a larger editor font takes the headings with it.
    private func headingSize(_ level: Int) -> CGFloat {
        let scale = Broadsheet.TypeScale.heading[min(max(level - 1, 0), Broadsheet.TypeScale.heading.count - 1)]
        return (scale / Broadsheet.TypeScale.body) * fontSize
    }

    private func font(_ key: FontKey) -> NSFont {
        if let cached = fonts[key] { return cached }
        let made = makeFont(key)
        fonts[key] = made
        return made
    }

    private func makeFont(_ key: FontKey) -> NSFont {
        let weight: NSFont.Weight = key.bold ? .bold : .regular

        if key.mono {
            let mono = NSFont.monospacedSystemFont(ofSize: key.size, weight: weight)
            return key.italic ? slanted(mono) : mono
        }

        var descriptor: NSFontDescriptor
        if AppFonts.isRegistered {
            // Asking by weight rather than by symbolic trait, because the family is a variable font.
            descriptor = NSFontDescriptor(fontAttributes: [
                .family: AppFonts.familyName,
                .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
            ])
        } else {
            let system = NSFont.systemFont(ofSize: key.size, weight: weight).fontDescriptor
            descriptor = system.withDesign(.serif) ?? system
        }

        if key.italic {
            descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic))
        }

        guard let font = NSFont(descriptor: descriptor, size: key.size) else {
            return NSFont.systemFont(ofSize: key.size, weight: weight)
        }
        guard key.italic, !font.fontDescriptor.symbolicTraits.contains(.italic) else { return font }
        return slanted(font)
    }

    // The fallback when a family carries no italic face of its own.
    private func slanted(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    // MARK: Paragraphs

    private func bodyParagraph() -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = Broadsheet.TypeScale.bodyLineHeight
        return paragraph
    }

    private func headingParagraph(size: CGFloat) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.2
        paragraph.paragraphSpacingBefore = size * 0.4
        paragraph.paragraphSpacing = size * 0.15
        return paragraph
    }

    private func quoteParagraph() -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = Broadsheet.TypeScale.bodyLineHeight
        paragraph.firstLineHeadIndent = Broadsheet.Space.x4
        paragraph.headIndent = Broadsheet.Space.x4
        return paragraph
    }

    private func codeParagraph() -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.35
        paragraph.firstLineHeadIndent = Broadsheet.Space.x2
        paragraph.headIndent = Broadsheet.Space.x2
        return paragraph
    }

    // A hanging indent the width of the marker, so a wrapped list item lines up under its text.
    private func listParagraph(markerWidth: Int, size: CGFloat) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = Broadsheet.TypeScale.bodyLineHeight

        let sample = String(repeating: "0", count: max(markerWidth, 1))
        let width = (sample as NSString).size(
            withAttributes: [.font: font(FontKey(size: size, bold: false, italic: false, mono: false))]
        ).width

        paragraph.headIndent = width
        return paragraph
    }
}
