import GRDB
import SwiftUI

// AC-48. The two step publish: the details and a live rule list, then the exact files and the
// commit message, then per step progress, and git's own words with Close and Retry if it fails.
@Observable final class PublishFlow: Identifiable {
    enum Phase {
        case details
        case checking
        case review(PublishPlan)
        case publishing
        case done(pushed: Bool)
        case failed(String)
    }

    let id = UUID()
    private(set) var document: Document
    private(set) var phase: Phase = .details
    private(set) var steps: [PublishStep: StepState] = [:]

    var publishDate: Date
    var featured: Bool
    var canonicalURL: String
    var message = ""

    @ObservationIgnored private let publisher: Publisher
    @ObservationIgnored private let documents: DocumentStore

    init(document: Document, publisher: Publisher, documents: DocumentStore) {
        self.document = document
        self.publisher = publisher
        self.documents = documents
        self.publishDate = document.publishDate ?? Date()
        self.featured = document.featured
        self.canonicalURL = document.fields.canonicalUrl?.absoluteString ?? ""
    }

    // The document as it would be written, so the rule list is live while you edit.
    var edited: Document {
        var copy = document
        copy.featured = featured
        let trimmed = canonicalURL.trimmingCharacters(in: .whitespaces)
        copy.fields.canonicalUrl = trimmed.isEmpty ? nil : URL(string: trimmed)
        return copy
    }

    var rules: [ValidationRule] {
        publisher.validator(for: edited).validate(edited)
    }

    var siteURL: String {
        publisher.siteURL(collection: document.collection, slug: document.slug ?? "")
    }

    // A published post whose slug moved gets a redirect, and the sheet says so before it happens.
    var redirectWarning: String? {
        guard let old = document.publishedSlug, let new = document.slug, old != new else { return nil }
        return "The address changes from /\(document.collection.rawValue)/\(old). The old one will redirect here."
    }

    func proceed() async {
        do {
            document = edited
            try documents.update(id: document.id, [
                Column("featured").set(to: featured),
                Column("fields_json").set(to: try DatabaseJSON.encode(document.fields)),
            ])
            phase = .checking
            try await publisher.preflight()
            let plan = try publisher.plan(for: document, publishDate: publishDate)
            message = plan.defaultMessage
            phase = .review(plan)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func publish(_ plan: PublishPlan) async {
        steps = Dictionary(uniqueKeysWithValues: PublishStep.allCases.map { ($0, .waiting) })
        phase = .publishing
        do {
            let result = try await publisher.publish(
                plan, message: message.isEmpty ? plan.defaultMessage : message, document: document
            ) { step, state in
                steps[step] = state
            }
            phase = .done(pushed: result.pushed)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func retry() {
        phase = .details
    }
}

struct PublishSheet: View {
    @Bindable var flow: PublishFlow
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x3) {
            Text(title)
                .font(Broadsheet.serif(Broadsheet.TypeScale.heading[3], weight: .semibold))

            switch flow.phase {
            case .details: details
            case .checking: ProgressView("Checking your repository").controlSize(.small)
            case .review(let plan): review(plan)
            case .publishing: progress
            case .done(let pushed): done(pushed)
            case .failed(let message): failure(message)
            }
        }
        .padding(Broadsheet.Space.x6)
        .frame(width: 520)
        .font(Broadsheet.serif(Broadsheet.TypeScale.uiLarge))
    }

    private var title: String {
        switch flow.phase {
        case .details, .checking: "Publish"
        case .review: "Review the changes"
        case .publishing: "Publishing"
        case .done: "Published"
        case .failed: "Publishing stopped"
        }
    }

    // MARK: Step one

    private var details: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x3) {
            LabeledContent("Address") {
                Text(flow.siteURL).textSelection(.enabled)
            }
            if let warning = flow.redirectWarning {
                Text(warning).foregroundStyle(Broadsheet.Colors.accentText)
            }

            DatePicker("Publish date", selection: $flow.publishDate, displayedComponents: .date)
            Toggle("Featured on the home page", isOn: $flow.featured)

            LabeledContent("Cover") {
                Text(flow.document.cover == nil ? "None" : flow.document.coverAlt)
                    .foregroundStyle(Broadsheet.Colors.secondaryText)
            }

            if flow.document.collection == .blog {
                DisclosureGroup("Advanced") {
                    TextField("Canonical URL, if this first appeared elsewhere", text: $flow.canonicalURL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Canonical URL")
                }
            }

            Divider()
            RuleList(rules: flow.rules)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onClose).keyboardShortcut(.cancelAction)
                Button("Continue") { Task { await flow.proceed() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!DocumentValidator.allPass(flow.rules))
            }
        }
    }

    // MARK: Step two

    private func review(_ plan: PublishPlan) -> some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x3) {
            Text("These files change in your repository, and nothing else:")
            VStack(alignment: .leading, spacing: Broadsheet.Space.x1) {
                ForEach(plan.changes, id: \.path) { change in
                    HStack(alignment: .firstTextBaseline) {
                        Text(change.verb)
                            .foregroundStyle(Broadsheet.Colors.secondaryText)
                            .frame(width: 100, alignment: .leading)
                        Text(change.path).font(.system(.body, design: .monospaced))
                    }
                }
            }
            .accessibilityElement(children: .combine)

            TextField("Commit message", text: $flow.message)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Commit message")

            HStack {
                Button("Back") { flow.retry() }
                Spacer()
                Button("Cancel", role: .cancel, action: onClose).keyboardShortcut(.cancelAction)
                Button("Publish") { Task { await flow.publish(plan) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Progress and outcome

    private var progress: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x2) {
            ForEach(PublishStep.allCases, id: \.self) { step in
                HStack {
                    stepIcon(flow.steps[step] ?? .waiting)
                    Text(step.rawValue)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private func stepIcon(_ state: StepState) -> some View {
        switch state {
        case .waiting: Image(systemName: "circle").foregroundStyle(Broadsheet.Colors.secondaryText).accessibilityLabel("Waiting")
        case .running: ProgressView().controlSize(.small).accessibilityLabel("Running")
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Broadsheet.Colors.accentText).accessibilityLabel("Failed")
        }
    }

    private func done(_ pushed: Bool) -> some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x3) {
            Text(pushed ? "It is on GitHub. Your site rebuilds in a minute or two." : "Committed.")
            Text(flow.siteURL).textSelection(.enabled).foregroundStyle(Broadsheet.Colors.secondaryText)
            HStack {
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x3) {
            ScrollView {
                Text(message)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            HStack {
                Spacer()
                Button("Close", role: .cancel, action: onClose).keyboardShortcut(.cancelAction)
                Button("Retry") { flow.retry() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

// The live checklist, so a failing rule is fixed before Continue rather than discovered after.
struct RuleList: View {
    let rules: [ValidationRule]

    var body: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x1) {
            ForEach(rules) { rule in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: rule.passed ? "checkmark" : "xmark")
                        .foregroundStyle(rule.passed ? Broadsheet.Colors.secondaryText : Broadsheet.Colors.accentText)
                        .accessibilityHidden(true)
                    Text(rule.passed ? rule.label : rule.problem)
                        .foregroundStyle(rule.passed ? Broadsheet.Colors.secondaryText : Broadsheet.Colors.text)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(rule.passed ? "Passes: \(rule.label)" : "Fails: \(rule.problem)")
            }
        }
    }
}
