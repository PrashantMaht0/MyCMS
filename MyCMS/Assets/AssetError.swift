import Foundation

// Failures the image pipeline reports to the writer.
nonisolated enum AssetError: LocalizedError {
    case unsupportedFormat(name: String)
    case copyFailed(name: String, underlying: Error)
    case resizeFailed(name: String)
    case needsTitle

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let name):
            "\(name) is not a picture the site can show. Use a PNG, JPEG, GIF, WebP or HEIC file."
        case .copyFailed(let name, let underlying):
            "Could not copy \(name) into the app. \(underlying.localizedDescription)"
        case .resizeFailed(let name):
            "Could not shrink \(name) to 2000 pixels on its long edge."
        case .needsTitle:
            "Give the post a title first. Its images are filed under the address the title makes."
        }
    }
}
