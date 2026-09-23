import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import MyCMS

private func pngData(width: Int, height: Int) throws -> Data {
    let context = try #require(
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())

    let data = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@MainActor
private func fixture(slug: String? = "a-post") throws -> (AssetStore, DocumentStore, Document, URL) {
    let database = try MyCMS.Database.inMemory()
    let documents = DocumentStore(database: database)
    var document = try documents.create(collection: .blog)
    if let slug {
        try documents.update(id: document.id, Column("slug").set(to: slug))
        document = try #require(try documents.fetch(id: document.id))
    }
    let root = FileManager.default.temporaryDirectory.appending(path: "assets-\(UUID().uuidString)")
    return (AssetStore(database: database, root: root), documents, document, root)
}

@Suite("Asset store")
@MainActor
struct AssetStoreTests {

    @Test("A 4000 pixel picture is stored at 2000 on its long edge and recorded, which is AC-9")
    func capsAndRecords() throws {
        let (store, _, document, _) = try fixture()
        let asset = try store.store(
            data: pngData(width: 4000, height: 1000), suggestedName: "Big Photo.png", for: document)

        #expect(asset.id != nil)
        #expect(asset.width == 2000)
        #expect(asset.height == 500)
        #expect(asset.fileName == "big-photo.png")
        #expect(asset.sha256.count == 64)
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: asset).path(percentEncoded: false)))
        #expect(try store.assets(for: document).count == 1)
    }

    @Test("A picture already under the cap is kept byte for byte")
    func smallPicturesAreUntouched() throws {
        let (store, _, document, _) = try fixture()
        let original = try pngData(width: 300, height: 200)
        let asset = try store.store(data: original, suggestedName: "small.png", for: document)

        #expect(try Data(contentsOf: store.fileURL(for: asset)) == original)
        #expect(asset.width == 300)
    }

    @Test("A second file with the same name gets a numeric suffix")
    func namesStayUnique() throws {
        let (store, _, document, _) = try fixture()
        let first = try store.store(data: pngData(width: 10, height: 10), suggestedName: "shot.png", for: document)
        let second = try store.store(data: pngData(width: 10, height: 10), suggestedName: "shot.png", for: document)

        #expect(first.fileName == "shot.png")
        #expect(second.fileName == "shot-2.png")
    }

    @Test("A draft with no title yet is refused, so no path is ever written without a slug")
    func untitledDraftIsRefused() throws {
        let (store, _, document, _) = try fixture(slug: nil)
        #expect(throws: AssetError.self) {
            try store.store(data: pngData(width: 10, height: 10), suggestedName: "a.png", for: document)
        }
    }

    @Test("Something that is not a picture is refused")
    func notAPicture() throws {
        let (store, _, document, _) = try fixture()
        #expect(throws: AssetError.self) {
            try store.store(data: Data("hello".utf8), suggestedName: "notes.txt", for: document)
        }
    }

    @Test("A reference resolves to the app's copy, and a missing file resolves to nothing, per AC-12 and AC-16")
    func resolvesToTheAppCopy() throws {
        let (store, _, document, _) = try fixture()
        let asset = try store.store(data: pngData(width: 10, height: 10), suggestedName: "a.png", for: document)
        let reference = AssetStore.markdownPath(fileName: asset.fileName, collection: .blog, slug: "a-post")

        #expect(reference == "../../assets/blog/a-post/a.png")
        #expect(store.resolve(reference: reference, for: document)?.url == store.fileURL(for: asset))

        try FileManager.default.removeItem(at: store.fileURL(for: asset))
        #expect(store.resolve(reference: reference, for: document) == nil)
        #expect(store.asset(forReference: reference, in: document)?.width == 10)
    }

    @Test("A slug change rewrites image paths only, never prose or code, which is AC-11")
    func rewriteIsScoped() {
        let body = """
            ![one](../../assets/blog/old-slug/one.png)

            I wrote about ../../assets/blog/old-slug/ once, and old-slug in prose.

            Inline ![two](../../assets/blog/old-slug/two.png) too.

            `![not](../../assets/blog/old-slug/code.png)`

            ```
            ![fenced](../../assets/blog/old-slug/fenced.png)
            ```
            """
        let rewritten = AssetStore.rewriteReferences(in: body, from: "old-slug", to: "new-slug", collection: .blog)

        #expect(rewritten.contains("![one](../../assets/blog/new-slug/one.png)"))
        #expect(rewritten.contains("![two](../../assets/blog/new-slug/two.png)"))
        #expect(rewritten.contains("I wrote about ../../assets/blog/old-slug/ once, and old-slug in prose."))
        #expect(rewritten.contains("`![not](../../assets/blog/old-slug/code.png)`"))
        #expect(rewritten.contains("![fenced](../../assets/blog/old-slug/fenced.png)"))
    }

    @Test("An image the body stopped using loses its row and its file, which is AC-65")
    func prunesOrphans() throws {
        let (store, _, document, _) = try fixture()
        let kept = try store.store(data: pngData(width: 10, height: 10), suggestedName: "kept.png", for: document)
        let dropped = try store.store(data: pngData(width: 10, height: 10), suggestedName: "gone.png", for: document)
        let cover = try store.store(data: pngData(width: 10, height: 10), suggestedName: "cover.png", for: document)

        let body = "![kept](\(AssetStore.markdownPath(fileName: kept.fileName, collection: .blog, slug: "a-post")))\n"
        let coverPath = AssetStore.markdownPath(fileName: cover.fileName, collection: .blog, slug: "a-post")
        let removed = try store.pruneOrphans(for: document, body: body, cover: coverPath)

        #expect(removed == 1)
        #expect(try store.assets(for: document).map(\.fileName).sorted() == ["cover.png", "kept.png"])
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: dropped).path(percentEncoded: false)))
    }

    @Test("Image references record whether they stand alone on their line")
    func blockImagesAreFound() {
        let structure = MarkdownRenderer.parse("![a](x.png)\n\nText ![b](y.png) inline.\n")
        #expect(structure.images.map(\.isBlock) == [true, false])
        #expect(structure.images.first?.alt == "a")
        #expect(structure.images.first?.source == "x.png")
    }
}

