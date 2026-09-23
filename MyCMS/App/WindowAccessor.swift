import AppKit
import SwiftUI

// AppKit restores window geometry itself, so this only hands it a name to autosave under.
// NavigationSplitView already autosaves its column widths through the same AppKit mechanism.
struct WindowFrameAutosave: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.setFrameAutosaveName(name)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    func windowFrameAutosave(_ name: String) -> some View {
        background(WindowFrameAutosave(name: name).frame(width: 0, height: 0))
    }
}
