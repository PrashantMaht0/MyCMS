import Foundation
import GRDB
import OSLog

/// The open document, and the only source of truth for its text while the editor is up.
///
/// Every edit marks a field dirty and schedules an autosave one second later; `flush` is awaited
/// before leaving so nothing is lost. The library's observation never writes back into it, which is
/// what stops a save moving the caret. It also owns the rules that ride along with a save: a title
/// change moves the slug only while a document has never been published, and moving a slug rewrites
/// the picture paths in the same write.
@MainActor @Observable final class DocumentSession {
    // What the save pill shows. A failure keeps its attempt count so Retry can settle it.
    enum SaveState: Equatable {
        case clean
        case dirty
        case saving
        case failed(message: String, attempts: Int)
    }

    // One paragraph of the body, identified by its own text rather than its position.
    nonisolated struct Paragraph: Identifiable, Equatable, Sendable {
        let id: Int
        let text: String
        let range: Range<String.Index>
    }

    private(set) var document: Document
    private(set) var saveState: SaveState = .clean
    private(set) var documentWasDeleted = false

    var body: String { didSet { if !isApplyingOwnEdit { markDirty(.body, from: oldValue, to: body) } } }
    var title: String { didSet { markDirty(.title, from: oldValue, to: title) } }
    var subtitle: String { didSet { markDirty(.subtitle, from: oldValue, to: subtitle) } }
    var tags: [String] {
        didSet {
            if tags != oldValue {
                dirtyFields.insert(.tags)
                scheduleSave()
            }
        }
    }
    // Spec 0006 B, AC-12. The project fields, saved into fields_json by the same autosave.
    var fields: DocumentFields {
        didSet {
            if fields != oldValue, !isApplyingOwnEdit {
                dirtyFields.insert(.fields)
                scheduleSave()
            }
        }
    }

    // AC-66. The cover is a Markdown path like an inline image, and its alt text travels with it.
    private(set) var cover: String?
    private(set) var coverAlt: String

    private enum Field: Hashable { case body, title, subtitle, tags, cover, fields }

    private let store: DocumentStore
    private let assets: AssetStore?
    private let revisions: RevisionStore?
    // Set while the session rewrites its own body, so the rewrite is saved once rather than twice.
    private var isApplyingOwnEdit = false
    private let autosaveDelay: Duration
    private var dirtyFields: Set<Field> = []
    private var saveTask: Task<Void, Never>?

    init(
        document: Document, store: DocumentStore, assets: AssetStore? = nil, revisions: RevisionStore? = nil,
        autosaveDelay: Duration = .seconds(1)
    ) {
        self.document = document
        self.store = store
        self.assets = assets
        self.revisions = revisions
        self.autosaveDelay = autosaveDelay
        self.body = document.bodyMd
        self.title = document.title
        self.subtitle = document.description
        self.tags = document.tags
        self.fields = document.fields
        self.cover = document.cover
        self.coverAlt = document.coverAlt
    }

    func setCover(_ path: String?, alt: String) {
        guard path != cover || alt != coverAlt else { return }
        cover = path
        coverAlt = path == nil ? "" : alt
        dirtyFields.insert(.cover)
        scheduleSave()
    }

    // MARK: Paragraphs

    // Split on blank lines, Markdown's own paragraph rule, but never inside a fenced code block.
    var paragraphs: [Paragraph] {
        Self.split(body)
    }

    nonisolated static func split(_ text: String) -> [Paragraph] {
        var result: [Paragraph] = []
        var inFence = false
        var blockStart = text.startIndex
        var index = text.startIndex
        var blockHasContent = false

        func closeBlock(endingAt end: String.Index) {
            let slice = text[blockStart..<end]
            let trimmed = slice.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.append(Paragraph(id: trimmed.hashValue, text: trimmed, range: blockStart..<end))
            }
            blockHasContent = false
        }

        while index < text.endIndex {
            let lineEnd = text[index...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[index..<lineEnd]
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~") {
                inFence.toggle()
                blockHasContent = true
            } else if trimmedLine.isEmpty && !inFence {
                // A blank line outside a fence ends the current paragraph.
                if blockHasContent { closeBlock(endingAt: index) }
                blockStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
            } else {
                blockHasContent = true
            }

            index = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }

