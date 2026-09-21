import Foundation

// What the model sent for one suggestion, before code has decided anything about it.
nonisolated struct RawSuggestion: Decodable, Sendable, Equatable {
    let kind: String
    let original: String
    let replacement: String
    let reason: String
}

// A suggestion that passed the gate, anchored to an exact range of the stored text.
nonisolated struct Suggestion: Sendable, Identifiable, Equatable {
    enum Kind: String, Sendable, CaseIterable {
        case punctuation
        case grammar
    }

    let id: UUID
    var rowID: Int64?
    let kind: Kind
    let original: String
    let replacement: String
    let reason: String
    var range: NSRange
    let targetHash: String
}

nonisolated enum SuggestionVerdict: Sendable, Equatable {
    enum Reason: String, Sendable {
        case unknownKind = "kind is not punctuation or grammar"
        case notAnchored = "original is not in the paragraph"
        case noChange = "replacement is the same as original"
        case disproportionate = "too large a change for a correction"
        case touchesCode = "falls on code"
        case overlaps = "overlaps a suggestion already shown"
        case dismissed = "dismissed before"
    }

    case shown(Suggestion.Kind, NSRange)
    case dropped(Reason)
}

// AC-22 to AC-25 and AC-28. Nothing the model returns is an edit: each check here is deterministic,
// and a failure is a logged drop that never reaches the screen.
nonisolated enum SuggestionVerifier {
    // AC-25. Dropped only when a change exceeds both limits; either alone is not enough.
    static let proportionLimit = 0.3
    static let characterFloor = 4

    // AC-22. Anything but the exact shape is dropped whole.
    static func parse(_ json: String) -> [RawSuggestion]? {
        struct Envelope: Decodable { let suggestions: [RawSuggestion] }
        return (try? JSONDecoder().decode(Envelope.self, from: Data(json.utf8)))?.suggestions
    }

    // `paragraphStart` is the paragraph's UTF-16 offset in the body; `shown` are ranges already
    // accepted earlier in this same pass, so two overlapping proposals never both appear.
    static func verify(
        _ raw: RawSuggestion, paragraph: String, paragraphStart: Int, code: [NSRange], shown: [NSRange]
    ) -> SuggestionVerdict {
        guard let kind = Suggestion.Kind(rawValue: raw.kind.lowercased()) else { return .dropped(.unknownKind) }

        // AC-23. Verbatim or nothing, and the match is also where the underline goes.
        let local = (paragraph as NSString).range(of: raw.original)
        guard !raw.original.isEmpty, local.location != NSNotFound else { return .dropped(.notAnchored) }
        let range = NSRange(location: paragraphStart + local.location, length: local.length)

        // AC-24.
        guard raw.replacement != raw.original else { return .dropped(.noChange) }

        // AC-25.
        let distance = editDistance(raw.original, raw.replacement)
        if Double(distance) > proportionLimit * Double(raw.original.count), distance > characterFloor {
            return .dropped(.disproportionate)
        }

        // AC-33. Code is never sent, so an anchor on it can only be a coincidence.
        guard !code.contains(where: { $0.intersection(range).map { $0.length > 0 } ?? false }) else {
            return .dropped(.touchesCode)
        }

        // AC-28.
        guard !shown.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { return .dropped(.overlaps) }

        return .shown(kind, range)
    }

    // Levenshtein over characters, so an accented letter or an emoji counts as one.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

// AC-19, AC-21 and AC-33. The whole post as context and one paragraph as the target, with code
// taken out, and when it will not fit, context goes from the furthest paragraph inwards.
nonisolated enum SuggestionContext {
    struct Paragraph: Sendable, Equatable {
        // UTF-16 range of the paragraph's own text in the body.
        let range: NSRange
        let text: String
        // What the model is shown: inline code swapped for a placeholder.
        let masked: String
        let isCode: Bool
    }

    static let codePlaceholder = "[code]"

    // The window, less the prompt and room for the answer, at a conservative four characters a token.
    static func characterBudget(promptCharacters: Int, window: Int = 8192, answerTokens: Int = 1024) -> Int {
        max((window - answerTokens) * 4 - promptCharacters, 2000) * 3 / 4
    }

    static func paragraphs(of body: String) -> [Paragraph] {
        let structure = MarkdownRenderer.parse(body)
        let text = body as NSString

        return DocumentSession.split(body).compactMap { block in
            let blockRange = NSRange(block.range, in: body)
            let local = text.range(of: block.text, range: blockRange)
            guard local.location != NSNotFound else { return nil }

            let codeInside = structure.codeRanges.compactMap { $0.intersection(local) }.filter { $0.length > 0 }
            let wholeIsCode = codeInside.contains { $0.location <= local.location && $0.upperBound >= local.upperBound }
                || block.text.hasPrefix("```") || block.text.hasPrefix("~~~")

            let masked = NSMutableString(string: block.text)
            for code in codeInside.sorted(by: { $0.location > $1.location }) {
                masked.replaceCharacters(
                    in: NSRange(location: code.location - local.location, length: code.length), with: codePlaceholder)
            }
            return Paragraph(range: local, text: block.text, masked: masked as String, isCode: wholeIsCode)
        }
    }

    static func message(title: String, subtitle: String, paragraphs: [Paragraph], target: Int, budget: Int) -> String {
        let prose = paragraphs.enumerated().filter { !$0.element.isCode }
        var kept: Set<Int> = [target]
        var used = paragraphs[target].masked.count + title.count + subtitle.count

        // Nearest first, so what survives a tight window is what surrounds the target.
        for (index, paragraph) in prose.sorted(by: { abs($0.offset - target) < abs($1.offset - target) })
        where index != target {
            guard used + paragraph.masked.count <= budget else { continue }
            kept.insert(index)
            used += paragraph.masked.count
        }

        let context = prose.filter { kept.contains($0.offset) }.map(\.element.masked).joined(separator: "\n\n")
        return """
            <context>
            Title: \(title)
            Subtitle: \(subtitle)

            \(context)
            </context>

            <target>
            \(paragraphs[target].masked)
            </target>
            """
    }

    // The schema Ollama holds the answer to, matching RawSuggestion.
    static let schema = try! JSONValue(parsing: """
        {"type": "object", "required": ["suggestions"], "properties": {"suggestions": {"type": "array",
         "items": {"type": "object", "required": ["kind", "original", "replacement", "reason"],
         "properties": {"kind": {"type": "string", "enum": ["punctuation", "grammar"]},
         "original": {"type": "string"}, "replacement": {"type": "string"}, "reason": {"type": "string"}}}}}}
        """)

    static let rewriteSchema = try! JSONValue(parsing: """
        {"type": "object", "required": ["alternatives"], "properties": {"alternatives": {"type": "array",
         "items": {"type": "string"}}}}
        """)
}
