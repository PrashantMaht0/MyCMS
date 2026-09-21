import Foundation
import GRDB

// Every record maps snake case columns to camel case properties. Declared once here, never redeclared.
nonisolated protocol DatabaseRecord: Codable, FetchableRecord, PersistableRecord, Sendable {}

nonisolated extension DatabaseRecord {
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
}

// Rows the app only ever reads, so they carry the decoding half and nothing else.
nonisolated protocol DatabaseRow: Codable, FetchableRecord, Sendable {}

nonisolated extension DatabaseRow {
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
}

// The JSON columns are written by hand, so both sides use one encoder and one decoder.
nonisolated enum DatabaseJSON {
    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(text.utf8))
    }
}
