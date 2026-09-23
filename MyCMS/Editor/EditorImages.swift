import AppKit
import SwiftUI

/// Everything that happens between a picture arriving and its Markdown landing in the text.
///
/// A picture can arrive by drop, paste or the file picker, and goes to the body or the cover. It is
/// stored first, then the alt text is asked for; cancelling removes what was stored, so a refused
/// picture leaves nothing behind.
@Observable final class ImageInsertion {
    enum Target {
        // Nil means wherever the caret is by the time this picture's turn comes.
        case body(NSRange?)
        case cover
    }

    struct Pending: Identifiable {
        let asset: Asset
        let url: URL
        let target: Target

        var id: Int64 { asset.id ?? -1 }
    }

    private(set) var pending: Pending?
    var errorMessage: String?

    @ObservationIgnored private var queue: [(MarkdownEditorTextView.IncomingImage, Target)] = []
    @ObservationIgnored private let assets: AssetStore
    @ObservationIgnored private let session: DocumentSession
    @ObservationIgnored private let controller: EditorTextController

    init(assets: AssetStore, session: DocumentSession, controller: EditorTextController) {
        self.assets = assets
        self.session = session
        self.controller = controller
    }

    func receive(_ images: [MarkdownEditorTextView.IncomingImage], target: Target) async {
        // A title typed a moment ago may not have claimed its slug yet, so that save goes first.
        if session.document.slug == nil { await session.flush() }
        queue.append(
            contentsOf: images.enumerated().map { index, image in
                // Only the first picture goes to the drop point; the rest follow it down the page.
                if case .body = target, index > 0 { return (image, .body(nil)) }
                return (image, target)
            })
        advance()
    }

    func confirm(alt: String) {
        guard let pending, let slug = session.document.slug else { return }
        self.pending = nil

        let cleanAlt =
            alt
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let path = AssetStore.markdownPath(
            fileName: pending.asset.fileName, collection: session.document.collection, slug: slug)

        if let id = pending.asset.id { try? assets.setAlt(cleanAlt, for: id) }

        switch pending.target {
        case .body(let range):
            controller.insertImageBlock("![\(cleanAlt)](\(path))", at: range ?? controller.selection)
        case .cover:
            session.setCover(path, alt: cleanAlt)
        }
        advance()
    }

    func cancel() {
        guard let pending else { return }
        self.pending = nil
        try? assets.remove(pending.asset)
        advance()
    }

    private func advance() {
        guard pending == nil, !queue.isEmpty else { return }
        let (image, target) = queue.removeFirst()

        do {
            let asset: Asset
            switch (image, target) {
            case (.file(let url), .cover):
                asset = try assets.storeCover(fileURL: url, for: session.document)
            case (.file(let url), .body):
                asset = try assets.store(fileURL: url, for: session.document)
            case (.data(let data, let name), _):
                asset = try assets.store(data: data, suggestedName: name, for: session.document)
            }
            pending = Pending(asset: asset, url: assets.fileURL(for: asset), target: target)
        } catch {
            queue.removeAll()
            errorMessage = error.localizedDescription
        }
    }
}

// AC-9. Alt text is required, so Insert stays off until there is some.
struct AltTextSheet: View {
    let pending: ImageInsertion.Pending
    let onInsert: (String) -> Void
    let onCancel: () -> Void

    @State private var alt = ""

    private var isCover: Bool {
        if case .cover = pending.target { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x3) {
            Text(isCover ? "Describe the cover image" : "Describe this image")
                .font(Broadsheet.serif(Broadsheet.TypeScale.heading[3], weight: .semibold))

            if let image = NSImage(contentsOf: pending.url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 220)
                    .accessibilityHidden(true)
            }

            Text("Alt text is what a screen reader says, and what shows if the picture fails to load.")
                .font(Broadsheet.serif(Broadsheet.TypeScale.uiLarge))
                .foregroundStyle(Broadsheet.Colors.secondaryText)

            TextField("A short description", text: $alt)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Alt text")
                .onSubmit(insert)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(isCover ? "Set cover" : "Insert", action: insert)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(Broadsheet.Space.x6)
        .frame(width: 440)
    }

    private var trimmed: String {
        alt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func insert() {
        guard !trimmed.isEmpty else { return }
        onInsert(trimmed)
    }
}
