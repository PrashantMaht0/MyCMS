import Foundation
import GRDB
import Testing

@testable import MyCMS

// A throwaway repo on disk, so the scanner and the importer are exercised against real files
// rather than against a fake file system.
private final class TempRepo {
    let url: URL

    init() throws {
        url = URL.temporaryDirectory.appending(path: "mycms-repo-\(UUID().uuidString)")
        for collection in Document.Collection.allCases {
            try FileManager.default.createDirectory(
                at: url.appending(path: "src/content/\(collection.rawValue)"),
                withIntermediateDirectories: true)
        }
    }

    @discardableResult
    func write(_ text: String, to path: String) throws -> URL {
        let fileURL = url.appending(path: "src/content/\(path)")
        try Data(text.utf8).write(to: fileURL)
        return fileURL
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private let blogFile = """
    ---
    title: My Journey to Ireland
    description: My first blog ( An Self Introduction)
    publishDate: 2026-09-10
    draft: false
    tags: [personal, ireland]
    ---

    It started with a visa appointment.
    """

private let projectFile = """
    ---
    title: GoCRM
    description: A multi tenant CRM for small businesses.
    publishDate: 2026-08-06
    draft: false
    order: 5
    tags: [crm, spring-boot]
    role: Solo project
    timeline: Jun to Aug 2026
    status: complete
    tech: [Java, Spring Boot]
    repoUrl: https://github.com/PrashantMaht0/GoCRM
    ---

    A CRM.
    """

@Suite("Frontmatter reader")
struct FrontmatterReaderTests {
    @Test("Reads a real blog file, including a bare YAML date")
    func readsBlogFile() throws {
        let repo = try TempRepo()
        let fileURL = try repo.write(blogFile, to: "blog/my-journey-to-ireland.md")

        let file = try FrontmatterReader.read(fileURL: fileURL, collection: .blog)

        #expect(file.frontmatter.title == "My Journey to Ireland")
        #expect(file.frontmatter.tags == ["personal", "ireland"])
        #expect(file.frontmatter.draft == false)
        #expect(file.body == "It started with a visa appointment.")

        // The bare 2026-09-10 must land as a real date, whichever way Yams hands it over.
        let day = try #require(file.frontmatter.publishDate?.value)
        #expect(FlexibleDate.dayFormatter.string(from: day) == "2026-09-10")
    }

    @Test("Reads a project file, with the fields only projects carry")
    func readsProjectFile() throws {
        let repo = try TempRepo()
        let fileURL = try repo.write(projectFile, to: "projects/gocrm.md")

        let file = try FrontmatterReader.read(fileURL: fileURL, collection: .projects)

        #expect(file.frontmatter.role == "Solo project")
        #expect(file.frontmatter.status == .complete)
        #expect(file.frontmatter.tech == ["Java", "Spring Boot"])
        #expect(file.frontmatter.order == 5)
    }

    @Test("A blog file needs no project fields, but a project file does")
    func requiredFieldsDifferByCollection() throws {
        let repo = try TempRepo()
        let blogURL = try repo.write(blogFile, to: "blog/ok.md")
        let asProject = try repo.write(blogFile, to: "projects/missing.md")

        #expect(throws: Never.self) {
            try FrontmatterReader.read(fileURL: blogURL, collection: .blog)
        }

        do {
            _ = try FrontmatterReader.read(fileURL: asProject, collection: .projects)
            Issue.record("Expected the missing project fields to be reported")
        } catch let error as RepositoryError {
            #expect(error == .missingFields(names: ["role", "timeline", "status"]))
        }
    }

    @Test("A file with no fence is refused rather than half read")
    func refusesAFileWithNoFence() throws {
        let repo = try TempRepo()
        let fileURL = try repo.write("Just a heading\n", to: "blog/bare.md")

        #expect(throws: RepositoryError.noFence) {
            try FrontmatterReader.read(fileURL: fileURL, collection: .blog)
        }
    }

