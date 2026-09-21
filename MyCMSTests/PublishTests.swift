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
        let text = try FrontmatterWriter.serialize(document, publishDate: day.date(from: "2026-09-21")!, updatedDate: nil)

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
        try write(Redirects.path, """
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

    func draft(title: String = "Hello World", description: String = "A first post.", body: String = "Hi.\n") throws -> Document {
        var document = try documents.create(collection: .blog)
        try documents.update(id: document.id, [
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
    let context = try #require(CGContext(
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
        #expect(FileManager.default.fileExists(atPath: box.work.appending(path: "src/assets/blog/hello-world/shot.png").path(percentEncoded: false)))
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
        try Sandbox.git(box.root, "clone", "--quiet", box.remote.path(percentEncoded: false), other.path(percentEncoded: false))
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

    @Test("A failed push keeps the commit and records it for Push now, per AC-44")
    func pushFailureKeepsCommit() async throws {
        let box = try Sandbox()
        let document = try box.draft()
        let plan = try box.publisher.plan(for: document, publishDate: Date())
        let parked = box.root.appending(path: "parked.git")

        // Preflight's pull needs the remote, so it disappears only once the commit exists.
        let result: Result<PublishResult, Error>
        do {
            let value = try await box.publisher.publish(plan, message: plan.defaultMessage, document: document) { step, state in
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
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path(percentEncoded: false))
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

        try await box.publisher.discard(pending)
        #expect(try box.status().isEmpty)
        #expect(try await box.publisher.reconcile() == nil)
    }

    @Test("Staging names every path, and nothing in the app ever stages everything, per AC-42")
    func neverStagesEverything() throws {
        let sources = try FileManager.default.subpathsOfDirectory(atPath: #filePath.components(separatedBy: "/MyCMSTests/")[0] + "/MyCMS")
            .filter { $0.hasSuffix(".swift") }
        let root = #filePath.components(separatedBy: "/MyCMSTests/")[0] + "/MyCMS/"
        for file in sources {
            let text = try String(contentsOfFile: root + file, encoding: .utf8)
            #expect(!text.contains("\"add\", \"-A\""), "\(file) stages everything")
            #expect(!text.contains("\"add\", \".\""), "\(file) stages everything")
        }
    }
}

@Suite("Redirects file")
struct RedirectsTests {
    @Test("An entry goes in before the closing brace, and a file of another shape is refused")
    func insertsOrRefuses() throws {
        let text = "export const redirects: Record<string, string> = {\n  '/about': '/#about',\n};\n"
        let added = try Redirects.adding(from: "/blog/a", to: "/blog/b", in: text)
        #expect(added == "export const redirects: Record<string, string> = {\n  '/about': '/#about',\n  '/blog/a': '/blog/b',\n};\n")
        #expect(try Redirects.adding(from: "/blog/a", to: "/blog/b", in: added) == added)

        #expect(throws: PublishError.self) {
            try Redirects.adding(from: "/a", to: "/b", in: "export default {}\n")
        }
    }
}
