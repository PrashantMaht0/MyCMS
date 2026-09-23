import Foundation
import GRDB

/// The whole database schema, as one registered migration.
///
/// v1 is rewritten rather than appended to while the app has never shipped, so there is one
/// definition to read rather than a chain of deltas. Creates documents plus its child tables
/// (revisions, assets, ai_suggestions, publishes, settings) and the full text search index.
nonisolated enum Migrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: createSchema)
        migrator.registerMigration("v2", migrate: addAcknowledgedHash)
        migrator.registerMigration("v3", migrate: addAssetSize)
        migrator.registerMigration("v4", migrate: addSuggestionTargetHash)
        migrator.registerMigration("v5", migrate: indexRevisionsByTime)
        return migrator
    }

    private static func createSchema(_ db: GRDB.Database) throws {
        try createDocuments(db)
        try createChildTables(db)
        try createSettings(db)
        try createSearchIndex(db)
    }

    // Feature 20. The foreign hash you chose to keep the app's version over, so a divergence you
    // already answered stops showing a badge until the file changes again.
    private static func addAcknowledgedHash(_ db: GRDB.Database) throws {
        try db.alter(table: "documents") { t in
            t.add(column: "acknowledged_hash", .text)
        }
    }

    // Spec 0005 A. The stored image's size after the cap, so the editor can reserve its space
    // before decoding the file, which is what stops the text jumping as pictures load.
    private static func addAssetSize(_ db: GRDB.Database) throws {
        try db.alter(table: "assets") { t in
            t.add(column: "width", .integer)
            t.add(column: "height", .integer)
        }
    }

    // Spec 0005 B. The paragraph a suggestion was made against, which keys both the cache and the
    // dismissal memory, indexed because the dismissal lookup runs on every check.
    private static func addSuggestionTargetHash(_ db: GRDB.Database) throws {
        try db.alter(table: "ai_suggestions") { t in
            t.add(column: "target_hash", .text)
        }
        try db.create(
            index: "ai_suggestions_on_document_target_outcome",
            on: "ai_suggestions",
            columns: ["document_id", "target_hash", "outcome"])
    }

    // Spec 0005 D. The history panel always reads one document newest first.
    private static func indexRevisionsByTime(_ db: GRDB.Database) throws {
        try db.create(
            index: "revisions_on_document_created_at", on: "revisions", columns: ["document_id", "created_at"])
    }

    private static func createDocuments(_ db: GRDB.Database) throws {
        try db.create(table: "documents") { t in
            t.primaryKey("id", .text)
            t.column("collection", .text).notNull()
                .check { Document.Collection.allNames.contains($0) }
            // Null until the document has a title, so the partial index below leaves drafts alone.
            t.column("slug", .text)
            t.column("title", .text).notNull().defaults(to: "")
            t.column("description", .text).notNull().defaults(to: "")
            t.column("body_md", .text).notNull().defaults(to: "")
            t.column("tags", .text).notNull().defaults(to: "[]")
            t.column("featured", .boolean).notNull().defaults(to: false)
            t.column("publish_date", .text)
            t.column("updated_date", .text)
            t.column("cover", .text)
            t.column("cover_alt", .text).notNull().defaults(to: "")
            t.column("fields_json", .text).notNull().defaults(to: "{}")
            t.column("state", .text).notNull().defaults(to: Document.State.draft.rawValue)
                .check { Document.State.allNames.contains($0) }
            t.column("published_slug", .text)
            t.column("published_hash", .text)
            t.column("published_at", .text)
            t.column("created_at", .text).notNull()
            t.column("updated_at", .text).notNull()
            // Derived once here so no read path can disagree about what modified means.
            // COALESCE keeps the column a real boolean when published_at is still null.
            t.column("is_modified", .boolean)
                .generatedAs(sql: "COALESCE(state = 'published' AND updated_at > published_at, 0)")
        }

        // One document per published file path, while any number of untitled drafts coexist.
        try db.create(
            index: "documents_on_collection_slug",
            on: "documents",
            columns: ["collection", "slug"],
            options: .unique,
            condition: Column("slug") != nil)

        // The library's default view, the query the app runs most.
        try db.create(index: "documents_on_state_updated_at", on: "documents", columns: ["state", "updated_at"])

        // Feature 16 compares file hashes to detect edits made outside the app.
        try db.create(index: "documents_on_published_hash", on: "documents", columns: ["published_hash"])
    }

    private static func createChildTables(_ db: GRDB.Database) throws {
        try db.create(table: "revisions") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("document_id", .text).notNull()
                .references("documents", onDelete: .cascade)
            t.column("body_md", .text).notNull()
            t.column("snapshot_json", .text).notNull()
            t.column("reason", .text).notNull()
            t.column("created_at", .text).notNull()
        }

        try db.create(table: "assets") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("document_id", .text).notNull()
                .references("documents", onDelete: .cascade)
            t.column("file_name", .text).notNull()
            t.column("stored_path", .text).notNull()
            t.column("sha256", .text).notNull()
            t.column("alt", .text).notNull().defaults(to: "")
            t.column("created_at", .text).notNull()
        }

        try db.create(table: "ai_suggestions") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("document_id", .text).notNull()
                .references("documents", onDelete: .cascade)
            t.column("kind", .text).notNull()
            t.column("original", .text).notNull()
            t.column("replacement", .text).notNull()
            t.column("reason", .text).notNull()
            t.column("model", .text).notNull()
            t.column("prompt_version", .text).notNull()
            t.column("latency_ms", .integer).notNull()
            t.column("outcome", .text).notNull()
            t.column("created_at", .text).notNull()
        }

        // A publish record outlives the document it describes, so it keeps its own copy of where it went.
        try db.create(table: "publishes") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("document_id", .text)
                .references("documents", onDelete: .setNull)
            t.column("collection", .text).notNull()
            t.column("slug", .text).notNull()
            t.column("commit_sha", .text)
            t.column("files_json", .text).notNull()
            t.column("status", .text).notNull()
            t.column("error", .text)
            t.column("created_at", .text).notNull()
        }

        // SQLite does not index foreign keys for you, and every child table is read by document.
        for table in ["revisions", "assets", "ai_suggestions", "publishes"] {
            try db.create(index: "\(table)_on_document_id", on: table, columns: ["document_id"])
        }
    }

    private static func createSettings(_ db: GRDB.Database) throws {
        try db.create(table: "settings") { t in
            t.primaryKey("key", .text)
            t.column("value", .text).notNull()
        }
    }

    // synchronize generates the insert, update and delete triggers, so nothing reindexes by hand.
    private static func createSearchIndex(_ db: GRDB.Database) throws {
        try db.create(virtualTable: "documents_fts", using: FTS5()) { t in
            t.synchronize(withTable: "documents")
            // Porter over unicode61, so searching writing also finds write.
            t.tokenizer = .porter(wrapping: .unicode61())
            t.column("title")
            t.column("description")
            t.column("body_md")
        }
    }
}
