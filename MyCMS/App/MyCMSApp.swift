import SwiftUI

// One window, one environment, and the settings scene macOS expects.
@main struct MyCMSApp: App {
    @State private var environment = AppEnvironment()

    init() {
        AppFonts.register()
    }

    var body: some Scene {
        // One window, because one library and one editor cannot be shared by two.
        Window("MyCMS", id: "main") {
            RootView()
                .frame(minWidth: 900, minHeight: 600)
                .environment(environment)
        }
        .defaultSize(width: 1100, height: 700)

        // AC-55. Command comma and the sidebar item show this same view over the same model.
        Settings {
            SettingsView()
                .environment(environment)
        }
    }
}
