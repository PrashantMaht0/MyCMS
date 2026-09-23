import Foundation
import GRDB
import Testing

@testable import MyCMS

// The database check against a real file, in a temporary folder rather than Application Support.
@Suite("Database check")
struct DatabaseOpenTests {
    @Test("Opens and migrates a database in a folder that does not exist yet")
    func opensAndMigrates() throws {
        let folder = URL.temporaryDirectory.appending(path: "mycms-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let database = MyCMS.Database(url: folder.appending(path: "mycms.sqlite"))
        let path = try database.open()

        #expect(path.hasSuffix("mycms.sqlite"))
        #expect(FileManager.default.fileExists(atPath: path))

        // The real file carries the whole schema, not just an empty database.
        try database.read { db in
            let hasDocuments = try db.tableExists("documents")
            let hasSearchIndex = try db.tableExists("documents_fts")
            #expect(hasDocuments)
            #expect(hasSearchIndex)
        }
    }

    @Test("Reports a failure when the folder cannot be created")
    func reportsDirectoryFailure() {
        // /dev/null is a file, so a folder can never be created inside it.
        let database = MyCMS.Database(url: URL(fileURLWithPath: "/dev/null/nope/mycms.sqlite"))

        #expect(throws: DataError.self) {
            try database.open()
        }
    }
}

@Suite("Git check")
struct GitClientTests {
    @Test("Reports the version git printed")
    func reportsVersion() async throws {
        let client = GitClient { _, _, _ in
            ProcessOutput(status: 0, standardOutput: "git version 2.50.1\n", standardError: "", wasTerminated: false)
        }

        #expect(try await client.version() == "git version 2.50.1")
    }

    @Test("Surfaces a launch failure when the binary is missing")
    func surfacesLaunchFailure() async {
        let client = GitClient { path, _, _ in
            throw PublishError.launchFailed(path: path, underlying: CocoaError(.fileNoSuchFile))
        }

        await #expect(throws: PublishError.self) {
            try await client.version()
        }
    }

    @Test("Surfaces a non zero exit with its standard error text")
    func surfacesCommandFailure() async throws {
        let client = GitClient { _, _, _ in
            ProcessOutput(
                status: 128, standardOutput: "", standardError: "fatal: not a git repository", wasTerminated: false)
        }

        do {
            _ = try await client.version()
            Issue.record("Expected the check to throw")
        } catch let error as PublishError {
            #expect(error.errorDescription == "fatal: not a git repository")
        }
    }

    @Test("Reports a timeout when the process was terminated")
    func reportsTimeout() async throws {
        let client = GitClient { _, _, _ in
            ProcessOutput(status: 15, standardOutput: "", standardError: "", wasTerminated: true)
        }

        do {
            _ = try await client.version()
            Issue.record("Expected the check to throw")
        } catch let error as PublishError {
            #expect(error.errorDescription?.contains("5 seconds") == true)
        }
    }

    @Test("Runs the real git on this machine")
    func runsRealGit() async throws {
        let version = try await GitClient().version()
        #expect(version.hasPrefix("git version"))
    }
}

@Suite("Ollama check")
struct OllamaClientTests {
    @Test("Reports reachable on a 200 response")
    func reportsReachable() async throws {
        let client = OllamaClient(fetch: { request in
            (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        let detail = try await client.checkReachable()
        #expect(detail.contains("127.0.0.1:11434"))
    }

    @Test("Reports not reachable when the request fails")
    func reportsNotReachable() async {
        let client = OllamaClient(fetch: { _ in
            throw URLError(.cannotConnectToHost)
        })

        await #expect(throws: AIError.self) {
            try await client.checkReachable()
        }
    }

    @Test("Reports an unexpected status as a failure")
    func reportsUnexpectedStatus() async {
        let client = OllamaClient(fetch: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        })

        await #expect(throws: AIError.self) {
            try await client.checkReachable()
        }
    }

