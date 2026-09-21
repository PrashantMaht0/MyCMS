import SwiftUI

// Sidebar, list, detail. Native structure, Broadsheet inside the content.
struct LibraryView: View {
    @Environment(AppEnvironment.self) private var environment
    let model: LibraryModel
    let onOpen: (Document) -> Void
    var onResolve: (UUID, OutsideChangeResolution) -> Void = { _, _ in }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            list
        } detail: {
            detail
        }
        .task { model.start() }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { model.collection }, set: { model.collection = $0 })) {
            Section("Collections") {
                ForEach(Document.Collection.allCases, id: \.self) { collection in
                    HStack {
                        Text(label(for: collection))
                        Spacer()
                        Text("\(model.count(for: .all, in: collection))")
                            .foregroundStyle(Broadsheet.Colors.secondaryText)
                            .monospacedDigit()
                    }
                    .tag(collection)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(label(for: collection)), \(model.count(for: .all, in: collection)) documents")
                }
            }

            Section("Show") {
                ForEach(LibraryModel.Filter.allCases) { filter in
                    Button {
                        model.filter = filter
                    } label: {
                        HStack {
                            Text(filter.label)
                                .foregroundStyle(model.filter == filter ? Broadsheet.Colors.text : Broadsheet.Colors.secondaryText)
                            Spacer()
                            Text("\(model.count(for: filter, in: model.collection))")
                                .foregroundStyle(Broadsheet.Colors.secondaryText)
                                .monospacedDigit()
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(filter.label), \(model.count(for: filter, in: model.collection)) documents")
                    .accessibilityAddTraits(model.filter == filter ? [.isButton, .isSelected] : .isButton)
                    .keyboardShortcut(filter.shortcut, modifiers: .command)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Broadsheet.Colors.surface)
        .safeAreaInset(edge: .bottom) { SidebarFooter(model: environment.preferences) }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
    }

    private var list: some View {
        VStack(spacing: 0) {
            if let errorText = model.errorText {
                ErrorBanner(message: errorText) { model.dismissError() }
            }
            documentList
        }
    }

    private var documentList: some View {
        List(selection: Binding(get: { model.selectedID }, set: { model.selectedID = $0 })) {
            ForEach(model.visibleDocuments) { item in
                DocumentRow(item: item, isChangedOutside: model.isChangedOutside(item.id)).tag(item.id)
            }
        }
        .overlay {
            if model.visibleDocuments.isEmpty { emptyList }
        }
        .searchable(text: Binding(get: { model.query }, set: { model.query = $0 }), prompt: "Search")
        .scrollContentBackground(.hidden)
        .background(Broadsheet.Colors.background)
        .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 460)
        .toolbar {
            ToolbarItem {
                Button {
                    if let document = model.create() { onOpen(document) }
                } label: {
                    Label(newLabel, systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityLabel(newLabel)
                .accessibilityHint("Creates a draft and opens it for writing")
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let id = model.selectedID, let document = model.document(id: id) {
            DocumentDetail(
                document: document,
                preview: PreviewModel(settings: environment.settings, assets: environment.assets),
                publisher: environment.publisher,
                isChangedOutside: model.isChangedOutside(document.id),
                onEdit: { onOpen(document) },
                onLoadFile: { onResolve(document.id, .loadFile) },
                onKeepMine: { onResolve(document.id, .keepMine) })
        } else {
            ContentUnavailableView(
                "Nothing selected",
                systemImage: "doc.text",
                description: Text("Pick something on the left, or start a new one.")
            )
            .background(Broadsheet.Colors.background)
        }
    }

    private var emptyList: some View {
        Group {
            if !model.query.isEmpty {
                ContentUnavailableView.search(text: model.query)
            } else if model.filter != .all {
                ContentUnavailableView(
                    "No \(model.filter.label.lowercased()) here",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Switch to All to see everything in \(label(for: model.collection).lowercased()).")
                )
            } else {
                ContentUnavailableView(
                    "Nothing written yet",
                    systemImage: "square.and.pencil",
                    description: Text("Start your first \(singular(model.collection)).")
                )
            }
        }
    }

    private var newLabel: String {
        model.collection == .blog ? "New post" : "New project"
    }

    private func label(for collection: Document.Collection) -> String {
        collection == .blog ? "Blog posts" : "Projects"
    }

    private func singular(_ collection: Document.Collection) -> String {
        collection == .blog ? "post" : "project"
    }
}

private struct DocumentRow: View {
    let item: DocumentListItem
    var isChangedOutside = false

    var body: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x1) {
            HStack(spacing: Broadsheet.Space.x2) {
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .font(Broadsheet.serif(Broadsheet.TypeScale.heading[4], weight: .semibold))
                    .lineLimit(1)
                Badge(item: item, isChangedOutside: isChangedOutside)
            }

            if !item.description.isEmpty {
                Text(item.description)
                    .font(Broadsheet.serif(Broadsheet.TypeScale.uiLarge))
                    .foregroundStyle(Broadsheet.Colors.secondaryText)
                    .lineLimit(1)
            }

            Text(item.updatedAt.formatted(.relative(presentation: .named)))
                .font(Broadsheet.serif(Broadsheet.TypeScale.uiSmall))
                .foregroundStyle(Broadsheet.Colors.secondaryText)
        }
        .padding(.vertical, Broadsheet.Space.x1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibleLabel)
    }

    private var accessibleLabel: String {
        let name = item.title.isEmpty ? "Untitled" : item.title
        let state = isChangedOutside
            ? "changed outside the app"
            : (item.isModified ? "edited since publishing" : item.state.rawValue)
        let when = item.updatedAt.formatted(.relative(presentation: .named))
        return "\(name), \(state), updated \(when)"
    }
}

// The state is never colour alone; the badge always carries its word.
private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Broadsheet.Space.x2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .accessibilityHidden(true)
            Text(message)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.link)
        }
        .font(Broadsheet.serif(Broadsheet.TypeScale.uiLarge))
        .foregroundStyle(Broadsheet.Colors.accentText)
        .padding(Broadsheet.Space.x3)
        .background(Broadsheet.Colors.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Something went wrong: \(message)")
    }
}

