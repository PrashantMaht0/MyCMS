import Foundation
import GRDB
import Synchronization

/// The one SQLite connection the whole app shares, opened once at launch.
///
/// Every store takes this by reference and never opens its own file, so writes from the editor,
/// the publisher and the repo scan all serialise through one queue. `open()` creates the folder,
/// runs the migrations and turns foreign keys on; it throws `DataError` with the resolved path,
/// which the failure screen shows. `inMemory()` is for tests.
nonisolated final class Database: Sendable {
    let url: URL

    // The queue arrives at open(), so the only mutable state is guarded rather than left racy.
    private let connection = Mutex<DatabaseQueue?>(nil)

    init(url: URL = Database.defaultURL) {
        self.url = url
    }

    // Application Support is not gated by privacy consent, so this path needs no prompt.
    static var defaultURL: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.homeDirectory.appending(path: "Library/Application Support")
        let identifier = Bundle.main.bundleIdentifier ?? "com.prashantmahto.MyCMS"
        return base.appending(path: identifier).appending(path: "mycms.sqlite")
    }

    var resolvedPath: String { url.path(percentEncoded: false) }

    // Opens the database, creating its folder when missing, and runs every migration.
    @discardableResult
    func open() throws -> String {
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw DataError.directoryUnavailable(path: folder.path(percentEncoded: false), underlying: error)
        }

        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: resolvedPath)
        } catch {
            throw DataError.openFailed(path: resolvedPath, underlying: error)
        }

        do {
            try Migrations.migrator.migrate(queue)
        } catch {
            throw DataError.migrationFailed(path: resolvedPath, underlying: error)
        }

        connection.withLock { $0 = queue }
        return resolvedPath
    }

    // A fresh migrated database that touches no file, so every test starts from the same empty schema.
    static func inMemory() throws -> Database {
        let database = Database(url: URL(fileURLWithPath: ":memory:"))
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue)
        database.connection.withLock { $0 = queue }
        return database
    }

    // The health check gates the UI on a successful open, so reaching this while closed is a wiring bug.
    var queue: DatabaseQueue {
        get throws {
            guard let queue = connection.withLock({ $0 }) else { throw DataError.notOpen }
            return queue
        }
    }

    func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try queue.read(block)
    }

    func write<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try queue.write(block)
    }
}