@Suite("Images in the document session")
@MainActor
struct ImageSessionTests {

    @Test("A draft's claimed slug reaches the open session, so images can be added straight after titling")
    func slugReachesTheSession() async throws {
        let (store, documents, _, _) = try fixture(slug: nil)
        let document = try documents.create(collection: .blog)
        let session = DocumentSession(document: document, store: documents, assets: store)

        session.title = "Hello World"
        await session.flush()

        #expect(session.document.slug == "hello-world")
    }

    @Test("Retitling a draft rewrites its image paths in the same save, which is AC-11")
    func retitleRewritesImages() async throws {
        let (store, documents, _, _) = try fixture(slug: nil)
        let created = try documents.create(collection: .blog)
        let session = DocumentSession(document: created, store: documents, assets: store)
        session.title = "Old Title"
        await session.flush()

        let asset = try store.store(
            data: pngData(width: 10, height: 10), suggestedName: "pic.png", for: session.document)
        let oldPath = AssetStore.markdownPath(fileName: asset.fileName, collection: .blog, slug: "old-title")
        session.body = "Intro mentions old-title in prose.\n\n![a pic](\(oldPath))\n"
        session.setCover(oldPath, alt: "cover")
        await session.flush()

        session.title = "New Title"
        await session.flush()

        let saved = try #require(try documents.fetch(id: created.id))
        #expect(saved.slug == "new-title")
        #expect(saved.bodyMd.contains("![a pic](../../assets/blog/new-title/pic.png)"))
        #expect(saved.bodyMd.contains("Intro mentions old-title in prose."))
        #expect(saved.cover == "../../assets/blog/new-title/pic.png")
        #expect(session.body == saved.bodyMd)
        // The file never moved, because storage is keyed by the document id.
        #expect(store.resolve(reference: saved.cover ?? "", for: session.document) != nil)
    }

