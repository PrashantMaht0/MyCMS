import Foundation

/// The one container every long lived service hangs off: the database, the stores, the publisher,
/// git, Ollama and the setup state.
///
/// Views read it from the SwiftUI environment and never build a service themselves, which is what
/// keeps one database connection and one publisher for the whole app.
@Observable final class AppEnvironment {
    let database: Database
    let documents: DocumentStore
    let settings: SettingsStore
    let assets: AssetStore
    let publisher: Publisher
    let revisions: RevisionStore
    let suggestions: SuggestionStore
    let preferences: SettingsModel
    let git: GitClient
    let ollama: OllamaClient
    let repository: RepositoryService
    let importer: ImportService
    let health: HealthCheck
    let setup: SetupModel

    init(
        database: Database = Database(),
        git: GitClient = GitClient(),
        ollama: OllamaClient = OllamaClient()
    ) {
        self.database = database
        // One connection, shared. The health check opens it, nothing here does.
        self.documents = DocumentStore(database: database)
        self.settings = SettingsStore(database: database)
        self.assets = AssetStore(database: database)
        self.revisions = RevisionStore(database: database)
        self.suggestions = SuggestionStore(database: database)
        self.publisher = Publisher(
            git: git, settings: settings, assets: assets, documents: documents, revisions: revisions)
        self.git = git
        self.ollama = ollama
        self.repository = RepositoryService(git: git, settings: settings)
        self.importer = ImportService(store: documents, settings: settings, assets: assets)
        self.health = HealthCheck(database: database, git: git, ollama: ollama, repository: repository)
        self.setup = SetupModel(repository: repository, importer: importer, store: documents)
        self.preferences = SettingsModel(
            settings: settings, repository: repository, setup: setup, database: database, documents: documents)
    }
}
