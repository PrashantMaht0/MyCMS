import Foundation
import OSLog

// The first launch gate. Owns the four steps, the one hard requirement (a valid repo folder) and
// what gets written to settings when you press Start writing.
@Observable final class OnboardingModel {
    // What one step is doing right now. Only the repo step can block you from continuing.
    enum StepState: Equatable {
        case waiting
        case running
        case finished(CheckOutcome)

        var outcome: CheckOutcome? {
            if case .finished(let outcome) = self { return outcome }
            return nil
        }

        var isRunning: Bool { self == .running }
    }

    private let repository: RepositoryService
    private let ollama: OllamaClient
    private let importer: ImportService
    private let settings: SettingsStore

    private(set) var repo: RepositorySettings?
    private(set) var repoError: String?
    private(set) var isValidating = false

    private(set) var git: StepState = .waiting
    private(set) var ollamaStep: StepState = .waiting
    private(set) var importStep: StepState = .waiting
    private(set) var report: ImportReport?

    private var gitTask: Task<Void, Never>?
    // Tells a cancelled check apart from one replaced by a newer run, which must not report at all.
    private var gitCancelledByUser = false

    init(
        repository: RepositoryService,
        ollama: OllamaClient,
        importer: ImportService,
        settings: SettingsStore
    ) {
        self.repository = repository
        self.ollama = ollama
        self.importer = importer
        self.settings = settings
    }

    // The folder is the only hard gate. Everything after it can fail and you still get in.
    var canStartWriting: Bool { repo != nil && !isValidating }

    // MARK: Step 1, the folder

    func choose(folder: URL) async {
        isValidating = true
        repoError = nil
        defer { isValidating = false }

        do {
            let validated = try await repository.validate(folder: folder)
            try repository.record(validated)
            repo = validated
            Loggers.onboarding.info("Repository accepted on branch \(validated.branch, privacy: .public)")
        } catch {
            repo = nil
            repoError = message(for: error)
            Loggers.onboarding.notice("Repository rejected: \(self.repoError ?? "", privacy: .public)")
            return
        }

        // Both are about the repo and neither needs the other, so they run together.
        checkGit()
        await runImport()
    }

    // MARK: Step 2, git

    func checkGit() {
        guard let repo else { return }

        gitCancelledByUser = false
        gitTask?.cancel()
        git = .running

        gitTask = Task { [repository] in
            let outcome: CheckOutcome
            do {
                let verification = try await repository.verifyPush(repo)
                outcome = .ok(verification.detail)
            } catch is CancellationError {
                outcome = .failed(RepositoryError.checkCancelled.localizedDescription)
            } catch {
                outcome = .failed(self.message(for: error))
            }

            // A run replaced by a newer one reports nothing, or it would overwrite the new result.
            guard !Task.isCancelled || self.gitCancelledByUser else { return }
            self.git = .finished(outcome)
            try? repository.record(outcome, forKey: SettingsKey.checkGit)
        }
    }

    // A network check must never strand you on this screen, so it can always be stopped.
    func cancelGitCheck() {
        gitCancelledByUser = true
        gitTask?.cancel()
    }

    // MARK: Step 3, Ollama

    func checkOllama() {
        ollamaStep = .running

        Task { [ollama, settings, repository] in
            let expected =
                (try? settings.string(forKey: SettingsKey.ollamaModel))
                .flatMap { $0 } ?? OllamaClient.defaultModel

            let outcome: CheckOutcome
            do {
                let version = try await ollama.version()
                let installed = try await ollama.installedModels()
                let hasModel = installed.contains(expected)
                outcome = .ok(
                    "Ollama \(version) running · \(expected) \(hasModel ? "installed" : "not installed")")
            } catch {
                outcome = .failed(self.message(for: error))
            }

            self.ollamaStep = .finished(outcome)
            try? repository.record(outcome, forKey: SettingsKey.checkOllama)
        }
    }

    func skipOllama() {
        let outcome = CheckOutcome.skipped("Skipped, AI can be set up later in Settings.")
        ollamaStep = .finished(outcome)
        try? repository.record(outcome, forKey: SettingsKey.checkOllama)
    }

    // MARK: Step 4, import

    func runImport() async {
        guard let repo else { return }
        importStep = .running

        let importer = self.importer
        let url = repo.url
        let outcome: CheckOutcome
        do {
            // Reading the repo and writing the rows has no business on the main actor.
            let result = try await Task.detached(priority: .userInitiated) {
                try importer.run(repo: url)
            }.value
            report = result
            outcome = .ok(result.summaryLine)
        } catch {
            report = nil
            outcome = .failed(message(for: error))
        }

        importStep = .finished(outcome)
    }

    // MARK: Finishing

    func finish() {
        // An Ollama step nobody touched counts as skipped, so the record is never blank.
        if ollamaStep == .waiting {
            skipOllama()
        }
        try? repository.markSetupComplete()
        Loggers.onboarding.info("Setup completed")
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
