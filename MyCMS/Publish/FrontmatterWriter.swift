import Foundation
import Yams

/// Turns a document into the exact file the site reads: YAML frontmatter, then the Markdown body.
///
/// Writes project only fields for projects and drops them for posts, always writes `tech` for a
/// project (an empty list when there is none), and quotes anything YAML would otherwise
/// misread. The bytes it returns are hashed as `published_hash`, which is how the app later
/// notices a file changed outside the app.
nonisolated enum FrontmatterWriter {
    static func frontmatter(for document: Document, publishDate: Date, updatedDate: Date?) -> Frontmatter {
        let fields = document.fields
        let isProject = document.collection == .projects
        let hasCover = !(document.cover ?? "").isEmpty

        return Frontmatter(
            title: document.title,
            description: document.description,
            publishDate: FlexibleDate(publishDate),
            updatedDate: updatedDate.map(FlexibleDate.init),
            // Notes 4.2. Drafts live in SQLite, so every file the app writes is live.
            draft: false,
            featured: document.featured,
            tags: document.tags,
            cover: hasCover ? document.cover : nil,
            coverAlt: hasCover ? document.coverAlt : nil,
            // Notes 6.2. The document's own id, on every publish, which is what ties file to row.
            cmsId: document.id,
            aiAssisted: fields.aiAssisted,
            canonicalUrl: isProject ? nil : fields.canonicalUrl,
            role: isProject ? fields.role : nil,
            timeline: isProject ? fields.timeline : nil,
            status: isProject ? fields.status : nil,
            tech: isProject ? (fields.tech ?? []) : nil,
            videoUrl: isProject ? fields.videoUrl : nil,
            repoUrl: isProject ? fields.repoUrl : nil,
            liveUrl: isProject ? fields.liveUrl : nil,
            order: isProject ? fields.order : nil)
    }

    static func serialize(_ document: Document, publishDate: Date, updatedDate: Date?) throws -> String {
        let encoder = YAMLEncoder()
        encoder.options = YAMLEncoder.Options(width: -1, allowUnicode: true)
        let yaml = try encoder.encode(frontmatter(for: document, publishDate: publishDate, updatedDate: updatedDate))
        return "---\n\(yaml)---\n\n\(document.bodyMd)"
    }
}
