import Foundation
import GRDB

// Spec 0005 D. Snapshots of a document, kept until the document is deleted, so a publish, an
// accepted AI rewrite and an ordinary afternoon of editing can all be taken back.
nonisolated struct RevisionStore: Sendable {
    // Notes 5.3's four reasons. Only autosave is ever rate limited.
    enum Reason: String, Sendable, CaseIterable {
        case autosave
        case beforeAI = "before_ai"
        case publish
        case manual

        var label: String {
            switch self {
            case .autosave: "While editing"
            case .beforeAI: "Before an AI rewrite"
            case .publish: "Published"
            case .manual: "Before a restore"
            }
        }
    }

    // AC-49. At most one autosave snapshot per ten minutes of editing.
    static let autosaveInterval: TimeInterval = 10 * 60

    private let database: Database

    init(database: Database) {
        self.database = database
    }

    // Nil when the ten minute rule held an autosave back; the other three reasons always write.
    @discardableResult
    func snapshot(_ document: Document, body: String, reason: Reason, at date: Date = Date()) throws -> Int64? {
        try database.write { db in
            if reason == .autosave,
                let newest = try Revision
                    .filter(Column("document_id") == document.id.uuidString)
                    .filter(Column("reason") == Reason.autosave.rawValue)
                    .order(Column("created_at").desc)
                    .fetchOne(db),
                date.timeIntervalSince(newest.createdAt) < Self.autosaveInterval {
                return nil
            }

            var copy = document
            copy.bodyMd = body
            let revision = Revision(
                documentId: document.id, bodyMd: body, snapshotJson: try DatabaseJSON.encode(copy),
                reason: reason.rawValue, createdAt: date)
            try revision.insert(db)
            return db.lastInsertedRowID
        }
    }

    // AC-50. Newest first.
    func list(documentID: UUID) throws -> [Revision] {
        try database.read { db in
            try Revision
                .filter(Column("document_id") == documentID.uuidString)
                .order(Column("created_at").desc, Column("id").desc)
                .fetchAll(db)
        }
    }
}
