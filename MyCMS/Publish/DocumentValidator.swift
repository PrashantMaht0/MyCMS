import Foundation

// One Notes 4.2 rule, as the publish sheet's live list shows it.
nonisolated struct ValidationRule: Sendable, Equatable, Identifiable {
    let id: String
    let label: String
    let passed: Bool
    // Names the field and what is wrong with it, empty when the rule passes.
    let problem: String
}

// AC-38 and AC-67. Every rule the site's schema enforces, checked in Swift before anything is
// written, each one named so a failure says exactly which field to fix.
nonisolated struct DocumentValidator: Sendable {
    // Whether a body image reference points at a file publishing can actually deliver.
    let imageResolves: @Sendable (String) -> Bool

    static let titleLimit = 90
    static let descriptionLimit = 160

    func validate(_ document: Document) -> [ValidationRule] {
        var rules = common(document)
        switch document.collection {
        case .blog:
            rules.append(optionalURL("canonicalUrl", "Canonical URL", document.fields.canonicalUrl))
        case .projects:
            rules += project(document.fields)
        }
        rules.append(imagesResolve(document))
        return rules
    }

    static func allPass(_ rules: [ValidationRule]) -> Bool {
        rules.allSatisfy(\.passed)
    }

    // MARK: Both collections

    private func common(_ document: Document) -> [ValidationRule] {
        let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = document.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let badTags = document.tags.filter { !Self.isTag($0) }
        let hasCover = !(document.cover ?? "").isEmpty

        return [
            rule("title", "Title, up to \(Self.titleLimit) characters",
                 title.isEmpty ? "Title is empty." :
                    title.count > Self.titleLimit ? "Title is \(title.count) characters, over \(Self.titleLimit)." : nil),
            rule("description", "Subtitle, up to \(Self.descriptionLimit) characters",
                 description.isEmpty ? "Subtitle is empty; the site uses it as the description." :
                    description.count > Self.descriptionLimit
                    ? "Subtitle is \(description.count) characters, over \(Self.descriptionLimit)." : nil),
            rule("slug", "An address, from the title",
                 (document.slug ?? "").isEmpty ? "There is no slug yet. Give the post a title." : nil),
            rule("tags", "Tags are lowercase words joined by hyphens",
                 badTags.isEmpty ? nil : "Tags \(badTags.joined(separator: ", ")) need to be lowercase with hyphens."),
            rule("coverAlt", "A cover has alt text",
                 hasCover && document.coverAlt.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "The cover image has no alt text." : nil),
        ]
    }

    // MARK: Projects

    private func project(_ fields: DocumentFields) -> [ValidationRule] {
        [
            rule("role", "Role", (fields.role ?? "").isEmpty ? "Projects need a role." : nil),
            rule("timeline", "Timeline", (fields.timeline ?? "").isEmpty ? "Projects need a timeline." : nil),
            rule("status", "Status", fields.status == nil ? "Projects need a status: active, complete or archived." : nil),
            optionalURL("videoUrl", "Video URL", fields.videoUrl),
            optionalURL("repoUrl", "Repository URL", fields.repoUrl),
            optionalURL("liveUrl", "Live URL", fields.liveUrl),
        ]
    }

    // MARK: Images

    private func imagesResolve(_ document: Document) -> ValidationRule {
        let structure = MarkdownRenderer.parse(document.bodyMd)
        var missing = structure.images
            .filter { !structure.isCode(at: $0.range.location) && !Self.isRemote($0.source) }
            .map(\.source)
            .filter { !imageResolves($0) }
        if let cover = document.cover, !cover.isEmpty, !Self.isRemote(cover), !imageResolves(cover) {
            missing.append(cover)
        }
        return rule("images", "Every picture has its file",
                    missing.isEmpty ? nil : "No file for \(missing.joined(separator: ", ")).")
    }

    // MARK: Helpers

    private func rule(_ id: String, _ label: String, _ problem: String?) -> ValidationRule {
        ValidationRule(id: id, label: label, passed: problem == nil, problem: problem ?? "")
    }

    private func optionalURL(_ id: String, _ label: String, _ url: URL?) -> ValidationRule {
        guard let url else { return rule(id, label, nil) }
        let valid = ["http", "https"].contains(url.scheme ?? "") && url.host() != nil
        return rule(id, label, valid ? nil : "\(label) \(url.absoluteString) is not a web address.")
    }

    static func isTag(_ tag: String) -> Bool {
        tag.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    static func isRemote(_ source: String) -> Bool {
        source.hasPrefix("http://") || source.hasPrefix("https://")
    }
}
