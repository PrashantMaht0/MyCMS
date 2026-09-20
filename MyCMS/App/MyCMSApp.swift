import SwiftUI

@main struct MyCMSApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        // One window, because one library and one editor cannot be shared by two.
        Window("MyCMS", id: "main") {
            HealthView()
                .frame(minWidth: 900, minHeight: 600)
                .environment(environment)
        }
        .defaultSize(width: 1100, height: 700)

        Settings {
            SettingsPlaceholderView()
        }
    }
}

// Command comma opens this until feature 21 builds the real settings window.
struct SettingsPlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Settings")
                .font(.title3.weight(.semibold))
            Text("Repository, AI and editor preferences arrive in feature 21.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(width: 420)
    }
}