private struct Badge: View {
    let item: DocumentListItem
    var isChangedOutside = false

    var body: some View {
        Text(text)
            .font(Broadsheet.serif(Broadsheet.TypeScale.uiSmall, weight: .semibold))
            .textCase(.uppercase)
            .padding(.horizontal, Broadsheet.Space.x1)
            .padding(.vertical, 1)
            .background(Broadsheet.Colors.surface, in: .rect(cornerRadius: Broadsheet.Radius.small))
            .foregroundStyle(
                isChangedOutside || item.isModified
                    ? Broadsheet.Colors.accentText
                    : Broadsheet.Colors.secondaryText)
            .accessibilityHidden(true)
    }

    private var text: String {
        // The file on disk differs from what the app wrote, which outranks anything else it could say.
        if isChangedOutside { return "Changed outside" }
        if item.isModified { return "Edited" }
        return item.state == .published ? "Published" : "Draft"
    }
}

// The file in the repo no longer matches what the app wrote. Neither version is thrown away
// without you saying which one wins.
private struct OutsideChangeNotice: View {
    let onLoadFile: () -> Void
    let onKeepMine: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x2) {
            Text("Changed outside MyCMS")
                .font(Broadsheet.serif(Broadsheet.TypeScale.heading[4], weight: .semibold))
                .foregroundStyle(Broadsheet.Colors.accentText)
            Text("The file in your repo is not the one this app last wrote. Nothing has been overwritten.")
                .font(.system(size: Broadsheet.TypeScale.uiLarge))
                .foregroundStyle(Broadsheet.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Broadsheet.Space.x2) {
                Button("Load the file's version", action: onLoadFile)
                Button("Keep my version", action: onKeepMine)
            }
        }
        .padding(Broadsheet.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Broadsheet.Colors.surface, in: .rect(cornerRadius: Broadsheet.Radius.medium))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("This document changed outside MyCMS. Choose which version to keep.")
    }
}

