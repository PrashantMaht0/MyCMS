import AppKit
import SwiftUI

// AppKit already restores a window's size and position correctly, so this hands it the name
// to autosave under rather than reimplementing geometry in UserDefaults.
// The split view needs no equivalent: SwiftUI's NavigationSplitView autosaves its own column
// widths under "SidebarNavigationSplitView", which is the same AppKit mechanism.
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
