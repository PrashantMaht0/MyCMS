import Foundation
import GRDB
import OSLog

// What an import did, and the line the setup screen shows for it.
nonisolated struct ImportReport: Sendable {
    nonisolated struct Skipped: Sendable, Equatable {
        var path: String
        var reason: String
    }

    var importedByCollection: [Document.Collection: Int] = [:]
    var unchanged: Int = 0
    var changedOutside: Int = 0
    var missingFiles: [String] = []
    var renamed: [ImportPlan.Rename] = []
    var skipped: [Skipped] = []

    var importedTotal: Int { importedByCollection.values.reduce(0, +) }

    // Imported 1 post and 5 projects, the mockup's own line.
    var summaryLine: String {
        let parts = [(Document.Collection.blog, "post"), (.projects, "project")]
            .compactMap { collection, noun -> String? in
                let count = importedByCollection[collection] ?? 0
                guard count > 0 else { return nil }
                return "\(count) \(noun)\(count == 1 ? "" : "s")"
            }

        guard !parts.isEmpty else { return "Nothing new to import" }
        return "Imported " + parts.joined(separator: " and ")
    }

    // The second line, only when there is something worth saying.
    var noteLine: String? {
        var notes: [String] = []
        if changedOutside > 0 { notes.append("\(changedOutside) changed outside the app") }
        if !renamed.isEmpty { notes.append("\(renamed.count) draft slug moved aside") }
        if !missingFiles.isEmpty { notes.append("\(missingFiles.count) published file missing") }
        if !skipped.isEmpty { notes.append("\(skipped.count) file skipped") }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }
}

