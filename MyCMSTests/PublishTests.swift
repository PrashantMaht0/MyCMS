import Foundation
import GRDB
import ImageIO
import Testing

@testable import MyCMS

private let day = FlexibleDate.dayFormatter

@Suite("Frontmatter writer")
struct FrontmatterWriterTests {

    private func blogDocument() -> Document {
        Document(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            collection: .blog, slug: "a-post",
            title: "Tricky: a title with \"quotes\" and a colon", description: "One line.",
            bodyMd: "## Heading\n\nBody with **bold**.\n",
            tags: ["swift", "mac-apps"], featured: true,
            fields: DocumentFields(canonicalUrl: URL(string: "https://example.com/a")),
            createdAt: Date(), updatedAt: Date())
    }

    @Test("A document writes frontmatter the reader reads back identically, with cmsId and draft false, per AC-39")
    func roundTrips() throws {
        let document = blogDocument()
        let text = try FrontmatterWriter.serialize(
            document, publishDate: day.date(from: "2026-09-21")!, updatedDate: nil)

        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let read = try FrontmatterReader.read(fileURL: url, collection: .blog)

        #expect(read.frontmatter.title == document.title)
        #expect(read.frontmatter.cmsId == document.id)
        #expect(read.frontmatter.draft == false)
        #expect(read.frontmatter.featured == true)
        #expect(read.frontmatter.tags == ["swift", "mac-apps"])
        #expect(read.frontmatter.canonicalUrl == URL(string: "https://example.com/a"))
        #expect(read.frontmatter.publishDate.map { day.string(from: $0.value) } == "2026-09-21")
        #expect(read.frontmatter.updatedDate == nil)
        #expect(text.hasSuffix("\n\n## Heading\n\nBody with **bold**.\n"))
    }
}

// A real working repository with a bare remote, both throwaway, so nothing touches your site.
@MainActor
private final class Sandbox {
    let root = FileManager.default.temporaryDirectory.appending(path: "publish-\(UUID().uuidString)")
    var work: URL { root.appending(path: "work") }
    var remote: URL { root.appending(path: "remote.git") }

    let database: MyCMS.Database
    let documents: DocumentStore
    let settings: SettingsStore
    let assets: AssetStore
    let publisher: Publisher

    init() throws {
        database = try MyCMS.Database.inMemory()
        documents = DocumentStore(database: database)
        settings = SettingsStore(database: database)
        assets = AssetStore(database: database, root: root.appending(path: "app-assets"))
        publisher = Publisher(
            git: GitClient(), settings: settings, assets: assets, documents: documents,
            revisions: RevisionStore(database: database))

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.git(root, "init", "--quiet", "--bare", "--initial-branch=main", remote.path(percentEncoded: false))
        try Self.git(root, "init", "--quiet", "--initial-branch=main", work.path(percentEncoded: false))
        try Self.git(work, "config", "user.name", "Test Writer")
        try Self.git(work, "config", "user.email", "writer@example.com")
        try Self.git(work, "config", "commit.gpgsign", "false")
        try Self.git(work, "remote", "add", "origin", remote.path(percentEncoded: false))

        try write("src/content/blog/.gitkeep", "")
        try write("src/assets/.gitkeep", "")
        try write("src/pages/index.astro", "<h1>Home</h1>\n")
        try write(
            Redirects.path,
            """
            /**
             * Append-only slug redirect map.
             * Format: '/blog/old-slug': '/blog/new-slug'
             */
            export const redirects: Record<string, string> = {
              // The wireframe folds "About" into the homepage; keep the old path alive.
              '/about': '/#about',
            };

            """)
        try Self.git(work, "add", ".")
        try Self.git(work, "commit", "--quiet", "-m", "Start")
        try Self.git(work, "push", "--quiet", "origin", "main")

        try settings.set(work.path(percentEncoded: false), forKey: SettingsKey.repoPath)
        try settings.set("origin", forKey: SettingsKey.repoRemoteName)
    }

    func write(_ path: String, _ text: String) throws {
        let url = work.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ path: String) -> String? {
        try? String(contentsOf: work.appending(path: path), encoding: .utf8)
    }

    func draft(title: String = "Hello World", description: String = "A first post.", body: String = "Hi.\n") throws
        -> Document
    {
        var document = try documents.create(collection: .blog)
        try documents.update(
            id: document.id,
            [
                Column("title").set(to: title), Column("description").set(to: description),
                Column("body_md").set(to: body), Column("slug").set(to: SlugRule.derive(from: title)),
            ])
        document = try #require(try documents.fetch(id: document.id))
        return document
    }

    func publish(_ document: Document, date: String = "2026-09-21") async throws -> PublishResult {
        let plan = try publisher.plan(for: document, publishDate: day.date(from: date)!)
        return try await publisher.publish(plan, message: plan.defaultMessage, document: document) { _, _ in }
    }