    @Test("The hash is of the raw bytes, so a byte changing changes it")
    func hashesRawBytes() throws {
        let repo = try TempRepo()
        let fileURL = try repo.write(blogFile, to: "blog/hash.md")
        let first = try FrontmatterReader.read(fileURL: fileURL, collection: .blog).hash

        #expect(first == ContentHash.sha256(try Data(contentsOf: fileURL)))
        #expect(first.count == 64)

        try repo.write(blogFile + "\n", to: "blog/hash.md")
        let second = try FrontmatterReader.read(fileURL: fileURL, collection: .blog).hash
        #expect(first != second)
    }
}

@Suite("Remote display")
struct RemoteDisplayTests {
    @Test("An SSH and an HTTPS remote read the same on screen")
    func shortensBothRemoteForms() {
        #expect(RepositorySettings.shorten("git@github.com:Owner/Repo.git") == "github.com/Owner/Repo")
        #expect(RepositorySettings.shorten("https://github.com/Owner/Repo.git") == "github.com/Owner/Repo")
        #expect(RepositorySettings.shorten("https://user@github.com/Owner/Repo") == "github.com/Owner/Repo")
    }

    @Test("The git version is trimmed to what the step has room for")
    func trimsTheVersion() {
        #expect(RepositoryService.displayVersion("git version 2.39.5 (Apple Git-154)") == "Git 2.39.5")
        #expect(RepositoryService.displayVersion("git version 2.50.1") == "Git 2.50.1")
    }
}

@Suite("Repo scan and import")
struct ImportTests {
    private func makeStore() throws -> (MyCMS.Database, DocumentStore, SettingsStore) {
        let database = try MyCMS.Database.inMemory()
        return (database, DocumentStore(database: database), SettingsStore(database: database))
    }

    @Test("A first import brings in every file and reports the mockup's line")
    func importsEverything() throws {
        let repo = try TempRepo()
        try repo.write(blogFile, to: "blog/my-journey-to-ireland.md")
        try repo.write(projectFile, to: "projects/gocrm.md")

        let (_, store, settings) = try makeStore()
        let report = try ImportService(store: store, settings: settings).run(repo: repo.url)

        #expect(report.summaryLine == "Imported 1 post and 1 project")
        #expect(try store.list().count == 2)

        let imported = try #require(try store.list(state: .published).first { $0.slug == "gocrm" })
        let document = try #require(try store.fetch(id: imported.id))
        #expect(document.state == .published)
        #expect(document.publishedSlug == "gocrm")
        #expect(document.publishedHash?.count == 64)
        #expect(document.fields.role == "Solo project")
    }

    @Test("A freshly imported file is not badged as edited, because nobody edited it")
    func importedIsNotModified() throws {
        let repo = try TempRepo()
        try repo.write(blogFile, to: "blog/post.md")

        let (_, store, settings) = try makeStore()
        _ = try ImportService(store: store, settings: settings).run(repo: repo.url)

        let item = try #require(try store.list().first)
        #expect(item.state == .published)
        #expect(item.isModified == false)

        let document = try #require(try store.fetch(id: item.id))
        #expect(document.isModified == false)
    }

    @Test("Running it again imports nothing, because every file is already known")
    func isIdempotent() throws {
        let repo = try TempRepo()
        try repo.write(blogFile, to: "blog/post.md")

        let (_, store, settings) = try makeStore()
        let importer = ImportService(store: store, settings: settings)

        _ = try importer.run(repo: repo.url)
        let second = try importer.run(repo: repo.url)

        #expect(second.importedTotal == 0)
        #expect(second.unchanged == 1)
        #expect(try store.list().count == 1)
    }

    @Test("A file added by hand later arrives on the next scan, not only at setup")
    func picksUpAFileAddedLater() throws {
        let repo = try TempRepo()
        try repo.write(blogFile, to: "blog/first.md")

        let (_, store, settings) = try makeStore()
        let importer = ImportService(store: store, settings: settings)
        _ = try importer.run(repo: repo.url)
        #expect(try store.list().count == 1)

        // You wrote this one on GitHub, or by hand, after setup was already finished.
        try repo.write(
            blogFile.replacingOccurrences(of: "My Journey to Ireland", with: "Added By Hand"),
            to: "blog/second.md")

        let run = try importer.refresh(repo: repo.url)
        #expect(run.report.importedTotal == 1)
        #expect(try store.list().count == 2)
        #expect(run.findings.count == 2)
    }

