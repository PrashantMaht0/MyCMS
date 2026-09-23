import AppKit
import Foundation
import OSLog

// Spec 0005 E. One set of preferences read from the settings table and written back on every
// change, shared by the Settings window, the sidebar route and the open editor alike.
@Observable final class SettingsModel {
    // Editor
    var fontSize: Double = Double(Broadsheet.TypeScale.body) {
        didSet { write(SettingsKey.editorFontSize, String(fontSize)) }
    }
    var showMarkers = true { didSet { write(SettingsKey.editorShowMarkers, showMarkers ? "true" : "false") } }

    // AI
    var ollamaURL = OllamaClient.defaultBaseURL.absoluteString { didSet { write(SettingsKey.ollamaURL, ollamaURL) } }
    var model = OllamaClient.defaultModel { didSet { write(SettingsKey.ollamaModel, model) } }
    var grammarEnabled = true { didSet { write(SettingsKey.aiGrammarEnabled, grammarEnabled ? "true" : "false") } }
    var punctuationEnabled = true {
        didSet { write(SettingsKey.aiPunctuationEnabled, punctuationEnabled ? "true" : "false") }
    }
    var rewritesEnabled = true { didSet { write(SettingsKey.aiRewritesEnabled, rewritesEnabled ? "true" : "false") } }
    var checkDelay = 1.5 { didSet { write(SettingsKey.aiCheckDelaySeconds, String(checkDelay)) } }

    // Read only views of the recorded rows.
    private(set) var repository: RepositorySettings?
    private(set) var ollamaStatus: CheckOutcome?
    private(set) var installedModels: [String] = []
    private(set) var modelListProblem: String?
    private(set) var repositoryProblem: String?
    private(set) var isChangingRepository = false
    private(set) var exportMessage: String?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let repositoryService: RepositoryService
    @ObservationIgnored private let setup: SetupModel
    @ObservationIgnored private let database: Database
    @ObservationIgnored private let documents: DocumentStore
    // Set while load() fills the properties, so reading a row never writes it straight back.
    @ObservationIgnored private var isLoading = false

    init(
        settings: SettingsStore, repository: RepositoryService, setup: SetupModel, database: Database,
        documents: DocumentStore
    ) {
        self.settings = settings
        self.repositoryService = repository
        self.setup = setup
        self.database = database
        self.documents = documents
    }

    // AC-60. Everything comes back from the table, so every value survives a relaunch.
    func load() {
        isLoading = true
        defer { isLoading = false }

        let string = { (key: String) in (try? self.settings.string(forKey: key)) ?? nil }
        fontSize = string(SettingsKey.editorFontSize).flatMap(Double.init) ?? Double(Broadsheet.TypeScale.body)
        showMarkers = string(SettingsKey.editorShowMarkers) != "false"
        ollamaURL = string(SettingsKey.ollamaURL) ?? OllamaClient.defaultBaseURL.absoluteString
        model = string(SettingsKey.ollamaModel) ?? OllamaClient.defaultModel
        grammarEnabled = string(SettingsKey.aiGrammarEnabled) != "false"
        punctuationEnabled = string(SettingsKey.aiPunctuationEnabled) != "false"
        rewritesEnabled = string(SettingsKey.aiRewritesEnabled) != "false"
        checkDelay = string(SettingsKey.aiCheckDelaySeconds).flatMap(Double.init) ?? 1.5
        refreshRecorded()
    }

    // AC-62. The status bar's source: stored rows, never a fresh check.
    func refreshRecorded() {
        repository = try? repositoryService.recorded()
        ollamaStatus = try? settings.decode(CheckOutcome.self, forKey: SettingsKey.checkOllama)
    }

    private func write(_ key: String, _ value: String) {
        guard !isLoading else { return }
        do {
            try settings.set(value, forKey: key)
        } catch {
            Loggers.data.error(
                "Could not save \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: AI

    // AC-57. The live installed list, with the stored model kept visible when Ollama cannot answer.
    func refreshModels() async {
        guard let url = URL(string: ollamaURL), url.scheme != nil else {
            modelListProblem = "That is not a web address."
            return
        }
        do {
            installedModels = try await OllamaClient(baseURL: url).installedModels().sorted()
            modelListProblem = nil
        } catch {
            installedModels = []
            modelListProblem = "Could not read the model list from Ollama. \(error.localizedDescription)"
        }
    }

    // MARK: Repository

    // AC-56. The same validation setup uses, word for word, then setup's own swap and import.
    func changeRepository(to folder: URL) async {
        isChangingRepository = true
        defer { isChangingRepository = false }
        do {
            _ = try await repositoryService.validate(folder: folder)
            repositoryProblem = nil
            await setup.repair(with: folder)
        } catch {
            repositoryProblem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        refreshRecorded()
    }

    // MARK: Data

    var databaseFolder: URL { database.url.deletingLastPathComponent() }

    func revealDatabaseFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([database.url])
    }

    // AC-59. Every document, draft or published, written the way a publish would write it.
    func export(to folder: URL) {
        write(SettingsKey.exportLastFolder, folder.path(percentEncoded: false))
        do {
            let count = try ExportService(documents: documents).exportAll(to: folder)
            exportMessage = "Exported \(count) documents to \(folder.lastPathComponent)."
        } catch {
            exportMessage = error.localizedDescription
        }
    }
}
