import Foundation
import Testing

@testable import MyCMS

private func raw(_ original: String, _ replacement: String, kind: String = "punctuation") -> RawSuggestion {
    RawSuggestion(kind: kind, original: original, replacement: replacement, reason: "r")
}

@Suite("Suggestion gate")
struct SuggestionVerifierTests {
    let paragraph = "Its really true that I use to go there."

    @Test("Its to It's survives: 33 percent is over the ratio but under the four character floor, per AC-25")
    func shortFixSurvives() {
        let verdict = SuggestionVerifier.verify(
            raw("Its", "It's"), paragraph: paragraph, paragraphStart: 10, code: [], shown: [])
        #expect(verdict == .shown(.punctuation, NSRange(location: 10, length: 3)))
    }

    @Test("A whole sentence rewrite called grammar fails both limits and is dropped, per AC-25")
    func rewriteIsDisproportionate() {
        let verdict = SuggestionVerifier.verify(
            raw("Its really true that I use to go there.", "Honestly, I went there all the time.", kind: "grammar"),
            paragraph: paragraph, paragraphStart: 0, code: [], shown: [])
        #expect(verdict == .dropped(.disproportionate))
    }

    @Test("An original not in the paragraph, a no op, and an unknown kind are all dropped, per AC-23 and AC-24")
    func basicDrops() {
        #expect(
            SuggestionVerifier.verify(
                raw("It is", "It's"), paragraph: paragraph, paragraphStart: 0, code: [], shown: [])
                == .dropped(.notAnchored))
        #expect(
            SuggestionVerifier.verify(raw("true", "true"), paragraph: paragraph, paragraphStart: 0, code: [], shown: [])
                == .dropped(.noChange))
        #expect(
            SuggestionVerifier.verify(
                raw("true", "truly", kind: "style"), paragraph: paragraph, paragraphStart: 0, code: [], shown: [])
                == .dropped(.unknownKind))
    }

    @Test("A second suggestion overlapping one already shown is dropped, so only one underline appears, per AC-28")
    func overlapIsDropped() {
        let first = SuggestionVerifier.verify(
            raw("use to go", "used to go", kind: "grammar"), paragraph: paragraph, paragraphStart: 0, code: [],
            shown: [])
        guard case .shown(_, let range) = first else {
            Issue.record("first should show")
            return
        }
        let second = SuggestionVerifier.verify(
            raw("use to", "used to", kind: "grammar"), paragraph: paragraph, paragraphStart: 0, code: [], shown: [range]
        )
        #expect(second == .dropped(.overlaps))
    }

    @Test("An anchor landing on code is dropped")
    func codeIsOffLimits() {
        let verdict = SuggestionVerifier.verify(
            raw("Its", "It's"), paragraph: paragraph, paragraphStart: 0, code: [NSRange(location: 0, length: 5)],
            shown: [])
        #expect(verdict == .dropped(.touchesCode))
    }

    @Test("A response in any other shape is dropped whole, per AC-22")
    func schemaIsEnforced() {
        #expect(
            SuggestionVerifier.parse(
                #"{"suggestions":[{"kind":"grammar","original":"a","replacement":"b","reason":"c"}]}"#)?.count == 1)
        #expect(SuggestionVerifier.parse(#"{"suggestions":[{"kind":"grammar","original":"a"}]}"#) == nil)
        #expect(SuggestionVerifier.parse("Sure! Here are some fixes") == nil)
    }

    @Test("An emoji before the anchor does not move it, because offsets are UTF-16 throughout")
    func emojiKeepsAnchor() {
        let text = "🎉 Its fine."
        let verdict = SuggestionVerifier.verify(
            raw("Its", "It's"), paragraph: text, paragraphStart: 0, code: [], shown: [])
        #expect(verdict == .shown(.punctuation, (text as NSString).range(of: "Its")))
    }
}

@Suite("Suggestion context")
struct SuggestionContextTests {
    @Test("Fenced code is never a target and inline code is masked before anything is sent, per AC-33")
    func codeIsNeverSent() {
        let body = "Call `secret()` now.\n\n```\nlet key = 1\n```\n\nPlain words.\n"
        let paragraphs = SuggestionContext.paragraphs(of: body)

        #expect(paragraphs.map(\.isCode) == [false, true, false])
        #expect(paragraphs[0].masked == "Call [code] now.")
        let message = SuggestionContext.message(
            title: "T", subtitle: "S", paragraphs: paragraphs, target: 2, budget: 10_000)
        #expect(!message.contains("secret()"))
        #expect(!message.contains("let key"))
    }

