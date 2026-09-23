import GRDB
import SwiftUI

/// The state behind the Publish sheet: details, checks, the file list, then progress.
///
/// A new address lives here and nowhere else until the commit exists, so cancelling or a failure
/// leaves the document exactly as it was. `movedTo` is set only once a commit carries the move,
/// which is the editor's signal to take up the new paths.
@Observable final class PublishFlow: Identifiable {
    // The steps of the sheet, in order. Each one draws a different set of controls.
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
    // Spec 0006 A, AC-8. The new slug lives here and nowhere else until the commit exists.
    var isChangingAddress = false
    var newSlug = ""
    // Set once a publish that moved the address has committed, so the editor can take it up.
    private(set) var movedTo: String?

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
        publisher.siteURL(collection: document.collection, slug: movedTo ?? requestedSlug ?? document.slug ?? "")
    }

    // AC-5. Once a post has been live its slug is frozen, and this is the only way to move it.
    var canChangeAddress: Bool { document.publishedSlug != nil }

    private var typedSlug: String { newSlug.trimmingCharacters(in: .whitespaces) }

    var requestedSlug: String? {
        guard isChangingAddress, !typedSlug.isEmpty, typedSlug != document.slug else { return nil }
        return typedSlug
    }

    // AC-8. Checked as typed: the slug rule, then an exact match against the other documents.
    var addressProblem: String? {
        guard isChangingAddress else { return nil }
        guard let slug = requestedSlug else { return "Type the new address, or turn Change address off." }
        guard SlugRule.isValid(slug) else { return PublishError.slugInvalid(slug).errorDescription }
        let taken = (try? documents.isSlugTaken(slug, in: document.collection, except: document.id)) ?? true
        return taken ? PublishError.slugTaken(slug).errorDescription : nil
    }

    // The exact line src/redirects.ts gains, shown before anything is written.
    var redirectLine: String? {
        guard let old = document.publishedSlug, let slug = requestedSlug, addressProblem == nil else { return nil }
        let collection = document.collection.rawValue
        return "'/\(collection)/\(old)': '/\(collection)/\(slug)',"
    }

    func proceed() async {
        do {
            document = edited
            try documents.update(
                id: document.id,
                [
                    Column("featured").set(to: featured),
                    Column("fields_json").set(to: try DatabaseJSON.encode(document.fields)),
                ])
            phase = .checking
            try await publisher.preflight()
            let plan = try publisher.plan(for: document, publishDate: publishDate, newSlug: requestedSlug)
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
            if plan.movedFrom != nil { movedTo = plan.slug }
            phase = .done(pushed: result.pushed)
        } catch {
            // A failed push still has its commit, so the address has moved all the same.
            if case PublishError.pushFailed = error, plan.movedFrom != nil { movedTo = plan.slug }
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
            if flow.canChangeAddress { changeAddress }

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
                    .disabled(!DocumentValidator.allPass(flow.rules) || flow.addressProblem != nil)
            }
        }
    }

    // AC-8. Old address, new address and the redirect line, all before Continue.
    private var changeAddress: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x2) {
            Toggle("Change address", isOn: $flow.isChangingAddress)
            if flow.isChangingAddress {
                TextField("New address", text: $flow.newSlug)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("New address")
                LabeledContent("Old address") {
                    Text("/\(flow.document.collection.rawValue)/\(flow.document.publishedSlug ?? "")")
                        .font(.system(.body, design: .monospaced))
                }
                if let problem = flow.addressProblem {
                    Text(problem).foregroundStyle(Broadsheet.Colors.accentText)
                } else if let line = flow.redirectLine {
                    Text("src/redirects.ts gains this line, so shared links keep working:")
                        .foregroundStyle(Broadsheet.Colors.secondaryText)
                    Text(line).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
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
        StepProgress(steps: flow.steps)
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

// Each git step with its state, shared by publishing and unpublishing.
private struct StepProgress: View {
    let steps: [PublishStep: StepState]

    var body: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x2) {
            ForEach(PublishStep.allCases, id: \.self) { step in
                HStack {
                    icon(steps[step] ?? .waiting)
                    Text(step.rawValue)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private func icon(_ state: StepState) -> some View {
        switch state {
        case .waiting:
            Image(systemName: "circle").foregroundStyle(Broadsheet.Colors.secondaryText).accessibilityLabel("Waiting")
        case .running: ProgressView().controlSize(.small).accessibilityLabel("Running")
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Done")
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(Broadsheet.Colors.accentText).accessibilityLabel(
                "Failed")
        }
    }
}

/// The state behind the Unpublish sheet: the checks, the exact paths to delete, and any redirect
/// that will break.
///
/// Preflight runs before the plan, so the file listing it shows is the one just pulled.
@Observable final class UnpublishFlow: Identifiable {
    enum Phase {
        case checking
        case review(PublishPlan)
        case running
        case done(pushed: Bool)
        case failed(String)
    }

    let id = UUID()
    let document: Document
    private(set) var phase: Phase = .checking
    private(set) var steps: [PublishStep: StepState] = [:]
    private(set) var brokenRedirects: [String] = []
    var message = ""

    @ObservationIgnored private let publisher: Publisher

    init(document: Document, publisher: Publisher) {
        self.document = document
        self.publisher = publisher
    }

    // AC-2. Preflight before the plan, so the listing it reads is the one just pulled.
    func prepare() async {
        phase = .checking
        do {
            try await publisher.preflight()
            let plan = try publisher.planUnpublish(for: document)
            brokenRedirects = publisher.redirectsPointing(at: document)
            message = plan.defaultMessage
            phase = .review(plan)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func unpublish(_ plan: PublishPlan) async {
        steps = Dictionary(uniqueKeysWithValues: PublishStep.allCases.map { ($0, .waiting) })
        phase = .running
        do {
            let result = try await publisher.unpublish(
                plan, message: message.isEmpty ? plan.defaultMessage : message, document: document
            ) { step, state in
                steps[step] = state
            }
            phase = .done(pushed: result.pushed)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

struct UnpublishSheet: View {
    @Bindable var flow: UnpublishFlow
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x3) {
            Text(title)
                .font(Broadsheet.serif(Broadsheet.TypeScale.heading[3], weight: .semibold))

            switch flow.phase {
            case .checking: ProgressView("Checking your repository").controlSize(.small)
            case .review(let plan): review(plan)
            case .running: StepProgress(steps: flow.steps)
            case .done(let pushed): done(pushed)
            case .failed(let message): failure(message)
            }
        }
        .padding(Broadsheet.Space.x6)
        .frame(width: 520)
        .font(Broadsheet.serif(Broadsheet.TypeScale.uiLarge))
        .task { await flow.prepare() }
    }

    private var title: String {
        switch flow.phase {
        case .checking, .review: "Unpublish “\(flow.document.title.isEmpty ? "Untitled" : flow.document.title)”"
        case .running: "Unpublishing"
        case .done: "Unpublished"
        case .failed: "Unpublishing stopped"
        }
    }

    private func review(_ plan: PublishPlan) -> some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x3) {
            if plan.changes.isEmpty {
                Text(
                    "Its files are already gone from your repository, so nothing is committed. It just becomes a draft."
                )
            } else {
                Text("These files are deleted from your repository, and nothing else:")
                VStack(alignment: .leading, spacing: Broadsheet.Space.x1) {
                    ForEach(plan.paths, id: \.self) { path in
                        Text(path).font(.system(.body, design: .monospaced))
                    }
                }
                .accessibilityElement(children: .combine)
            }

            Text(
                "Your words, versions and pictures stay in the app. Publishing it again puts it back at the same address."
            )
            .foregroundStyle(Broadsheet.Colors.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            if !flow.brokenRedirects.isEmpty {
                Text(
                    "These old addresses redirect here and will lead to a missing page: "
                        + flow.brokenRedirects.joined(separator: ", ")
                )
                .foregroundStyle(Broadsheet.Colors.accentText)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !plan.changes.isEmpty {
                TextField("Commit message", text: $flow.message)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Commit message")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onClose).keyboardShortcut(.cancelAction)
                Button("Unpublish", role: .destructive) { Task { await flow.unpublish(plan) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func done(_ pushed: Bool) -> some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x3) {
            Text(pushed ? "It is a draft again. Your site drops the page when it rebuilds." : "Committed.")
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
                Button("Try again") { Task { await flow.prepare() } }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