    @Test("Asks for the model list at the right path")
    func asksForModelList() async throws {
        let recorder = URLRecorder()
        let client = OllamaClient(fetch: { request in
            recorder.record(request.url)
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        _ = try await client.checkReachable()
        #expect(recorder.url?.absoluteString == "http://127.0.0.1:11434/api/tags")
    }
}

@Suite("Health check")
@MainActor
struct HealthCheckTests {
    @Test("Every check ends in a state, and the rows keep their fixed order")
    func runsAllThree() async {
        let folder = URL.temporaryDirectory.appending(path: "mycms-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let health = HealthCheck(
            database: MyCMS.Database(url: folder.appending(path: "mycms.sqlite")),
            git: GitClient { _, _, _ in
                ProcessOutput(status: 0, standardOutput: "git version 2.50.1", standardError: "", wasTerminated: false)
            },
            ollama: OllamaClient(fetch: { _ in throw URLError(.cannotConnectToHost) })
        )

        await health.runOnce()

        #expect(health.results.map(\.name) == CheckName.allCases)
        #expect(health.results.allSatisfy { $0.state != .pending })
        #expect(health.results.first { $0.name == .ollama }?.state == .failed)
        #expect(health.results.first { $0.name == .ollama }?.errorText != nil)
    }

    @Test("A second run does no work, because the checks are once per launch")
    func runsOnlyOnce() async {
        let folder = URL.temporaryDirectory.appending(path: "mycms-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let counter = RunCounter()
        let health = HealthCheck(
            database: MyCMS.Database(url: folder.appending(path: "mycms.sqlite")),
            git: GitClient { _, _, _ in
                counter.increment()
                return ProcessOutput(
                    status: 0, standardOutput: "git version 2.50.1", standardError: "", wasTerminated: false)
            },
            ollama: OllamaClient(fetch: { _ in throw URLError(.cannotConnectToHost) })
        )

        await health.runOnce()
        await health.runOnce()

        #expect(counter.value == 1)
    }
}

// Small thread safe boxes, because the injected closures run off the main actor.
private nonisolated final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?

    var url: URL? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        stored = url
    }
}

private nonisolated final class RunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
}

// The wiring the whole data layer rests on: one connection, opened by the check, shared by the stores.
@Suite("Database wiring")
@MainActor
struct DatabaseWiringTests {
    @Test("The check opens the same connection the store writes through")
    func checkAndStoreShareOneConnection() async throws {
        let folder = URL.temporaryDirectory.appending(path: "mycms-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let environment = AppEnvironment(
            database: MyCMS.Database(url: folder.appending(path: "mycms.sqlite")),
            git: GitClient { _, _, _ in
                ProcessOutput(status: 0, standardOutput: "git version 2.50.1", standardError: "", wasTerminated: false)
            },
            ollama: OllamaClient(fetch: { _ in throw URLError(.cannotConnectToHost) })
        )

        // Nothing is open until the check runs, which is what keeps the window instant.
        #expect(throws: DataError.self) {
            try environment.documents.list()
        }

        await environment.health.runOnce()

        #expect(environment.health.databaseFailure == nil)
        let document = try environment.documents.create(collection: .blog)
        #expect(try environment.documents.fetch(id: document.id) != nil)
    }

    @Test("A failed open blocks the surface and carries the path to reveal")
    func failedOpenBlocksTheSurface() async {
        let environment = AppEnvironment(
            database: MyCMS.Database(url: URL(fileURLWithPath: "/dev/null/nope/mycms.sqlite")),
            git: GitClient { _, _, _ in
                ProcessOutput(status: 0, standardOutput: "git version 2.50.1", standardError: "", wasTerminated: false)
            },
            ollama: OllamaClient(fetch: { _ in throw URLError(.cannotConnectToHost) })
        )

        await environment.health.runOnce()

        let failure = environment.health.databaseFailure
        #expect(failure != nil)
        #expect(failure?.errorText?.isEmpty == false)
        #expect(failure?.path?.hasSuffix("mycms.sqlite") == true)
    }
}
