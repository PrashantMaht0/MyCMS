import Foundation
import GRDB

/// Everything the app does to documents: create, read, list, search, update, delete.
///
/// Holds the shared `Database`, never its own file. Writes go through `update(id:_:)` with typed
/// column assignments, which also stamps `updated_at`. Throws `DataError.notFound` for an id that
/// is gone, `.slugTaken` when two documents in one collection claim a slug, and
/// `.publishedCannotBeDeleted` when a delete would remove something live on the site.
/// `observeList` streams list rows to the library on the main queue.
nonisolated struct DocumentStore: Sendable {
    private let database: Database
    private let now: @Sendable () -> Date

    // The clock is injected so a test can fix the timestamps it checks.
    init(database: Database, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.now = now
    }

    // The id and both timestamps come from the store. A caller never supplies them.
    func create(collection: Document.Collection) throws -> Document {
        let timestamp = now()
        let document = Document(
            id: UUID(),
            collection: collection,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        try database.write { db in
            try document.insert(db)
        }
        return document
    }

    // The import extension in ImportPlan.swift runs its own SQL, so it reaches the connection here.
    func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try database.read(block)
    }

    func write<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try database.write(block)
    }

    func fetch(id: UUID) throws -> Document? {
        try database.read { db in
            try Document.filter(Column("id") == id.uuidString).fetchOne(db)
        }
    }

    func list(state: Document.State? = nil) throws -> [DocumentListItem] {
        try database.read { db in
            try Self.listItems(db, state: state)
        }
    }

    // Values arrive on the main queue. Hopping to the main actor is the consumer's job, because
    // Data/ cannot import SwiftUI and so cannot promise more than this.
    func observeList(state: Document.State? = nil) throws -> AsyncValueObservation<[DocumentListItem]> {
        let queue = try database.queue
        let observation = ValueObservation.tracking { db in
            try Self.listItems(db, state: state)
        }
        return observation.values(in: queue, scheduling: .async(onQueue: .main))
    }

    // Assignments are typed, so a mistyped column fails to compile rather than fail during an autosave.
    func update(id: UUID, _ assignments: ColumnAssignment...) throws {
        try update(id: id, assignments)
    }

    func update(id: UUID, _ assignments: [ColumnAssignment]) throws {
        guard !assignments.isEmpty else { return }

        try database.write { db in
            let all = assignments + [Column("updated_at").set(to: now())]
            let updated: Int
            do {
                updated = try Document.filter(Column("id") == id.uuidString).updateAll(db, all)
            } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
                // Feature 5 matches on this, never on a raw SQLite result code.
                throw DataError.slugTaken
            }
            guard updated > 0 else { throw DataError.notFound }
        }
    }

    // Resolves a slug to one that is free in this collection, so the caller never writes a
    // slug the database would reject. A rejected slug would take the whole update down with it.
    func claimSlug(_ base: String?, for id: UUID, in collection: Document.Collection) throws -> String? {
        guard let base else { return nil }

        return try database.read { db in
            for attempt in 1...100 {
                let candidate = SlugRule.candidate(base, attempt: attempt)
                let taken =
                    try Document
                    .filter(Column("collection") == collection.rawValue)
                    .filter(Column("slug") == candidate)
                    .filter(Column("id") != id.uuidString)
                    .fetchCount(db) > 0
                if !taken { return candidate }
            }
            return "\(base)-\(UUID().uuidString.prefix(8).lowercased())"
        }
    }

    // Spec 0006 A, AC-8. An exact match only, so a taken slug is refused rather than suffixed.
    func isSlugTaken(_ slug: String, in collection: Document.Collection, except id: UUID) throws -> Bool {
        try database.read { db in
            try Document
                .filter(Column("collection") == collection.rawValue)
                .filter(Column("slug") == slug)
                .filter(Column("id") != id.uuidString)
                .fetchCount(db) > 0
        }
    }

    func search(_ query: String) throws -> [DocumentListItem] {
        guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return [] }

        return try database.read { db in
            try DocumentListItem.fetchAll(
                db,
                sql: """
                    SELECT \(DocumentListItem.selection)
                    FROM documents
                    JOIN documents_fts ON documents_fts.rowid = documents.rowid
                    WHERE documents_fts MATCH ?
                    ORDER BY documents.updated_at DESC
                    """, arguments: [pattern])
        }
    }

    // The child rows go with it, by SQLite cascade rather than by anything written here.
    // Spec 0006 A, AC-7. Only a draft; a live post has to be unpublished first.
    func delete(id: UUID) throws {
        try database.write { db in
            let row = Document.filter(Column("id") == id.uuidString)
            guard let state = try String.fetchOne(db, row.select(Column("state"))) else { throw DataError.notFound }
            guard state != Document.State.published.rawValue else { throw DataError.publishedCannotBeDeleted }
            _ = try row.deleteAll(db)
        }
    }

    private static func listItems(_ db: GRDB.Database, state: Document.State?) throws -> [DocumentListItem] {
        var sql = "SELECT \(DocumentListItem.selection) FROM documents"
        let arguments: StatementArguments

        if let state {
            sql += " WHERE documents.state = ?"
            arguments = [state.rawValue]
        } else {
            arguments = []
        }

        sql += " ORDER BY documents.updated_at DESC"
        return try DocumentListItem.fetchAll(db, sql: sql, arguments: arguments)
    }
}
