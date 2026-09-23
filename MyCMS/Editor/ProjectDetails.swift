import SwiftUI

// Spec 0006 B, AC-13. The chip rules, kept apart from the view so a test can reach them.
nonisolated enum TechChips {
    // How many chips the site's project card shows.
    static let cardCount = 4

    // Trimmed, never blank, and never a second spelling of one already there; the first one stays.
    static func adding(_ entry: String, to tech: [String]) -> [String] {
        let chip = entry.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chip.isEmpty, !tech.contains(where: { $0.caseInsensitiveCompare(chip) == .orderedSame }) else {
            return tech
        }
        return tech + [chip]
    }

    // The chip at `from` lands where the chip at `to` was, and everything between shifts over.
    static func moving(from: Int, to: Int, in tech: [String]) -> [String] {
        guard tech.indices.contains(from), tech.indices.contains(to), from != to else { return tech }
        var moved = tech
        let chip = moved.remove(at: from)
        moved.insert(chip, at: to)
        return moved
    }
}

// AC-12. A project's own fields, edited in a sheet so the writing surface stays clear, and saved
// through the session's autosave as you type.
struct ProjectDetails: View {
    @Binding var fields: DocumentFields
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: Broadsheet.Space.x1) {
                Image(systemName: "slider.horizontal.3")
                Text("Project details")
                if !summary.isEmpty {
                    Text(summary).foregroundStyle(Broadsheet.Colors.secondaryText)
                }
            }
        }
        .buttonStyle(.plain)
        .font(Broadsheet.serif(Broadsheet.TypeScale.uiLarge))
        .accessibilityHint("Opens the role, timeline, status, tech and links for this project")
        .sheet(isPresented: $isPresented) { sheet }
    }

    // What is already set, so the closed button still says something useful.
    private var summary: String {
        var parts = [fields.role, fields.timeline, fields.status?.rawValue.capitalized].compactMap { $0 }
        if let tech = fields.tech, !tech.isEmpty { parts.append("\(tech.count) tech") }
        return parts.joined(separator: " · ")
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x4) {
            Text("Project details")
                .font(Broadsheet.serif(Broadsheet.TypeScale.heading[3], weight: .semibold))
            form
            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Broadsheet.Space.x6)
        .frame(width: 560)
        .font(Broadsheet.serif(Broadsheet.TypeScale.uiLarge))
        .onExitCommand { isPresented = false }
    }

    private var form: some View {
        Grid(
            alignment: .leadingFirstTextBaseline, horizontalSpacing: Broadsheet.Space.x3,
            verticalSpacing: Broadsheet.Space.x2
        ) {
            row("Role") {
                TextField("Like Solo project", text: text(\.role)).accessibilityLabel("Role")
            }
            row("Timeline") {
                TextField("Like Jun to Aug 2026", text: text(\.timeline)).accessibilityLabel("Timeline")
            }
            row("Status") {
                Picker("Status", selection: $fields.status) {
                    Text("Not set").tag(DocumentFields.ProjectStatus?.none)
                    ForEach(DocumentFields.ProjectStatus.allCases, id: \.self) { status in
                        Text(status.rawValue.capitalized).tag(Optional(status))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            row("Tech") {
                TechField(tech: Binding(get: { fields.tech ?? [] }, set: { fields.tech = $0.isEmpty ? nil : $0 }))
            }
            row("Video") { URLField(label: "Video URL", url: $fields.videoUrl) }
            row("Repository") { URLField(label: "Repository URL", url: $fields.repoUrl) }
            row("Live site") { URLField(label: "Live URL", url: $fields.liveUrl) }
            row("Order") { OrderField(order: $fields.order) }
        }
        .textFieldStyle(.roundedBorder)
    }

    // One labelled row, the label right aligned so the fields start on one edge.
    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(Broadsheet.Colors.secondaryText)
                .gridColumnAlignment(.trailing)
                .accessibilityHidden(true)
            content()
        }
    }

    // A blank field stores nothing, so the frontmatter never carries an empty role or timeline.
    private func text(_ path: WritableKeyPath<DocumentFields, String?>) -> Binding<String> {
        Binding(get: { fields[keyPath: path] ?? "" }, set: { fields[keyPath: path] = $0.isEmpty ? nil : $0 })
    }
}

// AC-14. What you typed stays on screen; the stored URL follows it, and a bad one is named beside it.
private struct URLField: View {
    let label: String
    @Binding var url: URL?
    @State private var typed: String

