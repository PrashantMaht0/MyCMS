import Foundation

// The portfolio repo the app publishes into, as recorded in the settings table.
nonisolated struct RepositorySettings: Codable, Equatable, Sendable {
    var path: String
    var remoteName: String
    var remoteUrl: String
    var branch: String
    var wasDirtyAtSetup: Bool

    var url: URL { URL(fileURLWithPath: path) }

    // github.com/Owner/Repo, for the setup screen and the status bar. Display only, never stored.
    var shortRemote: String { Self.shorten(remoteUrl) }

    static func shorten(_ remoteUrl: String) -> String {
        var text = remoteUrl.trimmingCharacters(in: .whitespacesAndNewlines)

        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        }
        if let at = text.firstIndex(of: "@") {
            text = String(text[text.index(after: at)...])
        }
        // An SSH remote separates host and path with a colon, which reads wrong on screen.
        if let colon = text.firstIndex(of: ":") {
            text.replaceSubrange(colon...colon, with: "/")
        }
        if text.hasSuffix(".git") {
            text.removeLast(4)
        }
        return text
    }
}

// What the app remembers about setup itself, so reopening skips straight to the library.
nonisolated struct SetupState: Sendable {
    var completedAt: Date?
    var repository: RepositorySettings?
    var git: CheckOutcome?
    var ollama: CheckOutcome?

    // Both halves are required. A completion stamp with no repo is not a finished setup.
    var isComplete: Bool { completedAt != nil && repository != nil }

    static let empty = SetupState()
}

// What proving push access produced, and the line the setup screen shows for it.
nonisolated struct PushVerification: Sendable {
    var gitVersion: String
    var canPush: Bool
    var detail: String
}
