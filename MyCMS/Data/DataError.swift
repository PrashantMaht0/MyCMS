import Foundation

// Failures the database layer reports to the user.
nonisolated enum DataError: LocalizedError {
    case directoryUnavailable(path: String, underlying: Error)
    case openFailed(path: String, underlying: Error)
    case migrationFailed(path: String, underlying: Error)
    case notOpen
    case notFound
    case slugTaken

    var errorDescription: String? {
        switch self {
        case .directoryUnavailable(let path, let underlying):
            "Could not create the storage folder at \(path). \(underlying.localizedDescription)"
        case .openFailed(let path, let underlying):
            "Could not open the database at \(path). \(underlying.localizedDescription)"
        case .migrationFailed(let path, let underlying):
            "Could not set up the database at \(path). \(underlying.localizedDescription)"
        case .notOpen:
            "The database was used before it was opened."
        case .notFound:
            "That document is no longer in the database."
        case .slugTaken:
            "Another document in this collection already uses that slug."
        }
    }

    // The failure panel shows the resolved path beside the error, so it comes back out here.
    var path: String? {
        switch self {
        case .directoryUnavailable(let path, _), .openFailed(let path, _), .migrationFailed(let path, _):
            path
        case .notOpen, .notFound, .slugTaken:
            nil
        }
    }
}
