import Foundation
import GRDB
import Testing
@testable import MyCMS

@Suite("Settings")
@MainActor
struct SettingsTests {
    @Test("Every setting is written to the table and read back by a fresh model, per AC-60")
    func survivesRelaunch() throws {
        let environment = AppEnvironment(database: try MyCMS.Database.inMemory())
        let model = environment.preferences
        model.load()
        model.fontSize = 19
        model.showMarkers = false
        model.ollamaURL = "http://localhost:9999"
        model.model = "llama3.1:8b"
        model.grammarEnabled = false
        model.punctuationEnabled = false
        model.rewritesEnabled = false
        model.checkDelay = 3

        let reopened = SettingsModel(
            settings: environment.settings, repository: environment.repository, setup: environment.setup,
            database: environment.database, documents: environment.documents)
        reopened.load()
        #expect(reopened.fontSize == 19)
        #expect(!reopened.showMarkers)
        #expect(reopened.ollamaURL == "http://localhost:9999")
        #expect(reopened.model == "llama3.1:8b")
        #expect(!reopened.grammarEnabled && !reopened.punctuationEnabled && !reopened.rewritesEnabled)
        #expect(reopened.checkDelay == 3)
    }

    @Test("Loading never writes the rows it just read")
    func loadingIsReadOnly() throws {
        let environment = AppEnvironment(database: try MyCMS.Database.inMemory())
        environment.preferences.load()
        #expect(try environment.settings.string(forKey: SettingsKey.editorFontSize) == nil)
    }

    @Test("A folder that is not a repository is refused with setup's own words, per AC-56")
    func repositoryUsesTheSameValidator() async throws {
        let environment = AppEnvironment(database: try MyCMS.Database.inMemory())
        let folder = FileManager.default.temporaryDirectory.appending(path: "plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        await environment.preferences.changeRepository(to: folder)
        let expected = try await {
            do {
                _ = try await environment.repository.validate(folder: folder)
                return ""
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? ""
            }
        }()
        #expect(environment.preferences.repositoryProblem == expected)
        #expect(!expected.isEmpty)
    }

    @Test("Export writes one Markdown file per document, identical to what a publish would write, per AC-59")
    func exportMatchesPublish() throws {
        let database = try MyCMS.Database.inMemory()
        let documents = DocumentStore(database: database)
        let titled = try documents.create(collection: .blog)
        try documents.update(id: titled.id, [Column("title").set(to: "Hello"), Column("slug").set(to: "hello"), Column("body_md").set(to: "Hi.\n")])
        let untitled = try documents.create(collection: .projects)

        let folder = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)")
        #expect(try ExportService(documents: documents).exportAll(to: folder) == 2)

        let saved = try #require(try documents.fetch(id: titled.id))
        let written = try String(contentsOf: folder.appending(path: "blog/hello.md"), encoding: .utf8)
        #expect(written == (try FrontmatterWriter.serialize(saved, publishDate: saved.createdAt, updatedDate: nil)))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "projects/\(untitled.id.uuidString).md").path(percentEncoded: false)))
    }
}
