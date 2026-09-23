import Foundation

/// What a finished git process produced: status, both streams, and whether it was killed on timeout.
nonisolated struct ProcessOutput: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
    let wasTerminated: Bool

    var trimmedError: String { standardError.trimmingCharacters(in: .whitespacesAndNewlines) }

    // What the user is shown when a command fails, always git's own words rather than ours.
    var failureText: String {
        trimmedError.isEmpty ? "git exited with status \(status)." : trimmedError
    }
}

/// Everything publishing can refuse or fail on, each carrying the words the user sees.
///
/// Preflight refusals (`dirtyOutsideContent`, `wrongBranch`, `pullNotFastForward`), plan refusals
/// (`validationFailed`, `slugTaken`, `slugInvalid`, `unknownFilesInFolder`, `notPublished`), and
/// write time failures (`writeFailed`, `pushFailed`, `rollbackIncomplete`).
nonisolated enum PublishError: LocalizedError {
    case launchFailed(path: String, underlying: Error)
    case timedOut(seconds: Int)
    case commandFailed(status: Int32, message: String)
    case notConfigured
    case dirtyOutsideContent(paths: [String])
    case wrongBranch(found: String)
    case pullNotFastForward(gitMessage: String)
    case validationFailed([ValidationRule])
    case redirectsUnreadable(reason: String)
    case writeFailed(path: String, underlying: Error)
    case pushFailed(gitMessage: String)
    case rollbackIncomplete(paths: [String])
    case nothingChanged
    case notPublished
    case unknownFilesInFolder(paths: [String])
    case slugInvalid(String)
    case slugTaken(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let path, let underlying):
            "Could not run \(path). \(underlying.localizedDescription)"
        case .timedOut(let seconds):
            "git did not finish within \(seconds) seconds."
        case .commandFailed(let status, let message):
            message.isEmpty ? "git exited with status \(status)." : message
        case .notConfigured:
            "No repository is set up, so there is nowhere to publish to."
        case .dirtyOutsideContent(let paths):
            "Your repository has changes outside the content folders, so publishing stopped rather "
                + "than commit work it did not make:\n" + paths.joined(separator: "\n")
        case .wrongBranch(let found):
            "Your repository is on \(found). Publishing only happens from main."
        case .pullNotFastForward(let gitMessage):
            "Your repository and GitHub have both moved on, so a plain pull cannot bring them together. "
                + "Nothing was merged or rebased. Sort it out in git, then publish again.\n\n\(gitMessage)"
        case .validationFailed(let rules):
            rules.filter { !$0.passed }.map(\.problem).joined(separator: "\n")
        case .redirectsUnreadable(let reason):
            "src/redirects.ts is not in the shape the app can safely edit, so nothing was written. \(reason)"
        case .writeFailed(let path, let underlying):
            "Could not write \(path). \(underlying.localizedDescription)"
        case .pushFailed(let gitMessage):
            "The commit is safe on your machine, but the push failed. You can push it from the library.\n\n\(gitMessage)"
        case .rollbackIncomplete(let paths):
            "Publishing failed, and these paths could not be put back as they were:\n" + paths.joined(separator: "\n")
        case .nothingChanged:
            "Nothing a reader would see has changed since the last publish."
        case .notPublished:
            "This document is not live on your site, so there is nothing to unpublish."
        case .unknownFilesInFolder(let paths):
            "These files sit in the post's picture folder but the app holds no copy of them, so deleting "
                + "them would lose them. Nothing was written. Move them or add them to the post first:\n"
                + paths.joined(separator: "\n")
        case .slugInvalid(let slug):
            "\(slug.isEmpty ? "An empty address" : "“\(slug)”") is not a valid address. Use lowercase letters, "
                + "digits and single hyphens, with no hyphen at either end."
        case .slugTaken(let slug):
            "Another document in this collection already uses “\(slug)”. Pick a different address."
        }
    }
}

