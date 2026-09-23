import Foundation
import GRDB

/// The key and value table, typed: strings, dates, and `Codable` values as JSON.
///
/// Every setting the app keeps lives here, under a name from `SettingsKey`. A read of a missing
/// key is nil, not an error, and a row that will not decode reads as absent rather than throwing,
/// so a hand edited value can never stop the app launching.
nonisolated struct SettingsStore: Sendable {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func string(forKey key: String) throws -> String? {
        try database.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
        }
    }

    func set(_ value: String?, forKey key: String) throws {
        try write([key: value])
    }

    // Several rows at once, so a half written repo record can never exist on disk.
    func write(_ pairs: [String: String?]) throws {
        guard !pairs.isEmpty else { return }

        try database.write { db in
            for (key, value) in pairs {
                if let value {
                    try db.execute(
                        sql: """
                            INSERT INTO settings (key, value) VALUES (?, ?)
                            ON CONFLICT(key) DO UPDATE SET value = excluded.value
                            """,
                        arguments: [key, value])
                } else {
                    try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
                }
            }
        }
    }

    // A malformed row is treated as absent, because a settings value is never worth a crash.
    func decode<T: Decodable>(_ type: T.Type, forKey key: String) throws -> T? {
        guard let text = try string(forKey: key) else { return nil }
        return try? DatabaseJSON.decode(type, from: text)
    }

    func encode(_ value: (some Encodable)?, forKey key: String) throws {
        guard let value else {
            try set(nil, forKey: key)
            return
        }
        try set(DatabaseJSON.encode(value), forKey: key)
    }

    func date(forKey key: String) throws -> Date? {
        try string(forKey: key).flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    func setDate(_ date: Date?, forKey key: String) throws {
        try set(date.map { ISO8601DateFormatter().string(from: $0) }, forKey: key)
    }
}

// Every settings key the app writes, named once so no caller spells one by hand.
nonisolated enum SettingsKey {
    static let repoPath = "repo.path"
    static let repoRemoteName = "repo.remoteName"
    static let repoRemoteUrl = "repo.remoteUrl"
    static let repoBranch = "repo.branch"
    static let repoWasDirtyAtSetup = "repo.wasDirtyAtSetup"
    static let setupCompletedAt = "setup.completedAt"
    static let checkGit = "check.git"
    static let checkOllama = "check.ollama"
    static let ollamaModel = "ollama.model"
    static let scanLastRunAt = "scan.lastRunAt"
    static let editorShowMarkers = "editor.showMarkers"
    static let editorFontSize = "editor.fontSize"
    static let ollamaURL = "ollama.url"
    static let aiGrammarEnabled = "ai.grammarEnabled"
    static let aiPunctuationEnabled = "ai.punctuationEnabled"
    static let aiRewritesEnabled = "ai.rewritesEnabled"
    static let aiCheckDelaySeconds = "ai.checkDelaySeconds"
    static let exportLastFolder = "export.lastFolder"
}