    @Test(
        "A post too long for the window keeps the title and the whole target, and drops the furthest context first, per AC-21"
    )
    func overflowTrimsFromTheFarEnd() {
        let body = (0..<40).map { "Paragraph \($0) " + String(repeating: "word ", count: 40) }.joined(separator: "\n\n")
        let paragraphs = SuggestionContext.paragraphs(of: body)
        let message = SuggestionContext.message(
            title: "My Title", subtitle: "My Sub", paragraphs: paragraphs, target: 39, budget: 2000)

        #expect(message.contains("Title: My Title"))
        #expect(message.contains("<target>\n\(paragraphs[39].masked)\n</target>"))
        #expect(message.contains("Paragraph 38 "))
        #expect(!message.contains("Paragraph 0 "))
    }
}

// A pretend Ollama: answers the model list, and answers each chat from a closure over the target.
private nonisolated final class FakeOllama: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var chatCalls: Int { lock.withLock { calls } }
    let answer: @Sendable (String) async throws -> String
    let reachable: Bool

    init(reachable: Bool = true, answer: @escaping @Sendable (String) async throws -> String) {
        self.reachable = reachable
        self.answer = answer
    }

    func client(_ url: URL) -> OllamaClient {
        OllamaClient(
            baseURL: url,
            fetch: { [reachable] request in
                guard reachable else { throw URLError(.cannotConnectToHost) }
                let body = #"{"models":[{"name":"llama3.2:3b"}]}"#
                return (
                    Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            },
            chatFetch: { [self] request in
                lock.withLock { calls += 1 }
                let sent = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                let target =
                    sent.components(separatedBy: "<target>\\n").last?.components(separatedBy: "\\n</target>").first
                    ?? ""
                let content = try await answer(target)
                let reply = try JSONEncoder().encode(["message": ["role": "assistant", "content": content]])
                return (
                    reply, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            })
    }
}

private nonisolated func suggestions(_ items: [(String, String, String)]) -> String {
    let list = items.map { #"{"kind":"\#($0.0)","original":"\#($0.1)","replacement":"\#($0.2)","reason":"r"}"# }
    return #"{"suggestions":[\#(list.joined(separator: ","))]}"#
}

@MainActor
private func waitFor(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Suite("Suggestion engine", .serialized)
@MainActor
struct SuggestionEngineTests {
    private func engine(body: String, fake: FakeOllama, store: SuggestionStore? = nil)
        throws -> (SuggestionEngine, DocumentSession, SuggestionStore)
    {
        let database = try MyCMS.Database.inMemory()
        let documents = DocumentStore(database: database)
        let session = DocumentSession(document: try documents.create(collection: .blog), store: documents)
        session.body = body
        let suggestionStore = store ?? SuggestionStore(database: database)
        let engine = SuggestionEngine(
            session: session, store: suggestionStore, settings: SettingsStore(database: database),
            makeClient: fake.client)
        engine.apply = { range, expected, replacement in
            let text = session.body as NSString
            guard range.upperBound <= text.length, text.substring(with: range) == expected else { return false }
            session.body = text.replacingCharacters(in: range, with: replacement)
            return true
        }
        return (engine, session, suggestionStore)
    }

    @Test("A pause checks the paragraph and a verified fix appears at its exact range, per AC-18")
    func happyPath() async throws {
        let fake = FakeOllama { _ in suggestions([("punctuation", "Its", "It's")]) }
        let (engine, session, _) = try engine(body: "Its really true.\n", fake: fake)
        engine.scheduleCheck(after: .zero)
        try await waitFor { !engine.suggestions.isEmpty }

        #expect(engine.suggestions.first?.range == (session.body as NSString).range(of: "Its"))
        #expect(engine.availability == .ready(model: "llama3.2:3b"))
    }

    @Test("A made up original never shows and is logged as dropped, per AC-23 and AC-27")
    func unanchoredIsLogged() async throws {
        let fake = FakeOllama { _ in suggestions([("grammar", "not in there", "x")]) }
        let (engine, _, store) = try engine(body: "Plain words here.\n", fake: fake)
        engine.scheduleCheck(after: .zero)
        try await waitFor { fake.chatCalls == 1 && !engine.isChecking }
        try await Task.sleep(for: .milliseconds(50))

        #expect(engine.suggestions.isEmpty)
        #expect(try store.dropRate(model: "llama3.2:3b", promptVersion: "grammar.v1") == 1)
    }

    @Test("An unchanged paragraph is never asked twice, even by a fresh engine after a relaunch, per AC-18")
    func unchangedIsCached() async throws {
        let fake = FakeOllama { _ in suggestions([]) }
        let (engine, session, store) = try engine(body: "Fine text.\n", fake: fake)
        engine.scheduleCheck(after: .zero)
        try await waitFor { fake.chatCalls == 1 && !engine.isChecking }

        engine.scheduleCheck(after: .zero)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.chatCalls == 1)

        let again = SuggestionEngine(
            session: session, store: store, settings: SettingsStore(database: try MyCMS.Database.inMemory()),
            makeClient: fake.client)
        again.scheduleCheck(after: .zero)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.chatCalls == 1)
    }

    @Test("A dismissed fix does not come back, even after a relaunch, per AC-31")
    func dismissalSticks() async throws {
        let fake = FakeOllama { _ in suggestions([("punctuation", "Its", "It's")]) }
        let (engine, session, store) = try engine(body: "Its fine.\n", fake: fake)
        engine.scheduleCheck(after: .zero)
        try await waitFor { !engine.suggestions.isEmpty }
        engine.dismiss(try #require(engine.suggestions.first))

        let relaunched = SuggestionEngine(
            session: session, store: store, settings: SettingsStore(database: try MyCMS.Database.inMemory()),
            makeClient: fake.client)
        relaunched.scheduleCheck(after: .zero)
        try await Task.sleep(for: .milliseconds(300))
        #expect(relaunched.suggestions.isEmpty)
    }

    @Test("Editing the anchored words makes the fix stale rather than letting it land somewhere else, per AC-26")
    func editMakesStale() async throws {
        let fake = FakeOllama { _ in suggestions([("punctuation", "Its", "It's")]) }
        let (engine, session, _) = try engine(body: "Its fine.\n", fake: fake)
        engine.scheduleCheck(after: .zero)
        try await waitFor { !engine.suggestions.isEmpty }

        session.body = "Is fine.\n"
        engine.textEdited(range: NSRange(location: 1, length: 0), delta: -1)
        #expect(engine.suggestions.isEmpty)
    }

    @Test("An edit above a fix shifts it rather than dropping it")
    func editAboveShifts() async throws {
        let fake = FakeOllama { _ in suggestions([("punctuation", "Its", "It's")]) }
        let (engine, session, _) = try engine(body: "Its fine.\n", fake: fake)
        engine.scheduleCheck(after: .zero)
        try await waitFor { !engine.suggestions.isEmpty }
        engine.isEnabled = false

        session.body = "Hello. Its fine.\n"
        engine.textEdited(range: NSRange(location: 0, length: 7), delta: 7)
        #expect(engine.suggestions.first?.range == NSRange(location: 7, length: 3))
    }

    @Test("Accept all punctuation fixes three in one paragraph, the last one landing correctly, per AC-30")
    func acceptAllPunctuation() async throws {
        let fake = FakeOllama { _ in
            suggestions([
                ("punctuation", "Its", "It's"), ("punctuation", "dont", "don't"),
                ("punctuation", "people.Still", "people. Still"),
            ])
        }
        let (engine, session, _) = try engine(body: "Its true I dont know people.Still here.\n", fake: fake)
        engine.scheduleCheck(after: .zero)
        try await waitFor { engine.suggestions.count == 3 }
        engine.isEnabled = false

        #expect(engine.acceptAllPunctuation() == 0)
        #expect(session.body == "It's true I don't know people. Still here.\n")
    }

    @Test("A server that never answers times out, frees the slot, and reports rather than hangs, per AC-68")
    func timeoutFreesTheSlot() async throws {
        let fake = FakeOllama { _ in
            try await Task.sleep(for: .seconds(30))
            return ""
        }
        let (engine, _, _) = try engine(body: "Words.\n", fake: fake)
        engine.requestTimeout = 0.3
        engine.scheduleCheck(after: .zero)
        try await waitFor { if case .notRunning = engine.availability { return true } else { return false } }
        #expect(!engine.isChecking)
    }

    @Test("With Ollama stopped the engine says so quietly and nothing throws, per AC-17")
    func ollamaDown() async throws {
        let fake = FakeOllama(reachable: false) { _ in "" }
        let (engine, _, _) = try engine(body: "Words.\n", fake: fake)
        await engine.refreshAvailability()
        #expect(engine.availability == .notRunning("Ollama isn't running."))
    }
}
