import Foundation
import GRDB

// One import's whole effect on the database. Built in Repository/ from what is on disk, applied
// here in a single transaction, so a failure part way through imports nothing at all.
nonisolated struct ImportPlan: Sendable {
    // A local draft moved aside because a published file already serves that slug.
    nonisolated struct Rename: Sendable, Equatable {
        var id: UUID
        var from: String
        var to: String
    }

    // An existing document taking on what the file says, with the hashes that prove it matches.
    nonisolated struct Adoption: Sendable, Equatable {
        var id: UUID
        var slug: String
        var title: String
        var description: String
        var bodyMd: String
        var tags: [String]
        var featured: Bool
        var publishDate: Date?
        var updatedDate: Date?
        var cover: String?
        var coverAlt: String
        var fields: DocumentFields
        var publishedHash: String
        var publishedAt: Date?
    }

    // Renames run first, or an insert would collide with the slug the draft is still holding.
    var renames: [Rename] = []
    var inserts: [Document] = []
    var adoptions: [Adoption] = []

    var isEmpty: Bool { renames.isEmpty && inserts.isEmpty && adoptions.isEmpty }
}

nonisolated extension DocumentStore {
    // The narrow rows the repo scan compares against what is on disk.
    func fileRefs() throws -> [DocumentFileRef] {
        try read { db in
            try DocumentFileRef.fetchAll(db, sql: "SELECT \(DocumentFileRef.selection) FROM documents")
        }
    }

    // Everything or nothing. Invariant 8 of spec 0004.
    func apply(_ plan: ImportPlan, at timestamp: Date) throws {
        guard !plan.isEmpty else { return }

        try write { db in
            for rename in plan.renames {
                try db.execute(
                    sql: "UPDATE documents SET slug = ?, updated_at = ? WHERE id = ?",
                    arguments: [rename.to, timestamp, rename.id.uuidString])
            }

            for document in plan.inserts {
                try document.insert(db)
            }

            for adoption in plan.adoptions {
                try db.execute(
                    sql: """
                        UPDATE documents SET
                            slug = ?, title = ?, description = ?, body_md = ?, tags = ?,
                            featured = ?, publish_date = ?, updated_date = ?, cover = ?,
                            cover_alt = ?, fields_json = ?, state = ?, published_slug = ?,
                            published_hash = ?, acknowledged_hash = NULL, published_at = ?,
                            updated_at = ?
                        WHERE id = ?
                        
                        """,
                    arguments: [
                        adoption.slug, adoption.title, adoption.description, adoption.bodyMd,
                        try DatabaseJSON.encode(adoption.tags), adoption.featured,
                        adoption.publishDate, adoption.updatedDate, adoption.cover,
                        adoption.coverAlt, try DatabaseJSON.encode(adoption.fields),
                        Document.State.published.rawValue, adoption.slug,
                        adoption.publishedHash, adoption.publishedAt,
                        adoption.publishedAt ?? timestamp,
                        adoption.id.uuidString,
                    ])
            }
        }
    }

    // Keeping the app's version. The hash you saw is remembered so the badge stops nagging.
    func acknowledge(id: UUID, fileHash: String) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE documents SET acknowledged_hash = ? WHERE id = ?",
                arguments: [fileHash, id.uuidString])
        }
    }

    // A repo swap invalidates every hash, because each one describes a file in the old repo.
    func clearPublishedHashes() throws {
        try write { db in
            try db.execute(sql: "UPDATE documents SET published_hash = NULL, acknowledged_hash = NULL")
        }
    }
}
