import Foundation
import GRDB
import Testing

@testable import MyCMS

// A clock the tests move by hand, so every timestamp in an assertion is a known value.
private nonisolated final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current += seconds
    }

    var provider: @Sendable () -> Date {
        { [self] in now }
    }
}

// Every test gets a freshly migrated in memory database and touches no file on disk.
private func makeStore(clock: TestClock = TestClock()) throws -> (MyCMS.Database, DocumentStore) {
    let database = try MyCMS.Database.inMemory()
    return (database, DocumentStore(database: database, now: clock.provider))
}

@Suite("Schema")
struct SchemaTests {
    @Test("A fresh migration creates every table and the search index")
    func createsEveryTable() throws {
        let database = try MyCMS.Database.inMemory()

        try database.read { db in
            for table in ["documents", "revisions", "assets", "ai_suggestions", "publishes", "settings"] {
                let exists = try db.tableExists(table)
                #expect(exists, "\(table) is missing")
            }
            let searchIndexExists = try db.tableExists("documents_fts")
            #expect(searchIndexExists)
        }
    }

    @Test("The documents table has the columns, nullability and defaults the spec fixes")
    func documentsColumnsMatchTheSpec() throws {
        let database = try MyCMS.Database.inMemory()

        try database.read { db in
            let columns = try db.columns(in: "documents")
            let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })

            let notNull = [
                "id", "collection", "title", "description", "body_md", "tags", "featured",
                "cover_alt", "fields_json", "state", "created_at", "updated_at",
            ]
            for name in notNull {
                #expect(byName[name]?.isNotNull == true, "\(name) should be not null")
            }

            let nullable = [
                "slug", "publish_date", "updated_date", "cover",
                "published_slug", "published_hash", "published_at",
            ]
            for name in nullable {
                #expect(byName[name]?.isNotNull == false, "\(name) should be nullable")
            }