/// Turns what the scanner found into database rows, in one transaction, without touching the repo.
///
/// `run` imports every file the app does not know yet; `refresh` does the same and hands back the
/// findings so a caller that also needs the badges does not scan twice. It runs on every launch,
/// not just the first, because a file you added by hand has to arrive on its own. After the rows
/// land it adopts each post's pictures into the app's own store, so nothing depends on the repo
/// staying where it is.
nonisolated struct ImportService: Sendable {
    private let store: DocumentStore
    private let settings: SettingsStore
    private let scanner: ContentScanner
    // Nil only in tests that exercise rows alone; the app always passes its store.
    private let assets: AssetStore?
    private let now: @Sendable () -> Date

    init(
        store: DocumentStore,
        settings: SettingsStore,
        assets: AssetStore? = nil,
        scanner: ContentScanner = ContentScanner(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.settings = settings
        self.assets = assets
        self.scanner = scanner
        self.now = now
    }

    func scan(repo: URL) throws -> [ScanFinding] {
        scanner.scan(repo: repo, known: try store.fileRefs())
    }

    // Imports every file the app does not know. A file that already matches a document is left
    // alone, because adopting a changed file is a choice you make, not one an import makes.
    @discardableResult
    func run(repo: URL) throws -> ImportReport {
        try refresh(repo: repo).report
    }

    // Returns the findings too, so a caller needing the badges does not scan twice. Runs on every
    // launch, because a file you added by hand has to arrive on its own.
    func refresh(repo: URL) throws -> (report: ImportReport, findings: [ScanFinding]) {
        let findings = try scan(repo: repo)
        let report = try apply(findings)
        adoptPublishedPictures(repo: repo)
        try settings.setDate(now(), forKey: SettingsKey.scanLastRunAt)
        return (report, findings)
    }

    // MARK: Adopting pictures

    // Spec 0006 C, AC-17. Every document that is or was published, which covers what this import
    // just added. Stored names are skipped before any file is read, so a repeat pass is cheap.
    private func adoptPublishedPictures(repo: URL) {
        let documents: [Document]
        do {
            documents = try store.read { db in
                try Document.filter(Column("published_slug") != nil).fetchAll(db)
            }
        } catch {
            Loggers.repository.error("Picture adoption skipped: \(error.localizedDescription, privacy: .public)")
            return
        }

        let adopted = documents.reduce(0) { $0 + adoptPictures(for: $1, repo: repo) }
        if adopted > 0 {
            Loggers.repository.info("Adopted \(adopted, privacy: .public) picture(s) from the repo")
        }
    }

    // Copies each picture under the document's own asset folder into the app. A reference with no
    // file in the repo stays as it is, and a failure on one picture never stops the rest.
    @discardableResult
    func adoptPictures(for document: Document, repo: URL) -> Int {
        guard let assets, let slug = document.publishedSlug ?? document.slug else { return 0 }
        let prefix = "../../assets/\(document.collection.rawValue)/\(slug)/"

        let structure = MarkdownRenderer.parse(document.bodyMd)
        var references = structure.images
            .filter { $0.source.hasPrefix(prefix) && !structure.isCode(at: $0.range.location) }
            .map { (source: $0.source, alt: $0.alt) }
        if let cover = document.cover, cover.hasPrefix(prefix) {
            references.append((cover, document.coverAlt))
        }

        let stored = Set(((try? assets.assets(for: document)) ?? []).map(\.fileName))
        var seen = Set<String>()
        var count = 0
        for reference in references {
            guard let name = AssetStore.fileName(inReference: reference.source, collection: document.collection),
                !stored.contains(name), seen.insert(name).inserted,
                let file = AssetStore.repoFile(for: reference.source, collection: document.collection, repo: repo)
            else { continue }

            do {
                if try assets.adopt(repoFile: file, fileName: name, alt: reference.alt, for: document) != nil {
                    count += 1
                }
            } catch {
                Loggers.repository.error(
                    "Could not adopt \(name, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
        }
        return count
    }

    func apply(_ findings: [ScanFinding]) throws -> ImportReport {
        let refs = try store.fileRefs()
        let timestamp = now()

        var report = ImportReport()
        var plan = ImportPlan()

        // Every slug the database holds plus every slug this import will claim, so a moved draft
        // cannot land on one that is about to be taken.
        var occupied = Set(refs.compactMap { ref in ref.slug.map { "\(ref.collection.rawValue)/\($0)" } })
        for finding in findings where finding.verdict == .new {
            occupied.insert("\(finding.collection.rawValue)/\(finding.slug)")
        }

        let draftsBySlug = Dictionary(
            refs.filter { $0.state == .draft }.compactMap { ref in
                ref.slug.map { ("\(ref.collection.rawValue)/\($0)", ref) }
            },
            uniquingKeysWith: { first, _ in first })

        for finding in findings {
            switch finding.verdict {
            case .new:
                guard let file = finding.file, let hash = finding.fileHash else { continue }

                // The file keeps the slug, because it is what the live site serves at that URL.
                if let draft = draftsBySlug["\(finding.collection.rawValue)/\(finding.slug)"] {
                    let moved = freeSlug(base: finding.slug, collection: finding.collection, occupied: &occupied)
                    plan.renames.append(ImportPlan.Rename(id: draft.id, from: finding.slug, to: moved))
                    report.renamed.append(ImportPlan.Rename(id: draft.id, from: finding.slug, to: moved))
                }

                plan.inserts.append(
                    document(from: file, finding: finding, hash: hash, timestamp: timestamp))
                report.importedByCollection[finding.collection, default: 0] += 1

            case .unchanged:
                report.unchanged += 1
            case .changedOutside:
                report.changedOutside += 1
            case .missingFile:
                report.missingFiles.append(finding.relativePath)
            case .skipped(let reason):
                report.skipped.append(ImportReport.Skipped(path: finding.relativePath, reason: reason))
            }
        }

        try store.apply(plan, at: timestamp)

        Loggers.repository.info(
            "Import ran: \(report.importedTotal, privacy: .public) imported, \(report.skipped.count, privacy: .public) skipped"
        )
        return report
    }

    // MARK: Resolving a file that changed outside the app

    // Load the file's version. The document takes on what the file says and the badge clears.
    func loadFileVersion(documentId: UUID, repo: URL) throws {
        let (ref, fileURL) = try locate(documentId: documentId, repo: repo)
        let file = try FrontmatterReader.read(fileURL: fileURL, collection: ref.collection)
        let slug = ref.publishedSlug ?? ref.slug ?? fileURL.deletingPathExtension().lastPathComponent

        var plan = ImportPlan()
        plan.adoptions.append(
            ImportPlan.Adoption(
                id: documentId,
                slug: slug,
                title: file.frontmatter.title ?? "",
                description: file.frontmatter.description ?? "",
                bodyMd: file.body,
                tags: file.frontmatter.tags ?? [],
                featured: file.frontmatter.featured ?? false,
                publishDate: file.frontmatter.publishDate?.value,
                updatedDate: file.frontmatter.updatedDate?.value,
                cover: file.frontmatter.cover,
                coverAlt: file.frontmatter.coverAlt ?? "",
                fields: file.frontmatter.documentFields,
                publishedHash: file.hash,
                publishedAt: file.frontmatter.publishDate?.value))

        try store.apply(plan, at: now())
    }

    // Keep the app's version. The file's current hash is remembered, so the badge stays quiet
    // until the file changes again rather than nagging until the next publish.
    func keepAppVersion(documentId: UUID, repo: URL) throws {
        let (_, fileURL) = try locate(documentId: documentId, repo: repo)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw RepositoryError.fileGone(path: fileURL.path(percentEncoded: false))
        }
        try store.acknowledge(id: documentId, fileHash: ContentHash.sha256(data))
    }

    // MARK: Helpers

    private func locate(documentId: UUID, repo: URL) throws -> (DocumentFileRef, URL) {
        guard let ref = try store.fileRefs().first(where: { $0.id == documentId }) else {
            throw RepositoryError.documentNotFound
        }
        guard let slug = ref.publishedSlug ?? ref.slug else {
            throw RepositoryError.fileGone(path: "src/content/\(ref.collection.rawValue)")
        }

        let fileURL = repo.appending(path: "src/content/\(ref.collection.rawValue)/\(slug).md")
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            throw RepositoryError.fileGone(path: "src/content/\(ref.collection.rawValue)/\(slug).md")
        }
        return (ref, fileURL)
    }

    private func freeSlug(
        base: String,
        collection: Document.Collection,
        occupied: inout Set<String>
    ) -> String {
        for attempt in 2...100 {
            let candidate = SlugRule.candidate(base, attempt: attempt)
            let key = "\(collection.rawValue)/\(candidate)"
            if !occupied.contains(key) {
                occupied.insert(key)
                return candidate
            }
        }
        let fallback = "\(base)-\(UUID().uuidString.prefix(8).lowercased())"
        occupied.insert("\(collection.rawValue)/\(fallback)")
        return fallback
    }

    private func document(
        from file: ContentFile,
        finding: ScanFinding,
        hash: String,
        timestamp: Date
    ) -> Document {
        let frontmatter = file.frontmatter

        // Anything sitting in src/content is published, whatever its draft flag says. The flag
        // itself is kept so a republish writes back exactly what was there.
        let publishedAt = frontmatter.publishDate?.value ?? modifiedDate(finding.fileURL) ?? timestamp

        return Document(
            id: frontmatter.cmsId ?? UUID(),
            collection: finding.collection,
            slug: finding.slug,
            title: frontmatter.title ?? "",
            description: frontmatter.description ?? "",
            bodyMd: file.body,
            tags: frontmatter.tags ?? [],
            featured: frontmatter.featured ?? false,
            publishDate: frontmatter.publishDate?.value,
            updatedDate: frontmatter.updatedDate?.value,
            cover: frontmatter.cover,
            coverAlt: frontmatter.coverAlt ?? "",
            fields: frontmatter.documentFields,
            state: .published,
            publishedSlug: finding.slug,
            publishedHash: hash,
            publishedAt: publishedAt,
            createdAt: timestamp,
            // Importing is not editing. is_modified is updated_at > published_at, so leaving this
            // at the import moment would badge a file you have never opened as Edited.
            updatedAt: publishedAt)
    }

    private func modifiedDate(_ url: URL?) -> Date? {
        guard let url else { return nil }
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
