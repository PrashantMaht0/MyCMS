import Foundation

// What a finished git process produced.
nonisolated struct ProcessOutput: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String
    let wasTerminated: Bool
}

// Failures the git layer reports to the user.
nonisolated enum GitError: LocalizedError {
    case launchFailed(path: String, underlying: Error)
    case timedOut(seconds: Int)
    case commandFailed(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let path, let underlying):
            "Could not run \(path). \(underlying.localizedDescription)"
        case .timedOut(let seconds):
            "git did not finish within \(seconds) seconds."
        case .commandFailed(let status, let message):
            message.isEmpty ? "git exited with status \(status)." : message
        }
    }
}

// Runs the system git. Feature 7 grows this into the real publish client.
actor GitClient {
    typealias Run = @Sendable (String, [String], TimeInterval) throws -> ProcessOutput

    // An app launched from Finder has no useful PATH, so git is always absolute.
    static let executablePath = "/usr/bin/git"

    private let run: Run

    init(run: @escaping Run = GitClient.runProcess) {
        self.run = run
    }

    // Reports the installed git version, which is also the proof that git can run at all.
    func version() throws -> String {
        let output = try run(Self.executablePath, ["--version"], 5)

        if output.wasTerminated {
            throw GitError.timedOut(seconds: 5)
        }
        guard output.status == 0 else {
            throw GitError.commandFailed(status: output.status, message: output.standardError)
        }
        return output.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Launches a process and reads both pipes to completion before waiting on it.
    nonisolated static func runProcess(
        path: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw GitError.launchFailed(path: path, underlying: error)
        }

        // A timer terminates the child so a hung git cannot hang the check forever.
        let terminator = DispatchWorkItem { [weak process] in process?.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: terminator)

        // Both pipes are drained concurrently, before waitUntilExit, or a full buffer deadlocks.
        let collector = OutputCollector()
        let group = DispatchGroup()
        for (handle, isStandardOutput) in [
            (outPipe.fileHandleForReading, true),
            (errPipe.fileHandleForReading, false)
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
