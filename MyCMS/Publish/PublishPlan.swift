import Foundation

/// Everything one publish or unpublish will do, decided before any of it happens.
///
/// The sheet shows this list, the stager stages exactly this list, and a rollback undoes exactly
/// this list. `action` says whether it publishes or takes down, `movedFrom` carries the old slug
/// when the address changes, and `isAllowed` is the invariant that no path outside `src/content/`,
/// `src/assets/` and `src/redirects.ts` can ever be written.
nonisolated struct PublishPlan: Sendable {
    // Spec 0006 A, AC-11. Recorded in the intent, so recovery knows what it is finishing.
    enum Action: String, Codable, Sendable {
        case publish, unpublish
    }

    // The only three things a plan may do to a file, each naming its path.
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
    var action: Action = .publish
    // The slug the document's body and cover use now, when this publish moves it to `slug`.
    var movedFrom: String?

    var paths: [String] { changes.map(\.path) }

    // Spec 0006 A, AC-3 and AC-9, the one place that decides which pictures leave a slug's folder:
    // only files the app holds a copy of. Anything else stops the plan, because deleting it loses it.
    static func retireFolder(
        collection: Document.Collection, slug: String, known: Set<String>, repo: URL
    ) throws -> [Change] {
        let folder = "src/assets/\(collection.rawValue)/\(slug)"
        let names =
            ((try? FileManager.default.contentsOfDirectory(
                atPath: repo.appending(path: folder).path(percentEncoded: false))) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()

        let unknown = names.filter { !known.contains($0) }
        guard unknown.isEmpty else {
            throw PublishError.unknownFilesInFolder(paths: unknown.map { "\(folder)/\($0)" })
        }
        return names.map { .delete(path: "\(folder)/\($0)") }
    }

    // Invariant 3. The only places the app may ever write in your repository.
    static func isAllowed(_ path: String) -> Bool {
        !path.contains("..")
            && (path.hasPrefix("src/content/") || path.hasPrefix("src/assets/") || path == Redirects.path)
    }
}

/// `src/redirects.ts`, edited in place: one entry added before the closing brace, or nothing.
///
/// `adding` refuses a file it does not recognise rather than rewriting it, and never adds an entry
/// twice. `sources` answers which old addresses point at a post, which is what the unpublish
/// confirmation warns about.
nonisolated enum Redirects {
    static let path = "src/redirects.ts"
    private static let declaration = "export const redirects: Record<string, string> = {"

    // Spec 0006 A, AC-1. The old addresses that lead to this one, which a takedown leaves pointing nowhere.
    static func sources(pointingAt target: String, in text: String) -> [String] {
        let pattern = #"^\s*'([^']+)'\s*:\s*'([^']+)'\s*,?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return text.components(separatedBy: "\n").compactMap { line in
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                let from = Range(match.range(at: 1), in: line), let to = Range(match.range(at: 2), in: line),
                line[to] == target
            else { return nil }
            return String(line[from])
        }
    }

    static func adding(from old: String, to new: String, in text: String) throws -> String {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == declaration }) else {
            throw PublishError.redirectsUnreadable(reason: "It has no `\(declaration)` line.")
        }
        guard let close = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "};" })
        else {
            throw PublishError.redirectsUnreadable(reason: "The redirects object is never closed with `};`.")
        }

        let entry = "  '\(old)': '\(new)',"
        // A second rename back and forth would otherwise stack identical lines.
        guard
            !lines[start...close].contains(where: {
                $0.trimmingCharacters(in: .whitespaces) == entry.trimmingCharacters(in: .whitespaces)
            })
        else { return text }

        var updated = lines
        updated.insert(entry, at: close)
        return updated.joined(separator: "\n")
    }
}
