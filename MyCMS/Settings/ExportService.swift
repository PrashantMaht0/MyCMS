import Foundation
import GRDB

// AC-59. Every document as the Markdown a publish would write, into a folder you choose. It reads
// the database only and never touches the repository.
nonisolated struct ExportService: Sendable {
    let documents: DocumentStore

    func exportAll(to folder: URL) throws -> Int {
        let all = try documents.read { db in try Document.fetchAll(db) }
        for document in all {
            // Drafts have no slug until they have a title, so they fall back to their id.
            let name = "\(document.collection.rawValue)/\(document.slug ?? document.id.uuidString).md"
            let target = folder.appending(path: name)
            let text = try FrontmatterWriter.serialize(
                document, publishDate: document.publishDate ?? document.createdAt, updatedDate: document.updatedDate)
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: target, options: .atomic)
            } catch {
                throw PublishError.writeFailed(path: name, underlying: error)
            }
        }
        return all.count
    }
}
