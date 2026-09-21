import Foundation
import GRDB
import Testing
@testable import MyCMS

@Suite("Revisions")
@MainActor
struct RevisionTests {
    private func fixture() throws -> (RevisionStore, DocumentStore, Document) {
        let database = try MyCMS.Database.inMemory()
        let documents = DocumentStore(database: database)
        return (RevisionStore(database: database), documents, try documents.create(collection: .blog))
    }

    @Test("Two edits inside ten minutes keep exactly one autosave version, per AC-49")
    func autosaveIsRateLimited() throws {
        let (store, _, document) = try fixture()
        let now = Date()
        #expect(try store.snapshot(document, body: "a", reason: .autosave, at: now) != nil)
        #expect(try store.snapshot(document, body: "b", reason: .autosave, at: now.addingTimeInterval(300)) == nil)
        #expect(try store.snapshot(document, body: "c", reason: .autosave, at: now.addingTimeInterval(601)) != nil)
        #expect(try store.list(documentID: document.id).count == 2)
    }

    @Test("A publish and a pre rewrite snapshot are never held back, per AC-49")
    func importantSnapshotsAlwaysWrite() throws {
        let (store, _, document) = try fixture()
        let now = Date()
        try store.snapshot(document, body: "a", reason: .autosave, at: now)
        #expect(try store.snapshot(document, body: "b", reason: .beforeAI, at: now.addingTimeInterval(1)) != nil)
        #expect(try store.snapshot(document, body: "c", reason: .publish, at: now.addingTimeInterval(2)) != nil)
        #expect(try store.list(documentID: document.id).map(\.reason) == ["publish", "before_ai", "autosave"])
    }

    @Test("Editing keeps the text from before the edit, and restoring keeps the text you left, per AC-52 and AC-54")
    func editAndRestore() async throws {
        let (store, documents, created) = try fixture()
        let session = DocumentSession(document: created, store: documents, revisions: store)
        session.body = "First draft."
        await session.flush()
        session.body = "Second draft."
        await session.flush()

        let autosave = try #require(try store.list(documentID: created.id).first)
        #expect(autosave.reason == "autosave")
        #expect(autosave.bodyMd == "")

        let older = Revision(documentId: created.id, bodyMd: "Old words.", snapshotJson: "{}", reason: "publish", createdAt: Date())
        session.restore(older)
        await session.flush()

        #expect(session.body == "Old words.")
        #expect(try documents.fetch(id: created.id)?.bodyMd == "Old words.")
        #expect(session.wordCount == 2)
        let newest = try #require(try store.list(documentID: created.id).first)
        #expect(newest.reason == "manual")
        #expect(newest.bodyMd == "Second draft.")
    }

    @Test("Deleting a document removes its versions, per AC-53")
    func cascade() throws {
        let (store, documents, document) = try fixture()
        try store.snapshot(document, body: "a", reason: .publish)
        try documents.delete(id: document.id)
        #expect(try store.list(documentID: document.id).isEmpty)
    }
}

@Suite("Word diff")
struct WordDiffTests {
    @Test("One changed word is one removal and one insertion, not a rewritten paragraph, per AC-51")
    func oneWord() {
        let runs = WordDiff.diff(from: "The quick brown fox jumps.", to: "The quick red fox jumps.")
        #expect(runs == [.same("The quick "), .removed("brown "), .inserted("red "), .same("fox jumps.")])
    }

    @Test("An inserted sentence and a deleted paragraph each come out as a single run")
    func sentencesAndParagraphs() {
        let inserted = WordDiff.diff(from: "One. Three.", to: "One. Two here. Three.")
        #expect(inserted.filter { if case .inserted = $0 { true } else { false } } == [.inserted("Two here. ")])

        let removed = WordDiff.diff(from: "Keep this.\n\nDrop this whole paragraph.", to: "Keep this.")
        #expect(removed.filter { if case .removed = $0 { true } else { false } }.count == 1)
    }

    @Test("Joining the runs of the new side gives back the new text")
    func reassembles() {
        let old = "Hello there, world.\nSecond line"
        let new = "Hello, world.\nSecond line here"
        let rebuilt = WordDiff.diff(from: old, to: new).compactMap { run -> String? in
            switch run {
            case .same(let s), .inserted(let s): s
            case .removed: nil
            }
        }.joined()
        #expect(rebuilt == new)
    }
}

