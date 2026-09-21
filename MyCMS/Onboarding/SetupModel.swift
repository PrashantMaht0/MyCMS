import Foundation
import OSLog

// What you chose to do about a file that changed outside the app.
enum OutsideChangeResolution: Sendable {
    case loadFile
    case keepMine
}

// Decides what the window shows after the health check: setup, a repair screen, or the library.
// Also owns the background scan that keeps the library honest about the repo.
@MainActor @Observable final class SetupModel {
    enum Stage: Equatable {
        case loading
        case needsSetup
        case needsRepair(String, path: String?)
        case ready
    }

    private let repository: RepositoryService
    private let importer: ImportService
    private let store: DocumentStore

    private(set) var stage: Stage = .loading
    private(set) var state: SetupState = .empty
    private(set) var changedOutside: Set<UUID> = []
    private(set) var missingFiles: Set<UUID> = []
    private(set) var isScanning = false
    var resolutionError: String?

    init(repository: RepositoryService, importer: ImportService, store: DocumentStore) {
        self.repository = repository
        self.importer = importer
        self.store = store
    }

    var repo: RepositorySettings? { state.repository }

    func makeOnboardingModel(ollama: OllamaClient, settings: SettingsStore) -> OnboardingModel {
        OnboardingModel(repository: repository, ollama: ollama, importer: importer, settings: settings)
    }

    // MARK: Deciding what to show

    func load() async {
        do {
            state = try repository.setupState()
        } catch {
            stage = .needsSetup
            return
        }

        guard state.isComplete else {
            stage = .needsSetup
            return
        }

        // AC-23 names exactly three blocking conditions, and this is where they are checked.
        do {
            let refreshed = try await repository.revalidate()
            try repository.record(refreshed)
            state.repository = refreshed
            stage = .ready
        } catch let error as RepositoryError {
            Loggers.repository.error("Recorded repository no longer usable: \(error.localizedDescription, privacy: .public)")
            stage = .needsRepair(error.localizedDescription, path: state.repository?.path)
        } catch {
            stage = .needsRepair(error.localizedDescription, path: state.repository?.path)
        }
    }

    // Setup just finished, so pick up what it recorded without revalidating it again.
    func setupFinished() {
        state = (try? repository.setupState()) ?? state
        stage = state.isComplete ? .ready : .needsSetup
    }

    // MARK: Repair, which doubles as a repo swap

    func repair(with folder: URL) async {
        let previousPath = state.repository?.path

        do {
            let validated = try await repository.validate(folder: folder)
            try repository.record(validated)

            // A different repo invalidates every recorded hash, because each one describes a file
            // in a repo that is no longer the recorded one.
            if previousPath != validated.path {
                try store.clearPublishedHashes()
                Loggers.repository.notice("Repository swapped, every published hash cleared")
            }

            state.repository = validated
            let importer = self.importer
            _ = try await runOffMainActor { try importer.run(repo: validated.url) }
            stage = .ready
            await scan()
        } catch {
            stage = .needsRepair(message(for: error), path: previousPath)
        }
    }

    // MARK: The background scan

    // Runs after the library has opened, so disk work never holds up the window. It imports as
    // well as compares, because a file added to the repo by hand has to arrive on its own.
    func scan() async {
        guard let repo = state.repository, !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        let importer = self.importer
        let findings: [ScanFinding]
        do {
            let run = try await runOffMainActor { try importer.refresh(repo: repo.url) }
            findings = run.findings
            if run.report.importedTotal > 0 {
                Loggers.repository.info(
                    "Launch scan imported \(run.report.importedTotal, privacy: .public) new file(s)")
            }
        } catch {
            Loggers.repository.error("Scan failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        changedOutside = Set(findings.compactMap { $0.verdict == .changedOutside ? $0.matchedId : nil })
        missingFiles = Set(findings.compactMap { $0.verdict == .missingFile ? $0.matchedId : nil })
    }

    // MARK: Resolving one document

    func resolve(_ id: UUID, with resolution: OutsideChangeResolution) async {
        guard let repo = state.repository else { return }
        resolutionError = nil

        let importer = self.importer
        do {
            switch resolution {
            case .loadFile:
                try await runOffMainActor { try importer.loadFileVersion(documentId: id, repo: repo.url) }
            case .keepMine:
                try await runOffMainActor { try importer.keepAppVersion(documentId: id, repo: repo.url) }
            }
            changedOutside.remove(id)
        } catch {
            resolutionError = message(for: error)
        }
    }

    // Disk and database work has no business on the main actor, however small the repo is today.
    private func runOffMainActor<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
