import Foundation
import Testing
@testable import MyCMS

@Suite("HTML and preview")
@MainActor
struct PreviewTests {

    @Test("Headings, lists, quotes, code, links and emphasis all come out as HTML, per AC-13")
    func blocksRender() {
        let html = MarkdownRenderer.html(for: """
            ## Title

            Some **bold** and *thin* and ~~gone~~.

            > Quoted

            - one
            - two

            3. three

            A [link](https://example.com "tip").

            ---
            """)

        #expect(html.contains("<h2>Title</h2>"))
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<em>thin</em>"))
        #expect(html.contains("<del>gone</del>"))
        #expect(html.contains("<blockquote>"))
        #expect(html.contains("<li>one</li>"))
        #expect(html.contains("<ol start=\"3\">"))
        #expect(html.contains("<a href=\"https://example.com\" title=\"tip\">link</a>"))
        #expect(html.contains("<hr>"))
    }

    @Test("Code shows its angle brackets rather than becoming tags")
    func codeIsEscaped() {
        let html = MarkdownRenderer.html(for: "Use `a < b` here.\n\n```html\n<div>&</div>\n```\n")

        #expect(html.contains("<code>a &lt; b</code>"))
        #expect(html.contains("<pre><code class=\"language-html\">&lt;div&gt;&amp;&lt;/div&gt;"))
        #expect(!html.contains("<div>&</div>"))
    }

    @Test("An image keeps its alt text and loads whatever source the caller maps it to")
    func imagesAreMapped() {
        let html = MarkdownRenderer.html(for: "![Salt & <pepper>](../../assets/blog/p/box.png)\n") { source in
            source.hasSuffix("box.png") ? "data:image/png;base64,AAAA" : nil
        }

        #expect(html.contains("<img src=\"data:image/png;base64,AAAA\" alt=\"Salt &amp; &lt;pepper&gt;\">"))
    }

    @Test("The page wraps the post in the prose class and forbids anything remote, per AC-14")
    func pageIsLockedDown() {
        let page = PreviewModel.wrap("<p>Hi</p>", stylesheet: ".prose { color: red; }")

        #expect(page.contains("<div class=\"prose\">"))
        #expect(page.contains(".prose { color: red; }"))
        #expect(page.contains("default-src 'none'"))
    }

    @Test("No repository or no stylesheet means no site style, so the fallback is used, per AC-15")
    func missingStylesheetFallsBack() throws {
        let database = try MyCMS.Database.inMemory()
        let settings = SettingsStore(database: database)
        let model = PreviewModel(settings: settings, assets: AssetStore(database: database))

        #expect(model.siteStylesheet() == nil)

        try settings.set("/nonexistent/repo", forKey: SettingsKey.repoPath)
        #expect(model.siteStylesheet() == nil)

        let document = try DocumentStore(database: database).create(collection: .blog)
        let page = model.page(for: document, body: "Hello", stylesheet: model.siteStylesheet())
        #expect(page.contains("Source Serif 4"))
    }

    @Test("A real repository's stylesheet is read from src/styles/global.css")
    func readsTheSiteStylesheet() throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo.appending(path: "src/styles"), withIntermediateDirectories: true)
        try ".prose { margin: 0 }".write(to: repo.appending(path: "src/styles/global.css"), atomically: true, encoding: .utf8)

        let database = try MyCMS.Database.inMemory()
        let settings = SettingsStore(database: database)
        try settings.set(repo.path(percentEncoded: false), forKey: SettingsKey.repoPath)

        #expect(PreviewModel(settings: settings, assets: AssetStore(database: database)).siteStylesheet() == ".prose { margin: 0 }")
    }

    @Test("An imported post's picture is read from the repo's src/assets, and nothing outside it")
    func repoImagesResolveReadOnly() throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "repo-\(UUID().uuidString)")
        let folder = repo.appending(path: "src/assets/blog/trip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: folder.appending(path: "pic.jpg"))
        try Data([1]).write(to: repo.appending(path: "secret.txt"))

        let database = try MyCMS.Database.inMemory()
        let settings = SettingsStore(database: database)
        try settings.set(repo.path(percentEncoded: false), forKey: SettingsKey.repoPath)
        let model = PreviewModel(settings: settings, assets: AssetStore(database: database))
        let document = try DocumentStore(database: database).create(collection: .blog)

        #expect(model.imageFile(for: "../../assets/blog/trip/pic.jpg", in: document)?.lastPathComponent == "pic.jpg")
        #expect(model.imageFile(for: "../../../secret.txt", in: document) == nil)
        #expect(model.imageFile(for: "../../assets/blog/trip/nope.jpg", in: document) == nil)
        #expect(model.imageFile(for: "https://example.com/a.png", in: document) == nil)

        let page = model.page(for: document, body: "![a trip](../../assets/blog/trip/pic.jpg)\n", stylesheet: nil)
        #expect(page.contains("src=\"data:image/jpeg;base64,AQID\""))
    }
}
