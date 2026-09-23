import Foundation
import Markdown

/// The one Markdown parser, used for three different jobs.
///
/// `parse` returns the structure the editor styles with (styled runs, code ranges, image
/// references, a line index). `html(for:resolvingImages:)` renders the preview and the library
/// detail pane, asking the caller where each picture lives so the renderer never touches the disk.
/// Everything is derived from the text; nothing here ever changes it.
nonisolated enum MarkdownRenderer {
    static func parse(_ text: String) -> MarkdownStructure {
        let lineIndex = LineIndex(text)
        var collector = SpanCollector(lineIndex: lineIndex, units: Array(text.utf16))
        collector.visit(Markdown.Document(parsing: text))

        return MarkdownStructure(
            lineIndex: lineIndex, runs: collector.runs, codeRanges: collector.codeRanges,
            images: collector.images)
    }

    static func runs(in range: NSRange, of structure: MarkdownStructure) -> [StyledRun] {
        structure.runs(in: range)
    }

    static func isCode(at offset: Int, in structure: MarkdownStructure) -> Bool {
        structure.isCode(at: offset)
    }
}

// Markers are found by reading the characters at a node's own edges rather than by assuming a
// length, so `__bold__` and `**bold**` both work and a surprising cmark range degrades quietly.
private nonisolated struct SpanCollector: MarkupWalker {
    let lineIndex: LineIndex
    let units: [UInt16]

    var runs: [StyledRun] = []
    var codeRanges: [NSRange] = []
    var images: [ImageReference] = []

    private enum Unit {
        static let tab: UInt16 = 9
        static let newline: UInt16 = 10
        static let space: UInt16 = 32
        static let bang: UInt16 = 33
        static let hash: UInt16 = 35
        static let closeParen: UInt16 = 41
        static let star: UInt16 = 42
        static let plus: UInt16 = 43
        static let dash: UInt16 = 45
        static let dot: UInt16 = 46
        static let zero: UInt16 = 48
        static let nine: UInt16 = 57
        static let greater: UInt16 = 62
        static let openBracket: UInt16 = 91
        static let closeBracket: UInt16 = 93
        static let underscore: UInt16 = 95
        static let backtick: UInt16 = 96
        static let tilde: UInt16 = 126
    }

    // MARK: Inline

    mutating func visitStrong(_ strong: Strong) {
        if let span = span(of: strong) {
            runs.append(StyledRun(range: span, style: .strong))
            markDelimiters(span) { $0 == Unit.star || $0 == Unit.underscore }
        }
        descendInto(strong)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        if let span = span(of: emphasis) {
            runs.append(StyledRun(range: span, style: .emphasis))
            markDelimiters(span) { $0 == Unit.star || $0 == Unit.underscore }
        }
        descendInto(emphasis)
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        if let span = span(of: strikethrough) {
            runs.append(StyledRun(range: span, style: .strikethrough))
            markDelimiters(span) { $0 == Unit.tilde }
        }
        descendInto(strikethrough)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        guard let span = span(of: inlineCode) else { return }
        runs.append(StyledRun(range: span, style: .inlineCode))
        codeRanges.append(span)
        markDelimiters(span) { $0 == Unit.backtick }
    }

    mutating func visitLink(_ link: Link) {
        if let span = span(of: link), first(at: span.location) == Unit.openBracket,
            let closing = closingBracket(from: span.location, limit: span.upperBound)
        {
            runs.append(StyledRun(range: span, style: .link))
            runs.append(StyledRun(range: NSRange(location: span.location, length: 1), style: .marker))
            runs.append(
                StyledRun(
                    range: NSRange(location: closing, length: span.upperBound - closing),
                    style: .marker))
        }
        descendInto(link)
    }

    // Feature 13 draws the picture. All this does is stop the syntax around it shouting.
    mutating func visitImage(_ image: Markdown.Image) {
        if let span = span(of: image), first(at: span.location) == Unit.bang,
            let closing = closingBracket(from: span.location + 1, limit: span.upperBound)
        {
            runs.append(StyledRun(range: NSRange(location: span.location, length: 2), style: .marker))
            runs.append(
                StyledRun(
                    range: NSRange(location: closing, length: span.upperBound - closing),
                    style: .marker))
            images.append(
                ImageReference(
                    range: span, source: image.source ?? "", alt: image.plainText,
                    isBlock: standsAlone(span)))
        }
    }

    // True when nothing but whitespace shares the line with this span.
    private func standsAlone(_ span: NSRange) -> Bool {
        var start = span.location
        while start > 0, units[start - 1] != Unit.newline {
            guard isSpace(units[start - 1]) else { return false }
            start -= 1
        }
        let end = lineEnd(from: span.upperBound, limit: units.count)
        return forwardRun(from: span.upperBound, end: end, while: isSpace) == end - span.upperBound
    }

    // MARK: Blocks

    mutating func visitHeading(_ heading: Heading) {
        if let span = span(of: heading) {
            runs.append(StyledRun(range: span, style: .heading(level: heading.level)))
            markHeadingSyntax(span)
        }
        descendInto(heading)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        if let span = span(of: blockQuote) {
            runs.append(StyledRun(range: span, style: .blockQuote))
            let quoteMarkers = lineMarkers(in: span) { lineStart, lineEnd in
                let indent = forwardRun(from: lineStart, end: lineEnd, while: isSpace)
                let carets = forwardRun(from: lineStart + indent, end: lineEnd) { $0 == Unit.greater }
                guard carets > 0 else { return nil }

                let spaces = forwardRun(from: lineStart + indent + carets, end: lineEnd, while: isSpace)
                return NSRange(location: lineStart, length: indent + carets + spaces)
            }
            runs.append(contentsOf: quoteMarkers)
        }
        descendInto(blockQuote)
    }

    mutating func visitListItem(_ listItem: ListItem) {
        if let span = span(of: listItem), let marker = listMarker(in: span) {
            runs.append(StyledRun(range: span, style: .listItem(markerWidth: marker.length)))
            runs.append(StyledRun(range: marker, style: .marker))
        }
        descendInto(listItem)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        guard let span = span(of: codeBlock) else { return }
        runs.append(StyledRun(range: span, style: .codeBlock))
        codeRanges.append(span)

        // Only the fence lines are syntax. What sits between them is the code itself.
        let fenceMarkers = lineMarkers(in: span) { lineStart, lineEnd in
            let indent = forwardRun(from: lineStart, end: lineEnd, while: isSpace)
            let fence = forwardRun(from: lineStart + indent, end: lineEnd) {
                $0 == Unit.backtick || $0 == Unit.tilde
            }
            guard fence >= 3 else { return nil }
            return NSRange(location: lineStart, length: lineEnd - lineStart)
        }
        runs.append(contentsOf: fenceMarkers)
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        guard let span = span(of: thematicBreak) else { return }
        runs.append(StyledRun(range: span, style: .marker))
    }

    // MARK: Reading the source

    private func span(of markup: Markup) -> NSRange? {
        guard let source = markup.range else { return nil }
        let converted = lineIndex.utf16Range(of: source)
        return converted.length > 0 ? converted : nil
    }

    private func first(at offset: Int) -> UInt16? {
        offset >= 0 && offset < units.count ? units[offset] : nil
    }

    private func isSpace(_ unit: UInt16) -> Bool {
        unit == Unit.space || unit == Unit.tab
    }

    private func forwardRun(from offset: Int, end: Int, while matches: (UInt16) -> Bool) -> Int {
        var index = max(offset, 0)
        let limit = min(end, units.count)
        while index < limit, matches(units[index]) { index += 1 }
        return index - max(offset, 0)
    }

    private func backwardRun(from end: Int, start: Int, while matches: (UInt16) -> Bool) -> Int {
        var index = min(end, units.count)
        while index > start, index > 0, matches(units[index - 1]) { index -= 1 }
        return min(end, units.count) - index
    }

    private func lineEnd(from offset: Int, limit: Int) -> Int {
        var index = offset
        let end = min(limit, units.count)
        while index < end, units[index] != Unit.newline { index += 1 }
        return index
    }

    private func closingBracket(from offset: Int, limit: Int) -> Int? {
        var depth = 0
        var index = offset
        let end = min(limit, units.count)

        while index < end {
            if units[index] == Unit.openBracket {
                depth += 1
            } else if units[index] == Unit.closeBracket {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    // MARK: Marker shapes

    private mutating func markDelimiters(_ span: NSRange, matching: (UInt16) -> Bool) {
        let leading = forwardRun(from: span.location, end: span.upperBound, while: matching)
        let trailing = backwardRun(
            from: span.upperBound, start: span.location + leading, while: matching)

        if leading > 0 {
            runs.append(
                StyledRun(range: NSRange(location: span.location, length: leading), style: .marker))
        }
        if trailing > 0 {
            runs.append(
                StyledRun(
                    range: NSRange(location: span.upperBound - trailing, length: trailing),
                    style: .marker))
        }
    }

    private mutating func markHeadingSyntax(_ span: NSRange) {
        let indent = forwardRun(from: span.location, end: span.upperBound, while: isSpace)
        let hashes = forwardRun(from: span.location + indent, end: span.upperBound) { $0 == Unit.hash }

        guard hashes > 0 else {
            // Setext. The heading's own range runs over its underline, which is all syntax.
            let underline = lastLineStart(in: span)
            if underline > span.location, underline < span.upperBound {
                runs.append(
                    StyledRun(
                        range: NSRange(location: underline, length: span.upperBound - underline),
                        style: .marker))
            }
            return
        }

        let opening =
            indent + hashes
            + forwardRun(from: span.location + indent + hashes, end: span.upperBound, while: isSpace)
        runs.append(
            StyledRun(range: NSRange(location: span.location, length: opening), style: .marker))

        // A closed ATX heading ends in its own run of hashes, which is syntax too.
        let closing = backwardRun(from: span.upperBound, start: span.location + opening) {
            $0 == Unit.hash
        }
        guard closing > 0 else { return }

        let gap = backwardRun(
            from: span.upperBound - closing, start: span.location + opening, while: isSpace)
        runs.append(
            StyledRun(
                range: NSRange(
                    location: span.upperBound - closing - gap, length: closing + gap),
                style: .marker))
    }

    private func listMarker(in span: NSRange) -> NSRange? {
        let end = lineEnd(from: span.location, limit: span.upperBound)
        let indent = forwardRun(from: span.location, end: end, while: isSpace)
        var width = forwardRun(from: span.location + indent, end: end) {
            $0 == Unit.dash || $0 == Unit.star || $0 == Unit.plus
        }

        if width == 0 {
            let digits = forwardRun(from: span.location + indent, end: end) {
                $0 >= Unit.zero && $0 <= Unit.nine
            }
            let terminator = forwardRun(from: span.location + indent + digits, end: end) {
                $0 == Unit.dot || $0 == Unit.closeParen
            }
            guard digits > 0, terminator > 0 else { return nil }
            width = digits + terminator
        }

        let spaces = forwardRun(from: span.location + indent + width, end: end, while: isSpace)
        return NSRange(location: span.location, length: indent + width + spaces)
    }

    private func lastLineStart(in span: NSRange) -> Int {
        var index = min(span.upperBound, units.count)
        while index > span.location {
            if units[index - 1] == Unit.newline { return index }
            index -= 1
        }
        return span.location
    }

    private func lineMarkers(in span: NSRange, marker: (Int, Int) -> NSRange?) -> [StyledRun] {
        var found: [StyledRun] = []
        var lineStart = span.location

        while lineStart < span.upperBound {
            let end = lineEnd(from: lineStart, limit: span.upperBound)
            if let range = marker(lineStart, end), range.length > 0 {
                found.append(StyledRun(range: range, style: .marker))
            }
            lineStart = end + 1
        }
        return found
    }
}
