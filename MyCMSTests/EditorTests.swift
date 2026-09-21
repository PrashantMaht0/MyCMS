import Foundation
import GRDB
import Testing
@testable import MyCMS

// A fixed sleep racing a debounce is why these tests used to fail at random on a loaded
// machine. This waits for the condition instead, so the timeout only matters when something
// is genuinely broken, never when the machine is merely busy.
@MainActor
func eventually(
    _ description: @autoclosure () -> String = "condition",
    timeout: Duration = .seconds(10),
    poll: Duration = .milliseconds(5),
    until condition: () throws -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if try condition() { return }
        try await Task.sleep(for: poll)
    }
    Issue.record("Timed out after \(timeout) waiting for \(description())")
}

@Suite("Slug rule")
struct SlugRuleTests {
    @Test("A title becomes a path segment")
    func derivesSlug() {
        #expect(SlugRule.derive(from: "A newbie experience of reading books")
            == "a-newbie-experience-of-reading-books")
        #expect(SlugRule.derive(from: "Hello, World!") == "hello-world")
        #expect(SlugRule.derive(from: "  Kayaking   in   winter  ") == "kayaking-in-winter")
    }

    @Test("A title with nothing usable in it becomes null, never an empty string")
    func emptyDerivationIsNil() {
        #expect(SlugRule.derive(from: "!!!") == nil)
        #expect(SlugRule.derive(from: "   ") == nil)
        #expect(SlugRule.derive(from: "") == nil)
    }

    @Test("A taken slug gets the lowest free suffix, and the whole write still lands")
    func claimsAFreeSlug() throws {
        let database = try MyCMS.Database.inMemory()
        let store = DocumentStore(database: database)

        let first = try store.create(collection: .blog)
        let second = try store.create(collection: .blog)
        let other = try store.create(collection: .projects)

        let a = try store.claimSlug("hello-world", for: first.id, in: .blog)
        #expect(a == "hello-world")
        try store.update(id: first.id, Column("slug").set(to: a))

        let b = try store.claimSlug("hello-world", for: second.id, in: .blog)
        #expect(b == "hello-world-2")

        // The other collection is a different file path, so no suffix is needed.
        let c = try store.claimSlug("hello-world", for: other.id, in: .projects)
        #expect(c == "hello-world")
    }
}

@Suite("Word count")
struct WordCountTests {
    @Test("Markers, urls and fenced code do not count as prose")
    func countsProseOnly() {
        #expect(DocumentSession.countWords("# Heading here") == 2)
        #expect(DocumentSession.countWords("**bold** and *italic*") == 3)
        #expect(DocumentSession.countWords("See [the docs](https://example.com/a/b)") == 3)
        #expect(DocumentSession.countWords("```\nlet x = 1\n\nlet y = 2\n```") == 0)
        #expect(DocumentSession.countWords("- one\n- two\n- three") == 3)
        #expect(DocumentSession.countWords("> quoted words here") == 3)
    }

    @Test("Reading time is words over 200, rounded up, never zero")
    func readingTime() async throws {
        let database = try MyCMS.Database.inMemory()
        let store = DocumentStore(database: database)
        let session = await DocumentSession(document: try store.create(collection: .blog), store: store)

        await MainActor.run { session.body = Array(repeating: "word", count: 201).joined(separator: " ") }
        #expect(await session.wordCount == 201)
        #expect(await session.readingMinutes == 2)
    }
}

@Suite("Paragraph splitting")
struct ParagraphTests {
    @Test("Blank lines split paragraphs, but not inside a fenced code block")
    func fenceAware() {
        let text = "First para.\n\nSecond para.\n\n```\nlet a = 1\n\nlet b = 2\n```\n\nLast para."
        let paragraphs = DocumentSession.split(text)
        #expect(paragraphs.count == 4, "got \(paragraphs.map(\.text))")
        #expect(paragraphs[0].text == "First para.")
        #expect(paragraphs[2].text.contains("let a = 1"))
        #expect(paragraphs[2].text.contains("let b = 2"))
        #expect(paragraphs[3].text == "Last para.")
    }

    @Test("Identity is the text, not the position, so inserting above does not churn the rest")
    func identityIsContent() {
        let before = DocumentSession.split("Alpha.\n\nBeta.")
        let after = DocumentSession.split("New one.\n\nAlpha.\n\nBeta.")

        let beforeIDs = Set(before.map(\.id))
        let unchanged = after.filter { beforeIDs.contains($0.id) }
        #expect(unchanged.count == 2, "inserting a paragraph changed the identity of the others")
    }
}

@Suite("Autosave")
@MainActor
struct AutosaveTests {
    private func makeSession() throws -> (DocumentStore, DocumentSession) {
        let database = try MyCMS.Database.inMemory()
        let store = DocumentStore(database: database)
        let document = try store.create(collection: .blog)
        // A tiny delay keeps the test fast while still exercising the real debounce path.
        return (store, DocumentSession(document: document, store: store, autosaveDelay: .milliseconds(20)))
    }

    @Test("Typing in the body persists it")
    func bodyPersists() async throws {
        let (store, session) = try makeSession()

        session.body = "Some words I actually typed."
        #expect(session.saveState == .dirty)

        try await eventually("the body to be written and the state to settle") {
            try store.fetch(id: session.document.id)?.bodyMd == "Some words I actually typed."
                && session.saveState == .clean
        }

        #expect(try store.fetch(id: session.document.id)?.bodyMd == "Some words I actually typed.")
        #expect(session.saveState == .clean)
    }

