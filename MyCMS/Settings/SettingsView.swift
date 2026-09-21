import AppKit
import SwiftUI
import UniformTypeIdentifiers

// AC-55 to AC-59. One view, the same instance whether opened with Command comma or from the sidebar.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let model = environment.preferences
        TabView {
            RepositorySection(model: model).tabItem { Label("Repository", systemImage: "externaldrive") }
            AISection(model: model).tabItem { Label("AI", systemImage: "sparkles") }
            EditorSection(model: model).tabItem { Label("Editor", systemImage: "textformat") }
            DataSection(model: model).tabItem { Label("Data", systemImage: "cylinder") }
        }
        .frame(width: 540, height: 400)
        .task { model.load() }
    }
}

private struct RepositorySection: View {
    let model: SettingsModel
    @State private var choosing = false

    var body: some View {
        Form {
            LabeledContent("Folder", value: model.repository?.path ?? "Not set")
            LabeledContent("Remote", value: model.repository.map { "\($0.remoteName)  \($0.remoteUrl)" } ?? "None")
            LabeledContent("Branch", value: model.repository?.branch ?? "None")

            HStack {
                Button(model.isChangingRepository ? "Checking" : "Change") { choosing = true }
                    .disabled(model.isChangingRepository)
                if model.isChangingRepository { ProgressView().controlSize(.small) }
            }
            if let problem = model.repositoryProblem {
                Text(problem).foregroundStyle(Broadsheet.Colors.accentText).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            Task { await model.changeRepository(to: folder) }
        }
    }
}

private struct AISection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                TextField("Ollama URL", text: $model.ollamaURL)
                    .onSubmit { Task { await model.refreshModels() } }
                Text("This is where your writing is sent to be checked. Keep it on this Mac unless you mean otherwise.")
                    .font(.caption).foregroundStyle(.secondary)

                Picker("Model", selection: $model.model) {
                    // The stored model stays listed even when Ollama cannot say whether it is there.
                    ForEach(Array(Set(model.installedModels + [model.model])).sorted(), id: \.self) { name in
                        Text(model.installedModels.contains(name) ? name : "\(name) (not installed)").tag(name)
                    }
                }
                if let problem = model.modelListProblem {
                    Text(problem).font(.caption).foregroundStyle(Broadsheet.Colors.accentText)
                }
                Button("Refresh model list") { Task { await model.refreshModels() } }
            }
            Section("Suggestions") {
                Toggle("Grammar", isOn: $model.grammarEnabled)
                Toggle("Punctuation", isOn: $model.punctuationEnabled)
                Toggle("Rewrites on request", isOn: $model.rewritesEnabled)
                Stepper(value: $model.checkDelay, in: 0.5...10, step: 0.5) {
                    Text("Check \(model.checkDelay, specifier: "%.1f") seconds after you stop typing")
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshModels() }
    }
}

private struct EditorSection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Stepper(value: $model.fontSize, in: 11...28, step: 1) {
                Text("Font size \(Int(model.fontSize)) points")
            }
            Toggle("Show Markdown markers", isOn: $model.showMarkers)
            Text("Hiding markers changes only how they are drawn. The text you publish keeps every one.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct DataSection: View {
    let model: SettingsModel
    @State private var exporting = false

    var body: some View {
        Form {
            LabeledContent("Database", value: model.databaseFolder.path(percentEncoded: false))
            Button("Show in Finder") { model.revealDatabaseFolder() }

            Section {
                Button("Export every document") { exporting = true }
                Text("Writes each post and project, drafts included, as the Markdown a publish would write.")
                    .font(.caption).foregroundStyle(.secondary)
                if let message = model.exportMessage { Text(message) }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $exporting, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            model.export(to: folder)
        }
    }
}
