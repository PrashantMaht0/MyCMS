import SwiftUI
import UniformTypeIdentifiers

// Screen 1 of the mockup. Four steps, one of which is a hard gate: without a valid repo folder
// there is nothing downstream that would work, so Start writing stays off until there is one.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    var onFinished: () -> Void

    @State private var isChoosingFolder = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Broadsheet.Space.x6) {
                header
                steps
            }
            .padding(Broadsheet.Space.x8)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Broadsheet.Colors.background)
        .safeAreaInset(edge: .bottom) { footer }
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let folder = urls.first else { return }
            Task { await model.choose(folder: folder) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x2) {
            Text("Set up MyCMS")
                .font(Broadsheet.serif(Broadsheet.TypeScale.heading[1], weight: .semibold))
                .foregroundStyle(Broadsheet.Colors.text)
            Text("Point this at your portfolio repo and it takes care of the rest.")
                .font(Broadsheet.serif(Broadsheet.TypeScale.body))
                .foregroundStyle(Broadsheet.Colors.secondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var steps: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x3) {
            repositoryStep
            gitStep
            ollamaStep
            importStep
        }
    }

    private var repositoryStep: some View {
        StepCard(number: 1, title: "Choose your portfolio repo") {
            HStack(spacing: Broadsheet.Space.x2) {
                Button(model.repo == nil ? "Choose Folder" : "Choose a different folder") {
                    isChoosingFolder = true
                }
                .buttonStyle(PrimaryButton(isProminent: model.repo == nil))
                .disabled(model.isValidating)

                if model.isValidating {
                    ProgressView().controlSize(.small)
                }
            }

            if let repo = model.repo {
                StatusLine(
                    state: .ok,
                    text: "\(repo.shortRemote) · branch \(repo.branch)")
                if repo.wasDirtyAtSetup {
                    StatusLine(
                        state: .note,
                        text:
                            "That repo has uncommitted changes. Fine for now; publishing will ask you to deal with them."
                    )
                }
            }

            if let error = model.repoError {
                StatusLine(state: .failed, text: error)
            }
        }
    }

    private var gitStep: some View {
        StepCard(number: 2, title: "Check git") {
            HStack(spacing: Broadsheet.Space.x2) {
                Button(model.git.outcome == nil ? "Check Git" : "Check again") {
                    model.checkGit()
                }
                .buttonStyle(PrimaryButton(isProminent: false))
                .disabled(model.repo == nil || model.git.isRunning)

                if model.git.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancelGitCheck() }
                        .buttonStyle(.link)
                }
            }

            if model.git.isRunning {
                StatusLine(state: .running, text: "Asking the remote whether it would accept a push.")
            }
            if let outcome = model.git.outcome {
                StatusLine(state: .init(outcome.outcome), text: outcome.detail)
                if outcome.outcome == .failed {
                    StatusLine(
                        state: .note,
                        text: "You can still write. Publishing is what needs push, and you can fix this before then.")
                }
            }
        }
    }

    private var ollamaStep: some View {
        StepCard(number: 3, title: "Check Ollama", isOptional: true) {
            HStack(spacing: Broadsheet.Space.x2) {
                Button(model.ollamaStep.outcome == nil ? "Check Ollama" : "Check again") {
                    model.checkOllama()
                }
                .buttonStyle(PrimaryButton(isProminent: false))
                .disabled(model.ollamaStep.isRunning)

                Button("Skip") { model.skipOllama() }
                    .buttonStyle(.link)
                    .disabled(model.ollamaStep.isRunning)

                if model.ollamaStep.isRunning {
                    ProgressView().controlSize(.small)
                }
            }

            if let outcome = model.ollamaStep.outcome {
                StatusLine(state: .init(outcome.outcome), text: outcome.detail)
            }
        }
    }

    private var importStep: some View {
        StepCard(number: 4, title: "Import what is already there") {
            if model.importStep.isRunning {
                StatusLine(state: .running, text: "Reading src/content.")
            }

            if let outcome = model.importStep.outcome {
                StatusLine(state: .init(outcome.outcome), text: outcome.detail)
            }

            if let report = model.report {
                if let note = report.noteLine {
                    StatusLine(state: .note, text: note)
                }
                ForEach(report.renamed, id: \.id) { rename in
                    StatusLine(
                        state: .note,
                        text:
                            "Your draft at \(rename.from) moved to \(rename.to), because the published file keeps that slug."
                    )
                }
                ForEach(report.skipped, id: \.path) { skipped in
                    StatusLine(state: .failed, text: "\(skipped.path): \(skipped.reason)")
                }
            }

            if model.repo == nil {
                StatusLine(state: .note, text: "Runs as soon as a repo is chosen.")
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Start writing") { onFinished() }
                .buttonStyle(PrimaryButton(isProminent: true))
                .disabled(!model.canStartWriting)
                .keyboardShortcut(.defaultAction)
        }
        .padding(Broadsheet.Space.x4)
        .background(.bar)
    }
}

