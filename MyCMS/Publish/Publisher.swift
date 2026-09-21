import Foundation
import GRDB
import OSLog

// One step of a publish, for the sheet's progress list.
nonisolated enum PublishStep: String, CaseIterable, Sendable {
    case preflight = "Check the repository"
    case write = "Write the files"
    case stage = "Stage them"
    case commit = "Commit"
    case push = "Push to GitHub"
}

nonisolated enum StepState: Sendable, Equatable {
    case waiting, running, done, failed
}

nonisolated struct PublishResult: Sendable {
    let commitSHA: String
    let pushed: Bool
}

// A publish the app was interrupted in the middle of, found on the next launch.
nonisolated struct PendingPublish: Sendable, Identifiable {
    let id: Int64
    let documentID: UUID?
    let paths: [String]
    let dirtyPaths: [String]
    let message: String
}

// Spec 0005 C. The one writer to your portfolio repo. It refuses rather than guesses, writes only
// what its plan names, and leaves the working tree as it found it on any failure it survives.
@MainActor final class Publisher {
    private let git: GitClient
    private let settings: SettingsStore
    private let assets: AssetStore
    private let documents: DocumentStore
    private let revisions: RevisionStore

    init(git: GitClient, settings: SettingsStore, assets: AssetStore, documents: DocumentStore, revisions: RevisionStore) {
        self.git = git
        self.settings = settings
        self.assets = assets
        self.documents = documents
        self.revisions = revisions
    }

    private struct Repo {
        let url: URL
        let remote: String
        let branch: String
    }

    private func repo() throws -> Repo {
        guard let path = try settings.string(forKey: SettingsKey.repoPath) else { throw PublishError.notConfigured }
        return Repo(
            url: URL(fileURLWithPath: path),
            remote: try settings.string(forKey: SettingsKey.repoRemoteName) ?? "origin",
            branch: RepositoryService.requiredBranch)
    }

    // The public address a slug will have, when the remote is a GitHub Pages repository.
    func siteURL(collection: Document.Collection, slug: String) -> String {
        let path = "/\(collection.rawValue)/\(slug)"
        guard let remote = (try? settings.string(forKey: SettingsKey.repoRemoteUrl)) ?? nil,
            let host = remote.split(separator: "/").last?.replacingOccurrences(of: ".git", with: ""),
            host.lowercased().hasSuffix(".github.io")
        else { return path }
        return "https://\(host.lowercased())\(path)"
    }

    // MARK: Preflight

    // AC-35 to AC-37, all before anything is written.
    func preflight() async throws {
        let repo = try repo()

        let outside = try await git.changedPaths(at: repo.url).filter { !PublishPlan.isAllowed($0) }
        guard outside.isEmpty else { throw PublishError.dirtyOutsideContent(paths: outside.sorted()) }

        let branch = try await git.currentBranch(at: repo.url)
        guard branch == repo.branch else { throw PublishError.wrongBranch(found: branch) }

        let pull = try await git.pullFastForward(at: repo.url, remote: repo.remote, branch: repo.branch)
        guard pull.status == 0 else { throw PublishError.pullNotFastForward(gitMessage: pull.failureText) }
    }

    // MARK: Validation and planning

    func validator(for document: Document) -> DocumentValidator {
        let repoURL = try? repo().url
        let assets = assets
        return DocumentValidator { reference in
            if assets.resolve(reference: reference, for: document) != nil { return true }
            guard let repoURL else { return false }
            return AssetStore.repoFile(for: reference, collection: document.collection, repo: repoURL) != nil
        }
    }

