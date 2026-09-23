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

// What the progress list draws beside each step.
nonisolated enum StepState: Sendable, Equatable {
    case waiting, running, done, failed
}

// What a finished run reports: the commit, and whether it reached GitHub.
nonisolated struct PublishResult: Sendable {
    let commitSHA: String
    let pushed: Bool
}

/// A publish or unpublish the app was interrupted in the middle of, found at the next launch.
///
/// `dirtyPaths` is the subset the repository still shows as changed, and `action` says which prompt
/// to show and what finishing it means.
nonisolated struct PendingPublish: Sendable, Identifiable {
    let id: Int64
    let documentID: UUID?
    let paths: [String]
    let dirtyPaths: [String]
    let message: String
    var action: PublishPlan.Action = .publish
}

/// The one writer to your portfolio repository. Everything that changes the site goes through here.
///
/// It refuses rather than guesses: `preflight` stops on a change outside the content folders, a
/// branch that is not main, or a pull that would not fast forward. `plan(for:publishDate:newSlug:)`
/// decides every file a publish will touch before a byte is written, `planUnpublish` does the same
/// for a takedown, and `publish`/`unpublish` then write, stage each path by name, commit and push.
/// A failure it survives rolls every path back; a failed push keeps the commit and offers Push now.
/// The intent row written before the first byte is what lets `reconcile` find an interrupted run at
/// the next launch.
@MainActor final class Publisher {
    private let git: GitClient
    private let settings: SettingsStore
    private let assets: AssetStore
    private let documents: DocumentStore
    private let revisions: RevisionStore

