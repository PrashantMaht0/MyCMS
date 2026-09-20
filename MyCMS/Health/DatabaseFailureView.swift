import AppKit
import SwiftUI

// The blocking state. When the database cannot be opened there is nowhere safe to type,
// so this replaces the surface entirely rather than sitting beside it.
struct DatabaseFailureView: View {
    let result: CheckResult

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Label("MyCMS cannot open its database", systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.red)
                Text("Nothing you write could be saved, so the editor stays closed until this is fixed.")
                    .foregroundStyle(.secondary)
            }

            if let errorText = result.errorText {
                labelled("What went wrong", errorText)
            }

            if let path = result.path {
                labelled("Database file", path)

                Button("Reveal in Finder") {
                    let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: folder.path(percentEncoded: false))
                }
            }

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labelled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    DatabaseFailureView(
        result: .failed(
            .database,
            detail: "Could not open the database",
            error: DataError.openFailed(
                path: "/Users/you/Library/Application Support/com.prashantmahto.MyCMS/mycms.sqlite",
                underlying: CocoaError(.fileWriteNoPermission)
            )
        )
    )
    .frame(width: 700, height: 420)
}
