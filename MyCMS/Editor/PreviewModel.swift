import Foundation
import UniformTypeIdentifiers

/// Builds the page the preview and the library detail pane show, from the one renderer.
///
/// Pictures travel inside the page as data, so the web view never reads a file, and they come from
/// the app's own store only. Your site's stylesheet is read fresh each time the preview opens, so a
/// change to the site shows without relaunching.
struct PreviewModel {
    // Desktop fills the pane; Phone is a fixed common width, so a narrow layout can be checked.
    enum Width: String, CaseIterable, Identifiable {
        case desktop
        case phone

        var id: String { rawValue }
        var label: String { self == .desktop ? "Desktop" : "Phone" }

        // Desktop fills the pane like the editor does; Phone is a fixed common width, centred.
        var points: CGFloat? { self == .desktop ? nil : 390 }
    }

    let settings: SettingsStore
    let assets: AssetStore

    private var repo: URL? {
        ((try? settings.string(forKey: SettingsKey.repoPath)) ?? nil).map { URL(fileURLWithPath: $0) }
    }

    // Read fresh each time the preview opens, so a change to your site shows without a relaunch.
    func siteStylesheet() -> String? {
        guard let repo else { return nil }
        return try? String(contentsOf: repo.appending(path: "src/styles/global.css"), encoding: .utf8)
    }

    // Spec 0006 C, AC-19. The app's store only; imported pictures were adopted into it at import.
    func imageFile(for reference: String, in document: Document) -> URL? {
        assets.resolve(reference: reference, for: document)?.url
    }

    // Pictures travel inside the page as data, so the web view never needs to read a file at all.
    func page(for document: Document, body: String, stylesheet: String?) -> String {
        let html = MarkdownRenderer.html(for: body) { source in
            guard let url = imageFile(for: source, in: document), let data = try? Data(contentsOf: url)
            else { return nil }
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
            return "data:\(type);base64,\(data.base64EncodedString())"
        }
        return Self.wrap(html, stylesheet: stylesheet.map { Self.buildShim + $0 } ?? Self.fallbackStylesheet)
    }

    // What Astro injects at build time and global.css only references. Placed first, so anything
    // the site does define still wins.
    static let buildShim = """
        :root { --font-mono: ui-monospace, "SF Mono", Menlo, monospace; }

        """

    static func wrap(_ html: String, stylesheet: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(stylesheet)</style>
        </head><body style="margin:0"><div style="padding:0 30px 40px"><div class="prose">
        \(html)
        </div></div></body></html>
        """
    }

    // AC-15, and the detail pane's own look: Broadsheet's type and colours, in both appearances.
    static let fallbackStylesheet = """
        :root { color-scheme: light dark; --text: #201E1D; --muted: #605D5D; --rule: rgba(32,30,29,.16); --accent: #D6006C; }
        @media (prefers-color-scheme: dark) { :root { --text: #ECE9E8; --muted: #9B9797; --rule: rgba(236,233,232,.16); --accent: #FF90B1; } }
        html, body { margin: 0; background: transparent; color: var(--text); }
        body { font: 15px/1.55 "Source Serif 4 Variable", "Source Serif 4", Georgia, serif; }
        .prose > * + * { margin-top: 1em; }
        .prose h1, .prose h2, .prose h3 { line-height: 1.2; font-weight: 700; }
        .prose h2 { font-size: 32px; margin-top: 1.4em; } .prose h3 { font-size: 25px; margin-top: 1.2em; }
        .prose a { color: var(--accent); }
        .prose code { font: 0.92em ui-monospace, Menlo, monospace; border: 1px solid var(--rule); padding: 1px 4px; }
        .prose pre { border: 1px solid var(--rule); padding: 14px; overflow-x: auto; }
        .prose pre code { border: 0; padding: 0; }
        .prose blockquote { margin-left: 0; border-left: 2px solid var(--rule); padding-left: 18px; color: var(--muted); font-style: italic; }
        .prose img { max-width: 100%; height: auto; }
        .prose hr { border: 0; border-top: 1px solid var(--rule); }
        """
}
