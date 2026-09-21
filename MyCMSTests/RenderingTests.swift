import Foundation
import Testing
@testable import MyCMS

private func range(of substring: String, in text: String) -> NSRange {
    (text as NSString).range(of: substring)
}

private func styles(coveringStartOf substring: String, in structure: MarkdownStructure) -> [MarkdownStyle] {
    let found = range(of: substring, in: structure.text)
    return structure.runs(in: found).map(\.style)
}

@Suite("Markdown structure")
struct MarkdownStructureTests {

    @Test("Parsing never touches the string it was given")
    func textSurvivesParsing() {
        let text = "## Heading\n\n**bold** and *italic* and `code`\n"
        #expect(MarkdownRenderer.parse(text).text == text)
    }

    @Test("A heading is styled at its level and its hashes are markers")
    func headingAndItsMarkers() {
        let text = "## A heading\n\nBody text.\n"
        let structure = MarkdownRenderer.parse(text)
        let heading = range(of: "## A heading", in: text)
        let found = structure.runs(in: heading)

        #expect(found.contains { $0.style == .heading(level: 2) && $0.range == heading })
        #expect(found.contains { $0.style == .marker && $0.range == range(of: "## ", in: text) })
    }

    @Test("Bold and italic cover their delimiters, and the delimiters are markers")
    func emphasisSpans() {
        let text = "Some **bold** and *thin* words.\n"
        let structure = MarkdownRenderer.parse(text)

        #expect(structure.runs(in: range(of: "**bold**", in: text))
            .contains { $0.style == .strong && $0.range == range(of: "**bold**", in: text) })
        #expect(structure.runs(in: range(of: "*thin*", in: text))
            .contains { $0.style == .emphasis && $0.range == range(of: "*thin*", in: text) })

        let markers = structure.runs(in: range(of: "**bold**", in: text))
            .filter { $0.style == .marker }
        #expect(markers.count == 2)
        #expect(markers.allSatisfy { $0.range.length == 2 })
    }

    @Test("Underscore emphasis is found the same way as asterisk emphasis")
    func underscoreEmphasis() {
        let text = "Some __bold__ words.\n"
        let structure = MarkdownRenderer.parse(text)
        let markers = structure.runs(in: range(of: "__bold__", in: text)).filter { $0.style == .marker }

        #expect(markers.count == 2)
        #expect(markers.allSatisfy { $0.range.length == 2 })
    }

    @Test("An emoji in a heading does not move the offsets below it, which is AC-2")
    func utf16ConversionSurvivesAstralCharacters() {
        let text = "# 🎉 Party time\n\nSome **bold** text.\n"
        let structure = MarkdownRenderer.parse(text)

        let heading = range(of: "# 🎉 Party time", in: text)
        #expect(structure.runs(in: heading).contains { $0.style == .heading(level: 1) && $0.range == heading })

        let bold = range(of: "**bold**", in: text)
        #expect(structure.runs(in: bold).contains { $0.style == .strong && $0.range == bold })
    }

    @Test("An emoji mid line keeps a later span on the same line in the right place")
    func utf16ConversionWithinOneLine() {
        let text = "Party 🎉 then **bold** here.\n"
        let structure = MarkdownRenderer.parse(text)
        let bold = range(of: "**bold**", in: text)

        #expect(structure.runs(in: bold).contains { $0.style == .strong && $0.range == bold })
    }

    @Test("Inline code and fenced blocks are both code, and nothing else is")
    func codeRangesAreFound() {
        let text = "Call `parse()` now.\n\n```swift\nlet x = 1\n```\n\nPlain words.\n"
        let structure = MarkdownRenderer.parse(text)

        #expect(structure.isCode(at: range(of: "parse()", in: text).location))
        #expect(structure.isCode(at: range(of: "let x = 1", in: text).location))
        #expect(!structure.isCode(at: range(of: "Plain words.", in: text).location))
        #expect(!structure.isCode(at: range(of: "Call ", in: text).location))
    }

    @Test("A fence that is never closed styles the rest as code and does not crash, which is AC-5")
    func unterminatedFence() {
        let text = "Intro.\n\n```swift\nlet x = 1\nstill code\n"
        let structure = MarkdownRenderer.parse(text)

        #expect(structure.isCode(at: range(of: "still code", in: text).location))
        #expect(!structure.isCode(at: range(of: "Intro.", in: text).location))
    }

    @Test("A quote, a list and a link each carry their own style and markers")
    func blockStylesAndLinks() {
        let text = "> Quoted line\n\n- First item\n- Second item\n\nA [link](https://example.com) here.\n"
        let structure = MarkdownRenderer.parse(text)

        #expect(styles(coveringStartOf: "Quoted line", in: structure).contains(.blockQuote))
        #expect(structure.runs(in: range(of: "> ", in: text)).contains { $0.style == .marker })

        #expect(styles(coveringStartOf: "First item", in: structure)
            .contains { if case .listItem = $0 { true } else { false } })
        #expect(structure.runs(in: range(of: "- ", in: text)).contains { $0.style == .marker })

        #expect(styles(coveringStartOf: "link", in: structure).contains(.link))
        #expect(structure.runs(in: range(of: "](https://example.com)", in: text))
            .contains { $0.style == .marker && $0.range == range(of: "](https://example.com)", in: text) })
    }

    @Test("A run that starts before the asked for range is still returned")
    func overlapSearchLooksBackwards() {
        let text = "```\nline one\nline two\nline three\n```\n"
        let structure = MarkdownRenderer.parse(text)
        let middle = range(of: "line two", in: text)

        #expect(structure.runs(in: middle).contains { $0.style == .codeBlock })
    }

    @Test("Runs come back clipped to the range asked for, never wider")
    func runsAreClipped() {
        let text = "## A long heading line\n"
        let structure = MarkdownRenderer.parse(text)
        let window = NSRange(location: 3, length: 4)

        #expect(structure.runs(in: window).allSatisfy {
            $0.range.location >= window.location && $0.range.upperBound <= window.upperBound
        })
    }

    @Test("A five thousand word post parses and styles a viewport well inside a frame, per AC-4")
    func parsingAndStylingStayFast() {
        let paragraph = "## A heading in the middle of it\n\n"
            + "Some **bold** words and some *italic* ones, with `inline code` and a "
            + "[link](https://example.com) to finish, repeated until the post is a real length.\n\n"
        let text = String(repeating: paragraph, count: 200)
        #expect(DocumentSession.countWords(text) > 5000)

        let parseStart = ContinuousClock.now
        let structure = MarkdownRenderer.parse(text)
        let parsed = ContinuousClock.now - parseStart

        // One viewport's worth, which is the work a single keystroke actually costs.
        let window = NSRange(location: (text as NSString).length / 2, length: 3000)
        let styleStart = ContinuousClock.now
        for _ in 0..<10 { _ = structure.runs(in: window) }
        let styled = (ContinuousClock.now - styleStart) / 10

        #expect(parsed < .milliseconds(250))
        #expect(styled < .milliseconds(16))
    }

    @Test("Shifting keeps the last tree lined up with the text an edit just moved")
    func shiftingMovesLaterRuns() {
        let text = "Intro.\n\n**bold**\n"
        let structure = MarkdownRenderer.parse(text)
        let bold = range(of: "**bold**", in: text)
        let shifted = structure.shifted(after: 0, by: 5)

        #expect(shifted.runs(in: NSRange(location: bold.location + 5, length: bold.length))
            .contains { $0.style == .strong })
    }
}
