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
        let asset = try store.store(data: pngData(width: 4000, height: 1000), suggestedName: "Big Photo.png", for: document)

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

        let asset = try store.store(data: pngData(width: 10, height: 10), suggestedName: "pic.png", for: session.document)
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