    func plan(for document: Document, publishDate: Date) throws -> PublishPlan {
        let rules = validator(for: document).validate(document)
        guard DocumentValidator.allPass(rules), let slug = document.slug else {
            throw PublishError.validationFailed(rules)
        }
        let repo = try repo()
        let contentPath = "src/content/\(document.collection.rawValue)/\(slug).md"
        let isFirst = document.publishedSlug == nil

        let updatedDate = try decideUpdatedDate(
            for: document, publishDate: publishDate, repo: repo.url, isFirst: isFirst)
        let text = try FrontmatterWriter.serialize(document, publishDate: publishDate, updatedDate: updatedDate)
        let data = Data(text.utf8)

        var changes: [PublishPlan.Change] = []
        if Self.contents(of: repo.url, contentPath) != data {
            changes.append(.write(path: contentPath, data: data))
        }
        changes += try imageCopies(for: document, slug: slug, repo: repo.url)

        // AC-41. A published slug that moved leaves a redirect behind and its old file goes.
        if let old = document.publishedSlug, old != slug {
            let oldPath = "src/content/\(document.collection.rawValue)/\(old).md"
            if Self.contents(of: repo.url, oldPath) != nil { changes.append(.delete(path: oldPath)) }

            guard let redirects = Self.contents(of: repo.url, Redirects.path).flatMap({ String(data: $0, encoding: .utf8) })
            else { throw PublishError.redirectsUnreadable(reason: "The file is missing or is not text.") }
            let updated = try Redirects.adding(
                from: "/\(document.collection.rawValue)/\(old)", to: "/\(document.collection.rawValue)/\(slug)",
                in: redirects)
            if updated != redirects { changes.append(.write(path: Redirects.path, data: Data(updated.utf8))) }
        }

        guard !changes.isEmpty else { throw PublishError.nothingChanged }
        precondition(changes.allSatisfy { PublishPlan.isAllowed($0.path) }, "A publish plan named a path outside the allowed folders")

        let verb = isFirst ? "Publish" : "Update"
        return PublishPlan(
            documentID: document.id, collection: document.collection, slug: slug, changes: changes,
            defaultMessage: "\(verb) \(document.collection.rawValue)/\(slug)",
            publishDate: publishDate, updatedDate: updatedDate,
            fileHash: ContentHash.sha256(data), isFirstPublish: isFirst)
    }

    // AC-47. The date moves only when what a reader sees would change: identical bytes to the last
    // publish mean no, and so does a file on disk whose visible fields and body already match.
    private func decideUpdatedDate(for document: Document, publishDate: Date, repo: URL, isFirst: Bool) throws -> Date? {
        guard !isFirst else { return nil }

        let unchanged = try FrontmatterWriter.serialize(document, publishDate: publishDate, updatedDate: document.updatedDate)
        if ContentHash.sha256(Data(unchanged.utf8)) == document.publishedHash { return document.updatedDate }

        let path = "src/content/\(document.collection.rawValue)/\(document.publishedSlug ?? "").md"
        if let onDisk = try? FrontmatterReader.read(fileURL: repo.appending(path: path), collection: document.collection),
            Self.readerSees(onDisk.frontmatter, onDisk.body)
                == Self.readerSees(FrontmatterWriter.frontmatter(for: document, publishDate: publishDate, updatedDate: nil), document.bodyMd) {
            return document.updatedDate
        }
        return Date()
    }

