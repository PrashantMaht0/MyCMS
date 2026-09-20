import Foundation

// The one container every long lived service hangs off. Views read it, never build it.
@Observable final class AppEnvironment {
    let database: Database
    let documents: DocumentStore
    let git: GitClient
    let ollama: OllamaClient
    let health: HealthCheck

    init(
        database: Database = Database(),
        git: GitClient = GitClient(),
        ollama: OllamaClient = OllamaClient()
    ) {
        self.database = database
        // One connection, shared. The health check opens it, nothing here does.
        self.documents = DocumentStore(database: database)
        self.git = git
        self.ollama = ollama
        self.health = HealthCheck(database: database, git: git, ollama: ollama)
    }
}