    @discardableResult
    static func git(_ at: URL, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", at.path(percentEncoded: false)] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func log(_ repo: URL? = nil) throws -> [String] {
        try Self.git(repo ?? work, "log", "--format=%s", "main").split(separator: "\n").map(String.init)
    }

    func status() throws -> String {
        try Self.git(work, "status", "--porcelain")
    }
}

private func png() throws -> Data {
    let context = try #require(
        CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

@Suite("Publishing", .serialized)
@MainActor
struct PublisherTests {

    @Test("A draft with a picture lands on main with its frontmatter, its image and one pushed commit")
    func happyPath() async throws {
        let box = try Sandbox()
        var document = try box.draft()
        let asset = try box.assets.store(data: png(), suggestedName: "shot.png", for: document)
        let path = AssetStore.markdownPath(fileName: asset.fileName, collection: .blog, slug: "hello-world")
        try box.documents.update(id: document.id, Column("body_md").set(to: "Hi.\n\n![A shot](\(path))\n"))
        document = try #require(try box.documents.fetch(id: document.id))

        let result = try await box.publish(document)

        let file = try #require(box.read("src/content/blog/hello-world.md"))
        #expect(file.contains("cmsId: \(document.id.uuidString)"))
        #expect(file.contains("draft: false"))
        #expect(file.hasSuffix("Hi.\n\n![A shot](\(path))\n"))
        #expect(
            FileManager.default.fileExists(
                atPath: box.work.appending(path: "src/assets/blog/hello-world/shot.png").path(percentEncoded: false)))
        #expect(result.pushed)
        #expect(try box.log(box.remote).first == "Publish blog/hello-world")
        #expect(try box.status().isEmpty)

        let saved = try #require(try box.documents.fetch(id: document.id))
        #expect(saved.state == .published)
        #expect(saved.publishedSlug == "hello-world")
        #expect(saved.publishedHash == ContentHash.sha256(Data(file.utf8)))
        #expect(try box.publisher.latestPublish(for: document.id)?.status == "pushed")
        #expect(try box.publisher.latestPublish(for: document.id)?.commitSha == result.commitSHA)
        let revisions = try box.documents.read { db in try Revision.fetchCount(db) }
        #expect(revisions == 1)
    }

    @Test("A change outside the content folders stops it, naming the path, with nothing written, per AC-35")
    func refusesDirtyOutside() async throws {
        let box = try Sandbox()
        try box.write("src/pages/index.astro", "<h1>Edited</h1>\n")
        let document = try box.draft()

        await #expect { try await box.publish(document) } throws: { error in
            guard case PublishError.dirtyOutsideContent(let paths) = error else { return false }
            return paths == ["src/pages/index.astro"]
        }
        #expect(box.read("src/content/blog/hello-world.md") == nil)
    }

    @Test("A branch that is not main stops it, per AC-36")
    func refusesWrongBranch() async throws {
        let box = try Sandbox()
        try Sandbox.git(box.work, "checkout", "--quiet", "-b", "feature")
        let document = try box.draft()

        await #expect { try await box.publish(document) } throws: { error in
            if case PublishError.wrongBranch(found: "feature") = error { return true }
            return false
        }
    }

    @Test("Diverged histories stop it with git's own words and no merge, per AC-37")
    func refusesDivergence() async throws {
        let box = try Sandbox()
        let other = box.root.appending(path: "other")
        try Sandbox.git(
            box.root, "clone", "--quiet", box.remote.path(percentEncoded: false), other.path(percentEncoded: false))
        try Sandbox.git(other, "config", "user.name", "Other")
        try Sandbox.git(other, "config", "user.email", "o@example.com")
        try "x".write(to: other.appending(path: "src/content/blog/theirs.md"), atomically: true, encoding: .utf8)
        try Sandbox.git(other, "add", ".")
        try Sandbox.git(other, "commit", "--quiet", "-m", "Theirs")
        try Sandbox.git(other, "push", "--quiet", "origin", "main")

        try box.write("src/content/blog/mine.md", "y")
        try Sandbox.git(box.work, "add", ".")
        try Sandbox.git(box.work, "commit", "--quiet", "-m", "Mine")
        let before = try box.log()

        let document = try box.draft()
        await #expect { try await box.publish(document) } throws: { error in
            if case PublishError.pullNotFastForward(let message) = error { return !message.isEmpty }
            return false
        }
        #expect(try box.log() == before)
    }

    @Test("A document missing its subtitle is refused naming the field, per AC-38")
    func refusesInvalid() throws {
        let box = try Sandbox()
        let document = try box.draft(description: "")

        #expect { try box.publisher.plan(for: document, publishDate: Date()) } throws: { error in
            guard case PublishError.validationFailed(let rules) = error else { return false }
            return rules.contains { $0.id == "description" && !$0.passed }
        }
    }

    @Test("A picture whose file is gone refuses the publish rather than write a dangling path, per AC-67")
    func refusesMissingImage() throws {
        let box = try Sandbox()
        let document = try box.draft(body: "![gone](../../assets/blog/hello-world/gone.png)\n")

        #expect { try box.publisher.plan(for: document, publishDate: Date()) } throws: { error in
            guard case PublishError.validationFailed(let rules) = error else { return false }
            return rules.contains { $0.id == "images" && !$0.passed && $0.problem.contains("gone.png") }
        }
    }

    @Test("A picture only the repo holds is refused as missing, per spec 0006 AC-20")
    func refusesRepoOnlyImage() throws {
        let box = try Sandbox()
        let folder = box.work.appending(path: "src/assets/blog/hello-world")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: folder.appending(path: "repo-only.png"))
        let document = try box.draft(body: "![old](../../assets/blog/hello-world/repo-only.png)\n")

        #expect { try box.publisher.plan(for: document, publishDate: Date()) } throws: { error in
            guard case PublishError.validationFailed(let rules) = error else { return false }
            return rules.contains { $0.id == "images" && !$0.passed && $0.problem.contains("repo-only.png") }
        }
    }

    @Test("A failed push keeps the commit and records it for Push now, per AC-44")
    func pushFailureKeepsCommit() async throws {
        let box = try Sandbox()
        let document = try box.draft()
        let plan = try box.publisher.plan(for: document, publishDate: Date())
        let parked = box.root.appending(path: "parked.git")

        // Preflight's pull needs the remote, so it disappears only once the commit exists.
        let result: Result<PublishResult, Error>
        do {
            let value = try await box.publisher.publish(plan, message: plan.defaultMessage, document: document) {
                step, state in
                if step == .commit, state == .done {
                    try? FileManager.default.moveItem(at: box.remote, to: parked)
                }
            }
            result = .success(value)
        } catch {
            result = .failure(error)
        }

        guard case .failure(PublishError.pushFailed) = result else {
            Issue.record("Expected the push to fail, got \(result)")
            return
        }
        #expect(try box.log().first == "Publish blog/hello-world")
        let row = try #require(try box.publisher.latestPublish(for: document.id))
        #expect(row.status == "committed_not_pushed")
        #expect(!(row.error ?? "").isEmpty)

        try FileManager.default.moveItem(at: parked, to: box.remote)
        try await box.publisher.pushPending(rowID: try #require(row.id))
        #expect(try box.log(box.remote).first == "Publish blog/hello-world")
        #expect(try box.publisher.latestPublish(for: document.id)?.status == "pushed")
    }

    @Test("A commit that fails leaves the tree and the log exactly as they were, per AC-46")
    func commitFailureRollsBack() async throws {
        let box = try Sandbox()
        let hook = box.work.appending(path: ".git/hooks/pre-commit")
        try "#!/bin/sh\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: hook.path(percentEncoded: false))
        let before = try box.log()
        let document = try box.draft()

        await #expect(throws: PublishError.self) { try await box.publish(document) }

        #expect(try box.status().isEmpty)
        #expect(box.read("src/content/blog/hello-world.md") == nil)
        #expect(try box.log() == before)
        #expect(try box.publisher.latestPublish(for: document.id)?.status == "failed")
    }

    @Test("Renaming a published slug deletes the old file and adds a redirect, keeping /about, per AC-41")
    func slugRenameRedirects() async throws {
        let box = try Sandbox()
        let document = try box.draft(title: "Old Name")
        _ = try await box.publish(document)

        try box.documents.update(id: document.id, [Column("slug").set(to: "new-name")])
        let renamed = try #require(try box.documents.fetch(id: document.id))
        _ = try await box.publish(renamed)

        #expect(box.read("src/content/blog/old-name.md") == nil)
        #expect(box.read("src/content/blog/new-name.md") != nil)
        let redirects = try #require(box.read(Redirects.path))
        #expect(redirects.contains("  '/about': '/#about',\n  '/blog/old-name': '/blog/new-name',\n};"))
        #expect(redirects.contains("// The wireframe folds"))
    }

    @Test("Republishing with only a tag changed leaves updatedDate alone, and a body change sets it, per AC-47")
    func updatedDateOnlyForContent() async throws {
        let box = try Sandbox()
        let document = try box.draft()
        _ = try await box.publish(document)

        try box.documents.update(id: document.id, [Column("tags").set(to: "[\"swift\"]")])
        _ = try await box.publish(try #require(try box.documents.fetch(id: document.id)))
        #expect(!(box.read("src/content/blog/hello-world.md") ?? "").contains("updatedDate"))

        try box.documents.update(id: document.id, [Column("body_md").set(to: "Different words.\n")])
        _ = try await box.publish(try #require(try box.documents.fetch(id: document.id)))
        #expect((box.read("src/content/blog/hello-world.md") ?? "").contains("updatedDate"))
    }

    @Test("A publish interrupted before its commit is found on launch and can be discarded, per AC-46")
    func reconcileAndDiscard() async throws {
        let box = try Sandbox()
        let document = try box.draft()
        let plan = try box.publisher.plan(for: document, publishDate: Date())

        // What a crash leaves behind: the intent row and a written file, nothing committed.
        try box.documents.write { db in
            try Publish(
                documentId: document.id, collection: "blog", slug: "hello-world",
                filesJson: "{\"paths\":[\"src/content/blog/hello-world.md\"],\"message\":\"Publish blog/hello-world\"}",
                status: "pending", createdAt: Date()
            ).insert(db)
        }
        guard case .write(let path, let data) = try #require(plan.changes.first) else { return }
        try box.write(path, String(decoding: data, as: UTF8.self))

        let pending = try #require(try await box.publisher.reconcile())
        #expect(pending.dirtyPaths == ["src/content/blog/hello-world.md"])
        #expect(pending.action == .publish)

        try await box.publisher.discard(pending)
        #expect(try box.status().isEmpty)
        #expect(try await box.publisher.reconcile() == nil)
    }

    @Test("Staging names every path, and nothing in the app ever stages everything, per AC-42")
    func neverStagesEverything() throws {
        let sources = try FileManager.default.subpathsOfDirectory(
            atPath: #filePath.components(separatedBy: "/MyCMSTests/")[0] + "/MyCMS"
        )
        .filter { $0.hasSuffix(".swift") }
        let root = #filePath.components(separatedBy: "/MyCMSTests/")[0] + "/MyCMS/"
        for file in sources {
            let text = try String(contentsOfFile: root + file, encoding: .utf8)
            #expect(!text.contains("\"add\", \"-A\""), "\(file) stages everything")
            #expect(!text.contains("\"add\", \".\""), "\(file) stages everything")
        }
    }
}

// Spec 0006 A. Taking a post back, throwing a draft away, and moving a live address.
@Suite("Unpublish, delete and rename", .serialized)
@MainActor
struct LifecycleTests {

    // A published post with two stored pictures, the shape most of these start from.
    private func published(_ box: Sandbox) async throws -> Document {
        var document = try box.draft()
        var body = "Hi.\n"
        for name in ["one.png", "two.png"] {
            let asset = try box.assets.store(data: png(), suggestedName: name, for: document)
            body +=
                "\n![\(name)](\(AssetStore.markdownPath(fileName: asset.fileName, collection: .blog, slug: "hello-world")))\n"
        }
        try box.documents.update(id: document.id, Column("body_md").set(to: body))
        document = try #require(try box.documents.fetch(id: document.id))
        _ = try await box.publish(document)
        return try #require(try box.documents.fetch(id: document.id))
    }

    private func unpublish(_ box: Sandbox, _ document: Document) async throws -> PublishResult {
        let plan = try box.publisher.planUnpublish(for: document)
        return try await box.publisher.unpublish(plan, message: plan.defaultMessage, document: document) { _, _ in }
    }

    private func exists(_ box: Sandbox, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: box.work.appending(path: path).path(percentEncoded: false))
    }

    @Test("Unpublish removes the file and its known pictures in one pushed commit, per AC-3")
    func unpublishOneCommit() async throws {
        let box = try Sandbox()
        let document = try await published(box)
        let before = try box.log().count

        let result = try await unpublish(box, document)

        #expect(result.pushed)
        #expect(try box.log().count == before + 1)
        #expect(try box.log(box.remote).first == "Unpublish blog/hello-world")
        #expect(!exists(box, "src/content/blog/hello-world.md"))
        #expect(!exists(box, "src/assets/blog/hello-world/one.png"))
        #expect(!exists(box, "src/assets/blog/hello-world/two.png"))
        #expect(try box.status().isEmpty)
        #expect(try box.publisher.latestPublish(for: document.id)?.status == "pushed")
    }

    @Test("Unpublish makes a draft and keeps every word, picture, date and the address, per AC-4")
    func unpublishKeepsEverything() async throws {
        let box = try Sandbox()
        let document = try await published(box)
        _ = try await unpublish(box, document)

        let saved = try #require(try box.documents.fetch(id: document.id))
        #expect(saved.state == .draft)
        #expect(saved.publishedAt == nil)
        #expect(saved.publishedSlug == "hello-world")
        #expect(saved.publishedHash == document.publishedHash)
        #expect(saved.publishDate == document.publishDate)
        #expect(saved.bodyMd == document.bodyMd)
        #expect(saved.title == document.title)
        #expect(try box.assets.assets(for: saved).count == 2)
        #expect(
            try box.assets.assets(for: saved).allSatisfy {
                FileManager.default.fileExists(atPath: box.assets.fileURL(for: $0).path(percentEncoded: false))
            })
    }

    @Test("A picture the app never stored stops unpublish before anything is written, per AC-3")
    func unknownPictureStops() async throws {
        let box = try Sandbox()
        let document = try await published(box)
        try box.write("src/assets/blog/hello-world/by-hand.png", "not really a png")
        let before = try box.log()

        #expect { try box.publisher.planUnpublish(for: document) } throws: { error in
            guard case PublishError.unknownFilesInFolder(let paths) = error else { return false }
            return paths == ["src/assets/blog/hello-world/by-hand.png"]
        }
        #expect(exists(box, "src/content/blog/hello-world.md"))
        #expect(try box.log() == before)
    }

    @Test("A change outside the content folders refuses unpublish with nothing written, per AC-2")
    func unpublishRunsPreflight() async throws {
        let box = try Sandbox()
        let document = try await published(box)
        let plan = try box.publisher.planUnpublish(for: document)
        try box.write("src/pages/index.astro", "<h1>Changed</h1>\n")

        await #expect {
            try await box.publisher.unpublish(plan, message: plan.defaultMessage, document: document) { _, _ in }
        } throws: { error in
            guard case PublishError.dirtyOutsideContent(let paths) = error else { return false }
            return paths == ["src/pages/index.astro"]
        }
        #expect(exists(box, "src/content/blog/hello-world.md"))
        #expect(try box.documents.fetch(id: document.id)?.state == .published)
    }

    @Test("A failed push during unpublish keeps the commit and offers Push now, per AC-3")
    func unpublishPushFailure() async throws {
        let box = try Sandbox()
        let document = try await published(box)
        let plan = try box.publisher.planUnpublish(for: document)
        let parked = box.root.appending(path: "parked.git")

        await #expect {
            try await box.publisher.unpublish(plan, message: plan.defaultMessage, document: document) { step, state in
                if step == .commit, state == .done { try? FileManager.default.moveItem(at: box.remote, to: parked) }
            }
        } throws: { error in
            guard case PublishError.pushFailed = error else { return false }
            return true
        }

        #expect(try box.log().first == "Unpublish blog/hello-world")
        #expect(try box.publisher.latestPublish(for: document.id)?.status == "committed_not_pushed")
        #expect(try box.documents.fetch(id: document.id)?.state == .draft)
    }

    @Test("An unpublished draft keeps its slug through a title edit and republishes at the same address, per AC-5")
    func republishSameAddress() async throws {
        let box = try Sandbox()
        let document = try await published(box)
        let redirects = box.read(Redirects.path)
        _ = try await unpublish(box, document)

        let session = DocumentSession(
            document: try #require(try box.documents.fetch(id: document.id)), store: box.documents, assets: box.assets)
        session.title = "A Brand New Title"
        await session.flush()
        let edited = try #require(try box.documents.fetch(id: document.id))
        #expect(edited.slug == "hello-world")
        #expect(edited.title == "A Brand New Title")

        let plan = try box.publisher.plan(for: edited, publishDate: try #require(edited.publishDate))
        #expect(plan.defaultMessage == "Republish blog/hello-world")
        _ = try await box.publisher.publish(plan, message: plan.defaultMessage, document: edited) { _, _ in }

        let file = try #require(box.read("src/content/blog/hello-world.md"))
        #expect(file.contains("publishDate: '2026-09-21'"))
        #expect(exists(box, "src/assets/blog/hello-world/one.png"))
        #expect(exists(box, "src/assets/blog/hello-world/two.png"))
        #expect(box.read(Redirects.path) == redirects)
        #expect(try box.documents.fetch(id: document.id)?.state == .published)
    }

    @Test("A republish of identical bytes leaves updatedDate alone, per AC-5")
    func republishSameBytes() async throws {
        let box = try Sandbox()
        let document = try await published(box)
        _ = try await unpublish(box, document)

        let draft = try #require(try box.documents.fetch(id: document.id))
        _ = try await box.publish(draft)
        #expect(!(box.read("src/content/blog/hello-world.md") ?? "").contains("updatedDate"))
    }

    @Test("A redirect that points at the post is named before unpublishing, per AC-1")
    func warnsAboutRedirects() async throws {
        let box = try Sandbox()
        let document = try await published(box)
        let text = try #require(box.read(Redirects.path))
        try box.write(Redirects.path, try Redirects.adding(from: "/blog/older", to: "/blog/hello-world", in: text))

        #expect(box.publisher.redirectsPointing(at: document) == ["/blog/older"])
    }

    @Test("A published document is refused at the store, per AC-7")
    func publishedCannotBeDeleted() async throws {
        let box = try Sandbox()
        let document = try await published(box)

        #expect { try box.documents.delete(id: document.id) } throws: { error in
            guard case DataError.publishedCannotBeDeleted = error else { return false }
            return true
        }
        #expect(try box.documents.fetch(id: document.id) != nil)
    }

    @Test(
        "Deleting a draft removes its row, children and pictures, keeps publish history, and leaves the repo, per AC-6")
    func deleteDraft() async throws {
        let box = try Sandbox()
        let document = try await published(box)
        _ = try await unpublish(box, document)
        let stored = try box.assets.assets(for: document).map { box.assets.fileURL(for: $0) }
        let before = try box.log()

        let library = LibraryModel(
            store: box.documents, defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
        library.delete(document.id, assets: box.assets)

        #expect(library.errorText == nil)
        #expect(try box.documents.fetch(id: document.id) == nil)
        #expect(try box.documents.read { db in try Asset.fetchCount(db) } == 0)
        #expect(try box.documents.read { db in try Revision.fetchCount(db) } == 0)
        #expect(stored.allSatisfy { !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) })
        let history = try box.documents.read { db in try Publish.fetchAll(db) }
        #expect(history.count == 2)
        #expect(history.allSatisfy { $0.documentId == nil })
        #expect(try box.log() == before)
        #expect(try box.status().isEmpty)
    }

    @Test("Change address moves the file and pictures, adds the redirect, then moves the document, per AC-9")
    func changeAddress() async throws {
        let box = try Sandbox()
        let document = try await published(box)

        let plan = try box.publisher.plan(
            for: document, publishDate: try #require(document.publishDate), newSlug: "new-name")
        #expect(try box.documents.fetch(id: document.id)?.slug == "hello-world")
        _ = try await box.publisher.publish(plan, message: plan.defaultMessage, document: document) { _, _ in }

        #expect(try box.log(box.remote) == box.log())
        #expect(!exists(box, "src/content/blog/hello-world.md"))
        #expect(!exists(box, "src/assets/blog/hello-world/one.png"))
        #expect(exists(box, "src/assets/blog/new-name/one.png"))
        #expect(exists(box, "src/assets/blog/new-name/two.png"))
        let file = try #require(box.read("src/content/blog/new-name.md"))
        #expect(file.contains("](../../assets/blog/new-name/one.png)"))
        #expect(!file.contains("assets/blog/hello-world/"))
        let redirects = try #require(box.read(Redirects.path))
        #expect(redirects.contains("  '/about': '/#about',\n  '/blog/hello-world': '/blog/new-name',\n};"))
        #expect(try box.status().isEmpty)

        let saved = try #require(try box.documents.fetch(id: document.id))
        #expect(saved.slug == "new-name")
        #expect(saved.publishedSlug == "new-name")
        #expect(saved.bodyMd.contains("](../../assets/blog/new-name/two.png)"))
        #expect(box.assets.resolve(reference: "../../assets/blog/new-name/one.png", for: saved) != nil)
    }

    @Test("A taken or malformed new address is refused as typed, never suffixed, per AC-8")
    func refusesBadAddress() async throws {
        let box = try Sandbox()
        let document = try await published(box)
        _ = try box.draft(title: "Taken")
        let date = try #require(document.publishDate)

        #expect { try box.publisher.plan(for: document, publishDate: date, newSlug: "taken") } throws: { error in
            guard case PublishError.slugTaken("taken") = error else { return false }
            return true
        }
        #expect { try box.publisher.plan(for: document, publishDate: date, newSlug: "Bad Slug") } throws: { error in
            guard case PublishError.slugInvalid("Bad Slug") = error else { return false }
            return true
        }
        #expect(try box.documents.isSlugTaken("taken", in: .blog, except: document.id))
        #expect(!(try box.documents.isSlugTaken("take", in: .blog, except: document.id)))
    }

    @Test("A move whose commit fails leaves the slug, body and cover exactly as they were, per AC-10")
    func failedMoveChangesNothing() async throws {
        let box = try Sandbox()
        let document = try await published(box)
        let hook = box.work.appending(path: ".git/hooks/pre-commit")
        try "#!/bin/sh\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: hook.path(percentEncoded: false))

        let plan = try box.publisher.plan(
            for: document, publishDate: try #require(document.publishDate), newSlug: "new-name")
        await #expect(throws: PublishError.self) {
            try await box.publisher.publish(plan, message: plan.defaultMessage, document: document) { _, _ in }
        }

        let saved = try #require(try box.documents.fetch(id: document.id))
        #expect(saved.slug == "hello-world")
        #expect(saved.bodyMd == document.bodyMd)
        #expect(saved.cover == document.cover)
        #expect(exists(box, "src/content/blog/hello-world.md"))
        #expect(try box.status().isEmpty)
    }

    @Test("A moved address reaches the open editor, so a later save cannot write the old paths back, per AC-9")
    func sessionAdoptsAddress() async throws {
        let box = try Sandbox()
        let document = try await published(box)
        let session = DocumentSession(document: document, store: box.documents, assets: box.assets)

        let plan = try box.publisher.plan(
            for: document, publishDate: try #require(document.publishDate), newSlug: "new-name")
        _ = try await box.publisher.publish(plan, message: plan.defaultMessage, document: document) { _, _ in }
        session.adoptPublishedAddress("new-name")

        #expect(session.document.slug == "new-name")
        #expect(session.body.contains("assets/blog/new-name/one.png"))
        #expect(!session.body.contains("assets/blog/hello-world/"))
        #expect(session.saveState == .clean)
    }

    @Test("An interrupted unpublish is found at launch by its action and finishing it makes a draft, per AC-11")
    func recoversUnpublish() async throws {
        let box = try Sandbox()
        let document = try await published(box)
        let plan = try box.publisher.planUnpublish(for: document)

        // What a crash leaves behind: the intent naming the action, and deletes never committed.
        try box.documents.write { db in
            try Publish(
                documentId: document.id, collection: "blog", slug: "hello-world",
                filesJson: String(
                    decoding: try JSONSerialization.data(
                        withJSONObject: [
                            "action": "unpublish", "paths": plan.paths, "message": plan.defaultMessage,
                        ] as [String: Any]), as: UTF8.self),
                status: "pending", createdAt: Date()
            ).insert(db)
        }
        for path in plan.paths { try FileManager.default.removeItem(at: box.work.appending(path: path)) }

        let pending = try #require(try await box.publisher.reconcile())
        #expect(pending.action == .unpublish)
        #expect(Set(pending.dirtyPaths) == Set(plan.paths))

        try await box.publisher.finish(pending)
        #expect(try box.log(box.remote).first == "Unpublish blog/hello-world")
        #expect(try box.documents.fetch(id: document.id)?.state == .draft)
        #expect(try box.status().isEmpty)
    }
}

// Spec 0006 B. The project only fields, from the editor's session to the published file.
@Suite("Projects collection", .serialized)
@MainActor
struct ProjectTests {

    @Test("A chip is trimmed, a blank or a second spelling is ignored, and there is no length limit, per AC-13")
    func addingChips() {
        var tech = TechChips.adding("  Swift ", to: [])
        tech = TechChips.adding("docker", to: tech)
        tech = TechChips.adding("Docker", to: tech)
        tech = TechChips.adding("   ", to: tech)
        tech = TechChips.adding("A very long technology name that keeps going well past thirty two", to: tech)
        #expect(tech == ["Swift", "docker", "A very long technology name that keeps going well past thirty two"])
    }

    @Test("Dragging the fifth chip to first moves it there and shifts the rest, per AC-13")
    func reorderingChips() {
        let tech = ["a", "b", "c", "d", "e"]
        #expect(TechChips.moving(from: 4, to: 0, in: tech) == ["e", "a", "b", "c", "d"])
        #expect(TechChips.moving(from: 0, to: 2, in: tech) == ["b", "c", "a", "d", "e"])
        #expect(TechChips.moving(from: 9, to: 0, in: tech) == tech)
    }

    @Test("A URL that is not a web address is named in the publish rule's own words, per AC-14")
    func urlProblemWords() {
        #expect(
            DocumentValidator.urlProblem("Live URL", URL(string: "example.com"))
                == "Live URL example.com is not a web address.")
        #expect(DocumentValidator.urlProblem("Live URL", URL(string: "https://example.com")) == nil)
        #expect(DocumentValidator.urlProblem("Live URL", nil) == nil)
    }

    @Test("Project fields autosave into fields_json in on screen order, and keep the AI flag, per AC-12")
    func sessionSavesFields() async throws {
        let box = try Sandbox()
        let project = try box.documents.create(collection: .projects)
        let session = DocumentSession(document: project, store: box.documents, autosaveDelay: .milliseconds(1))

        session.markAIAssisted()
        var fields = session.fields
        fields.role = "Solo"
        fields.status = .active
        fields.tech = ["e", "a", "b"]
        session.fields = fields
        await session.flush()

        let saved = try #require(try box.documents.fetch(id: project.id))
        #expect(saved.fields.role == "Solo")
        #expect(saved.fields.status == .active)
        #expect(saved.fields.tech == ["e", "a", "b"])
        #expect(saved.fields.aiAssisted == true)
        #expect(session.saveState == .clean)
    }

    @Test("A project with its fields publishes them in order, and tech is always written, per AC-15")
    func projectPublishes() async throws {
        let box = try Sandbox()
        var project = try box.documents.create(collection: .projects)
        let fields = DocumentFields(
            role: "Solo project", timeline: "Jun to Aug 2026", status: .complete,
            tech: ["Swift", "SwiftUI", "GRDB", "Git", "Ollama"],
            repoUrl: URL(string: "https://github.com/example/mycms"), order: 2)
        try box.documents.update(
            id: project.id,
            [
                Column("title").set(to: "MyCMS"), Column("description").set(to: "A writing app."),
                Column("body_md").set(to: "Built it.\n"), Column("slug").set(to: "mycms"),
                Column("fields_json").set(to: try DatabaseJSON.encode(fields)),
            ])
        project = try #require(try box.documents.fetch(id: project.id))
        _ = try await box.publish(project)

        let file = try #require(box.read("src/content/projects/mycms.md"))
        let read = try FrontmatterReader.read(
            fileURL: box.work.appending(path: "src/content/projects/mycms.md"), collection: .projects)
        #expect(read.frontmatter.role == "Solo project")
        #expect(read.frontmatter.timeline == "Jun to Aug 2026")
        #expect(read.frontmatter.status == .complete)
        #expect(read.frontmatter.tech == ["Swift", "SwiftUI", "GRDB", "Git", "Ollama"])
        #expect(read.frontmatter.repoUrl == URL(string: "https://github.com/example/mycms"))
        #expect(read.frontmatter.order == 2)
        #expect(file.contains("tech:"))

        var bare = try box.documents.create(collection: .projects)
        try box.documents.update(
            id: bare.id,
            [
                Column("title").set(to: "Bare"), Column("description").set(to: "No tech."),
                Column("body_md").set(to: "x\n"), Column("slug").set(to: "bare"),
                Column("fields_json").set(
                    to: try DatabaseJSON.encode(DocumentFields(role: "r", timeline: "t", status: .active))),
            ])
        bare = try #require(try box.documents.fetch(id: bare.id))
        _ = try await box.publish(bare)
        let bareFile = try FrontmatterReader.read(
            fileURL: box.work.appending(path: "src/content/projects/bare.md"), collection: .projects)
        #expect(bareFile.frontmatter.tech == [])
    }

    @Test("A project missing role, timeline or status is refused, per AC-15")
    func projectRulesApply() throws {
        let box = try Sandbox()
        let project = try box.documents.create(collection: .projects)
        let failed = Set(box.publisher.validator(for: project).validate(project).filter { !$0.passed }.map(\.id))
        #expect(failed.isSuperset(of: ["role", "timeline", "status"]))
    }

    @Test("A blog post never writes project fields, even ones an import left behind, per AC-16")
    func blogStaysClean() async throws {
        let box = try Sandbox()
        var document = try box.draft()
        let stray = DocumentFields(role: "Stray", timeline: "Never", status: .active, tech: ["X"], order: 1)
        try box.documents.update(id: document.id, Column("fields_json").set(to: try DatabaseJSON.encode(stray)))
        document = try #require(try box.documents.fetch(id: document.id))
        _ = try await box.publish(document)

        let file = try #require(box.read("src/content/blog/hello-world.md"))
        for key in ["role:", "timeline:", "status:", "tech:", "order:"] {
            #expect(!file.contains(key), "\(key) leaked into a blog post")
        }
    }
}

@Suite("Redirects file")
struct RedirectsTests {
    @Test("The addresses that redirect to a post are found, and nothing else, per spec 0006 AC-1")
    func findsSources() {
        let text = """
            export const redirects: Record<string, string> = {
              '/about': '/#about',
              '/blog/old': '/blog/post',
              '/blog/older':'/blog/post'
              '/blog/other': '/blog/postscript',
            };
            """
        #expect(Redirects.sources(pointingAt: "/blog/post", in: text) == ["/blog/old", "/blog/older"])
    }

    @Test("An entry goes in before the closing brace, and a file of another shape is refused")
    func insertsOrRefuses() throws {
        let text = "export const redirects: Record<string, string> = {\n  '/about': '/#about',\n};\n"
        let added = try Redirects.adding(from: "/blog/a", to: "/blog/b", in: text)
        #expect(
            added
                == "export const redirects: Record<string, string> = {\n  '/about': '/#about',\n  '/blog/a': '/blog/b',\n};\n"
        )
        #expect(try Redirects.adding(from: "/blog/a", to: "/blog/b", in: added) == added)

        #expect(throws: PublishError.self) {
            try Redirects.adding(from: "/a", to: "/b", in: "export default {}\n")
        }
    }
}
