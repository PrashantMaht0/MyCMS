import Foundation
import OSLog

/// The prompt files shipped inside the app, read once and addressed by name and version.
///
/// The version travels with every suggestion row, so a cached verdict from an older prompt is never
/// reused for a newer one.
nonisolated struct PromptLibrary: Sendable {
    struct Prompt: Sendable {
        let text: String
        // The file's own name, such as grammar.v1, which is what ai_suggestions records.
        let version: String
    }

    let grammar: Prompt
    let rewrite: Prompt

    static let shared = PromptLibrary(bundle: .main)

    init(bundle: Bundle) {
        grammar = Self.load("grammar.v1", from: bundle)
        rewrite = Self.load("rewrite.v1", from: bundle)
    }

    private static func load(_ name: String, from bundle: Bundle) -> Prompt {
        let url =
            bundle.url(forResource: name, withExtension: "md")
            ?? bundle.url(forResource: name, withExtension: "md", subdirectory: "Prompts")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        if text.isEmpty { Loggers.ai.error("Prompt \(name, privacy: .public) is missing from the bundle") }
        return Prompt(text: text, version: name)
    }
}
