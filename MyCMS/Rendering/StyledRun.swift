import Foundation

// One stretch of characters and the one thing that is true about it. Runs overlap on purpose:
// a bold word inside a heading is a heading run and a strong run over the same characters.
nonisolated struct StyledRun: Sendable, Equatable {
    var range: NSRange
    var style: MarkdownStyle
}

nonisolated enum MarkdownStyle: Sendable, Equatable {
    case heading(level: Int)
    case blockQuote
    case listItem(markerWidth: Int)
    case codeBlock
    case link
    case strikethrough
    case strong
    case emphasis
    case inlineCode
    case marker

    // Application order. Block shape first, then inline traits on top of it, markers last so the
    // dimmed colour always wins over whatever the marker happens to sit inside.
    var precedence: Int {
        switch self {
        case .heading: 0
        case .blockQuote: 1
        case .listItem: 2
        case .codeBlock: 3
        case .link: 4
        case .strikethrough: 5
        case .strong: 6
        case .emphasis: 7
        case .inlineCode: 8
        case .marker: 9
        }
    }
}

// One `![alt](source)` in the body. A block image is alone on its line.
nonisolated struct ImageReference: Sendable, Equatable {
    var range: NSRange
    var source: String
    var alt: String
    var isBlock: Bool
}