    @Test("draft: true still imports as published, with the flag kept for a republish")
    func keepsTheDraftFlag() throws {
        let repo = try TempRepo()
        try repo.write(blogFile.replacingOccurrences(of: "draft: false", with: "draft: true"), to: "blog/post.md")

        let (_, store, settings) = try makeStore()
        _ = try ImportService(store: store, settings: settings).run(repo: repo.url)

        let item = try #require(try store.list().first)
        let document = try #require(try store.fetch(id: item.id))
        #expect(document.state == .published)
        #expect(document.fields.draft == true)
    }

    @Test("The file keeps the slug and the local draft is moved aside")
    func theFileWinsASlugClash() throws {
        let repo = try TempRepo()
        try repo.write(blogFile, to: "blog/post.md")

        let (_, store, settings) = try makeStore()
        let draft = try store.create(collection: .blog)
        try store.update(id: draft.id, Column("slug").set(to: "post"))

        let report = try ImportService(store: store, settings: settings).run(repo: repo.url)

        #expect(report.renamed.count == 1)
        #expect(report.renamed.first?.to == "post-2")

        let moved = try #require(try store.fetch(id: draft.id))
        #expect(moved.slug == "post-2")
        #expect(moved.state == .draft)

        // The published file kept the slug it is actually served at.
        let published = try #require(try store.list(state: .published).first)
        #expect(published.slug == "post")
    }

    @Test("A file that does not parse is skipped and named, and the rest still import")
    func skipsABadFile() throws {
        let repo = try TempRepo()
        try repo.write(blogFile, to: "blog/good.md")
        try repo.write("---\ntitle: [unclosed\n---\n", to: "blog/bad.md")

        let (_, store, settings) = try makeStore()
        let report = try ImportService(store: store, settings: settings).run(repo: repo.url)

        #expect(report.importedTotal == 1)
        #expect(report.skipped.count == 1)
        #expect(report.skipped.first?.path == "src/content/blog/bad.md")
        #expect(report.skipped.first?.reason.isEmpty == false)
    }

    @Test("A second file claiming the same cmsId is skipped rather than colliding")
    func skipsADuplicateId() throws {
        let repo = try TempRepo()
        let id = UUID().uuidString
        let withId = blogFile.replacingOccurrences(of: "draft: false", with: "draft: false\ncmsId: \(id)")
        try repo.write(withId, to: "blog/first.md")
        try repo.write(withId, to: "blog/second.md")

        let (_, store, settings) = try makeStore()
        let report = try ImportService(store: store, settings: settings).run(repo: repo.url)

        #expect(report.importedTotal == 1)
        #expect(report.skipped.count == 1)
        #expect(try store.list().count == 1)
    }
}

@Suite("Changed outside the app")
struct OutsideChangeTests {
    private func importedRepo() throws -> (TempRepo, DocumentStore, ImportService, UUID) {
        let repo = try TempRepo()
        try repo.write(blogFile, to: "blog/post.md")

        let database = try MyCMS.Database.inMemory()
        let store = DocumentStore(database: database)
        let importer = ImportService(store: store, settings: SettingsStore(database: database))
        _ = try importer.run(repo: repo.url)

        let id = try #require(try store.list().first?.id)
        return (repo, store, importer, id)
    }

    @Test("Editing the file outside the app is noticed rather than overwritten")
    func noticesAnOutsideEdit() throws {
        let (repo, store, importer, id) = try importedRepo()
        try repo.write(blogFile + "\n\nA line added by hand.\n", to: "blog/post.md")

        let findings = try importer.scan(repo: repo.url)
        #expect(findings.first?.verdict == .changedOutside)
        #expect(findings.first?.matchedId == id)

        // Nothing was written. That is the whole promise of the badge.
        let document = try #require(try store.fetch(id: id))
        #expect(!document.bodyMd.contains("added by hand"))
    }

