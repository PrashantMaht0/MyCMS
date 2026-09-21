import CryptoKit
import Foundation
import GRDB
import ImageIO
import OSLog
import UniformTypeIdentifiers

// Spec 0005 A, the one image pipeline: copy in, cap, hash, record, resolve, and forget the unused.
// Files live under the document's id, so a slug change rewrites paths and never moves a file.
nonisolated struct AssetStore: Sendable {
    // Notes 5.3. Astro builds its own WebP from whatever this leaves, so bigger is only waste.
    static let maxLongEdge = 2000

    private let database: Database
    let root: URL

    init(database: Database, root: URL = AssetStore.defaultRoot) {
        self.database = database
        self.root = root
    }

    // Beside the database, inside Application Support, so a backup of one carries the other.
    static var defaultRoot: URL {
        Database.defaultURL.deletingLastPathComponent().appending(path: "assets")
    }

    // MARK: Storing

    func store(fileURL: URL, for document: Document) throws -> Asset {
        let name = fileURL.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw AssetError.copyFailed(name: name, underlying: error)
        }
        return try store(data: data, suggestedName: name, for: document)
    }

    func store(data: Data, suggestedName: String, for document: Document) throws -> Asset {
        guard document.slug != nil else { throw AssetError.needsTitle }

        let prepared = try Self.prepare(data, name: suggestedName)
        let folder = root.appending(path: document.id.uuidString)
        let fileName = try uniqueName(
            Self.cleanName(suggestedName, extension: prepared.fileExtension), in: folder, for: document)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try prepared.data.write(to: folder.appending(path: fileName), options: .atomic)
        } catch {
            throw AssetError.copyFailed(name: suggestedName, underlying: error)
        }

        var asset = Asset(
            documentId: document.id,
            fileName: fileName,
            storedPath: "\(document.id.uuidString)/\(fileName)",
            sha256: SHA256.hash(data: prepared.data).map { String(format: "%02x", $0) }.joined(),
            alt: "",
            createdAt: Date(),
            width: prepared.width,
            height: prepared.height)

        asset.id = try database.write { db in
            try asset.insert(db)
            return db.lastInsertedRowID
        }
        Loggers.assets.info(
            "Stored \(fileName, privacy: .private) at \(prepared.width)x\(prepared.height)")
        return asset
    }

    // AC-66. A cover is an image like any other, so it takes exactly the same path in.
    func storeCover(fileURL: URL, for document: Document) throws -> Asset {
        try store(fileURL: fileURL, for: document)
    }

    func setAlt(_ alt: String, for id: Int64) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE assets SET alt = ? WHERE id = ?", arguments: [alt, id])
        }
    }

    // Undoes a store, for when you cancel the alt text prompt.
    func remove(_ asset: Asset) throws {
        try database.write { db in _ = try asset.delete(db) }
        try? FileManager.default.removeItem(at: fileURL(for: asset))
    }

    // MARK: Reading

    func assets(for document: Document) throws -> [Asset] {
        try database.read { db in
            try Asset.filter(Column("document_id") == document.id.uuidString)
                .order(Column("id"))
                .fetchAll(db)
        }
    }

    func fileURL(for asset: Asset) -> URL {
        root.appending(path: asset.storedPath)
    }

    // Notes 4.1. The path written into the body, which is also the path that gets published.
    static func markdownPath(fileName: String, collection: Document.Collection, slug: String) -> String {
        "../../assets/\(collection.rawValue)/\(slug)/\(fileName)"
    }

    // AC-12. Display always reads the app's copy. A miss is nil, and the editor draws AC-16's placeholder.
    func resolve(reference: String, for document: Document) -> (asset: Asset, url: URL)? {
        guard let fileName = Self.fileName(inReference: reference, collection: document.collection),
            let asset = try? assets(for: document).first(where: { $0.fileName == fileName })
        else { return nil }

        let url = fileURL(for: asset)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? (asset, url) : nil
    }

    // The known row behind a reference even when its file is gone, so the placeholder can be sized.
    func asset(forReference reference: String, in document: Document) -> Asset? {
        guard let fileName = Self.fileName(inReference: reference, collection: document.collection)
        else { return nil }
        return try? assets(for: document).first { $0.fileName == fileName }
    }

    // A picture a post imported from your site already has in the repo, read only, and never from
    // anywhere outside src/assets. Nil for a path that would escape that folder.
    static func repoFile(for reference: String, collection: Document.Collection, repo: URL) -> URL? {
        guard !reference.contains("://") else { return nil }
        let allowed = repo.appending(path: "src/assets").standardizedFileURL.path(percentEncoded: false)
        let file = repo.appending(path: "src/content/\(collection.rawValue)")
            .appending(path: reference.removingPercentEncoding ?? reference)
            .standardizedFileURL
        guard file.path(percentEncoded: false).hasPrefix(allowed + "/"),
            FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
        else { return nil }
        return file
    }

    static func fileName(inReference reference: String, collection: Document.Collection) -> String? {
        let prefix = "../../assets/\(collection.rawValue)/"
        guard reference.hasPrefix(prefix) else { return nil }

        let parts = reference.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return String(parts[1]).removingPercentEncoding ?? String(parts[1])
    }

    // MARK: Keeping the body and the rows in step

    // AC-11. Only well formed image spans under the old slug move; prose and code never change.
    static func rewriteReferences(
        in body: String, from oldSlug: String, to newSlug: String, collection: Document.Collection
    ) -> String {
        guard oldSlug != newSlug else { return body }

        let oldPrefix = "../../assets/\(collection.rawValue)/\(oldSlug)/"
        let newPrefix = "../../assets/\(collection.rawValue)/\(newSlug)/"
        let structure = MarkdownRenderer.parse(body)
        let text = NSMutableString(string: body)

        // Back to front, so each replacement leaves the earlier ranges where they were.
        for image in structure.images.reversed() where image.source.hasPrefix(oldPrefix) {
            guard !structure.isCode(at: image.range.location) else { continue }
            let span = text.substring(with: image.range) as NSString
            let at = span.range(of: "(" + oldPrefix)
            guard at.location != NSNotFound else { continue }

            text.replaceCharacters(
                in: NSRange(location: image.range.location + at.location + 1, length: (oldPrefix as NSString).length),
                with: newPrefix)
        }
        return text as String
    }

    // The same move for a lone path, which is what the cover field holds.
    static func movedPath(
        _ path: String, from oldSlug: String, to newSlug: String, collection: Document.Collection
    ) -> String {
        let oldPrefix = "../../assets/\(collection.rawValue)/\(oldSlug)/"
        guard path.hasPrefix(oldPrefix) else { return path }
        return "../../assets/\(collection.rawValue)/\(newSlug)/" + path.dropFirst(oldPrefix.count)
    }

    // AC-65. Rows and files the body and cover no longer mention go, so a deleted picture does not
    // stay on disk forever. Returns how many were removed.
    @discardableResult
    func pruneOrphans(for document: Document, body: String, cover: String?) throws -> Int {
        var referenced = Set(
            MarkdownRenderer.parse(body).images.compactMap {
                Self.fileName(inReference: $0.source, collection: document.collection)
            })
        if let cover, let name = Self.fileName(inReference: cover, collection: document.collection) {
            referenced.insert(name)
        }

        let orphans = try assets(for: document).filter { !referenced.contains($0.fileName) }
        for orphan in orphans { try remove(orphan) }

        if !orphans.isEmpty {
            Loggers.assets.info("Pruned \(orphans.count) unreferenced images")
        }
        return orphans.count
    }

    // Deleting a document cascades its rows; this takes the folder of files with them.
    func removeFolder(for documentID: UUID) {
        try? FileManager.default.removeItem(at: root.appending(path: documentID.uuidString))
    }

    // MARK: Names

    private func uniqueName(_ name: String, in folder: URL, for document: Document) throws -> String {
        let taken = Set(try assets(for: document).map(\.fileName))
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension

        var candidate = name
        var suffix = 2
        while taken.contains(candidate)
            || FileManager.default.fileExists(atPath: folder.appending(path: candidate).path(percentEncoded: false)) {
            candidate = "\(base)-\(suffix).\(ext)"
            suffix += 1
        }
        return candidate
    }

    // Lowercase, spaces to hyphens, nothing a URL would have to escape.
    static func cleanName(_ name: String, extension ext: String) -> String {
        let base = (name as NSString).deletingPathExtension.lowercased()
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: "-_"))

        var cleaned = ""
        for scalar in base.unicodeScalars {
            if allowed.contains(scalar), scalar.isASCII {
                cleaned.unicodeScalars.append(scalar)
            } else if !cleaned.hasSuffix("-") {
                cleaned.append("-")
            }
        }
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(trimmed.isEmpty ? "image" : trimmed).\(ext)"
    }

    // MARK: Capping

    private struct Prepared {
        let data: Data
        let width: Int
        let height: Int
        let fileExtension: String
    }

    // Kept byte for byte when already small enough; otherwise redrawn at the cap. HEIC is always
    // redrawn as JPEG, because a browser cannot show it.
    private static func prepare(_ data: Data, name: String) throws -> Prepared {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let typeID = CGImageSourceGetType(source) as String?,
            let type = UTType(typeID),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
            let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw AssetError.unsupportedFormat(name: name) }

        let accepted: [UTType] = [.png, .jpeg, .gif, .webP, .heic, .heif]
        guard accepted.contains(where: { type.conforms(to: $0) }) else {
            throw AssetError.unsupportedFormat(name: name)
        }

        // EXIF orientations 5 to 8 turn the picture on its side, so what you see swaps the two.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let (width, height) = orientation >= 5 ? (rawHeight, rawWidth) : (rawWidth, rawHeight)
        let isHEIC = type.conforms(to: .heic) || type.conforms(to: .heif)

        if max(width, height) <= maxLongEdge, !isHEIC {
            return Prepared(
                data: data, width: width, height: height,
                fileExtension: type.preferredFilenameExtension ?? "png")
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxLongEdge, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AssetError.resizeFailed(name: name)
        }

        // PNG and GIF keep transparency as PNG; everything photographic becomes JPEG.
        let output: UTType = type.conforms(to: .png) || type.conforms(to: .gif) ? .png : .jpeg
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, output.identifier as CFString, 1, nil)
        else { throw AssetError.resizeFailed(name: name) }

        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw AssetError.resizeFailed(name: name) }

        return Prepared(
            data: encoded as Data, width: image.width, height: image.height,
            fileExtension: output.preferredFilenameExtension ?? "jpg")
    }
}
