import Foundation
import Markdown

// The parsed shape of one document: every styled run, and every range the spell checker
// and the AI loop must leave alone. Built once per parse, then read per viewport.
nonisolated struct MarkdownStructure: Sendable {
    let lineIndex: LineIndex
    let codeRanges: [NSRange]
    let images: [ImageReference]

    private let runs: [StyledRun]
    // Running maximum of every run end so far, so an overlap search can binary search into it.
    private let maxEnd: [Int]

    var text: String { lineIndex.text }

    init(
        lineIndex: LineIndex, runs: [StyledRun], codeRanges: [NSRange], images: [ImageReference] = []
    ) {
        let ordered = runs.sorted { $0.range.location < $1.range.location }
        var running = 0

        self.lineIndex = lineIndex
        self.runs = ordered
        self.maxEnd = ordered.map { run in
            running = max(running, run.range.upperBound)
            return running
        }
        self.codeRanges = codeRanges.sorted { $0.location < $1.location }
        self.images = images.sorted { $0.range.location < $1.range.location }
    }

    func utf16Range(of range: SourceRange) -> NSRange {
        lineIndex.utf16Range(of: range)
    }

    // AC-4. The work here is bounded by the range asked for, never by the document.
    func runs(in range: NSRange) -> [StyledRun] {
        guard range.length > 0, !runs.isEmpty else { return [] }

        var low = 0
        var high = maxEnd.count
        while low < high {
            let mid = (low + high) / 2
            if maxEnd[mid] <= range.location { low = mid + 1 } else { high = mid }
        }

        var found: [StyledRun] = []
        var index = low
        while index < runs.count, runs[index].range.location < range.upperBound {
            if let clipped = runs[index].range.intersection(range), clipped.length > 0 {
                found.append(StyledRun(range: clipped, style: runs[index].style))
            }
            index += 1
        }

        return found.sorted { $0.style.precedence < $1.style.precedence }
    }

    // AC-5. Code ranges never overlap each other, so one binary search answers it.
    func isCode(at offset: Int) -> Bool {
        var low = 0
        var high = codeRanges.count - 1

        while low <= high {
            let mid = (low + high) / 2
            let candidate = codeRanges[mid]
            if offset < candidate.location {
                high = mid - 1
            } else if offset >= candidate.upperBound {
                low = mid + 1
            } else {
                return true
            }
        }
        return false
    }

    // Keeps the last good tree lined up with the text between parses, per AC-4.
    // Only runs(in:) and isCode(at:) stay meaningful afterwards; the line index is left behind.
    func shifted(after offset: Int, by delta: Int) -> MarkdownStructure {
        guard delta != 0 else { return self }

        return MarkdownStructure(
            lineIndex: lineIndex,
            runs: runs.compactMap { run in
                guard let moved = Self.shift(run.range, after: offset, by: delta) else { return nil }
                return StyledRun(range: moved, style: run.style)
            },
            codeRanges: codeRanges.compactMap { Self.shift($0, after: offset, by: delta) },
            images: images.compactMap { image in
                guard let moved = Self.shift(image.range, after: offset, by: delta) else { return nil }
                var shifted = image
                shifted.range = moved
                return shifted
            })
    }

    private static func shift(_ range: NSRange, after offset: Int, by delta: Int) -> NSRange? {
        if range.location >= offset {
            let location = range.location + delta
            return location >= 0 ? NSRange(location: location, length: range.length) : nil
        }
        guard range.upperBound > offset else { return range }

        let length = range.length + delta
        return length > 0 ? NSRange(location: range.location, length: length) : nil
    }
}
