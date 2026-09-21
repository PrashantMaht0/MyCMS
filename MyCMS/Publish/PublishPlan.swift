import Foundation

// Everything one publish will do, decided before any of it happens. The sheet shows this list,
// the stager stages exactly this list, and a rollback undoes exactly this list.
nonisolated struct PublishPlan: Sendable {
    enum Change: Sendable, Equatable {
        case write(path: String, data: Data)
        case copy(path: String, from: URL)
        case delete(path: String)

        var path: String {
            switch self {
            case .write(let path, _), .copy(let path, _), .delete(let path): path
            }
        }

        var verb: String {
            switch self {
            case .write: "Write"
            case .copy: "Copy picture"
            case .delete: "Delete"
            }
        }
    }

    let documentID: UUID
    let collection: Document.Collection
    let slug: String
    let changes: [Change]
    let defaultMessage: String
    let publishDate: Date
    let updatedDate: Date?
    // sha256 of the content file's bytes, recorded as published_hash once committed.
    let fileHash: String
    let isFirstPublish: Bool

    var paths: [String] { changes.map(\.path) }

    // Invariant 3. The only places the app may ever write in your repository.
    static func isAllowed(_ path: String) -> Bool {
        !path.contains("..")
            && (path.hasPrefix("src/content/") || path.hasPrefix("src/assets/") || path == Redirects.path)
    }
}

// AC-41. src/redirects.ts is edited in place, one entry before the closing brace, or not at all.
nonisolated enum Redirects {
    static let path = "src/redirects.ts"
    private static let declaration = "export const redirects: Record<string, string> = {"

    static func adding(from old: String, to new: String, in text: String) throws -> String {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == declaration }) else {
            throw PublishError.redirectsUnreadable(reason: "It has no `\(declaration)` line.")
        }
        guard let close = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "};" }) else {
            throw PublishError.redirectsUnreadable(reason: "The redirects object is never closed with `};`.")
        }

        let entry = "  '\(old)': '\(new)',"
        // A second rename back and forth would otherwise stack identical lines.
        guard !lines[start...close].contains(where: { $0.trimmingCharacters(in: .whitespaces) == entry.trimmingCharacters(in: .whitespaces) })
        else { return text }

        var updated = lines
        updated.insert(entry, at: close)
        return updated.joined(separator: "\n")
    }
}
