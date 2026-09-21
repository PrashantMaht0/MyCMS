import CryptoKit
import Foundation
import Yams

// The sha256 of a file exactly as it sits on disk. Hashing raw bytes rather than parsed content
// is the only version that can prove the file is untouched since the app last wrote it.
nonisolated enum ContentHash {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// A YAML date that survives being written either as a bare timestamp or as a quoted string.
nonisolated struct FlexibleDate: Codable, Sendable, Equatable {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let date = try? container.decode(Date.self) {
            value = date
            return
        }

        let text = try container.decode(String.self)
        guard let parsed = Self.parse(text) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "\(text) is not a date the app understands.")
        }
        value = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.dayFormatter.string(from: value))
    }

    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = ISO8601DateFormatter().date(from: trimmed) { return date }
        return dayFormatter.date(from: trimmed)
    }

    // A fixed locale and zone, because a date in a file must not depend on who opened it.
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// The frontmatter block, mirroring the site's schema from Notes section 4.2. Feature 6 writes
// this same type back out, so the reader and the writer can never disagree about a field.
nonisolated struct Frontmatter: Codable, Sendable {
    var title: String?
    var description: String?
    var publishDate: FlexibleDate?
    var updatedDate: FlexibleDate?
    var draft: Bool?
    var featured: Bool?
    var tags: [String]?
    var cover: String?
    var coverAlt: String?
    var cmsId: UUID?
    var aiAssisted: Bool?
    var canonicalUrl: URL?
    var role: String?
    var timeline: String?
    var status: DocumentFields.ProjectStatus?
    var tech: [String]?
    var videoUrl: URL?
    var repoUrl: URL?
    var liveUrl: URL?
    var order: Int?

    // Only what a Document cannot exist without. Full schema validation is feature 6's job, so
    // this reader deliberately does not duplicate that rule set.
    static func requiredFields(for collection: Document.Collection) -> [String] {
        switch collection {
        case .blog: ["title", "description", "publishDate"]
        case .projects: ["title", "description", "publishDate", "role", "timeline", "status"]
        }
    }

    func missingFields(for collection: Document.Collection) -> [String] {
        Self.requiredFields(for: collection).filter { name in
            switch name {
            case "title": title?.isEmpty ?? true
            case "description": description?.isEmpty ?? true
            case "publishDate": publishDate == nil
            case "role": role?.isEmpty ?? true
            case "timeline": timeline?.isEmpty ?? true
            case "status": status == nil
            default: false
            }
        }
    }

    // The project only half of the frontmatter, kept in one JSON column.
    var documentFields: DocumentFields {
        DocumentFields(
            draft: draft,
            aiAssisted: aiAssisted,
            canonicalUrl: canonicalUrl,
            role: role,
            timeline: timeline,
            status: status,
            tech: tech,
            videoUrl: videoUrl,
            repoUrl: repoUrl,
            liveUrl: liveUrl,
            order: order)
    }
}

// One file on disk, read and understood.
nonisolated struct ContentFile: Sendable {
    var frontmatter: Frontmatter
    var body: String
    var hash: String
}

nonisolated enum FrontmatterReader {
    static func read(fileURL: URL, collection: Document.Collection) throws -> ContentFile {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw RepositoryError.unreadable(reason: error.localizedDescription)
        }

        // The hash is taken before anything is parsed, so it describes the bytes and nothing else.
        let hash = ContentHash.sha256(data)

        guard let text = String(data: data, encoding: .utf8) else { throw RepositoryError.notText }

        let (yaml, body) = try split(text)

        let frontmatter: Frontmatter
        do {
            frontmatter = try YAMLDecoder().decode(Frontmatter.self, from: yaml)
        } catch {
            throw RepositoryError.invalidYAML(reason: error.localizedDescription)
        }

        let missing = frontmatter.missingFields(for: collection)
        guard missing.isEmpty else { throw RepositoryError.missingFields(names: missing) }

        return ContentFile(frontmatter: frontmatter, body: body, hash: hash)
    }

    // The fence must open the file, which is what Astro requires of it too.
    static func split(_ text: String) throws -> (yaml: String, body: String) {
        var lines = text.components(separatedBy: "\n")

        // A byte order mark from another editor would otherwise hide the opening fence.
        if let first = lines.first, first.hasPrefix("\u{FEFF}") {
            lines[0] = String(first.dropFirst())
        }

        guard isFence(lines.first) else { throw RepositoryError.noFence }
        guard let closing = lines.dropFirst().firstIndex(where: { isFence($0) }) else {
            throw RepositoryError.noFence
        }

        let yaml = lines[1..<closing].joined(separator: "\n")
        let body = lines[(closing + 1)...].joined(separator: "\n")
        return (yaml, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func isFence(_ line: String?) -> Bool {
        line?.trimmingCharacters(in: .whitespaces) == "---"
    }
}
