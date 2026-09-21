import Foundation
import OSLog

// Everything the app knows about the portfolio repo: whether a folder qualifies, whether git can
// push to it, and what was recorded last time. Feature 7 publishes through this, not around it.
nonisolated struct RepositoryService: Sendable {
    // The two folders the site's content lives in. A repo without them is the wrong repo.
    static let contentFolders = ["src/content/blog", "src/content/projects"]

    // Publishing targets main, so setup refuses anything else rather than failing at publish time.
    static let requiredBranch = "main"

    private let git: GitClient
    private let settings: SettingsStore
    private let now: @Sendable () -> Date

    init(
        git: GitClient,
        settings: SettingsStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.git = git
        self.settings = settings
        self.now = now
    }

    // MARK: Validating a folder

    // The checks run in the order their messages are worded, so the first failure is the useful one.
    func validate(folder: URL) async throws -> RepositorySettings {
        let given = folder.path(percentEncoded: false)

        guard isDirectory(folder) else { throw RepositoryError.notAGitRepo(path: given) }

        let root: String
        do {
            root = try await git.toplevel(at: folder)
        } catch {
            throw RepositoryError.notAGitRepo(path: given)
        }

        let repo = URL(fileURLWithPath: root)

        guard let remoteName = try await git.remoteName(at: repo), !remoteName.isEmpty else {
            throw RepositoryError.noRemote
        }
        let remoteUrl = try await git.remoteURL(at: repo, remote: remoteName)

        let missing = Self.contentFolders.filter { !isDirectory(repo.appending(path: $0)) }
        guard missing.isEmpty else { throw RepositoryError.missingContentFolders(missing: missing) }

        let branch = try await git.currentBranch(at: repo)
        guard branch == Self.requiredBranch else { throw RepositoryError.wrongBranch(found: branch) }

        // A dirty tree is recorded, never a blocker. Feature 7's preflight is where it matters.
        let wasDirty = (try? await git.isDirty(at: repo)) ?? false

        return RepositorySettings(
            path: root,
            remoteName: remoteName,
            remoteUrl: remoteUrl,
            branch: branch,
            wasDirtyAtSetup: wasDirty)
    }

    // The launch check. AC-23 names exactly three blocking conditions, so a branch that moved
    // since setup is re read rather than treated as a failure.
    func revalidate() async throws -> RepositorySettings {
        guard let recorded = try recorded() else { throw RepositoryError.notConfigured }

        guard isDirectory(recorded.url) else {
            throw RepositoryError.notAGitRepo(path: recorded.path)
        }

        do {
            _ = try await git.toplevel(at: recorded.url)
        } catch {
            throw RepositoryError.notAGitRepo(path: recorded.path)
        }

        guard let remoteName = try await git.remoteName(at: recorded.url), !remoteName.isEmpty else {
            throw RepositoryError.noRemote
        }

        var refreshed = recorded
        refreshed.remoteName = remoteName
        refreshed.remoteUrl = (try? await git.remoteURL(at: recorded.url, remote: remoteName)) ?? recorded.remoteUrl
        refreshed.branch = (try? await git.currentBranch(at: recorded.url)) ?? recorded.branch
        return refreshed
    }

    // MARK: Proving push access

    // ls-remote first, so a host that cannot be reached at all never reads as a rejected key.
    // A failure here carries git's own words, because ours would be a guess about your setup.
    func verifyPush(_ repository: RepositorySettings) async throws -> PushVerification {
        let version = try await git.version()

        let reachable = try await git.lsRemote(at: repository.url, remote: repository.remoteName)
        guard reachable.status == 0 else {
            throw RepositoryError.remoteUnreachable(gitMessage: reachable.failureText)
        }

        let pushable = try await git.pushDryRun(
            at: repository.url, remote: repository.remoteName, branch: repository.branch)
        guard pushable.status == 0 else {
            throw RepositoryError.pushDenied(gitMessage: pushable.failureText)
        }

        return PushVerification(
            gitVersion: version,
            canPush: true,
            detail: "\(Self.displayVersion(version)) found · can push to \(repository.remoteName)")
    }

    // git version 2.39.5 (Apple Git-154) becomes Git 2.39.5, which is what the screen has room for.
    static func displayVersion(_ raw: String) -> String {
        let number = raw
            .replacingOccurrences(of: "git version ", with: "")
            .split(separator: " ")
            .first
            .map(String.init) ?? raw
        return "Git \(number)"
    }

    // MARK: Reading and writing what was recorded

    func recorded() throws -> RepositorySettings? {
        guard
            let path = try settings.string(forKey: SettingsKey.repoPath),
            let remoteName = try settings.string(forKey: SettingsKey.repoRemoteName),
            let remoteUrl = try settings.string(forKey: SettingsKey.repoRemoteUrl),
            let branch = try settings.string(forKey: SettingsKey.repoBranch)
        else { return nil }

        return RepositorySettings(
            path: path,
            remoteName: remoteName,
            remoteUrl: remoteUrl,
            branch: branch,
            wasDirtyAtSetup: try settings.string(forKey: SettingsKey.repoWasDirtyAtSetup) == "true")
    }

    func record(_ repository: RepositorySettings) throws {
        try settings.write([
            SettingsKey.repoPath: repository.path,
            SettingsKey.repoRemoteName: repository.remoteName,
            SettingsKey.repoRemoteUrl: repository.remoteUrl,
            SettingsKey.repoBranch: repository.branch,
            SettingsKey.repoWasDirtyAtSetup: repository.wasDirtyAtSetup ? "true" : "false",
        ])
        Loggers.repository.info(
            "Recorded repository on branch \(repository.branch, privacy: .public) at \(repository.path, privacy: .private)")
    }

    func setupState() throws -> SetupState {
        SetupState(
            completedAt: try settings.date(forKey: SettingsKey.setupCompletedAt),
            repository: try recorded(),
            git: try settings.decode(CheckOutcome.self, forKey: SettingsKey.checkGit),
            ollama: try settings.decode(CheckOutcome.self, forKey: SettingsKey.checkOllama))
    }

    func record(_ outcome: CheckOutcome, forKey key: String) throws {
        try settings.encode(outcome, forKey: key)
    }

    func markSetupComplete() throws {
        try settings.setDate(now(), forKey: SettingsKey.setupCompletedAt)
    }

    // MARK: Helpers

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}
