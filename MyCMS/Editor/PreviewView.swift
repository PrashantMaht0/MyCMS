import SwiftUI

// AC-14 and AC-15. The post as your site draws it, at a desktop or a phone width.
struct PreviewView: View {
    let model: PreviewModel
    let document: Document
    let markdown: String

    @State private var width: PreviewModel.Width = .desktop
    @State private var stylesheet: String?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Width", selection: $width) {
                    ForEach(PreviewModel.Width.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .accessibilityLabel("Preview width")

                if loaded, stylesheet == nil {
                    Text("Your site's stylesheet was unavailable, so this uses a plain built in style.")
                        .font(Broadsheet.serif(Broadsheet.TypeScale.uiLarge))
                        .foregroundStyle(Broadsheet.Colors.accentText)
                }
                Spacer()
            }
            .padding(.horizontal, Broadsheet.Space.x4)
            .padding(.vertical, Broadsheet.Space.x1)

            Divider()

            MarkdownWebView(html: model.page(for: document, body: markdown, stylesheet: stylesheet))
                .frame(width: width.points)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            stylesheet = model.siteStylesheet()
            loaded = true
        }
    }
}
