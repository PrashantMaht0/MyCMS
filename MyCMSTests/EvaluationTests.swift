import Foundation
import Testing
@testable import MyCMS

extension Tag {
    @Tag static var evaluation: Self
}

// Notes 7.7, kept verbatim: real errors from the first blog post, plus one clean paragraph.
private nonisolated struct Fixture: Sendable {
    let paragraph: String
    // Text a correct fix's replacement contains; nil means the paragraph must come back clean.
    let expected: String?
}

private nonisolated let fixtures: [Fixture] = [
    Fixture(paragraph: "Complete Higher Education \u{2014}\u{2014}> Complete Bachelor’s in Computer Applications \u{2014}\u{2014}> Complete Master's aboard \u{2014}\u{2014}> Get the Job.", expected: "abroad"),
    Fixture(paragraph: "Its really true that the people you surround yourself with influence your life in many ways.", expected: "It's"),
    Fixture(paragraph: "I have traveled to many places in Ireland met many people.Still, traveling through irish roads a wave of nostalgia hits.", expected: "people. Still"),
    Fixture(paragraph: "From the very young age computers and technology was always been my favorite subject in school.", expected: "had always been"),
    Fixture(paragraph: "I miss all the cafes and restaurants I use to go.", expected: "used to go"),
    Fixture(paragraph: "Graduations day is next month.", expected: "Graduation day"),
    Fixture(paragraph: "Type a topic and five small agents take it from there: one searches the web, one checks the findings are true, one writes the post, one reviews how it reads, and one publishes it to Google Blogger.", expected: nil),
]

// AC-34. Runs the real prompt against the real local model, so it only runs when asked:
// TEST_RUNNER_MYCMS_EVAL=1 xcodebuild -scheme MyCMS -destination 'platform=macOS' test -only-testing:MyCMSTests/EvaluationTests
@Suite("Evaluation set", .tags(.evaluation), .enabled(if: ProcessInfo.processInfo.environment["MYCMS_EVAL"] == "1"))
struct EvaluationTests {
    @Test("Catches the six real errors and leaves the clean paragraph alone")
    func evaluate() async throws {
        let client = OllamaClient()
        let model = ProcessInfo.processInfo.environment["MYCMS_EVAL_MODEL"] ?? OllamaClient.defaultModel
        let prompt = PromptLibrary.shared.grammar
        #expect(!prompt.text.isEmpty)

        var caught = 0
        var falsePositives = 0
        for fixture in fixtures {
            let paragraphs = SuggestionContext.paragraphs(of: fixture.paragraph)
            let message = SuggestionContext.message(
                title: "My Journey to Ireland", subtitle: "My first blog", paragraphs: paragraphs, target: 0, budget: 20_000)
            let started = ContinuousClock.now
            let reply: String
            do {
                reply = try await client.chat(
                    model: model,
                    messages: [.init(role: "system", content: prompt.text), .init(role: "user", content: message)],
                    format: SuggestionContext.schema, temperature: 0.1, timeout: 120)
            } catch {
                // One bad reply is a miss for that fixture, not the end of the run.
                print("EVAL error on \(fixture.expected ?? "clean"): \(error.localizedDescription)")
                continue
            }

            var survivors: [RawSuggestion] = []
            var shown: [NSRange] = []
            for raw in SuggestionVerifier.parse(reply) ?? [] {
                if case .shown(_, let range) = SuggestionVerifier.verify(
                    raw, paragraph: fixture.paragraph, paragraphStart: 0, code: [], shown: shown) {
                    shown.append(range)
                    survivors.append(raw)
                }
            }

            // Judged on the paragraph after the fixes, so a shorter correct fix counts as a catch.
            let fixed = NSMutableString(string: fixture.paragraph)
            for range in shown.sorted(by: { $0.location > $1.location }) {
                guard let raw = zip(shown, survivors).first(where: { $0.0 == range })?.1 else { continue }
                fixed.replaceCharacters(in: range, with: raw.replacement)
            }

            let elapsed = ContinuousClock.now - started
            if let expected = fixture.expected {
                let hit = (fixed as String).contains(expected)
                if hit { caught += 1 }
                print("EVAL \(hit ? "caught" : "missed") \(expected) in \(elapsed): \(survivors.map { "\($0.original) -> \($0.replacement)" })")
            } else {
                falsePositives = survivors.count
                print("EVAL clean paragraph produced \(survivors.count) suggestions in \(elapsed)")
            }
        }

        print("EVAL \(model) \(prompt.version): caught \(caught) of 6, \(falsePositives) false positives")
        #expect(falsePositives == 0)
        #expect(caught >= 1)
    }
}