            #expect(byName["title"]?.defaultValueSQL == "''")
            #expect(byName["tags"]?.defaultValueSQL == "'[]'")
            #expect(byName["fields_json"]?.defaultValueSQL == "'{}'")
            #expect(byName["state"]?.defaultValueSQL == "'draft'")
            #expect(byName["is_modified"] != nil)
        }
    }

    @Test("The indexes the queries depend on exist, and the slug one is unique and partial")
    func indexesExist() throws {
        let database = try MyCMS.Database.inMemory()

        try database.read { db in
            let documentIndexes = try db.indexes(on: "documents")
            let slug = documentIndexes.first { $0.name == "documents_on_collection_slug" }
            #expect(slug?.isUnique == true)
            #expect(slug?.columns == ["collection", "slug"])
            #expect(documentIndexes.contains { $0.name == "documents_on_state_updated_at" })
            #expect(documentIndexes.contains { $0.name == "documents_on_published_hash" })

            // Partial, so untitled drafts are not constrained. SQLite records that on the index itself.
            let isPartial = try Bool.fetchOne(
                db,
                sql: "SELECT partial FROM pragma_index_list('documents') WHERE name = ?",
                arguments: ["documents_on_collection_slug"]
            )
            #expect(isPartial == true)

            for table in ["revisions", "assets", "ai_suggestions", "publishes"] {
                let indexes = try db.indexes(on: table)
                #expect(indexes.contains { $0.name == "\(table)_on_document_id" })
            }
        }
    }

    @Test("Migrating a second time changes nothing")
    func migratingTwiceIsASecondNoOp() throws {
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue)

        let before = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name || ' ' || COALESCE(sql, '') FROM sqlite_master ORDER BY name")
        }

        try Migrations.migrator.migrate(queue)

        let after = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name || ' ' || COALESCE(sql, '') FROM sqlite_master ORDER BY name")
        }

        #expect(before == after)
    }

    @Test("The database rejects a collection or state value it does not own")
    func checksRejectUnknownValues() throws {
        let database = try MyCMS.Database.inMemory()

        try database.write { db in
            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: """
                        INSERT INTO documents (id, collection, state, created_at, updated_at)
                        VALUES ('a', 'notes', 'draft', '2026-01-01', '2026-01-01')
                        """)
            }

            #expect(throws: DatabaseError.self) {
                try db.execute(
                    sql: """
                        INSERT INTO documents (id, collection, state, created_at, updated_at)
                        VALUES ('b', 'blog', 'modified', '2026-01-01', '2026-01-01')
                        """)
            }
        }
    }

    @Test("The child tables carry no check constraint, because their value lists are not designed yet")
    func childTablesAreUnconstrained() throws {
        let database = try MyCMS.Database.inMemory()

        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO documents (id, collection, state, created_at, updated_at)
                    VALUES ('doc', 'blog', 'draft', '2026-01-01', '2026-01-01')
                    """)

            // An outcome nobody has named yet is still accepted.
            try db.execute(
                sql: """
                    INSERT INTO ai_suggestions
                        (document_id, kind, original, replacement, reason, model,
                         prompt_version, latency_ms, outcome, created_at)
                    VALUES ('doc', 'invented', 'a', 'b', 'c', 'm', 'v1', 10, 'invented', '2026-01-01')
                    """)
        }
    }
}

@Suite("Document round trip")
struct DocumentRoundTripTests {
    @Test("A created document reads back equal in every field")
    func readsBackEqual() throws {
        let clock = TestClock()
        let (database, documents) = try makeStore(clock: clock)

        var document = try documents.create(collection: .blog)
        document.title = "A post about writing"
        document.description = "Short"
        document.bodyMd = "# Hello\n\nSome words."
        document.tags = ["swift", "macos"]
        document.featured = true
        document.coverAlt = "A screenshot"
        document.fields = DocumentFields(canonicalUrl: URL(string: "https://example.com/a"), role: "Author")

        try database.write { db in try document.update(db) }

        let fetched = try #require(try documents.fetch(id: document.id))
        #expect(fetched.id == document.id)
        #expect(fetched.title == document.title)
        #expect(fetched.bodyMd == document.bodyMd)
        #expect(fetched.tags == ["swift", "macos"])
        #expect(fetched.featured == true)
        #expect(fetched.fields == document.fields)
        #expect(fetched.state == .draft)
        #expect(fetched.createdAt == clock.now)
    }

    @Test("The store owns the id, the state, the slug and both timestamps")
    func storeOwnsTheGeneratedValues() throws {
        let clock = TestClock()
        let (_, documents) = try makeStore(clock: clock)

        let document = try documents.create(collection: .projects)

        #expect(document.slug == nil)
        #expect(document.state == .draft)
        #expect(document.createdAt == clock.now)
        #expect(document.updatedAt == clock.now)
        #expect(document.isModified == false)
    }

    @Test("The id is stored as text, so it is readable and the foreign keys match it")
    func idIsStoredAsText() throws {
        let (database, documents) = try makeStore()
        let document = try documents.create(collection: .blog)

        let stored = try database.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM documents")
        }

        #expect(stored == document.id.uuidString)
    }

    @Test("A column targeted update writes only the columns it names")
    func updateTouchesOnlyItsOwnColumns() throws {
        let clock = TestClock()
        let (_, documents) = try makeStore(clock: clock)
        let document = try documents.create(collection: .blog)

        // Stands in for a change written by another code path between a read and a write.
        try documents.update(id: document.id, Column("featured").set(to: true))
        clock.advance(by: 60)
        try documents.update(id: document.id, Column("body_md").set(to: "new text"))

        let fetched = try #require(try documents.fetch(id: document.id))
        #expect(fetched.featured == true, "the body write reverted an unrelated column")
        #expect(fetched.bodyMd == "new text")
        #expect(fetched.updatedAt == clock.now)
    }

    @Test("Updating a document that is gone reports notFound")
    func updateReportsNotFound() throws {
        let (_, documents) = try makeStore()

        #expect(throws: DataError.self) {
            try documents.update(id: UUID(), Column("title").set(to: "x"))
        }
    }

    @Test("Deleting removes the document, and deleting it twice reports notFound")
    func deleteRemovesTheDocument() throws {
        let (_, documents) = try makeStore()
        let document = try documents.create(collection: .blog)

        try documents.delete(id: document.id)
        #expect(try documents.fetch(id: document.id) == nil)

        #expect(throws: DataError.self) {
            try documents.delete(id: document.id)
        }
    }
}

@Suite("Slug constraint")
struct SlugConstraintTests {
    @Test("Any number of null slugs coexist, and a duplicate real slug is refused by the database")
    func partialUniqueIndexHolds() throws {
        let (_, documents) = try makeStore()

        let first = try documents.create(collection: .blog)
        let second = try documents.create(collection: .blog)
        let third = try documents.create(collection: .blog)
        #expect(try documents.list().count == 3)

        try documents.update(id: first.id, Column("slug").set(to: "a-post"))

        do {
            try documents.update(id: second.id, Column("slug").set(to: "a-post"))
            Issue.record("Expected the duplicate slug to be refused")
        } catch let error as DataError {
            guard case .slugTaken = error else {
                Issue.record("Expected slugTaken, got \(error)")
                return
            }
        }

        // The same slug in the other collection is a different file path, so it is allowed.
        try documents.update(id: third.id, Column("collection").set(to: "projects"))
        try documents.update(id: third.id, Column("slug").set(to: "a-post"))
    }
}

@Suite("Cascade")
struct CascadeTests {
    @Test("Deleting a document takes its children and leaves the publish record behind")
    func deleteCascadesButKeepsPublishes() throws {
        let (database, documents) = try makeStore()
        let document = try documents.create(collection: .blog)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        try database.write { db in
            try Revision(
                id: nil, documentId: document.id, bodyMd: "old", snapshotJson: "{}",
                reason: "publish", createdAt: timestamp
            ).insert(db)

            try Asset(
                id: nil, documentId: document.id, fileName: "a.png", storedPath: "/tmp/a.png",
                sha256: "abc", alt: "A picture", createdAt: timestamp
            ).insert(db)

            try AISuggestion(
                id: nil, documentId: document.id, kind: "punctuation", original: "a", replacement: "b",
                reason: "c", model: "qwen3", promptVersion: "v1", latencyMs: 12,
                outcome: "accepted", createdAt: timestamp
            ).insert(db)

            try Publish(
                id: nil, documentId: document.id, collection: "blog", slug: "a-post",
                commitSha: "deadbeef", filesJson: "[]", status: "pushed", error: nil, createdAt: timestamp
            ).insert(db)
        }

        try documents.delete(id: document.id)

        try database.read { db in
            let revisions = try Revision.fetchCount(db)
            let assets = try Asset.fetchCount(db)
            let suggestions = try AISuggestion.fetchCount(db)
            #expect(revisions == 0)
            #expect(assets == 0)
            #expect(suggestions == 0)

            let publish = try #require(try Publish.fetchOne(db))
            #expect(publish.documentId == nil)
            #expect(publish.collection == "blog")
            #expect(publish.slug == "a-post")
            #expect(publish.commitSha == "deadbeef")
        }
    }
}

@Suite("Derived modified state")
struct ModifiedStateTests {
    @Test("A published document edited after publishing reads as modified on every read path")
    func modifiedIsDerivedOnEveryReadPath() throws {
        let clock = TestClock()
        let (_, documents) = try makeStore(clock: clock)
        let document = try documents.create(collection: .blog)

        try documents.update(id: document.id, Column("title").set(to: "Findable words here"))

        // Published a minute ago, edited just now.
        clock.advance(by: 60)
        try documents.update(
            id: document.id,
            Column("state").set(to: "published"),
            Column("slug").set(to: "findable"),
            Column("published_at").set(to: clock.now.addingTimeInterval(-30))
        )

        let fetched = try #require(try documents.fetch(id: document.id))
        #expect(fetched.state == .published, "state itself never says modified")
        #expect(fetched.isModified == true)

        let listed = try #require(try documents.list().first)
        #expect(listed.isModified == true)

        let found = try #require(try documents.search("findable").first)
        #expect(found.isModified == true)
    }

    @Test("A published document that has not been touched since is not modified")
    func publishedAndUntouchedIsNotModified() throws {
        let clock = TestClock()
        let (_, documents) = try makeStore(clock: clock)
        let document = try documents.create(collection: .blog)

        try documents.update(
            id: document.id,
            Column("state").set(to: "published"),
            Column("published_at").set(to: clock.now.addingTimeInterval(30))
        )

        let fetched = try #require(try documents.fetch(id: document.id))
        #expect(fetched.isModified == false)
    }

    @Test("A draft is never modified, even with no published_at at all")
    func draftIsNeverModified() throws {
        let (_, documents) = try makeStore()
        let document = try documents.create(collection: .blog)

        #expect(try documents.fetch(id: document.id)?.isModified == false)
    }
}

@Suite("List and observation")
struct ListTests {
    @Test("The list is ordered by updated_at descending and can be filtered by state")
    func listOrdersAndFilters() throws {
        let clock = TestClock()
        let (_, documents) = try makeStore(clock: clock)

        let older = try documents.create(collection: .blog)
        clock.advance(by: 60)
        let newer = try documents.create(collection: .projects)

        #expect(try documents.list().map(\.id) == [newer.id, older.id])

        clock.advance(by: 60)
        try documents.update(id: older.id, Column("state").set(to: "published"))

        #expect(try documents.list(state: .published).map(\.id) == [older.id])
        #expect(try documents.list(state: .draft).map(\.id) == [newer.id])
    }

    @Test("A write from outside the observing code delivers a new list value")
    func observationDeliversAfterAWrite() async throws {
        let (_, documents) = try makeStore()
        var values = try documents.observeList().makeAsyncIterator()

        let first = try await values.next()
        #expect(first?.isEmpty == true)

        _ = try documents.create(collection: .blog)

        let second = try await values.next()
        #expect(second?.count == 1)
    }
}

@Suite("Search")
struct SearchTests {
    @Test("Search finds a word in the body, follows an edit, and forgets a deleted document")
    func searchStaysCorrect() throws {
        let (_, documents) = try makeStore()
        let document = try documents.create(collection: .blog)

        try documents.update(id: document.id, Column("body_md").set(to: "A note about kayaking in winter"))
        #expect(try documents.search("kayaking").map(\.id) == [document.id])

        try documents.update(id: document.id, Column("body_md").set(to: "A longer note about kayaking"))
        #expect(try documents.search("kayaking").map(\.id) == [document.id])

        try documents.update(id: document.id, Column("body_md").set(to: "Nothing about boats"))
        #expect(try documents.search("kayaking").isEmpty)

        try documents.update(id: document.id, Column("title").set(to: "Kayaking again"))
        #expect(try documents.search("kayaking").map(\.id) == [document.id])

        try documents.delete(id: document.id)
        #expect(try documents.search("kayaking").isEmpty)
    }

    @Test("The porter tokenizer matches a different form of the same word")
    func searchStemsWords() throws {
        let (_, documents) = try makeStore()
        let document = try documents.create(collection: .blog)

        try documents.update(id: document.id, Column("body_md").set(to: "Thoughts on writing every day"))

        #expect(try documents.search("write").map(\.id) == [document.id])
    }

    @Test("An empty query returns nothing rather than everything")
    func emptyQueryFindsNothing() throws {
        let (_, documents) = try makeStore()
        _ = try documents.create(collection: .blog)

        #expect(try documents.search("   ").isEmpty)
    }
}

@Suite("Open failure")
struct OpenFailureTests {
    @Test("A database in an unwritable folder reports the real error and the resolved path")
    func reportsThePathAndTheError() {
        // /dev/null is a file, so a folder can never be created inside it.
        let database = MyCMS.Database(url: URL(fileURLWithPath: "/dev/null/nope/mycms.sqlite"))

        do {
            _ = try database.open()
            Issue.record("Expected the open to fail")
        } catch let error as DataError {
            #expect(error.path != nil)
            #expect(error.errorDescription?.isEmpty == false)
        } catch {
            Issue.record("Expected a DataError, got \(error)")
        }
    }

    @Test("Using the database before it is opened is reported rather than crashing")
    func reportsUseBeforeOpen() {
        let database = MyCMS.Database(url: URL(fileURLWithPath: "/tmp/never-opened.sqlite"))

        #expect(throws: DataError.self) {
            try database.read { _ in }
        }
    }
}