// One numbered step. The optional tag is what tells you Ollama is not a gate.
private struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    var isOptional = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: Broadsheet.Space.x3) {
            Text("\(number)")
                .font(Broadsheet.serif(Broadsheet.TypeScale.uiSmall, weight: .semibold))
                .foregroundStyle(Broadsheet.Colors.secondaryText)
                .frame(width: 18, height: 18)
                .background(Broadsheet.Colors.divider, in: .rect(cornerRadius: Broadsheet.Radius.small))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Broadsheet.Space.x2) {
                HStack(spacing: Broadsheet.Space.x2) {
                    Text(title)
                        .font(Broadsheet.serif(Broadsheet.TypeScale.heading[4], weight: .semibold))
                        .foregroundStyle(Broadsheet.Colors.text)
                    if isOptional {
                        Text("optional")
                            .font(.system(size: Broadsheet.TypeScale.uiSmall))
                            .foregroundStyle(Broadsheet.Colors.secondaryText)
                            .padding(.horizontal, Broadsheet.Space.x1)
                            .padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: Broadsheet.Radius.small)
                                    .stroke(Broadsheet.Colors.divider))
                    }
                }

                content
            }
        }
        .padding(Broadsheet.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Broadsheet.Colors.surface, in: .rect(cornerRadius: Broadsheet.Radius.large))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number), \(title)\(isOptional ? ", optional" : "")")
    }
}

// One line of result under a step. The text is git's or Ollama's own, never reworded.
private struct StatusLine: View {
    enum State {
        case ok
        case failed
        case skipped
        case running
        case note

        init(_ outcome: CheckOutcome.Outcome) {
            switch outcome {
            case .ok: self = .ok
            case .failed: self = .failed
            case .skipped: self = .skipped
            }
        }
    }

    let state: State
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Broadsheet.Space.x2) {
            symbol
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: Broadsheet.TypeScale.uiLarge))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(accessibilityPrefix)\(text)")
    }

    @ViewBuilder private var symbol: some View {
        switch state {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(Broadsheet.Colors.secondaryText)
        case .running: Image(systemName: "ellipsis.circle").foregroundStyle(Broadsheet.Colors.secondaryText)
        case .note: Image(systemName: "info.circle").foregroundStyle(Broadsheet.Colors.secondaryText)
        }
    }

    private var color: Color {
        switch state {
        case .ok, .running, .skipped, .note: Broadsheet.Colors.secondaryText
        case .failed: .red
        }
    }

    private var accessibilityPrefix: String {
        switch state {
        case .ok: "Passed. "
        case .failed: "Failed. "
        case .skipped: "Skipped. "
        case .running: "Running. "
        case .note: ""
        }
    }
}

// Near square, like Broadsheet. The secondary form is a border, not a fill, because a fill built on
// Broadsheet's light only neutral ramp disappears in dark mode.
private struct PrimaryButton: ButtonStyle {
    var isProminent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: Broadsheet.TypeScale.uiLarge, weight: .medium))
            .foregroundStyle(isProminent ? Color.white : Broadsheet.Colors.text)
            .padding(.horizontal, Broadsheet.Space.x3)
            .padding(.vertical, Broadsheet.Space.x2)
            .background {
                let shape = RoundedRectangle(cornerRadius: Broadsheet.Radius.medium)
                if isProminent {
                    shape.fill(Broadsheet.Colors.accentText)
                } else {
                    shape.fill(Broadsheet.Colors.background)
                        .overlay(shape.stroke(Broadsheet.Colors.divider))
                }
            }
            // A button you cannot press has to look like one, whatever the appearance.
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}
