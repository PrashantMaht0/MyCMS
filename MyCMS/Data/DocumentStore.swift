import Foundation
import GRDB

// Everything the app does to documents. Holds the shared connection, never its own.
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

    func search(_ query: String) throws -> [DocumentListItem] {
        guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return [] }

        return try database.read { db in
            try DocumentListItem.fetchAll(db, sql: """
                SELECT \(DocumentListItem.selection)
                FROM documents
                JOIN documents_fts ON documents_fts.rowid = documents.rowid
                WHERE documents_fts MATCH ?
                ORDER BY documents.updated_at DESC
                """, arguments: [pattern])
        }
    }

    // The child rows go with it, by SQLite cascade rather than by anything written here.
    func delete(id: UUID) throws {
        try database.write { db in
            let deleted = try Document.filter(Column("id") == id.uuidString).deleteAll(db)
            guard deleted > 0 else { throw DataError.notFound }
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
