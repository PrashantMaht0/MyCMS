import AppKit
import SwiftUI

// AC-17 and AC-28. The quiet status line with Retry, then the verified suggestions grouped by kind,
// each with Accept and Dismiss, and an empty state when there is nothing to fix.
struct SuggestionPanel: View {
    let engine: SuggestionEngine
    let onSelect: (NSRange) -> Void

    @State private var skippedNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x3) {
            status
            Divider()

            if engine.suggestions.isEmpty {
                if case .ready = engine.availability, !engine.isChecking {
                    Text("Looks good.")
                        .foregroundStyle(Broadsheet.Colors.secondaryText)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Broadsheet.Space.x4) {
                        group(.punctuation, title: "Punctuation")
                        group(.grammar, title: "Grammar")
                    }
                }
            }

            if let skippedNote {
                Text(skippedNote).foregroundStyle(Broadsheet.Colors.secondaryText)
            }

            Spacer(minLength: 0)

            if engine.dropRate > 0 {
                Text("\(Int((engine.dropRate * 100).rounded()))% of this model's proposals were dropped by the checks.")
                    .font(Broadsheet.serif(Broadsheet.TypeScale.uiSmall))
                    .foregroundStyle(Broadsheet.Colors.secondaryText)
            }
        }
        .padding(Broadsheet.Space.x3)
        .frame(width: 280)
        .frame(maxHeight: .infinity, alignment: .top)
        .font(Broadsheet.serif(Broadsheet.TypeScale.uiLarge))
        .background(Broadsheet.Colors.surface.opacity(0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggestions")
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: Broadsheet.Space.x1) {
            switch engine.availability {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Looking for Ollama")
            case .ready(let model):
                Circle().fill(.green).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(engine.isChecking ? "Checking with \(model)" : model)
                if engine.isChecking { ProgressView().controlSize(.small) }
            case .notRunning(let reason):
                Text(reason).foregroundStyle(Broadsheet.Colors.secondaryText)
                retry
            case .modelMissing(let model):
                Text("Model \(model) not installed").foregroundStyle(Broadsheet.Colors.secondaryText)
                retry
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var retry: some View {
        Button("Retry") { engine.retry() }.buttonStyle(.link)
    }

    @ViewBuilder private func group(_ kind: Suggestion.Kind, title: String) -> some View {
        let items = engine.suggestions.filter { $0.kind == kind }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Broadsheet.Space.x2) {
                HStack {
                    Text("\(title) \(items.count)").font(Broadsheet.serif(Broadsheet.TypeScale.uiLarge, weight: .semibold))
                    Spacer()
                    if kind == .punctuation {
                        Button("Accept all") {
                            let skipped = engine.acceptAllPunctuation()
                            skippedNote = skipped == 0 ? nil : "\(skipped) no longer matched the text and were skipped."
                        }
                        .buttonStyle(.link)
                        .accessibilityLabel("Accept all punctuation")
                    }
                }
                ForEach(items) { item in
                    SuggestionRow(suggestion: item, onSelect: { onSelect(item.range) },
                                  onAccept: { engine.accept(item) }, onDismiss: { engine.dismiss(item) })
                }
            }
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: Suggestion
    let onSelect: () -> Void
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x1) {
            Button(action: onSelect) {
                (Text(suggestion.original).strikethrough().foregroundStyle(Broadsheet.Colors.secondaryText)
                    + Text("  ") + Text(suggestion.replacement).foregroundStyle(Broadsheet.Colors.text))
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .help("Show it in the text")
            .accessibilityLabel("Change \(suggestion.original) to \(suggestion.replacement)")

            Text(suggestion.reason)
                .font(Broadsheet.serif(Broadsheet.TypeScale.uiSmall))
                .foregroundStyle(Broadsheet.Colors.secondaryText)

            HStack {
                Button("Accept", action: onAccept)
                Button("Dismiss", action: onDismiss)
            }
            .controlSize(.small)
        }
        .padding(Broadsheet.Space.x2)
        .background(Broadsheet.Colors.background, in: .rect(cornerRadius: Broadsheet.Radius.medium))
    }
}

// AC-32. Alternatives for one sentence, shown in a popover under it.
@Observable final class RewriteRequest {
    enum State {
        case loading
        case ready([String])
        case failed(String)
    }

    let range: NSRange
    let original: String
    var state: State = .loading

    init(range: NSRange, original: String) {
        self.range = range
        self.original = original
    }
}

struct RewritePopover: View {
    let request: RewriteRequest
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Broadsheet.Space.x2) {
            Text("This sentence can be written this way:")
                .font(Broadsheet.serif(Broadsheet.TypeScale.uiLarge, weight: .semibold))
            switch request.state {
            case .loading:
                ProgressView().controlSize(.small)
            case .ready(let options) where options.isEmpty:
                Text("The model had nothing different to offer.").foregroundStyle(Broadsheet.Colors.secondaryText)
            case .ready(let options):
                ForEach(options, id: \.self) { option in
                    Button { onPick(option) } label: {
                        Text(option).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            case .failed(let message):
                Text(message).foregroundStyle(Broadsheet.Colors.secondaryText)
            }
        }
        .padding(Broadsheet.Space.x3)
        .frame(width: 380)
        .font(Broadsheet.serif(Broadsheet.TypeScale.body))
    }
}