/// Runs the system git at `/usr/bin/git`, so the app never holds a token or talks to GitHub itself.
///
/// Every call is scoped to one repository path and times out: local commands quickly, network
/// commands slower, a push slowest. Output comes back as `ProcessOutput` with git's own words,
/// which is what every error message shows. Staging is always by explicit path, never `add -A`.
actor GitClient {
    typealias Run = @Sendable (String, [String], TimeInterval) async throws -> ProcessOutput

    // An app launched from Finder has no useful PATH, so git is always absolute.
    static let executablePath = "/usr/bin/git"

    // A local command answers instantly. A network command needs room for a real round trip.
    enum Timeout {
        static let local: TimeInterval = 5
        static let network: TimeInterval = 15
        // A push carrying pictures over a slow link needs longer than a probe does.
        static let push: TimeInterval = 90
    }

    private let run: Run

    init(run: @escaping Run = GitClient.runProcess) {
        self.run = run
    }

    // Reports the installed git version, which is also the proof that git can run at all.
    func version() async throws -> String {
        try await succeeding(["--version"])
    }

    // Resolves any folder inside a working tree to the tree's own root.
    func toplevel(at folder: URL) async throws -> String {
        try await succeeding(scoped(folder, ["rev-parse", "--show-toplevel"]))
    }

    // The first configured remote. Empty output means the repo has none at all.
    func remoteName(at repo: URL) async throws -> String? {
        let names = try await succeeding(scoped(repo, ["remote"]))
        return names.split(separator: "\n").first.map(String.init)
    }

    func remoteURL(at repo: URL, remote: String) async throws -> String {
        try await succeeding(scoped(repo, ["remote", "get-url", remote]))
    }

    func currentBranch(at repo: URL) async throws -> String {
        try await succeeding(scoped(repo, ["rev-parse", "--abbrev-ref", "HEAD"]))
    }

    // Anything printed means something is uncommitted, tracked or not.
    func isDirty(at repo: URL) async throws -> Bool {
        try await !succeeding(scoped(repo, ["status", "--porcelain"])).isEmpty
    }

    // The two network commands hand back their raw output, because a failure's own text is the
    // thing the setup screen shows and throwing here would lose it.
    func lsRemote(at repo: URL, remote: String) async throws -> ProcessOutput {
        try await output(scoped(repo, ["ls-remote", "--exit-code", remote]), timeout: Timeout.network)
    }

    func pushDryRun(at repo: URL, remote: String, branch: String) async throws -> ProcessOutput {
        try await output(
            scoped(repo, ["push", "--dry-run", remote, "\(branch):\(branch)"]),
            timeout: Timeout.network)
    }

    // MARK: Publishing, spec 0005 C

    // Every changed path, tracked or not, NUL separated so a space or quote in a name survives.
    func changedPaths(at repo: URL) async throws -> [String] {
        let raw = try await succeedingRaw(
            scoped(repo, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]))
        var paths: [String] = []
        var records = raw.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let record = records.next() {
            guard record.count > 3 else { continue }
            let code = record.prefix(2)
            paths.append(String(record.dropFirst(3)))
            // A rename or copy carries its original path as the next record.
            if code.contains("R") || code.contains("C"), let original = records.next() {
                paths.append(String(original))
            }
        }
        return paths
    }

    // AC-37. Fast forward or nothing, and the output comes back whole so its text can be shown.
    func pullFastForward(at repo: URL, remote: String, branch: String) async throws -> ProcessOutput {
        try await output(scoped(repo, ["pull", "--ff-only", remote, branch]), timeout: Timeout.network)
    }

    // AC-42. One path per call, so nothing the plan did not name can ever be staged.
    func add(at repo: URL, path: String) async throws {
        _ = try await succeeding(scoped(repo, ["add", "--", path]))
    }

    // Commits what is staged with your own git identity, and hands back the new commit.
    func commit(at repo: URL, message: String) async throws -> String {
        _ = try await succeeding(scoped(repo, ["commit", "--quiet", "-m", message]), timeout: Timeout.network)
        return try await succeeding(scoped(repo, ["rev-parse", "HEAD"]))
    }

    func push(at repo: URL, remote: String, branch: String) async throws -> ProcessOutput {
        try await output(scoped(repo, ["push", remote, "\(branch):\(branch)"]), timeout: Timeout.push)
    }

    // Takes paths back out of the index without touching the files themselves.
    func unstage(at repo: URL, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await output(scoped(repo, ["reset", "--quiet", "--"] + paths))
    }

    func isTracked(at repo: URL, path: String) async throws -> Bool {
        try await output(scoped(repo, ["ls-files", "--error-unmatch", "--", path])).status == 0
    }

    // Puts a tracked path back exactly as the last commit has it, in the index and on disk.
    func restoreFromHead(at repo: URL, path: String) async throws {
        _ = try await succeeding(scoped(repo, ["checkout", "HEAD", "--", path]))
    }

    // Every repo command is scoped with -C rather than by changing any working directory.
    private func scoped(_ repo: URL, _ arguments: [String]) -> [String] {
        ["-C", repo.path(percentEncoded: false)] + arguments
    }

    private func output(_ arguments: [String], timeout: TimeInterval = Timeout.local) async throws -> ProcessOutput {
        let result = try await run(Self.executablePath, arguments, timeout)
        if result.wasTerminated {
            throw PublishError.timedOut(seconds: Int(timeout))
        }
        return result
    }

    private func succeeding(_ arguments: [String], timeout: TimeInterval = Timeout.local) async throws -> String {
        try await succeedingRaw(arguments, timeout: timeout).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func succeedingRaw(_ arguments: [String], timeout: TimeInterval = Timeout.local) async throws -> String {
        let result = try await output(arguments, timeout: timeout)
        guard result.status == 0 else {
            throw PublishError.commandFailed(status: result.status, message: result.trimmedError)
        }
        return result.standardOutput
    }

    // git must never wait for input, or a passphrase or an HTTPS credential helper hangs the app
    // behind a prompt nobody can see. Optional locks are off so a status read never races a write.
    nonisolated static let nonInteractiveEnvironment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        return environment
    }()

    // Runs off the main actor and terminates the child when the calling task is cancelled.
    nonisolated static func runProcess(
        path: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> ProcessOutput {
        let box = ProcessBox()

        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, Error>) in
                DispatchQueue.global().async {
                    do {
                        continuation.resume(
                            returning: try runSynchronously(
                                path: path, arguments: arguments, timeout: timeout, box: box))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.terminate()
        }

        // A cancelled run also looks terminated, so cancellation is reported as itself.
        try Task.checkCancellation()
        return result
    }

    // Launches a process and reads both pipes to completion before waiting on it.
    private nonisolated static func runSynchronously(
        path: String,
        arguments: [String],
        timeout: TimeInterval,
        box: ProcessBox
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = nonInteractiveEnvironment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Started under the box's lock, so a cancellation lands either before the start, and nothing
        // runs, or after it, and the running process is terminated. There is no window between.
        do {
            guard try box.launch(process) else { throw CancellationError() }
        } catch let error as CancellationError {
            throw error
        } catch {
            throw PublishError.launchFailed(path: path, underlying: error)
        }

        // A timer terminates the child so a hung git cannot hang the check forever.
        let terminator = DispatchWorkItem { [weak process] in process?.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: terminator)

        // Both pipes are drained concurrently, before waitUntilExit, or a full buffer deadlocks.
        let collector = OutputCollector()
        let group = DispatchGroup()
        for (handle, isStandardOutput) in [
            (outPipe.fileHandleForReading, true),
            (errPipe.fileHandleForReading, false),
        ] {
            DispatchQueue.global().async(group: group) {
                let data = (try? handle.readToEnd()) ?? Data()
                collector.store(data, isStandardOutput: isStandardOutput)
            }
        }
        group.wait()

        process.waitUntilExit()
        terminator.cancel()

        return ProcessOutput(
            status: process.terminationStatus,
            standardOutput: collector.text(isStandardOutput: true),
            standardError: collector.text(isStandardOutput: false),
            wasTerminated: process.terminationReason == .uncaughtSignal
        )
    }
}

// Holds the running process so a cancelled task can reach in and stop it.
private nonisolated final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isTerminated = false

    // Returns false when the task was cancelled before the process could start.
    func launch(_ process: Process) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isTerminated else { return false }
        try process.run()
        self.process = process
        return true
    }

    func terminate() {
        lock.lock()
        let running = process
        isTerminated = true
        lock.unlock()

        if let running, running.isRunning {
            running.terminate()
        }
    }
}

// Collects both pipes from two queues, so the reads need a lock between them.
private nonisolated final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var standardOutput = Data()
    private var standardError = Data()

    func store(_ data: Data, isStandardOutput: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStandardOutput {
            standardOutput = data
        } else {
            standardError = data
        }
    }

    func text(isStandardOutput: Bool) -> String {
        lock.lock()
        defer { lock.unlock() }
        let data = isStandardOutput ? standardOutput : standardError
        return String(data: data, encoding: .utf8) ?? ""
    }
}