private struct DocumentDetail: View {
    let document: Document
    let preview: PreviewModel
    let publisher: Publisher
    var isChangedOutside = false
    let onEdit: () -> Void
    var onLoadFile: () -> Void = {}
    var onKeepMine: () -> Void = {}

    // AC-13. The header stays put and the body scrolls inside the same renderer the preview uses.
    var body: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x3) {
            if isChangedOutside {
                OutsideChangeNotice(onLoadFile: onLoadFile, onKeepMine: onKeepMine)
            }

            Text(document.title.isEmpty ? "Untitled" : document.title)
                .font(Broadsheet.serif(Broadsheet.TypeScale.heading[1], weight: .semibold))

            if !document.description.isEmpty {
                Text(document.description)
                    .font(Broadsheet.serif(Broadsheet.TypeScale.heading[4]))
                    .foregroundStyle(Broadsheet.Colors.secondaryText)
            }

            Button("Edit", action: onEdit)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Opens this document in the editor")

            UnpushedNotice(documentID: document.id, publisher: publisher)

            if !document.bodyMd.isEmpty {
                Divider()
                MarkdownWebView(html: preview.page(for: document, body: document.bodyMd, stylesheet: nil))
                    .padding(.horizontal, -Broadsheet.Space.x6)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding([.horizontal, .top], Broadsheet.Space.x6)
        .background(Broadsheet.Colors.background)
    }
}

// AC-44. A commit that never reached GitHub stays visible until it does.
private struct UnpushedNotice: View {
    let documentID: UUID
    let publisher: Publisher

    @State private var row: Publish?
    @State private var isPushing = false
    @State private var failure: String?

    var body: some View {
        Group {
            if let row, row.status == "committed_not_pushed", let id = row.id {
                VStack(alignment: .leading, spacing: Broadsheet.Space.x1) {
                    HStack {
                        Text("Committed on this Mac but not pushed to GitHub yet.")
                        Button(isPushing ? "Pushing" : "Push now") { Task { await push(id) } }
                            .disabled(isPushing)
                    }
                    if let message = failure ?? row.error {
                        Text(message)
                            .font(Broadsheet.serif(Broadsheet.TypeScale.uiSmall))
                            .foregroundStyle(Broadsheet.Colors.secondaryText)
                            .textSelection(.enabled)
                    }
                }
                .padding(Broadsheet.Space.x2)
                .background(Broadsheet.Colors.surface, in: .rect(cornerRadius: Broadsheet.Radius.medium))
                .accessibilityElement(children: .contain)
            }
        }
        .task(id: documentID) { row = try? publisher.latestPublish(for: documentID) }
    }

    private func push(_ id: Int64) async {
        isPushing = true
        defer { isPushing = false }
        do {
            try await publisher.pushPending(rowID: id)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        row = try? publisher.latestPublish(for: documentID)
    }
}

// AC-55 and AC-62. The Settings route, and the status line: branch and Ollama, read from the rows
// the checks last wrote rather than by running a check to draw it.
private struct SidebarFooter: View {
    let model: SettingsModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x1) {
            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)

            HStack(spacing: Broadsheet.Space.x1) {
                Image(systemName: "arrow.triangle.branch").accessibilityHidden(true)
                Text(model.repository?.branch ?? "no repository")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Branch \(model.repository?.branch ?? "none")")

            HStack(spacing: Broadsheet.Space.x1) {
                Circle()
                    .fill(model.ollamaStatus?.outcome == .ok ? Color.green : Broadsheet.Colors.secondaryText)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(model.ollamaStatus?.outcome == .ok ? "Ollama running" : "Ollama not running")
            }
            .accessibilityElement(children: .combine)
        }
        .font(Broadsheet.serif(Broadsheet.TypeScale.uiSmall))
        .foregroundStyle(Broadsheet.Colors.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Broadsheet.Space.x3)
        .task { model.refreshRecorded() }
    }
}
