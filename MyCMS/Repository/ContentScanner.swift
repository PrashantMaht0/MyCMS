import Foundation

/// What the scan concluded about one file: where it is, its hash, which document it matched, and the
/// verdict the import acts on.
nonisolated struct ScanFinding: Sendable, Identifiable {
    // What the scan concluded about one file, and what the import does with it.
    enum Verdict: Sendable, Equatable {
        case new
        case unchanged
        case changedOutside
        case missingFile
        case skipped(reason: String)
    }

    var collection: Document.Collection
    var slug: String
    // src/content/blog/hello.md, for the summary and for anything shown to a person.
    var relativePath: String
    var fileURL: URL?
    var fileHash: String?
    var matchedId: UUID?
    var verdict: Verdict
    var file: ContentFile?

    var id: String { relativePath }
}

/// Walks the two content folders and compares every file to what the database holds.
///
/// Reads only: nothing here writes to the repo or the database. Matches a file to a document by
/// `cmsId` first and by slug second, and reports one `ScanFinding` per file: new, unchanged,
/// changed outside the app, or skipped with a reason. A published document whose file has gone is
/// reported too.
nonisolated struct ContentScanner: Sendable {
    func scan(repo: URL, known: [DocumentFileRef]) -> [ScanFinding] {
        // Only a published document is ever a match target. A draft holding the same slug is a
        // rename candidate, never something an import may overwrite.
        let published = known.filter { $0.state == .published }
        let byId = Dictionary(published.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var bySlug: [String: DocumentFileRef] = [:]
        for ref in published {
            if let slug = ref.publishedSlug ?? ref.slug {
                bySlug["\(ref.collection.rawValue)/\(slug)", default: ref] = ref
            }
        }

        var findings: [ScanFinding] = []
        var claimedIds: Set<UUID> = []
        var seenRefIds: Set<UUID> = []

        for collection in Document.Collection.allCases {
            let folder = repo.appending(path: "src/content/\(collection.rawValue)")
            for fileURL in markdownFiles(in: folder) {
                let slug = fileURL.deletingPathExtension().lastPathComponent
                let relativePath = "src/content/\(collection.rawValue)/\(fileURL.lastPathComponent)"

                let file: ContentFile
                do {
                    file = try FrontmatterReader.read(fileURL: fileURL, collection: collection)
                } catch {
                    findings.append(
                        ScanFinding(
                            collection: collection, slug: slug, relativePath: relativePath,
                            fileURL: fileURL, fileHash: nil, matchedId: nil,
                            verdict: .skipped(reason: readableReason(error)), file: nil))
                    continue
                }

                // Two files claiming one id would collide on the primary key, so the second loses.
                if let cmsId = file.frontmatter.cmsId, claimedIds.contains(cmsId) {
                    findings.append(
                        ScanFinding(
                            collection: collection, slug: slug, relativePath: relativePath,
                            fileURL: fileURL, fileHash: file.hash, matchedId: nil,
                            verdict: .skipped(reason: "Another file already uses cmsId \(cmsId.uuidString)."),
                            file: file))
                    continue
                }
                if let cmsId = file.frontmatter.cmsId { claimedIds.insert(cmsId) }

                let match =
                    file.frontmatter.cmsId.flatMap { byId[$0] }
                    ?? bySlug["\(collection.rawValue)/\(slug)"]
                if let match { seenRefIds.insert(match.id) }

                findings.append(
                    ScanFinding(
                        collection: collection, slug: slug, relativePath: relativePath,
                        fileURL: fileURL, fileHash: file.hash, matchedId: match?.id,
                        verdict: verdict(for: match, fileHash: file.hash), file: file))
            }
        }

        // A published document whose file is gone. Republishing is the only real fix, and that
        // belongs to feature 7, so this is reported rather than acted on.
        for ref in published where !seenRefIds.contains(ref.id) {
            let slug = ref.publishedSlug ?? ref.slug ?? ref.id.uuidString
            findings.append(
                ScanFinding(
                    collection: ref.collection, slug: slug,
                    relativePath: "src/content/\(ref.collection.rawValue)/\(slug).md",
                    fileURL: nil, fileHash: nil, matchedId: ref.id,
                    verdict: .missingFile, file: nil))
        }

        return findings
    }

    // Changed outside means the file differs from what the app wrote and from what you already
    // chose to keep the app's version over.
    private func verdict(for match: DocumentFileRef?, fileHash: String) -> ScanFinding.Verdict {
        guard let match else { return .new }
        if match.publishedHash == fileHash { return .unchanged }
        if match.acknowledgedHash == fileHash { return .unchanged }
        return .changedOutside
    }

    private func markdownFiles(in folder: URL) -> [URL] {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return
            contents
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func readableReason(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
