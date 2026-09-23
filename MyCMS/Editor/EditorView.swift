import SwiftUI
import UniformTypeIdentifiers

// The editor takes over the window, as the mockup draws it.
struct EditorView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var session: DocumentSession
    @State private var controller: EditorTextController
    @State private var styler = MarkdownStyler(
        fontSize: Broadsheet.TypeScale.body, showMarkers: true)
    @State private var images: ImageInsertion
    // Where a picked file goes. Kept apart from isPicking, because the picker clears its own
    // presented flag before it reports the file, which used to send every cover into the body.
    @State private var picking: ImageInsertion.Target?
    @State private var isPicking = false
    @State private var isPreviewing = false
    @State private var publishFlow: PublishFlow?
    @State private var suggestions: SuggestionEngine?
    @State private var rewritePopover: NSPopover?
    @State private var showsHistory = false

    private let assets: AssetStore
    private let revisions: RevisionStore
    private let onClose: () -> Void

    init(
        document: Document, store: DocumentStore, assets: AssetStore, revisions: RevisionStore,
        onClose: @escaping () -> Void
    ) {
        let session = DocumentSession(document: document, store: store, assets: assets, revisions: revisions)
        let controller = EditorTextController()
        _session = State(initialValue: session)
        _controller = State(initialValue: controller)
        _images = State(initialValue: ImageInsertion(assets: assets, session: session, controller: controller))
        self.assets = assets
        self.revisions = revisions
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            fields
            if isPreviewing {
                PreviewView(
                    model: PreviewModel(settings: environment.settings, assets: assets),
                    document: session.document,
                    markdown: session.body)
            } else {
                FormattingToolbar(controller: controller, aiEnabled: aiToggle)
                Divider()
                HStack(spacing: 0) {
                    // Rebuilt when the preview closes, and the styler reparses once on the way back.
                    MarkdownTextView(
                        text: Binding(get: { session.body }, set: { session.body = $0 }),
                        styler: styler,
                        controller: controller,
                        onImages: { incoming in
                            Task { await images.receive(incoming, target: .body(controller.selection)) }
                        },
                        suggestionRanges: suggestions?.isEnabled == true
                            ? suggestions?.suggestions.map(\.range) ?? [] : [],
                        onRewrite: rewritesEnabled ? { showRewrites(for: $0) } : nil)
                    if showsHistory {
                        Divider()
                        HistoryPanel(session: session, revisions: revisions)
                    } else if let suggestions, suggestions.isEnabled {
                        Divider()
                        SuggestionPanel(engine: suggestions) { controller.select($0) }
                    }
                }
            }
        }
        .background(Broadsheet.Colors.background)
        .task {
            applyEditorSettings()
            startSuggestions()
            controller.onPickImage = { pick(.body(controller.selection)) }
        }
        .fileImporter(
            isPresented: $isPicking,
            allowedContentTypes: [.image]
        ) { result in
            let target = picking ?? .body(nil)
            picking = nil
            guard case .success(let url) = result else { return }
            Task { await images.receive([.file(url)], target: target) }
        }
        .sheet(item: Binding(get: { images.pending }, set: { if $0 == nil { images.cancel() } })) { pending in
            AltTextSheet(pending: pending, onInsert: { images.confirm(alt: $0) }, onCancel: { images.cancel() })
        }
        .alert(
            "Could not add the image",
            isPresented: Binding(get: { images.errorMessage != nil }, set: { if !$0 { images.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(images.errorMessage ?? "")
        }
        .sheet(item: $publishFlow, onDismiss: { session.reloadFromStore() }) { flow in
            PublishSheet(flow: flow) {
                // AC-9. A moved address reaches the open text before the sheet's reload runs.
                if let slug = flow.movedTo { session.adoptPublishedAddress(slug) }
                publishFlow = nil
            }
        }
        .onChange(of: environment.preferences.fontSize) { _, size in styler.fontSize = CGFloat(size) }
        .onChange(of: environment.preferences.showMarkers) { _, show in styler.showMarkers = show }
        .onChange(of: session.documentWasDeleted) { _, gone in
            if gone { close() }
        }
    }

    // MARK: AI

    private var aiToggle: Binding<Bool> {
        Binding(get: { suggestions?.isEnabled ?? false }, set: { suggestions?.isEnabled = $0 })
    }

    private var rewritesEnabled: Bool {
        environment.preferences.rewritesEnabled
    }

    // Notes 7.9. Suggestions sit beside the editor and never stand in its way, running or not.
    private func startSuggestions() {
        guard suggestions == nil else { return }
        let engine = SuggestionEngine(session: session, store: environment.suggestions, settings: environment.settings)
        engine.apply = { [controller] range, original, replacement in
            controller.replace(range, expecting: original, with: replacement)
        }
        styler.onEdit = { [weak engine] range, delta in engine?.textEdited(range: range, delta: delta) }
        suggestions = engine
        Task {
            await engine.refreshAvailability()
            engine.scheduleCheck(after: .zero)
        }
    }

    // AC-32. The popover opens at once and fills in when the model answers.
    private func showRewrites(for range: NSRange) {
        guard let engine = suggestions, let anchor = controller.anchorView() else { return }
        let text = session.body as NSString
        guard range.upperBound <= text.length else { return }

        let request = RewriteRequest(range: range, original: text.substring(with: range))
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: RewritePopover(request: request) { choice in
                acceptRewrite(choice, for: request)
            })
        rewritePopover = popover
        popover.show(relativeTo: controller.rect(for: range), of: anchor, preferredEdge: .maxY)

        Task {
            do {
                request.state = .ready(try await engine.rewrites(of: range))
            } catch {
                request.state = .failed(error.localizedDescription)
            }
        }
    }

    // A snapshot first, so the rewrite can always be taken back from history, then the flag.
    private func acceptRewrite(_ choice: String, for request: RewriteRequest) {
        rewritePopover?.close()
        rewritePopover = nil
        _ = try? environment.revisions.snapshot(session.document, body: session.body, reason: .beforeAI)
        guard controller.replace(request.range, expecting: request.original, with: choice) else { return }
        session.markAIAssisted()
    }

    // Everything typed is saved first, so the file written is exactly what is on screen.
    private func startPublish() async {
        await session.flush()
        session.reloadFromStore()
        publishFlow = PublishFlow(
            document: session.document, publisher: environment.publisher, documents: environment.documents)
    }

    // AC-3 and AC-61. Read from the shared model, which the Settings window changes live.
    private func applyEditorSettings() {
        environment.preferences.load()
        styler.showMarkers = environment.preferences.showMarkers
        styler.fontSize = CGFloat(environment.preferences.fontSize)
    }

    private var topBar: some View {
        HStack(spacing: Broadsheet.Space.x3) {
            Button {
                close()
            } label: {
                Label("Library", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            .accessibilityLabel("Back to library")
            .accessibilityHint("Saves anything pending, then closes the editor")

            SavePill(state: session.saveState) { await session.retry() }

            Spacer()

            // AC-50. History shares the side of the editor with suggestions, one at a time.
            Toggle(isOn: $showsHistory) {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .toggleStyle(.button)
            .disabled(isPreviewing)
            .help("Earlier versions of this document")

            // AC-14. Preview is a toggle, so reading and writing are one keystroke apart.
            Toggle(isOn: $isPreviewing) {
                Label("Preview", systemImage: "eye")
            }
            .toggleStyle(.button)
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .help("Preview with your site's stylesheet")
            .accessibilityLabel("Preview")

            Button("Publish") { Task { await startPublish() } }
                .buttonStyle(.borderedProminent)
                .help("Validate, review the files, then commit and push to your site")

            Text("\(session.wordCount) words")
                .monospacedDigit()
                .accessibilityLabel("\(session.wordCount) words")
            Text("\(session.readingMinutes) min read")
                .monospacedDigit()
                .accessibilityLabel("about \(session.readingMinutes) minutes to read")
        }
        .font(Broadsheet.serif(Broadsheet.TypeScale.uiLarge))
        .foregroundStyle(Broadsheet.Colors.secondaryText)
        .padding(.horizontal, Broadsheet.Space.x4)
        .padding(.vertical, Broadsheet.Space.x2)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x2) {
            TextField("Title", text: Binding(get: { session.title }, set: { session.title = $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(Broadsheet.serif(Broadsheet.TypeScale.heading[1], weight: .semibold))
                .accessibilityLabel("Title")

            TextField(
                "Subtitle", text: Binding(get: { session.subtitle }, set: { session.subtitle = $0 }), axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(Broadsheet.serif(Broadsheet.TypeScale.heading[4]))
            .foregroundStyle(Broadsheet.Colors.secondaryText)
            .accessibilityLabel("Subtitle")

            if session.document.collection == .projects {
                ProjectDetails(fields: Binding(get: { session.fields }, set: { session.fields = $0 }))
            }

            TagField(tags: Binding(get: { session.tags }, set: { session.tags = $0 }))

            coverRow
        }
        // Never squeezed: a wrapping title would otherwise shrink to nothing; the body gives way instead.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Broadsheet.Space.x6)
        .padding(.top, Broadsheet.Space.x4)
    }

    private func pick(_ target: ImageInsertion.Target) {
        picking = target
        isPicking = true
    }

    // AC-66. The cover goes through the same store as an inline picture, alt text and all.
    private var coverRow: some View {
        HStack(spacing: Broadsheet.Space.x2) {
            if let cover = session.cover {
                if let url = assets.resolve(reference: cover, for: session.document)?.url,
                    let image = NSImage(contentsOf: url)
                {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 32)
                        .clipShape(.rect(cornerRadius: Broadsheet.Radius.small))
                        .accessibilityLabel("Cover: \(session.coverAlt)")
                } else {
                    Text("Cover missing: \(cover)")
                        .foregroundStyle(Broadsheet.Colors.accentText)
                }
                Button("Change cover") { pick(.cover) }
                    .buttonStyle(.link)
                Button("Remove") { session.setCover(nil, alt: "") }
                    .buttonStyle(.link)
                    .accessibilityLabel("Remove cover image")
            } else {
                Button("Add cover image") { pick(.cover) }
                    .buttonStyle(.link)
            }
        }
        .font(Broadsheet.serif(Broadsheet.TypeScale.uiSmall))
    }

    // Nothing is lost on the way out, because the pending save is awaited first.
    private func close() {
        Task {
            await session.flush()
            onClose()
        }
    }
}

private struct SavePill: View {
    let state: DocumentSession.SaveState
    let onRetry: () async -> Void

    var body: some View {
        HStack(spacing: Broadsheet.Space.x1) {
            Text(label)
            if case .failed(_, let attempts) = state, attempts >= 3 {
                Button("Retry") { Task { await onRetry() } }
                    .buttonStyle(.link)
            }
        }
        .foregroundStyle(isFailed ? Broadsheet.Colors.accentText : Broadsheet.Colors.secondaryText)
        .help(helpText)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isFailed ? "Not saved. \(helpText)" : "Save state: \(label)")
    }

    private var label: String {
        switch state {
        case .clean: "Saved"
        case .dirty: "Edited"
        case .saving: "Saving"
        case .failed: "Not saved"
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private var helpText: String {
        if case .failed(let message, _) = state { return message }
        return ""
    }
}

// Enter or comma commits, trimmed, lowercased, capped, no duplicates.
private struct TagField: View {
    // A one off, sized to fit a typical tag rather than to any spacing token.
    private static let inputWidth: CGFloat = 110

    @Binding var tags: [String]
    @State private var draft = ""

    var body: some View {
        HStack(spacing: Broadsheet.Space.x1) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: Broadsheet.Space.x1) {
                    Text(tag)
                    Button {
                        tags.removeAll { $0 == tag }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove tag \(tag)")
                }
                .font(Broadsheet.serif(Broadsheet.TypeScale.uiSmall))
                .padding(.horizontal, Broadsheet.Space.x1)
                .padding(.vertical, 2)
                .background(Broadsheet.Colors.surface, in: .rect(cornerRadius: Broadsheet.Radius.small))
            }

            TextField("Add tag", text: $draft)
                .textFieldStyle(.plain)
                .font(Broadsheet.serif(Broadsheet.TypeScale.uiSmall))
                .frame(maxWidth: Self.inputWidth)
                .accessibilityLabel("Add tag")
                .accessibilityHint("Type a tag and press Return")
                .onChange(of: draft) { _, value in
                    if value.hasSuffix(",") { commit() }
                }
                .onSubmit { commit() }
        }
    }

    private func commit() {
        let tag =
            draft
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        draft = ""

        guard !tag.isEmpty, tag.count <= 32 else { return }
        guard !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        tags.append(tag)
    }
}
