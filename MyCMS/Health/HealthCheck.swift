import Foundation
import OSLog

// Runs the three boundary checks at launch and holds their results.
@Observable final class HealthCheck {
    private(set) var results: [CheckResult] = CheckName.allCases.map(CheckResult.pending)

    private let database: Database
    private let git: GitClient
    private let ollama: OllamaClient
    private let repository: RepositoryService?
    private var hasRun = false

    init(database: Database, git: GitClient, ollama: OllamaClient, repository: RepositoryService? = nil) {
        self.database = database
        self.git = git
        self.ollama = ollama
        self.repository = repository
    }

    // Runs once per launch. A SwiftUI task can re-fire, and each re-fire would spawn real work.
    func runOnce() async {
        guard !hasRun else { return }
        hasRun = true
        await run()
    }

    // All three run together, so the window waits for the slowest one, not for their sum.
    private func run() async {
        let database = database
        let git = git
        let ollama = ollama

        results = CheckName.allCases.map(CheckResult.pending)

        await withTaskGroup(of: CheckResult.self) { group in
            group.addTask { Self.checkDatabase(database) }
            group.addTask { await Self.checkGit(git) }
            group.addTask { await Self.checkOllama(ollama) }

            for await result in group {
                apply(result)
            }
        }
    }

    // Nothing that writes may appear while the database is unusable, so the view asks here first.
    var databaseFailure: CheckResult? {
        results.first { $0.name == .database && $0.state == .failed }
    }

    // Results arrive in whatever order they finish, so each lands in its fixed row.
    private func apply(_ result: CheckResult) {
        guard let index = results.firstIndex(where: { $0.name == result.name }) else { return }
        results[index] = result
        record(result)
    }

    // The status bar reads this row rather than rerunning a check to draw itself. Only Ollama is
    // written here: the git row holds the last proof that a push would work, which is a network
    // call setup makes deliberately, and a launch must not overwrite it with something weaker.
    private func record(_ result: CheckResult) {
        guard let repository, result.name == .ollama else { return }

        let outcome: CheckOutcome
        switch result.state {
        case .ok: outcome = .ok(result.detail)
        case .failed: outcome = .failed(result.errorText ?? result.detail)
        case .skipped: outcome = .skipped(result.detail)
        case .pending: return
        }

        // A good row setup wrote names the version and the model. A launch that merely reached Ollama
        // must not replace it with its thinner line; only a change of outcome is worth recording.
        if outcome.outcome == .ok, (try? repository.setupState().ollama?.outcome) == .ok { return }

        // A launch check is never worth failing a launch over, so a write that fails is dropped.
        try? repository.record(outcome, forKey: SettingsKey.checkOllama)
    }

    // The open runs here rather than in AppEnvironment.init, so the window appears immediately.
    private nonisolated static func checkDatabase(_ database: Database) -> CheckResult {
        do {
            let path = try database.open()
            Loggers.data.info("Database opened and migrated")
            return .ok(.database, detail: path)
        } catch {
            Loggers.data.error("Database check failed: \(error.localizedDescription, privacy: .public)")
            return .failed(.database, detail: "Could not open the database", error: error, path: database.resolvedPath)
        }
    }

    private nonisolated static func checkGit(_ git: GitClient) async -> CheckResult {
        do {
            let version = try await git.version()
            Loggers.git.info("git reported its version")
            return .ok(.git, detail: version)
        } catch {
            Loggers.git.error("Git check failed: \(error.localizedDescription, privacy: .public)")
            return .failed(.git, detail: "Could not run \(GitClient.executablePath)", error: error)
        }
    }

    private nonisolated static func checkOllama(_ ollama: OllamaClient) async -> CheckResult {
        do {
            let detail = try await ollama.checkReachable()
            Loggers.ai.info("Ollama is reachable")
            return .ok(.ollama, detail: detail)
        } catch {
            Loggers.ai.notice("Ollama is not reachable: \(error.localizedDescription, privacy: .public)")
            return .failed(.ollama, detail: "Ollama is not reachable", error: error)
        }
    }
}