    init(
        git: GitClient, settings: SettingsStore, assets: AssetStore, documents: DocumentStore, revisions: RevisionStore
    ) {
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

    // Spec 0006 C, AC-20. A picture the app does not hold is missing, whatever the repo has.
    func validator(for document: Document) -> DocumentValidator {
        let assets = assets
        return DocumentValidator { reference in
            assets.resolve(reference: reference, for: document) != nil
        }
    }

    // Spec 0006 A, AC-8 to AC-10. A new slug lives only in this plan; the document's own slug, body
    // and cover move after the commit exists, in recordPublished.
    func plan(for document: Document, publishDate: Date, newSlug: String? = nil) throws -> PublishPlan {
        if let newSlug {
            guard SlugRule.isValid(newSlug) else { throw PublishError.slugInvalid(newSlug) }
            guard !(try documents.isSlugTaken(newSlug, in: document.collection, except: document.id)) else {
                throw PublishError.slugTaken(newSlug)
            }
        }

        let rules = validator(for: document).validate(document)
        guard DocumentValidator.allPass(rules), let current = document.slug else {
            throw PublishError.validationFailed(rules)
        }
        let slug = newSlug ?? current
        let repo = try repo()
        let collection = document.collection.rawValue
        let contentPath = "src/content/\(collection)/\(slug).md"
        let isFirst = document.publishedSlug == nil
        let old = document.publishedSlug.flatMap { $0 == slug ? nil : $0 }

        // The files carry the new address; the stored document keeps the old one until the commit.
        var written = document
        if slug != current {
            written.bodyMd = AssetStore.rewriteReferences(
                in: document.bodyMd, from: current, to: slug, collection: document.collection)
            written.cover = document.cover.map {
                AssetStore.movedPath($0, from: current, to: slug, collection: document.collection)
            }
        }

        let updatedDate = try decideUpdatedDate(
            for: written, publishDate: publishDate, repo: repo.url, isFirst: isFirst)
        let text = try FrontmatterWriter.serialize(written, publishDate: publishDate, updatedDate: updatedDate)
        let data = Data(text.utf8)

        var changes: [PublishPlan.Change] = []
        if Self.contents(of: repo.url, contentPath) != data {
            changes.append(.write(path: contentPath, data: data))
        }
        changes += try imageCopies(for: written, slug: slug, repo: repo.url)

        // AC-9. A moved address takes its old file and its known pictures with it, and leaves a redirect.
        if let old {
            let oldPath = "src/content/\(collection)/\(old).md"
            if Self.contents(of: repo.url, oldPath) != nil { changes.append(.delete(path: oldPath)) }
            changes += try PublishPlan.retireFolder(
                collection: document.collection, slug: old, known: storedNames(of: document), repo: repo.url)

            guard
                let redirects = Self.contents(of: repo.url, Redirects.path).flatMap({
                    String(data: $0, encoding: .utf8)
                })
            else { throw PublishError.redirectsUnreadable(reason: "The file is missing or is not text.") }
            let updated = try Redirects.adding(
                from: "/\(collection)/\(old)", to: "/\(collection)/\(slug)", in: redirects)
            if updated != redirects { changes.append(.write(path: Redirects.path, data: Data(updated.utf8))) }
        }

        guard !changes.isEmpty else { throw PublishError.nothingChanged }
        precondition(
            changes.allSatisfy { PublishPlan.isAllowed($0.path) },
            "A publish plan named a path outside the allowed folders")

        let verb = isFirst ? "Publish" : (document.state == .draft ? "Republish" : "Update")
        return PublishPlan(
            documentID: document.id, collection: document.collection, slug: slug, changes: changes,
            defaultMessage: "\(verb) \(collection)/\(slug)",
            publishDate: publishDate, updatedDate: updatedDate,
            fileHash: ContentHash.sha256(data), isFirstPublish: isFirst,
            movedFrom: slug != current ? current : nil)
    }

    // Spec 0006 A, AC-3. The post's Markdown and the pictures the app can put back, nothing else.
    func planUnpublish(for document: Document) throws -> PublishPlan {
        guard document.state == .published, let slug = document.publishedSlug else { throw PublishError.notPublished }
        let repo = try repo()
        let collection = document.collection.rawValue

        var changes: [PublishPlan.Change] = []
        let contentPath = "src/content/\(collection)/\(slug).md"
        if Self.contents(of: repo.url, contentPath) != nil { changes.append(.delete(path: contentPath)) }
        changes += try PublishPlan.retireFolder(
            collection: document.collection, slug: slug, known: storedNames(of: document), repo: repo.url)
        precondition(
            changes.allSatisfy { PublishPlan.isAllowed($0.path) },
            "An unpublish plan named a path outside the allowed folders")

        return PublishPlan(
            documentID: document.id, collection: document.collection, slug: slug, changes: changes,
            defaultMessage: "Unpublish \(collection)/\(slug)",
            publishDate: document.publishDate ?? Date(), updatedDate: document.updatedDate,
            fileHash: document.publishedHash ?? "", isFirstPublish: false, action: .unpublish)
    }

    // Spec 0006 A, AC-1. Redirects that will lead to a missing page once this post comes down.
    func redirectsPointing(at document: Document) -> [String] {
        guard let slug = document.publishedSlug, let repo = try? repo().url,
            let text = Self.contents(of: repo, Redirects.path).flatMap({ String(data: $0, encoding: .utf8) })
        else { return [] }
        return Redirects.sources(pointingAt: "/\(document.collection.rawValue)/\(slug)", in: text)
    }

    private func storedNames(of document: Document) throws -> Set<String> {
        Set(try assets.assets(for: document).map(\.fileName))
    }

    // AC-47. The date moves only when what a reader sees would change: identical bytes to the last
    // publish mean no, and so does a file on disk whose visible fields and body already match.
    private func decideUpdatedDate(for document: Document, publishDate: Date, repo: URL, isFirst: Bool) throws -> Date?
    {
        guard !isFirst else { return nil }

        let unchanged = try FrontmatterWriter.serialize(
            document, publishDate: publishDate, updatedDate: document.updatedDate)
        if ContentHash.sha256(Data(unchanged.utf8)) == document.publishedHash { return document.updatedDate }

        let path = "src/content/\(document.collection.rawValue)/\(document.publishedSlug ?? "").md"
        if let onDisk = try? FrontmatterReader.read(
            fileURL: repo.appending(path: path), collection: document.collection),
            Self.readerSees(onDisk.frontmatter, onDisk.body)
                == Self.readerSees(
                    FrontmatterWriter.frontmatter(for: document, publishDate: publishDate, updatedDate: nil),
                    document.bodyMd)
        {
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
        var referenced = Set(
            MarkdownRenderer.parse(document.bodyMd).images.compactMap {
                AssetStore.fileName(inReference: $0.source, collection: document.collection)
            })
        if let cover = document.cover,
            let name = AssetStore.fileName(inReference: cover, collection: document.collection)
        {
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
        try await run(plan, message: message, document: document, progress: progress)
    }

    // Spec 0006 A, AC-2 to AC-4. The same checks, staging, rollback and push as a publish.
    func unpublish(
        _ plan: PublishPlan, message: String, document: Document,
        progress: (PublishStep, StepState) -> Void
    ) async throws -> PublishResult {
        precondition(plan.action == .unpublish, "unpublish was handed a publish plan")
        // A post whose files are already gone has nothing to commit; it just becomes a draft.
        guard !plan.changes.isEmpty else {
            try await preflight()
            try recordUnpublished(plan)
            return PublishResult(commitSHA: "", pushed: true)
        }
        return try await run(plan, message: message, document: document, progress: progress)
    }

    private func run(
        _ plan: PublishPlan, message: String, document: Document,
        progress: (PublishStep, StepState) -> Void
    ) async throws -> PublishResult {
        let repo = try repo()

        progress(.preflight, .running)
        do { try await preflight() } catch {
            progress(.preflight, .failed)
            throw error
        }
        progress(.preflight, .done)

        // AC-46. The trace exists before the first byte does.
        let rowID = try writeIntent(plan, message: message)
        if plan.action == .publish { snapshot(document) }

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
        switch plan.action {
        case .publish: try recordPublished(plan, document: document)
        case .unpublish: try recordUnpublished(plan)
        }
        try updateRow(rowID, status: "committed_not_pushed", sha: sha, error: nil)

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
        guard
            let row = try documents.read({ db in
                try Publish.filter(Column("status") == "pending").order(Column("id")).fetchOne(db)
            }), let id = row.id
        else { return nil }

        let intent =
            (try? DatabaseJSON.decode(Intent.self, from: row.filesJson)) ?? Intent(action: nil, paths: [], message: "")
        let repo = try repo()
        let changed = Set(try await git.changedPaths(at: repo.url))
        return PendingPublish(
            id: id, documentID: row.documentId, paths: intent.paths,
            dirtyPaths: intent.paths.filter(changed.contains), message: intent.message,
            action: intent.action ?? .publish)
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
        // AC-11. A finished takedown leaves the document a draft, as an uninterrupted one would.
        if pending.action == .unpublish, let id = pending.documentID {
            try documents.update(
                id: id,
                [
                    Column("state").set(to: Document.State.draft.rawValue),
                    Column("published_at").set(to: Date?.none),
                ])
        }
        try updateRow(pending.id, status: "committed_not_pushed", sha: sha, error: nil)
        try await pushPending(rowID: pending.id)
    }

    // MARK: Pieces

    // A row written before spec 0006 has no action, and reads as a publish.
    private struct Intent: Codable {
        let action: PublishPlan.Action?
        let paths: [String]
        let message: String
    }

    private func writeIntent(_ plan: PublishPlan, message: String) throws -> Int64 {
        let row = Publish(
            documentId: plan.documentID, collection: plan.collection.rawValue, slug: plan.slug,
            filesJson: try DatabaseJSON.encode(Intent(action: plan.action, paths: plan.paths, message: message)),
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

    private func recordPublished(_ plan: PublishPlan, document: Document) throws {
        let now = Date()
        var assignments = [
            Column("state").set(to: Document.State.published.rawValue),
            Column("published_slug").set(to: plan.slug),
            Column("published_hash").set(to: plan.fileHash),
            Column("published_at").set(to: now),
            Column("publish_date").set(to: plan.publishDate),
            Column("updated_date").set(to: plan.updatedDate),
            // Stamped with the same instant, so the library does not call it modified straight away.
            Column("updated_at").set(to: now),
        ]
        // Spec 0006 A, AC-9. The slug and every path that names it move together, and only now.
        if let old = plan.movedFrom {
            let collection = document.collection
            assignments += [
                Column("slug").set(to: plan.slug),
                Column("body_md").set(
                    to: AssetStore.rewriteReferences(
                        in: document.bodyMd, from: old, to: plan.slug, collection: collection)),
                Column("cover").set(
                    to: document.cover.map {
                        AssetStore.movedPath($0, from: old, to: plan.slug, collection: collection)
                    }),
            ]
        }
        try documents.update(id: plan.documentID, assignments)
    }

    // Spec 0006 A, AC-4. Only the live state goes; the address and last bytes stay for a republish.
    private func recordUnpublished(_ plan: PublishPlan) throws {
        try documents.update(
            id: plan.documentID,
            [
                Column("state").set(to: Document.State.draft.rawValue),
                Column("published_at").set(to: Date?.none),
            ])
    }

    private func apply(_ change: PublishPlan.Change, in repo: URL) throws {
        let target = repo.appending(path: change.path)
        do {
            switch change {
            case .write(_, let data):
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            case .copy(_, let source):
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
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