    init(label: String, url: Binding<URL?>) {
        self.label = label
        _url = url
        _typed = State(initialValue: url.wrappedValue?.absoluteString ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("https://", text: $typed)
                .accessibilityLabel(label)
                .onChange(of: typed) { _, value in url = Self.parse(value) }
            if let problem = DocumentValidator.urlProblem(label, url) {
                Text(problem)
                    .font(Broadsheet.serif(Broadsheet.TypeScale.uiSmall))
                    .foregroundStyle(Broadsheet.Colors.accentText)
            }
        }
    }

    // Text URL(string:) cannot read is escaped rather than dropped, so it still gets named as wrong.
    static func parse(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
            ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
    }
}

// The site sorts projects by this, lowest first; blank means no order.
private struct OrderField: View {
    @Binding var order: Int?
    @State private var typed: String

    init(order: Binding<Int?>) {
        _order = order
        _typed = State(initialValue: order.wrappedValue.map(String.init) ?? "")
    }

    private var isWhole: Bool {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || Int(trimmed) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("Optional", text: $typed)
                .frame(maxWidth: 160)
                .accessibilityLabel("Order")
                .onChange(of: typed) { _, value in
                    let trimmed = value.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { order = nil } else if let number = Int(trimmed) { order = number }
                }
            if !isWhole {
                Text("Order is a whole number, like 3.")
                    .font(Broadsheet.serif(Broadsheet.TypeScale.uiSmall))
                    .foregroundStyle(Broadsheet.Colors.accentText)
            }
        }
    }
}

// AC-13. Return or a comma adds, each chip removes itself, and dragging one onto another moves it there.
private struct TechField: View {
    @Binding var tech: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x1) {
            ChipFlow(spacing: Broadsheet.Space.x1) {
                ForEach(Array(tech.enumerated()), id: \.element) { index, chip in
                    chipView(chip, index: index)
                }
                TextField("Add tech", text: $draft)
                    .textFieldStyle(.plain)
                    .frame(width: 110)
                    .accessibilityLabel("Add tech")
                    .accessibilityHint("Type a technology and press Return")
                    .onChange(of: draft) { _, value in if value.hasSuffix(",") { commit() } }
                    .onSubmit { commit() }
            }
            Text("The first \(TechChips.cardCount) show on the project card. Drag a chip to reorder.")
                .font(Broadsheet.serif(Broadsheet.TypeScale.uiSmall))
                .foregroundStyle(Broadsheet.Colors.secondaryText)
        }
    }

    private func chipView(_ chip: String, index: Int) -> some View {
        let onCard = index < TechChips.cardCount
        return HStack(spacing: Broadsheet.Space.x1) {
            Text(chip).fontWeight(onCard ? .semibold : .regular)
            Button {
                tech.removeAll { $0 == chip }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(chip)")
        }
        .font(Broadsheet.serif(Broadsheet.TypeScale.uiSmall))
        .padding(.horizontal, Broadsheet.Space.x1)
        .padding(.vertical, 2)
        .background(Broadsheet.Colors.surface, in: .rect(cornerRadius: Broadsheet.Radius.small))
        .overlay {
            if onCard {
                RoundedRectangle(cornerRadius: Broadsheet.Radius.small).stroke(Broadsheet.Colors.accent)
            }
        }
        .draggable(chip)
        .dropDestination(for: String.self) { dropped, _ in
            guard let name = dropped.first, let from = tech.firstIndex(of: name) else { return false }
            tech = TechChips.moving(from: from, to: index, in: tech)
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(chip), position \(index + 1)\(onCard ? ", shown on the card" : "")")
        .accessibilityActions {
            if index > 0 {
                Button("Move earlier") { tech = TechChips.moving(from: index, to: index - 1, in: tech) }
            }
            if index < tech.count - 1 {
                Button("Move later") { tech = TechChips.moving(from: index, to: index + 1, in: tech) }
            }
        }
    }

    private func commit() {
        tech = TechChips.adding(draft, to: tech)
        draft = ""
    }
}

// Lays chips out left to right and wraps them, so a long tech list never runs off the editor.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for (subview, point) in zip(subviews, rows.origins) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (origins: [CGPoint], width: CGFloat, height: CGFloat)
    {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, widest, y + rowHeight)
    }
}