    @Test("Leaving the document removes a picture the body no longer uses, which is AC-65")
    func leavingPrunes() async throws {
        let (store, documents, document, _) = try fixture()
        let session = DocumentSession(document: document, store: documents, assets: store)
        let asset = try store.store(data: pngData(width: 10, height: 10), suggestedName: "gone.png", for: document)
        let path = AssetStore.markdownPath(fileName: asset.fileName, collection: .blog, slug: "a-post")

        session.body = "![gone](\(path))\n"
        await session.flush()
        #expect(try store.assets(for: document).count == 1)

        session.body = "No picture any more.\n"
        await session.flush()
        #expect(try store.assets(for: document).isEmpty)
    }
}

// Spec 0006 C. A repo on disk with one imported post and its pictures, so adoption runs for real.
@MainActor
private struct ImportedRepo {
    let url = URL.temporaryDirectory.appending(path: "mycms-adopt-\(UUID().uuidString)")
    let pictures: [String: Data]

    init(body: String, cover: String? = nil, pictures: [String: Data]) throws {
        self.pictures = pictures
        let content = url.appending(path: "src/content/blog")
        let assets = url.appending(path: "src/assets/blog/trip")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: url.appending(path: "src/content/projects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        for (name, data) in pictures { try data.write(to: assets.appending(path: name)) }

        let coverLines = cover.map { "cover: \($0)\ncoverAlt: The cliffs\n" } ?? ""
        let file =
            "---\ntitle: Trip\ndescription: A trip.\npublishDate: 2026-09-10\ndraft: false\n\(coverLines)---\n\n\(body)"
        try Data(file.utf8).write(to: content.appending(path: "trip.md"))
    }

    // Every file under the repo with its bytes, so a test can prove nothing was touched.
    func snapshot() throws -> [String: Data] {
        let files =
            FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath } ?? []
        return try Dictionary(
            uniqueKeysWithValues: files.map { ($0.path(percentEncoded: false), try Data(contentsOf: $0)) })
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

@Suite("Adopting imported pictures")
@MainActor
struct AdoptionTests {
    private func make() throws -> (ImportService, AssetStore, DocumentStore, SettingsStore, URL) {
        let database = try MyCMS.Database.inMemory()
        let documents = DocumentStore(database: database)
        let settings = SettingsStore(database: database)
        let root = FileManager.default.temporaryDirectory.appending(path: "assets-\(UUID().uuidString)")
        let assets = AssetStore(database: database, root: root)
        return (ImportService(store: documents, settings: settings, assets: assets), assets, documents, settings, root)
    }

    private func imported(_ documents: DocumentStore) throws -> Document {
        let item = try #require(try documents.list().first { $0.slug == "trip" })
        return try #require(try documents.fetch(id: item.id))
    }

    @Test("Import copies each repo picture byte for byte under its own name with its alt, per AC-17")
    func importAdopts() throws {
        let big = try pngData(width: 3000, height: 1000)
        let repo = try ImportedRepo(
            body:
                "![Harbour](../../assets/blog/trip/harbour.png)\n\n![Big one](../../assets/blog/trip/Big%20One.png)\n",
            cover: "../../assets/blog/trip/cover.png",
            pictures: [
                "harbour.png": try pngData(width: 300, height: 200), "Big One.png": big,
                "cover.png": try pngData(width: 40, height: 20),
            ])
        defer { repo.remove() }
        let (importer, assets, documents, _, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }

        try importer.run(repo: repo.url)
        let document = try imported(documents)
        let stored = try assets.assets(for: document)

        #expect(Set(stored.map(\.fileName)) == ["harbour.png", "Big One.png", "cover.png"])
        let bigRow = try #require(stored.first { $0.fileName == "Big One.png" })
        #expect(try Data(contentsOf: assets.fileURL(for: bigRow)) == big)
        #expect(bigRow.width == 3000 && bigRow.height == 1000)
        #expect(bigRow.alt == "Big one")
        #expect(bigRow.sha256 == ContentHash.sha256(big))
        #expect(stored.first { $0.fileName == "cover.png" }?.alt == "The cliffs")
        #expect(assets.resolve(reference: "../../assets/blog/trip/harbour.png", for: document) != nil)
    }

    @Test("A second pass adds nothing and the repo is never modified, per AC-18")
    func idempotentAndReadOnly() throws {
        let repo = try ImportedRepo(
            body: "![Harbour](../../assets/blog/trip/harbour.png)\n",
            pictures: ["harbour.png": try pngData(width: 300, height: 200)])
        defer { repo.remove() }
        let (importer, assets, documents, _, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }

        let before = try repo.snapshot()
        try importer.run(repo: repo.url)
        try importer.run(repo: repo.url)
        let document = try imported(documents)

        #expect(try assets.assets(for: document).count == 1)
        #expect(importer.adoptPictures(for: document, repo: repo.url) == 0)
        #expect(try repo.snapshot() == before)
    }

    @Test("The launch pass picks up a published document imported before adoption existed, per AC-17")
    func launchPassCatchesUp() throws {
        let repo = try ImportedRepo(
            body: "![Harbour](../../assets/blog/trip/harbour.png)\n",
            pictures: ["harbour.png": try pngData(width: 300, height: 200)])
        defer { repo.remove() }
        let (importer, assets, documents, settings, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }

        // An importer without a store stands in for a build from before this change.
        try ImportService(store: documents, settings: settings).run(repo: repo.url)
        let document = try imported(documents)
        #expect(try assets.assets(for: document).isEmpty)

        _ = try importer.refresh(repo: repo.url)
        #expect(try assets.assets(for: document).count == 1)
    }

    @Test("Moving the repo away still shows adopted pictures, per AC-19")
    func previewSurvivesTheRepo() throws {
        let repo = try ImportedRepo(
            body: "![Harbour](../../assets/blog/trip/harbour.png)\n",
            pictures: ["harbour.png": try pngData(width: 300, height: 200)])
        let (importer, assets, documents, settings, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }

        try importer.run(repo: repo.url)
        let document = try imported(documents)
        try settings.set(repo.url.path(percentEncoded: false), forKey: SettingsKey.repoPath)
        repo.remove()

        let model = PreviewModel(settings: settings, assets: assets)
        #expect(model.imageFile(for: "../../assets/blog/trip/harbour.png", in: document) != nil)
        #expect(model.page(for: document, body: document.bodyMd, stylesheet: nil).contains("data:image/png;base64,"))
    }

    @Test("A reference with no repo file is left alone and nothing is stored for it, per AC-20")
    func missingFileIsSkipped() throws {
        let repo = try ImportedRepo(
            body: "![Gone](../../assets/blog/trip/gone.png)\n\n![Here](../../assets/blog/trip/here.png)\n",
            pictures: ["here.png": try pngData(width: 30, height: 20)])
        defer { repo.remove() }
        let (importer, assets, documents, _, root) = try make()
        defer { try? FileManager.default.removeItem(at: root) }

        try importer.run(repo: repo.url)
        let document = try imported(documents)

        #expect(try assets.assets(for: document).map(\.fileName) == ["here.png"])
        #expect(document.bodyMd.contains("gone.png"))
    }

    @Test("Adoption reads only inside src/assets, whether or not that folder exists yet")
    func repoFileIsConfined() throws {
        let repo = try ImportedRepo(body: "", pictures: ["pic.png": try pngData(width: 4, height: 4)])
        defer { repo.remove() }
        try Data([1]).write(to: repo.url.appending(path: "secret.txt"))

        #expect(AssetStore.repoFile(for: "../../assets/blog/trip/pic.png", collection: .blog, repo: repo.url) != nil)
        #expect(AssetStore.repoFile(for: "../../../secret.txt", collection: .blog, repo: repo.url) == nil)
        #expect(AssetStore.repoFile(for: "../../assets/blog/trip/nope.png", collection: .blog, repo: repo.url) == nil)
        #expect(AssetStore.repoFile(for: "https://example.com/a.png", collection: .blog, repo: repo.url) == nil)
    }

    @Test("An app copy with the same name wins over the repo's different bytes")
    func appCopyWins() throws {
        let (store, _, document, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let mine = try store.store(data: pngData(width: 30, height: 20), suggestedName: "pic.png", for: document)

        let file = root.appending(path: "repo-pic.png")
        try pngData(width: 60, height: 40).write(to: file)

        #expect(try store.adopt(repoFile: file, fileName: "pic.png", alt: "", for: document) == nil)
        #expect(try store.assets(for: document).map(\.sha256) == [mine.sha256])
    }
}
