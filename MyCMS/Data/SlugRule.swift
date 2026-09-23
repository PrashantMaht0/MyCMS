import Foundation

/// How a title becomes the path segment the site publishes at.
///
/// `derive` lowercases, turns every run of other characters into one hyphen, and returns nil for a
/// title with no letters or digits, because the database exempts only NULL from the unique index.
/// `isValid` is the check a slug typed by hand must pass.
nonisolated enum SlugRule {
    // Returns nil rather than an empty string, because the partial unique index exempts NULL only.
    static func derive(from title: String) -> String? {
        var slug = title.lowercased()
        slug = slug.replacingOccurrences(
            of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? nil : slug
    }

    // Spec 0006 A, AC-8. A typed slug is valid only when deriving it again gives it back unchanged.
    static func isValid(_ slug: String) -> Bool {
        derive(from: slug) == slug
    }

    // The suffix appended when a slug is already taken in the same collection.
    static func candidate(_ base: String, attempt: Int) -> String {
        attempt <= 1 ? base : "\(base)-\(attempt)"
    }
}
