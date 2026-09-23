import Foundation
import GRDB

/// Every AI suggestion's final state, the dismissal memory, and the "already checked" cache.
///
/// All three live in `ai_suggestions`, keyed on the exact paragraph text through `target_hash`, so
/// editing a paragraph makes its old verdicts stop applying without deleting anything.
nonisolated struct SuggestionStore: Sendable {
    // Where a suggestion ended up, which is also the dismissal memory.
    enum Outcome: String, Sendable {
        case shown, accepted, dismissed, stale, dropped
    }

    private let database: Database

    init(database: Database) {
        self.database = database
    }

    @discardableResult
    func record(_ row: AISuggestion) throws -> Int64 {
        try database.write { db in
            try row.insert(db)
            return db.lastInsertedRowID
        }
    }

    // A shown suggestion moves on to its final state rather than gaining a second row.
    func resolve(id: Int64, as outcome: Outcome) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE ai_suggestions SET outcome = ? WHERE id = ?", arguments: [outcome.rawValue, id])
        }
    }

    // AC-31. Keyed on the paragraph and the original text, and it survives a relaunch.
    func isDismissed(documentID: UUID, targetHash: String, original: String) throws -> Bool {
        try database.read { db in
            try AISuggestion
                .filter(Column("document_id") == documentID.uuidString)
                .filter(Column("target_hash") == targetHash)
                .filter(Column("outcome") == Outcome.dismissed.rawValue)
                .filter(Column("original") == original)
                .fetchCount(db) > 0
        }
    }

    // AC-18. A paragraph already checked with this model and prompt is never asked again.
    func wasChecked(documentID: UUID, targetHash: String, model: String, promptVersion: String) throws -> Bool {
        try database.read { db in
            try AISuggestion
                .filter(Column("document_id") == documentID.uuidString)
                .filter(Column("target_hash") == targetHash)
                .filter(Column("model") == model)
                .filter(Column("prompt_version") == promptVersion)
                .fetchCount(db) > 0
        }
    }

    // A cache hit shows what that check found before, still waiting on you, without asking again.
    func pending(documentID: UUID, targetHash: String, model: String, promptVersion: String) throws -> [AISuggestion] {
        try database.read { db in
            try AISuggestion
                .filter(Column("document_id") == documentID.uuidString)
                .filter(Column("target_hash") == targetHash)
                .filter(Column("model") == model)
                .filter(Column("prompt_version") == promptVersion)
                .filter(Column("outcome") == Outcome.shown.rawValue)
                .filter(Column("kind") != Self.checkMarker)
                .fetchAll(db)
        }
    }

    // One row per paragraph checked, so a paragraph that came back clean is cached too.
    static let checkMarker = "check"

    // AC-27. The share of everything the model proposed that the gate refused.
    func dropRate(model: String, promptVersion: String) throws -> Double {
        try database.read { db in
            let base = AISuggestion.filter(Column("model") == model).filter(Column("prompt_version") == promptVersion)
                .filter(Column("kind") != Self.checkMarker)
            let total = try base.fetchCount(db)
            guard total > 0 else { return 0 }
            let dropped = try base.filter(Column("outcome") == Outcome.dropped.rawValue).fetchCount(db)
            return Double(dropped) / Double(total)
        }
    }
}