    @Test("A title change carries the slug with it while the document is a draft")
    func titleCarriesSlug() async throws {
        let (store, session) = try makeSession()

        session.title = "A newbie experience of reading books"
        try await eventually("the slug to be derived and written") {
            try store.fetch(id: session.document.id)?.slug == "a-newbie-experience-of-reading-books"
        }

        let stored = try store.fetch(id: session.document.id)
        #expect(stored?.title == "A newbie experience of reading books")
        #expect(stored?.slug == "a-newbie-experience-of-reading-books")
    }

    // This is the regression guard for the flaky suite. The debounce here is deliberately
    // longer than the fixed 200ms wait these tests used to use, so the old approach would
    // fail this every time and the polling one cannot.
    @Test("A debounce slower than any fixed wait still settles")
    func slowDebounceStillSettles() async throws {
        let database = try MyCMS.Database.inMemory()
        let store = DocumentStore(database: database)
        let document = try store.create(collection: .blog)
        let session = DocumentSession(document: document, store: store, autosaveDelay: .milliseconds(300))

        session.body = "Typed on a machine that is busy."

        try await eventually("a 300ms debounce to land, well past the old 200ms guess") {
            try store.fetch(id: document.id)?.bodyMd == "Typed on a machine that is busy."
        }

        #expect(session.saveState == .clean)
    }

    @Test("Flushing writes immediately rather than waiting for the debounce")
    func flushWritesNow() async throws {
        let (store, session) = try makeSession()

        session.body = "Typed then closed at once."
        await session.flush()

        #expect(try store.fetch(id: session.document.id)?.bodyMd == "Typed then closed at once.")
    }

    @Test("A deleted document stops the session writing to it")
    func deletionStopsWrites() async throws {
        let (store, session) = try makeSession()
        try store.delete(id: session.document.id)

        session.body = "Typed after it was gone."
        try await eventually("the session to notice the document is gone") {
            session.documentWasDeleted
        }

        #expect(session.documentWasDeleted)
        #expect(session.body == "Typed after it was gone.", "the text must stay on screen")
    }
}

@Suite("Library state restore")
@MainActor
struct LibraryRestoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "mycms-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("A first launch opens on Blog posts, All, nothing selected")
    func firstLaunchDefaults() throws {
        let database = try MyCMS.Database.inMemory()
        let model = LibraryModel(store: DocumentStore(database: database), defaults: makeDefaults())

        #expect(model.collection == .blog)
        #expect(model.filter == .all)
        #expect(model.selectedID == nil)
    }

    @Test("All three stored values come back, not just the first one read")
    func restoresEveryValue() throws {
        let database = try MyCMS.Database.inMemory()
        let store = DocumentStore(database: database)
        let defaults = makeDefaults()
        let id = UUID()

        defaults.set("projects", forKey: "library.collection")
        defaults.set("published", forKey: "library.filter")
        defaults.set(id.uuidString, forKey: "library.selectedDocumentID")

        let model = LibraryModel(store: store, defaults: defaults)

        // Restoring the collection used to fire persist(), which overwrote the other two keys
        // with their defaults before they were ever read.
        #expect(model.collection == .projects)
        #expect(model.filter == .published)
        #expect(model.selectedID == id)
    }

    @Test("Changing the scope writes all three back")
    func persistsScope() throws {
        let database = try MyCMS.Database.inMemory()
        let defaults = makeDefaults()
        let model = LibraryModel(store: DocumentStore(database: database), defaults: defaults)

        model.collection = .projects
        model.filter = .drafts

        #expect(defaults.string(forKey: "library.collection") == "projects")
        #expect(defaults.string(forKey: "library.filter") == "drafts")
    }

    @Test("Counts come from the whole list, so every filter can be counted at once")
    func countsSpanEveryFilter() async throws {
        let database = try MyCMS.Database.inMemory()
        let store = DocumentStore(database: database)
        let model = LibraryModel(store: store, defaults: makeDefaults())

        let a = try store.create(collection: .blog)
        _ = try store.create(collection: .blog)
        _ = try store.create(collection: .projects)
        try store.update(id: a.id, Column("state").set(to: "published"))

        model.start()
        try await eventually("the observation to deliver all three documents") {
            model.allDocuments.count == 3
        }

        #expect(model.count(for: .all, in: .blog) == 2)
        #expect(model.count(for: .drafts, in: .blog) == 1)
        #expect(model.count(for: .published, in: .blog) == 1)
        #expect(model.count(for: .all, in: .projects) == 1)
        model.stop()
    }
}

@Suite("Word count, images")
struct ImageWordCountTests {
    @Test("An image contributes no words, because its alt text is not prose you read")
    func imageCountsZero() {
        #expect(DocumentSession.countWords("![a picture of a cat](/img/cat.png)") == 0)
        #expect(DocumentSession.countWords("Before ![a cat](/img/cat.png) after") == 2)
    }

    @Test("A link still counts its text after the reorder")
    func linkStillCountsItsText() {
        #expect(DocumentSession.countWords("See [the docs](https://example.com/a)") == 3)
        #expect(DocumentSession.countWords("[one](a) [two](b)") == 2)
    }
}