    private static func readerSees(_ frontmatter: Frontmatter, _ body: String) -> [String] {
        [
            frontmatter.title ?? "", frontmatter.description ?? "", frontmatter.cover ?? "",
            // Tags and featured are how a post is filed, not what it says, so they never move the date.
            frontmatter.coverAlt ?? "",
            frontmatter.role ?? "", frontmatter.timeline ?? "", frontmatter.status?.rawValue ?? "",
            (frontmatter.tech ?? []).joined(separator: ","),
            body.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
    }

    // AC-40. Each stored picture the post uses goes to src/assets/<collection>/<slug>/, unless an
    // identical file is already there.
    private func imageCopies(for document: Document, slug: String, repo: URL) throws -> [PublishPlan.Change] {
        var referenced = Set(MarkdownRenderer.parse(document.bodyMd).images.compactMap {
            AssetStore.fileName(inReference: $0.source, collection: document.collection)
        })
        if let cover = document.cover, let name = AssetStore.fileName(inReference: cover, collection: document.collection) {
            referenced.insert(name)
        }

        return try assets.assets(for: document)
            .filter { referenced.contains($0.fileName) }
            .compactMap { asset in
                let path = "src/assets/\(document.collection.rawValue)/\(slug)/\(asset.fileName)"
                if let existing = Self.contents(of: repo, path), ContentHash.sha256(existing) == asset.sha256 {
                    return nil
                }
                return .copy(path: path, from: assets.fileURL(for: asset))
            }
    }

    // MARK: Publishing

    func publish(
        _ plan: PublishPlan, message: String, document: Document,
        progress: (PublishStep, StepState) -> Void
    ) async throws -> PublishResult {
        let repo = try repo()

        progress(.preflight, .running)
        do { try await preflight() } catch { progress(.preflight, .failed); throw error }
        progress(.preflight, .done)

        // AC-46. The trace exists before the first byte does.
        let rowID = try writeIntent(plan, message: message)
        snapshot(document)

        progress(.write, .running)
        var originals: [String: Data?] = [:]
        do {
            for change in plan.changes {
                // updateValue, because assigning a nil Data would drop the key and forget a new file.
                originals.updateValue(Self.contents(of: repo.url, change.path), forKey: change.path)
                try apply(change, in: repo.url)
            }
        } catch {
            progress(.write, .failed)
            try await fail(rowID, plan: plan, originals: originals, repo: repo.url, error: error)
        }
        progress(.write, .done)

        progress(.stage, .running)
        do {
            for path in plan.paths { try await git.add(at: repo.url, path: path) }
        } catch {
            progress(.stage, .failed)
            try await fail(rowID, plan: plan, originals: originals, repo: repo.url, error: error)
        }
        progress(.stage, .done)

        progress(.commit, .running)
        let sha: String
        do {
            sha = try await git.commit(at: repo.url, message: message)
        } catch {
            progress(.commit, .failed)
            try await fail(rowID, plan: plan, originals: originals, repo: repo.url, error: error)
        }
        progress(.commit, .done)
        Loggers.publish.info("Committed \(plan.defaultMessage, privacy: .public) as \(sha, privacy: .public)")

        // AC-45. The document records what is now in the repo, whether or not the push lands.
        try recordPublished(plan, sha: sha, rowID: rowID)

        progress(.push, .running)
        let push = try await git.push(at: repo.url, remote: repo.remote, branch: repo.branch)
        guard push.status == 0 else {
            progress(.push, .failed)
            // AC-44. The commit stays; the row says so, and the library offers Push now.
            try updateRow(rowID, status: "committed_not_pushed", sha: sha, error: push.failureText)
            throw PublishError.pushFailed(gitMessage: push.failureText)
        }
        try updateRow(rowID, status: "pushed", sha: sha, error: nil)
        progress(.push, .done)
        return PublishResult(commitSHA: sha, pushed: true)
    }

    // AC-44. The Push now action for a commit that never left your machine.
    func pushPending(rowID: Int64) async throws {
        let repo = try repo()
        let push = try await git.push(at: repo.url, remote: repo.remote, branch: repo.branch)
        guard push.status == 0 else {
            try updateRow(rowID, status: "committed_not_pushed", sha: nil, error: push.failureText)
            throw PublishError.pushFailed(gitMessage: push.failureText)
        }
        try updateRow(rowID, status: "pushed", sha: nil, error: nil)
    }

    // The newest publish of a document, which is where a stuck push shows up.
    func latestPublish(for documentID: UUID) throws -> Publish? {
        try documents.read { db in
            try Publish.filter(Column("document_id") == documentID.uuidString)
                .order(Column("id").desc)
                .fetchOne(db)
        }
    }

    // MARK: Recovery

    // AC-46. A publish still pending at launch was interrupted by a crash or a force quit.
    func reconcile() async throws -> PendingPublish? {
        guard let row = try documents.read({ db in
            try Publish.filter(Column("status") == "pending").order(Column("id")).fetchOne(db)
        }), let id = row.id else { return nil }

        let intent = (try? DatabaseJSON.decode(Intent.self, from: row.filesJson)) ?? Intent(paths: [], message: "")
        let repo = try repo()
        let changed = Set(try await git.changedPaths(at: repo.url))
        return PendingPublish(
            id: id, documentID: row.documentId, paths: intent.paths,
            dirtyPaths: intent.paths.filter(changed.contains), message: intent.message)
    }

    // Puts every path the interrupted publish touched back as the last commit has it.
    func discard(_ pending: PendingPublish) async throws {
        let repo = try repo()
        try await git.unstage(at: repo.url, paths: pending.dirtyPaths)
        for path in pending.dirtyPaths {
            if try await git.isTracked(at: repo.url, path: path) {
                try await git.restoreFromHead(at: repo.url, path: path)
            } else {
                try? FileManager.default.removeItem(at: repo.url.appending(path: path))
            }
        }
        try updateRow(pending.id, status: "failed", sha: nil, error: "Discarded after an interrupted publish.")
    }

    // Completes an interrupted publish from what it had already written.
    func finish(_ pending: PendingPublish) async throws {
        let repo = try repo()
        for path in pending.dirtyPaths { try await git.add(at: repo.url, path: path) }
        let sha = try await git.commit(at: repo.url, message: pending.message)
        try updateRow(pending.id, status: "committed_not_pushed", sha: sha, error: nil)
        try await pushPending(rowID: pending.id)
    }

    // MARK: Pieces

    private struct Intent: Codable {
        let paths: [String]
        let message: String
    }

    private func writeIntent(_ plan: PublishPlan, message: String) throws -> Int64 {
        let row = Publish(
            documentId: plan.documentID, collection: plan.collection.rawValue, slug: plan.slug,
            filesJson: try DatabaseJSON.encode(Intent(paths: plan.paths, message: message)),
            status: "pending", createdAt: Date())
        return try documents.write { db in
            try row.insert(db)
            return db.lastInsertedRowID
        }
    }

    private func updateRow(_ id: Int64, status: String, sha: String?, error: String?) throws {
        try documents.write { db in
            if let sha {
                try db.execute(
                    sql: "UPDATE publishes SET status = ?, commit_sha = ?, error = ? WHERE id = ?",
                    arguments: [status, sha, error, id])
            } else {
                try db.execute(
                    sql: "UPDATE publishes SET status = ?, error = ? WHERE id = ?", arguments: [status, error, id])
            }
        }
    }

    // The publish reason snapshot, so publishing never ships without an undo. Child D owns the rest.
    private func snapshot(_ document: Document) {
        do {
            try revisions.snapshot(document, body: document.bodyMd, reason: .publish)
        } catch {
            Loggers.publish.error("Publish snapshot failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func recordPublished(_ plan: PublishPlan, sha: String, rowID: Int64) throws {
        let now = Date()
        try documents.update(
            id: plan.documentID, [
                Column("state").set(to: Document.State.published.rawValue),
                Column("published_slug").set(to: plan.slug),
                Column("published_hash").set(to: plan.fileHash),
                Column("published_at").set(to: now),
                Column("publish_date").set(to: plan.publishDate),
                Column("updated_date").set(to: plan.updatedDate),
                // Stamped with the same instant, so the library does not call it modified straight away.
                Column("updated_at").set(to: now),
            ])
        try updateRow(rowID, status: "committed_not_pushed", sha: sha, error: nil)
    }

    private func apply(_ change: PublishPlan.Change, in repo: URL) throws {
        let target = repo.appending(path: change.path)
        do {
            switch change {
            case .write(_, let data):
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            case .copy(_, let source):
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: source).write(to: target, options: .atomic)
            case .delete:
                try FileManager.default.removeItem(at: target)
            }
        } catch {
            throw PublishError.writeFailed(path: change.path, underlying: error)
        }
    }

    // AC-46. A failure the app survives unstages and restores every path, then marks the row.
    private func fail(
        _ rowID: Int64, plan: PublishPlan, originals: [String: Data?], repo: URL, error: Error
    ) async throws -> Never {
        try? await git.unstage(at: repo, paths: plan.paths)

        var stuck: [String] = []
        for (path, original) in originals {
            let target = repo.appending(path: path)
            do {
                if let original {
                    try original.write(to: target, options: .atomic)
                } else if FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: target)
                }
            } catch {
                stuck.append(path)
            }
        }

        try? updateRow(rowID, status: "failed", sha: nil, error: error.localizedDescription)
        Loggers.publish.error("Publish failed and was rolled back: \(error.localizedDescription, privacy: .public)")
        if !stuck.isEmpty { throw PublishError.rollbackIncomplete(paths: stuck.sorted()) }
        throw error
    }

    private static func contents(of repo: URL, _ path: String) -> Data? {
        try? Data(contentsOf: repo.appending(path: path))
    }
}
