import Foundation

// Failures the repository layer reports to the user. Every message names the check that failed,
// because the setup screen's whole job is telling you which one it was.
nonisolated enum RepositoryError: LocalizedError, Equatable {
    case notConfigured
    case notAGitRepo(path: String)
    case noRemote
    case missingContentFolders(missing: [String])
    case wrongBranch(found: String)
    case remoteUnreachable(gitMessage: String)
    case pushDenied(gitMessage: String)
    case checkCancelled
    // Reading a content file.
    case unreadable(reason: String)
    case notText
    case noFence
    case invalidYAML(reason: String)
    case missingFields(names: [String])
    // Importing and resolving divergences.
    case documentNotFound
    case fileGone(path: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "No repository has been chosen yet."
        case .notAGitRepo(let path):
            "That folder is not a git repository.\n\(path)"
        case .noRemote:
            "That repository has no remote, so nothing could be published from it."
        case .missingContentFolders(let missing):
            "That repository has no \(missing.joined(separator: " and ")). "
                + "This app writes into a portfolio site built with those folders."
        case .wrongBranch(let found):
            "That repository is on \(found). Switch it to \(RepositoryService.requiredBranch) first."
        case .remoteUnreachable(let gitMessage):
            gitMessage
        case .pushDenied(let gitMessage):
            gitMessage
        case .checkCancelled:
            "The check was cancelled before it finished."
        case .unreadable(let reason): "The file could not be read. \(reason)"
        case .notText: "The file is not UTF 8 text."
        case .noFence: "The file has no --- frontmatter block at the top."
        case .invalidYAML(let reason): "The frontmatter is not valid YAML. \(reason)"
        case .missingFields(let names): "The frontmatter is missing \(names.joined(separator: ", "))."
        case .documentNotFound: "That document is no longer in the database."
        case .fileGone(let path): "There is no file at \(path) any more."
        }
    }

    // The repair screen shows the recorded path beside the reason, the way the database panel does.
    var path: String? {
        if case .notAGitRepo(let path) = self { return path }
        return nil
    }
}
