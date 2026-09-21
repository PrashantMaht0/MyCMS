import SwiftUI

// AC-50 to AC-52. Every snapshot of this document, newest first; selecting one shows, word by
// word, what it would change, and Restore keeps the text you are leaving before it replaces it.
struct HistoryPanel: View {
    let session: DocumentSession
    let revisions: RevisionStore

    @State private var list: [Revision] = []
    @State private var selected: Revision?

    var body: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x3) {
            Text("History").font(Broadsheet.serif(Broadsheet.TypeScale.uiLarge, weight: .semibold))

            if list.isEmpty {
                Text("No versions yet. One is kept as you edit, at most every ten minutes, and on every publish.")
                    .foregroundStyle(Broadsheet.Colors.secondaryText)
            } else {
                List(list, selection: Binding(get: { selected?.id }, set: { id in selected = list.first { $0.id == id } })) { revision in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RevisionStore.Reason(rawValue: revision.reason)?.label ?? revision.reason)
                        Text(revision.createdAt, format: .relative(presentation: .named))
                            .font(Broadsheet.serif(Broadsheet.TypeScale.uiSmall))
                            .foregroundStyle(Broadsheet.Colors.secondaryText)
                    }
                    // The tag must be the selection's own type, Int64. An optional tag never matches, so a
                    // click would deselect; a stored row always has an id, and SQLite never issues 0.
                    .tag(revision.id ?? 0)
                    .accessibilityElement(children: .combine)
                }
                .listStyle(.plain)
                .frame(minHeight: 120, maxHeight: 220)
            }

            if let selected {
                Divider()
                Text("What restoring this version would change:")
                    .font(Broadsheet.serif(Broadsheet.TypeScale.uiSmall))
                    .foregroundStyle(Broadsheet.Colors.secondaryText)
                ScrollView {
                    DiffText(runs: WordDiff.diff(from: session.body, to: selected.bodyMd))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                Button("Restore this version") {
                    session.restore(selected)
                    reload()
                }
                .accessibilityHint("Keeps the current text as a version first, then puts this one back")
            }

            Spacer(minLength: 0)
        }
        .padding(Broadsheet.Space.x3)
        .frame(width: 320)
        .frame(maxHeight: .infinity, alignment: .top)
        .font(Broadsheet.serif(Broadsheet.TypeScale.uiLarge))
        .background(Broadsheet.Colors.surface.opacity(0.5))
        .task { reload() }
    }

    private func reload() {
        list = (try? revisions.list(documentID: session.document.id)) ?? []
        if let current = selected, !list.contains(where: { $0.id == current.id }) { selected = nil }
    }
}

// Inserts and removals told apart by more than colour: underline for added, strikethrough for gone.
private struct DiffText: View {
    let runs: [WordDiff.Run]

    var body: some View {
        runs.reduce(Text("")) { text, run in
            switch run {
            case .same(let words):
                text + Text(words)
            case .inserted(let words):
                text + Text(words).underline().foregroundStyle(.green)
            case .removed(let words):
                text + Text(words).strikethrough().foregroundStyle(Broadsheet.Colors.accentText)
            }
        }
        .font(Broadsheet.serif(Broadsheet.TypeScale.body))
        .accessibilityLabel(accessibleSummary)
    }

    private var accessibleSummary: String {
        let added = runs.filter { if case .inserted = $0 { true } else { false } }.count
        let removed = runs.filter { if case .removed = $0 { true } else { false } }.count
        return "\(added) additions and \(removed) removals"
    }
}