    @Test("Loading the file's version adopts it and clears the badge")
    func loadingTheFileAdoptsIt() throws {
        let (repo, store, importer, id) = try importedRepo()
        try repo.write(blogFile + "\n\nA line added by hand.\n", to: "blog/post.md")

        try importer.loadFileVersion(documentId: id, repo: repo.url)

        let document = try #require(try store.fetch(id: id))
        #expect(document.bodyMd.contains("added by hand"))
        // Adopting the file is not an edit, so it must not come back badged as one.
        #expect(document.isModified == false)
        #expect(try importer.scan(repo: repo.url).first?.verdict == .unchanged)
    }

    @Test("Keeping your version stops the badge until the file changes again")
    func keepingYoursQuietensTheBadge() throws {
        let (repo, store, importer, id) = try importedRepo()
        try repo.write(blogFile + "\n\nA line added by hand.\n", to: "blog/post.md")

        try importer.keepAppVersion(documentId: id, repo: repo.url)

        #expect(try importer.scan(repo: repo.url).first?.verdict == .unchanged)
        let kept = try #require(try store.fetch(id: id))
        #expect(!kept.bodyMd.contains("added by hand"))

        // Changed again since you answered, so it is a new question and the badge returns.
        try repo.write(blogFile + "\n\nAnd another line.\n", to: "blog/post.md")
        #expect(try importer.scan(repo: repo.url).first?.verdict == .changedOutside)
    }

    @Test("A published file deleted from the repo is reported, never silently dropped")
    func reportsAMissingFile() throws {
        let (repo, _, importer, id) = try importedRepo()
        try FileManager.default.removeItem(at: repo.url.appending(path: "src/content/blog/post.md"))

        let findings = try importer.scan(repo: repo.url)
        #expect(findings.first?.verdict == .missingFile)
        #expect(findings.first?.matchedId == id)
    }

    @Test("A repo swap clears every hash, because they describe files in the old repo")
    func aSwapClearsTheHashes() throws {
        let (_, store, _, id) = try importedRepo()
        #expect(try store.fetch(id: id)?.publishedHash != nil)

        try store.clearPublishedHashes()
        #expect(try store.fetch(id: id)?.publishedHash == nil)
    }
}

@Suite("Settings store")
struct SettingsStoreTests {
    @Test("A value round trips, and writing nil removes the row")
    func roundTripsAndRemoves() throws {
        let database = try MyCMS.Database.inMemory()
        let settings = SettingsStore(database: database)

        try settings.set("/tmp/repo", forKey: SettingsKey.repoPath)
        #expect(try settings.string(forKey: SettingsKey.repoPath) == "/tmp/repo")

        // Writing the same key again replaces it rather than failing on the primary key.
        try settings.set("/tmp/other", forKey: SettingsKey.repoPath)
        #expect(try settings.string(forKey: SettingsKey.repoPath) == "/tmp/other")

        try settings.set(String?.none, forKey: SettingsKey.repoPath)
        #expect(try settings.string(forKey: SettingsKey.repoPath) == nil)
    }

    @Test("A check outcome survives being written and read back")
    func storesACheckOutcome() throws {
        let database = try MyCMS.Database.inMemory()
        let settings = SettingsStore(database: database)

        let outcome = CheckOutcome.ok(
            "Git 2.50.1 found · can push to origin", at: Date(timeIntervalSince1970: 1_700_000_000))
        try settings.encode(outcome, forKey: SettingsKey.checkGit)

        let read = try #require(try settings.decode(CheckOutcome.self, forKey: SettingsKey.checkGit))
        #expect(read == outcome)
    }

    @Test("A row that is not the expected shape reads as absent rather than throwing")
    func survivesAMalformedRow() throws {
        let database = try MyCMS.Database.inMemory()
        let settings = SettingsStore(database: database)

        try settings.set("not json", forKey: SettingsKey.checkGit)
        #expect(try settings.decode(CheckOutcome.self, forKey: SettingsKey.checkGit) == nil)
    }
}
