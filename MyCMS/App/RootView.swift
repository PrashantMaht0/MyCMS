import SwiftUI

// What the one window shows: the launch checks, a blocking failure, first launch setup, the
// repair screen for a repo that moved, the library, or the editor.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var library: LibraryModel?
    @State private var onboarding: OnboardingModel?
    @State private var openDocument: Document?
    @State private var interrupted: PendingPublish?
    @State private var recoveryError: String?

    var body: some View {
        Group {
            if let failure = environment.health.databaseFailure {
                DatabaseFailureView(result: failure)
            } else {
                stageContent
            }
        }
        .background(Broadsheet.Colors.background)
        .windowFrameAutosave("MyCMSMain")
        .onChange(of: library?.allDocuments.map(\.id) ?? []) { _, ids in
            // An open document deleted from anywhere leaves the list, which is the only signal
            // available when the editor has been sitting open and untouched.
            guard let open = openDocument, !ids.contains(open.id) else { return }
            openDocument = nil
        }
        .onChange(of: environment.setup.stage) { _, stage in
            guard stage == .ready else { return }
            Task { await openLibrary() }
        }
        .alert(
            "A publish was interrupted",
            isPresented: Binding(get: { interrupted != nil }, set: { if !$0 { interrupted = nil } }),
            presenting: interrupted
        ) { pending in
            Button("Finish publishing") { Task { await recover(pending, finish: true) } }
            Button("Discard those changes", role: .destructive) { Task { await recover(pending, finish: false) } }
            Button("Decide later", role: .cancel) {}
        } message: { pending in
            Text("MyCMS stopped part way through a publish. These files in your repository were changed "
                + "and never committed:\n\n" + pending.dirtyPaths.joined(separator: "\n"))
        }
        .alert(
            "Could not recover the publish",
            isPresented: Binding(get: { recoveryError != nil }, set: { if !$0 { recoveryError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recoveryError ?? "")
        }
        .task {
            await environment.health.runOnce()
            // The store cannot be used until the health check has opened the connection.
            guard environment.health.databaseFailure == nil else { return }

            onboarding = environment.setup.makeOnboardingModel(
                ollama: environment.ollama, settings: environment.settings)
            await environment.setup.load()
            if environment.setup.stage == .ready { await openLibrary() }
        }
    }

    @ViewBuilder private var stageContent: some View {
        switch environment.setup.stage {
        case .loading:
            HealthView()

        case .needsSetup:
            if let onboarding {
                OnboardingView(model: onboarding) {
                    onboarding.finish()
                    environment.setup.setupFinished()
                }
            } else {
                HealthView()
            }

        case .needsRepair(let reason, let path):
            RepositoryRepairView(reason: reason, recordedPath: path) { folder in
                Task { await environment.setup.repair(with: folder) }
            }

        case .ready:
            readyContent
        }
    }

    @ViewBuilder private var readyContent: some View {
        if let library {
            if let document = openDocument {
                EditorView(
                    document: document, store: environment.documents, assets: environment.assets,
                    revisions: environment.revisions
                ) {
                    openDocument = nil
                }
            } else {
                LibraryView(
                    model: library,
                    onOpen: { openDocument = $0 },
                    onResolve: { id, resolution in
                        Task {
                            await environment.setup.resolve(id, with: resolution)
                            library.changedOutside = environment.setup.changedOutside
                        }
                    })
            }
        } else {
            HealthView()
        }
    }

    // The scan runs after the library exists, so reading the repo never holds up the window.
    private func openLibrary() async {
        let model = library ?? LibraryModel(store: environment.documents)
        library = model

        await environment.setup.scan()
        model.changedOutside = environment.setup.changedOutside

        // AC-46. Checked once the repo is known good, so the prompt never fronts a broken setup.
        if let pending = try? await environment.publisher.reconcile(), !pending.dirtyPaths.isEmpty {
            interrupted = pending
        }
    }

    private func recover(_ pending: PendingPublish, finish: Bool) async {
        do {
            if finish {
                try await environment.publisher.finish(pending)
            } else {
                try await environment.publisher.discard(pending)
            }
        } catch {
            recoveryError = error.localizedDescription
        }
    }
}