        if blockHasContent { closeBlock(endingAt: text.endIndex) }
        return result
    }

    // MARK: Counts

    var wordCount: Int {
        Self.countWords(body)
    }

    // Prose only, so the badge means what a reader would expect.
    static func countWords(_ markdown: String) -> Int {
        var total = 0
        var inFence = false

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence else { continue }
            total += countWordsInLine(String(rawLine))
        }
        return total
    }

    private static func countWordsInLine(_ line: String) -> Int {
        var text = line
        // Images go first. A link is the same shape without the bang, so stripping links first
        // would eat the [alt](url) out of an image and leave its alt text to be counted.
        text = text.replacingOccurrences(
            of: #"!\[[^\]]*\]\([^)]*\)"#, with: " ", options: .regularExpression)
        // A link counts its text, never its URL.
        text = text.replacingOccurrences(
            of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // Emphasis, heading and quote markers are not words.
        text = text.replacingOccurrences(
            of: #"(^\s{0,3}#{1,6}\s+)|(^\s*>\s?)|(^\s*[-*+]\s+)|(^\s*\d+\.\s+)"#,
            with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_~`]"#, with: "", options: .regularExpression)

        return text.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
            .count
    }

    var readingMinutes: Int {
        max(1, Int((Double(wordCount) / 200).rounded(.up)))
    }

    // MARK: Saving

    private func markDirty(_ field: Field, from old: String, to new: String) {
        guard old != new else { return }
        dirtyFields.insert(field)
        scheduleSave()
    }

    private func scheduleSave() {
        guard !documentWasDeleted else { return }
        if case .failed = saveState {} else { saveState = .dirty }

        saveTask?.cancel()
        saveTask = Task { [autosaveDelay] in
            try? await Task.sleep(for: autosaveDelay)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    // Awaited before switching document, leaving the editor, or quitting, so nothing is lost.
    func flush() async {
        saveTask?.cancel()
        saveTask = nil
        if !dirtyFields.isEmpty { await save() }
        pruneImages()
    }

    // AC-65, run as you leave rather than on every autosave, so cutting a picture and pasting it
    // back a few seconds later never finds its file already gone.
    private func pruneImages() {
        guard let assets, !documentWasDeleted, dirtyFields.isEmpty else { return }
        do {
            try assets.pruneOrphans(for: document, body: body, cover: cover)
        } catch {
            Loggers.assets.error("Pruning images failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() async {
        guard !dirtyFields.isEmpty, !documentWasDeleted else { return }

        let fields = dirtyFields
        let previousAttempts: Int
        if case .failed(_, let attempts) = saveState { previousAttempts = attempts } else { previousAttempts = 0 }
        saveState = .saving

        var assignments: [ColumnAssignment] = []
        if fields.contains(.subtitle) { assignments.append(Column("description").set(to: subtitle)) }
        if fields.contains(.tags) { assignments.append(Column("tags").set(to: Self.encodeTags(tags))) }
        if fields.contains(.fields) {
            assignments.append(Column("fields_json").set(to: (try? DatabaseJSON.encode(self.fields)) ?? "{}"))
        }
        if fields.contains(.cover) {
            assignments.append(Column("cover").set(to: cover))
            assignments.append(Column("cover_alt").set(to: coverAlt))
        }

        var newSlug = document.slug
        var rewrittenBody: String?
        var rewrittenCover: String?
        if fields.contains(.title) {
            assignments.append(Column("title").set(to: title))
            // Spec 0006 A, AC-5. Only a never published draft follows its title; Change address moves the rest.
            if document.publishedSlug == nil {
                let claimed =
                    (try? store.claimSlug(SlugRule.derive(from: title), for: document.id, in: document.collection))
                    ?? nil
                assignments.append(Column("slug").set(to: claimed))
                newSlug = claimed

                // AC-11. Image paths carry the slug, so they move in the same write as it does.
                if let old = document.slug, let claimed, old != claimed {
                    let movedBody = AssetStore.rewriteReferences(
                        in: body, from: old, to: claimed, collection: document.collection)
                    if movedBody != body { rewrittenBody = movedBody }
                    if let cover {
                        let movedCover = AssetStore.movedPath(
                            cover, from: old, to: claimed, collection: document.collection)
                        if movedCover != cover {
                            rewrittenCover = movedCover
                            assignments.append(Column("cover").set(to: rewrittenCover))
                        }
                    }
                }
            }
        }

        if fields.contains(.body) || rewrittenBody != nil {
            assignments.append(Column("body_md").set(to: rewrittenBody ?? body))
            // AC-49. The stored body from before this change, at most once per ten minutes.
            if document.bodyMd != (rewrittenBody ?? body) {
                _ = try? revisions?.snapshot(document, body: document.bodyMd, reason: .autosave)
            }
        }

        do {
            try store.update(id: document.id, assignments)
            dirtyFields.subtract(fields)

            if let rewrittenBody {
                isApplyingOwnEdit = true
                body = rewrittenBody
                isApplyingOwnEdit = false
            }
            if let rewrittenCover { cover = rewrittenCover }
            document.slug = newSlug
            document.cover = cover
            document.coverAlt = coverAlt
            document.bodyMd = body
            document.title = title
            document.description = subtitle
            document.tags = tags
            document.fields = self.fields
            saveState = dirtyFields.isEmpty ? .clean : .dirty
        } catch let error as DataError {
            if case .notFound = error {
                noteDeleted()
            } else {
                saveState = .failed(message: error.errorDescription ?? "Save failed", attempts: previousAttempts + 1)
            }
        } catch {
            saveState = .failed(message: error.localizedDescription, attempts: previousAttempts + 1)
        }
    }

    // AC-52 and AC-54. The text you are leaving is kept first, then the old version goes in like any
    // edit: autosaved, counted, and itself restorable later.
    func restore(_ revision: Revision) {
        _ = try? revisions?.snapshot(document, body: body, reason: .manual)
        body = revision.bodyMd
    }

    // AC-32. Notes open question 3: true once, and only once, an AI rewrite has been accepted.
    func markAIAssisted() {
        guard fields.aiAssisted != true else { return }
        var marked = fields
        marked.aiAssisted = true
        guard let encoded = try? DatabaseJSON.encode(marked),
            (try? store.update(id: document.id, Column("fields_json").set(to: encoded))) != nil
        else { return }
        document.fields.aiAssisted = true
        isApplyingOwnEdit = true
        fields.aiAssisted = true
        isApplyingOwnEdit = false
    }

    // After a publish the row has moved on (state, slug lock, dates), so the session takes it up.
    func reloadFromStore() {
        guard let fresh = try? store.fetch(id: document.id) else { return }
        document = fresh
        // The Publish sheet writes featured and the canonical URL, so fields follow unless you edited them.
        guard !dirtyFields.contains(.fields) else { return }
        isApplyingOwnEdit = true
        fields = fresh.fields
        isApplyingOwnEdit = false
    }

    // Spec 0006 A, AC-9. The publisher already stored the moved slug, body and cover in the commit's
    // transaction; this takes them into the open editor so a later save cannot write the old paths back.
    func adoptPublishedAddress(_ slug: String) {
        guard let old = document.slug, old != slug else { return reloadFromStore() }
        isApplyingOwnEdit = true
        body = AssetStore.rewriteReferences(in: body, from: old, to: slug, collection: document.collection)
        isApplyingOwnEdit = false
        if let cover { self.cover = AssetStore.movedPath(cover, from: old, to: slug, collection: document.collection) }
        reloadFromStore()
    }

    // The Retry control on the save pill. Clears the failure count so the pill can settle again.
    func retry() async {
        guard case .failed = saveState else { return }
        saveState = .dirty
        await save()
    }

    // The document is gone, so stop trying to write to it. The text stays on screen either way.
    func noteDeleted() {
        guard !documentWasDeleted else { return }
        documentWasDeleted = true
        saveTask?.cancel()
        saveTask = nil
        dirtyFields.removeAll()
    }

    private static func encodeTags(_ tags: [String]) -> String {
        (try? DatabaseJSON.encode(tags)) ?? "[]"
    }
}
