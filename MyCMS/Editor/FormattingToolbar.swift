import SwiftUI

// AC-6 to AC-8. The kept half of the Substack toolbar from Notes 5.1, and nothing else.
// There is no video control, because a project video is the videoUrl field on the collection.
struct FormattingToolbar: View {
    let controller: EditorTextController
    // The toolbar AI toggle: off stops checking and hides the suggestion panel.
    var aiEnabled: Binding<Bool>?

    var body: some View {
        tools
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) { aiToggle }
            .font(Broadsheet.serif(Broadsheet.TypeScale.uiLarge))
            .foregroundStyle(Broadsheet.Colors.text)
            .padding(.horizontal, Broadsheet.Space.x6)
            .padding(.top, Broadsheet.Space.x1)
            // Room between the tools and the rule under them.
            .padding(.bottom, Broadsheet.Space.x3)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Formatting")
    }

    private var tools: some View {
        HStack(spacing: Broadsheet.Space.x1) {
            ToolbarButton("arrow.uturn.backward", label: "Undo", enabled: controller.canUndo) {
                controller.undo()
            }
            ToolbarButton("arrow.uturn.forward", label: "Redo", enabled: controller.canRedo) {
                controller.redo()
            }

            separator
            stylePicker
            separator

            ToolbarButton("bold", label: "Bold", shortcut: "b") { controller.toggleBold() }
            ToolbarButton("italic", label: "Italic", shortcut: "i") { controller.toggleItalic() }
            ToolbarButton("strikethrough", label: "Strikethrough") { controller.toggleStrikethrough() }
            ToolbarButton("chevron.left.forwardslash.chevron.right", label: "Inline code") {
                controller.toggleInlineCode()
            }

            separator

            ToolbarButton("link", label: "Link", shortcut: "k") { controller.insertLink() }
            ToolbarButton("photo", label: "Image") { controller.insertImage() }
            ToolbarButton("text.quote", label: "Quote") { controller.toggleQuote() }
            ToolbarButton("list.bullet", label: "Bullet list") { controller.toggleBulletList() }
            ToolbarButton("list.number", label: "Numbered list") { controller.toggleNumberedList() }

            separator
            moreMenu
        }
    }

    @ViewBuilder private var aiToggle: some View {
        if let aiEnabled {
            Toggle(isOn: aiEnabled) {
                Image(systemName: "sparkles")
            }
            .toggleStyle(.button)
            .help("Grammar and punctuation suggestions")
            .accessibilityLabel("AI suggestions")
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Broadsheet.Colors.divider)
            .frame(width: 1, height: Broadsheet.Space.x3)
            .padding(.horizontal, Broadsheet.Space.x1)
            .accessibilityHidden(true)
    }

    // AC-7. Reflects what the caret is inside, and sets the paragraph when you pick from it.
    private var stylePicker: some View {
        Picker(
            "Style",
            selection: Binding(
                get: { controller.blockStyle },
                set: { controller.setBlockStyle($0) })
        ) {
            ForEach(EditorTextController.BlockStyle.allCases) { style in
                Text(style.label).tag(style)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 130)
        .accessibilityLabel("Paragraph style")
    }

    private var moreMenu: some View {
        Menu {
            Button("Divider") { controller.insertDivider() }
            Button("Code block") { controller.insertCodeBlock() }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: Broadsheet.Space.x6)
        .help("More")
        .accessibilityLabel("More formatting")
    }
}

private struct ToolbarButton: View {
    private let symbol: String
    private let label: String
    private let shortcut: KeyEquivalent?
    private let enabled: Bool
    private let action: () -> Void

    init(
        _ symbol: String,
        label: String,
        shortcut: KeyEquivalent? = nil,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.label = label
        self.shortcut = shortcut
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: Broadsheet.Space.x4, height: Broadsheet.Space.x4)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(label)
        .accessibilityLabel(label)
        .modifier(OptionalShortcut(key: shortcut))
    }
}

// keyboardShortcut has no optional form, so the modifier is applied only when there is one.
private struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: .command)
        } else {
            content
        }
    }
}
