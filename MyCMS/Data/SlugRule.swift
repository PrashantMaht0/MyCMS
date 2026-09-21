import Foundation

// How a title becomes the path segment the site publishes at.
nonisolated enum SlugRule {
    // Returns nil rather than an empty string, because the partial unique index exempts NULL only.
    static func derive(from title: String) -> String? {
        var slug = title.lowercased()
        slug = slug.replacingOccurrences(
            of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? nil : slug
    }

    // The suffix appended when a slug is already taken in the same collection.
    static func candidate(_ base: String, attempt: Int) -> String {
        attempt <= 1 ? base : "\(base)-\(attempt)"
    }
}
