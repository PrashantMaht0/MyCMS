import AppKit
import SwiftUI
import Testing

@testable import MyCMS

@Suite("History panel")
@MainActor
struct HistoryPanelTests {
    private func tables(in view: NSView) -> [NSTableView] {
        (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
    }

    @Test("Clicking a version keeps it selected, so its diff and Restore appear, per AC-51")
    func clickSelects() async throws {
        let database = try MyCMS.Database.inMemory()
        let documents = DocumentStore(database: database)
        let revisions = RevisionStore(database: database)
        let document = try documents.create(collection: .blog)
        let session = DocumentSession(document: document, store: documents, revisions: revisions)
        session.body = "Current words."
        try revisions.snapshot(document, body: "Older words.", reason: .autosave)
        try revisions.snapshot(document, body: "Oldest words.", reason: .publish, at: Date().addingTimeInterval(-60))

        let host = NSHostingView(rootView: HistoryPanel(session: session, revisions: revisions))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 600), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }

        let before = host.fittingSize.height
        let table = try #require(tables(in: host).first)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)) }
        host.layoutSubtreeIfNeeded()

        // A real selection adds the diff and Restore below the list. With an optional tag the click
        // reached SwiftUI as nil, nothing was selected, and the panel never grew.
        #expect(host.fittingSize.height > before)
    }
}
