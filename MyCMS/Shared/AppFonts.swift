import CoreText
import Foundation
import OSLog

// Source Serif 4 ships in the bundle, so the app never depends on it being installed.
// Registration is attempted once at launch; the serif fallback keeps the app readable if it fails.
nonisolated enum AppFonts {
    static let familyName = "Source Serif 4 Variable"

    private static let state = Registration()

    static var isRegistered: Bool { state.succeeded }

    // Called once from the app's init. Later calls are a no op.
    static func register() {
        state.registerOnce()
    }

    private final class Registration: @unchecked Sendable {
        private let lock = NSLock()
        private var hasRun = false
        private var ok = false

        var succeeded: Bool {
            lock.lock()
            defer { lock.unlock() }
            return ok
        }

        func registerOnce() {
            lock.lock()
            defer { lock.unlock() }
            guard !hasRun else { return }
            hasRun = true

            let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
            let fonts = urls.filter { $0.lastPathComponent.hasPrefix("SourceSerif4") }

            guard !fonts.isEmpty else {
                Loggers.app.error("Source Serif 4 is missing from the bundle, falling back to the system serif")
                return
            }

            // Registered one file at a time, because that overload reports which one failed.
            var failures: [String] = []
            for font in fonts {
                var error: Unmanaged<CFError>?
                if !CTFontManagerRegisterFontsForURL(font as CFURL, .process, &error) {
                    let reason = error?.takeRetainedValue().localizedDescription ?? "unknown reason"
                    failures.append("\(font.lastPathComponent): \(reason)")
                }
            }

            ok = failures.isEmpty
            if ok {
                Loggers.app.info("Registered \(fonts.count, privacy: .public) Source Serif 4 font files")
            } else {
                Loggers.app.error(
                    "Source Serif 4 failed to register, falling back to the system serif: \(failures.joined(separator: "; "), privacy: .public)"
                )
            }
        }
    }
}
