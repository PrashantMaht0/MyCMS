import SwiftUI
import UniformTypeIdentifiers

// Blocks the app when the recorded repo stops working. The library stays closed, because calling
// documents published while their files are out of reach would be a lie.
struct RepositoryRepairView: View {
    let reason: String
    let recordedPath: String?
    var onChoose: (URL) -> Void

    @State private var isChoosingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x4) {
            VStack(alignment: .leading, spacing: Broadsheet.Space.x2) {
                Text("Your portfolio repo is not where it was")
                    .font(Broadsheet.serif(Broadsheet.TypeScale.heading[2], weight: .semibold))
                    .foregroundStyle(Broadsheet.Colors.text)
                Text(reason)
                    .font(.system(size: Broadsheet.TypeScale.uiLarge))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let recordedPath {
                VStack(alignment: .leading, spacing: Broadsheet.Space.x1) {
                    Text("Recorded as")
                        .font(.system(size: Broadsheet.TypeScale.uiSmall))
                        .foregroundStyle(Broadsheet.Colors.secondaryText)
                    Text(recordedPath)
                        .font(.system(size: Broadsheet.TypeScale.uiLarge, design: .monospaced))
                        .foregroundStyle(Broadsheet.Colors.text)
                        .textSelection(.enabled)
                }
                .padding(Broadsheet.Space.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Broadsheet.Colors.surface, in: .rect(cornerRadius: Broadsheet.Radius.medium))
            }

            Text(
                "Choosing a different repo clears every recorded file hash and imports again, because those hashes describe files in the old one."
            )
            .font(.system(size: Broadsheet.TypeScale.uiLarge))
            .foregroundStyle(Broadsheet.Colors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Broadsheet.Space.x2) {
                Button("Choose again") { isChoosingFolder = true }
                    .keyboardShortcut(.defaultAction)
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }

            Spacer()
        }
        .padding(Broadsheet.Space.x8)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Broadsheet.Colors.background)
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let folder = urls.first else { return }
            onChoose(folder)
        }
    }
}
