import Foundation
import GRDB

// The five tables that exist now and get their store methods in the feature that owns them:
// publishes in feature 7, ai_suggestions in 9, assets in 13, revisions in 14, settings in 21.
// Each writes document_id as text by hand, so the foreign key matches documents.id and cascades.

// A snapshot of the whole document minus the body, taken on publish, before a rewrite, or while editing.
nonisolated struct Revision: DatabaseRecord, Identifiable, Equatable {
    static let databaseTableName = "revisions"

    var id: Int64?
    var documentId: UUID
    var bodyMd: String
    var snapshotJson: String
    var reason: String
    var createdAt: Date

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["document_id"] = documentId.uuidString
        container["body_md"] = bodyMd
        container["snapshot_json"] = snapshotJson
        container["reason"] = reason
        container["created_at"] = createdAt
    }
}

// An image copied into app storage, waiting to be written into the repo on publish.
nonisolated struct Asset: DatabaseRecord, Identifiable, Equatable {
    static let databaseTableName = "assets"

    var id: Int64?
    var documentId: UUID
    var fileName: String
    var storedPath: String
    var sha256: String
    var alt: String
    var createdAt: Date
    var width: Int?
    var height: Int?

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["document_id"] = documentId.uuidString
        container["file_name"] = fileName
        container["stored_path"] = storedPath
        container["sha256"] = sha256
        container["alt"] = alt
        container["created_at"] = createdAt
        container["width"] = width
        container["height"] = height
    }
}

// Every suggestion the model made and what became of it, kept so a prompt change can be judged.
nonisolated struct AISuggestion: DatabaseRecord, Identifiable, Equatable {
    static let databaseTableName = "ai_suggestions"

    var id: Int64?
    var documentId: UUID
    var kind: String
    var original: String
    var replacement: String
    var reason: String
    var model: String
    var promptVersion: String
    var latencyMs: Int
    var outcome: String
    var createdAt: Date
    var targetHash: String?

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["document_id"] = documentId.uuidString
        container["kind"] = kind
        container["original"] = original
        container["replacement"] = replacement
        container["reason"] = reason
        container["model"] = model
        container["prompt_version"] = promptVersion
        container["latency_ms"] = latencyMs
        container["outcome"] = outcome
        container["created_at"] = createdAt
        container["target_hash"] = targetHash
    }
}

// What was pushed and where. This row outlives the document, so it keeps its own collection and slug.
nonisolated struct Publish: DatabaseRecord, Identifiable, Equatable {
    static let databaseTableName = "publishes"

    var id: Int64?
    var documentId: UUID?
    var collection: String
    var slug: String
    var commitSha: String?
    var filesJson: String
    var status: String
    var error: String?
    var createdAt: Date

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id
        container["document_id"] = documentId?.uuidString
        container["collection"] = collection
        container["slug"] = slug
        container["commit_sha"] = commitSha
        container["files_json"] = filesJson
        container["status"] = status
        container["error"] = error
        container["created_at"] = createdAt
    }
}

// One preference. Feature 21 puts the real reading and writing on top of this.
nonisolated struct Setting: DatabaseRecord, Identifiable, Equatable {
    static let databaseTableName = "settings"

    var key: String
    var value: String

    var id: String { key }
}
