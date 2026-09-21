import Foundation
import Markdown

// Invariant 7. The one place swift-markdown's UTF-8 byte columns become the UTF-16 offsets
// that NSRange and NSTextView use. Two conversions would disagree on any line holding an emoji.
nonisolated struct LineIndex: Sendable {
    let text: String

    private let lines: [Line]
    private let totalUTF16: Int

    // A line is ASCII exactly when its UTF-8 and UTF-16 lengths agree, which makes the fast path free.
    private struct Line: Sendable {
        let start: String.Index
        let utf16Start: Int
        let utf16Length: Int
        let utf8Length: Int

        var isASCII: Bool { utf8Length == utf16Length }
    }

    init(_ text: String) {
        self.text = text
        self.totalUTF16 = text.utf16.count

        var built: [Line] = []
        var start = text.startIndex
        var utf16Start = 0

        while true {
            let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
            let slice = text[start..<end]
            let utf16Length = slice.utf16.count
            built.append(
                Line(
                    start: start,
                    utf16Start: utf16Start,
                    utf16Length: utf16Length,
                    utf8Length: slice.utf8.count))

            if end == text.endIndex { break }
            start = text.index(after: end)
            // The newline itself is one UTF-16 unit between one line's start and the next.
            utf16Start += utf16Length + 1
        }

        self.lines = built
    }

    var utf16Count: Int { totalUTF16 }

    // Both arguments are 1 based, as cmark reports them, and the column counts UTF-8 bytes.
    func utf16Offset(line: Int, column: Int) -> Int {
        guard !lines.isEmpty else { return 0 }

        let row = lines[min(max(line - 1, 0), lines.count - 1)]
        let byte = max(column - 1, 0)

        if row.isASCII { return row.utf16Start + min(byte, row.utf16Length) }
        guard byte > 0 else { return row.utf16Start }
        guard byte < row.utf8Length else { return row.utf16Start + row.utf16Length }

        var bytesSeen = 0
        var unitsSeen = 0
        var index = row.start
        let scalars = text.unicodeScalars

        while bytesSeen < byte, index < text.endIndex {
            let value = scalars[index].value
            bytesSeen += value < 0x80 ? 1 : value < 0x800 ? 2 : value < 0x1_0000 ? 3 : 4
            unitsSeen += value < 0x1_0000 ? 1 : 2
            index = scalars.index(after: index)
        }

        return row.utf16Start + min(unitsSeen, row.utf16Length)
    }

    // cmark's end column is exclusive once swift-markdown has added its one, so this is half open.
    func utf16Range(of range: SourceRange) -> NSRange {
        let start = utf16Offset(line: range.lowerBound.line, column: range.lowerBound.column)
        let end = utf16Offset(line: range.upperBound.line, column: range.upperBound.column)

        let lower = min(max(start, 0), totalUTF16)
        let upper = min(max(end, lower), totalUTF16)
        return NSRange(location: lower, length: upper - lower)
    }
}
