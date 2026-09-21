import Foundation

// What one launch check can be.
nonisolated enum CheckState: Sendable {
    case pending
    case ok
    case failed
    case skipped
}

// The three checks, in the order they are always displayed.
nonisolated enum CheckName: String, CaseIterable, Sendable {
    case database = "Database"
    case git = "Git"
    case ollama = "Ollama"

    // Only the database stops the app. Git and Ollama failing are things you can still work around,
    // so they must never be drawn like a fatal failure.
    var isFatal: Bool { self == .database }
}

// One row of the launch report.
nonisolated struct CheckResult: Identifiable, Sendable {
    let name: CheckName
    var state: CheckState
    var detail: String
    var errorText: String?
    // The file the failure was about, so the panel can offer to reveal its folder.
    var path: String?

    var id: CheckName { name }

    static func pending(_ name: CheckName) -> CheckResult {
        CheckResult(name: name, state: .pending, detail: "Checking", errorText: nil, path: nil)
    }

    static func ok(_ name: CheckName, detail: String) -> CheckResult {
        CheckResult(name: name, state: .ok, detail: detail, errorText: nil, path: nil)
    }

    // The real underlying text is kept, because it is the only thing that says how to fix it.
    static func skipped(_ name: CheckName, detail: String) -> CheckResult {
        CheckResult(name: name, state: .skipped, detail: detail, errorText: nil, path: nil)
    }

    static func failed(_ name: CheckName, detail: String, error: Error, path: String? = nil) -> CheckResult {
        CheckResult(
            name: name,
            state: .failed,
            detail: detail,
            errorText: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
            path: path ?? (error as? DataError)?.path
        )
    }
}
