import Foundation
import Markdown

// AC-13 and AC-14. Markdown to HTML for the preview and the detail pane. Not swift-markdown's own
// HTMLFormatter, which escapes nothing and drops alt text, so code showing a tag would become one.
nonisolated struct HTMLWriter: MarkupWalker {
    // Maps a Markdown image path to what the page should load; nil drops the picture's source.
    let imageSource: (String) -> String?
    private(set) var result = ""

    init(imageSource: @escaping (String) -> String?) {
        self.imageSource = imageSource
    }

    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    // MARK: Blocks

    mutating func visitParagraph(_ paragraph: Paragraph) {
        wrap("p", paragraph)
    }

    mutating func visitHeading(_ heading: Heading) {
        wrap("h\(min(max(heading.level, 1), 6))", heading)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        wrap("blockquote", blockQuote, newline: true)
    }

    mutating func visitUnorderedList(_ list: UnorderedList) {
        wrap("ul", list, newline: true)
    }

    mutating func visitOrderedList(_ list: OrderedList) {
        let start = list.startIndex == 1 ? "" : " start=\"\(list.startIndex)\""
        result += "<ol\(start)>\n"
        descendInto(list)
        result += "</ol>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) {
        result += "<li>"
        if let checkbox = listItem.checkbox {
            result += "<input type=\"checkbox\" disabled\(checkbox == .checked ? " checked" : "")> "
        }
        // A tight list item's paragraph reads as bare text, as it does on the site.
        for child in listItem.children {
            if let paragraph = child as? Paragraph, listItem.childCount == 1 || child.indexInParent == 0 {
                descendInto(paragraph)
            } else {
                visit(child)
            }
        }
        result += "</li>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let language = codeBlock.language.map { " class=\"language-\(Self.escape($0))\"" } ?? ""
        result += "<pre><code\(language)>\(Self.escape(codeBlock.code))</code></pre>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        result += "<hr>\n"
    }

    // Raw HTML passes through, as the site's own Markdown pipeline does. Scripts never run, because
    // both web views that show this have JavaScript turned off.
    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        result += html.rawHTML
    }

    mutating func visitTable(_ table: Table) {
        result += "<table>\n<thead>\n<tr>"
        for cell in table.head.cells {
            result += "<th>"
            descendInto(cell)
            result += "</th>"
        }
        result += "</tr>\n</thead>\n<tbody>\n"
        for row in table.body.rows {
            result += "<tr>"
            for cell in row.cells {
                result += "<td>"
                descendInto(cell)
                result += "</td>"
            }
            result += "</tr>\n"
        }
        result += "</tbody>\n</table>\n"
    }

    // MARK: Inline

    mutating func visitText(_ text: Text) {
        result += Self.escape(text.string)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        wrap("em", emphasis)
    }

    mutating func visitStrong(_ strong: Strong) {
        wrap("strong", strong)
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        wrap("del", strikethrough)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        result += "<code>\(Self.escape(inlineCode.code))</code>"
    }

    mutating func visitLink(_ link: Link) {
        let href = link.destination.map { " href=\"\(Self.escape($0))\"" } ?? ""
        let title = link.title.map { " title=\"\(Self.escape($0))\"" } ?? ""
        result += "<a\(href)\(title)>"
        descendInto(link)
        result += "</a>"
    }

    mutating func visitImage(_ image: Image) {
        let source = image.source.flatMap(imageSource).map { " src=\"\(Self.escape($0))\"" } ?? ""
        let title = image.title.map { " title=\"\(Self.escape($0))\"" } ?? ""
        result += "<img\(source) alt=\"\(Self.escape(image.plainText))\"\(title)>"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        result += inlineHTML.rawHTML
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        result += "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        result += "<br>\n"
    }

    // MARK: Helpers

    private mutating func wrap(_ tag: String, _ markup: Markup, newline: Bool = false) {
        result += "<\(tag)>" + (newline ? "\n" : "")
        descendInto(markup)
        result += "</\(tag)>\n"
    }
}

nonisolated extension MarkdownRenderer {
    // AC-63 still holds: this walks the same swift-markdown tree the editor styles from.
    static func html(for text: String, imageSource: @escaping (String) -> String? = { $0 }) -> String {
        var writer = HTMLWriter(imageSource: imageSource)
        writer.visit(Markdown.Document(parsing: text))
        return writer.result
    }
}
