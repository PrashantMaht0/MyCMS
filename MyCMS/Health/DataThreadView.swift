// observeList hands back GRDB's own async sequence, so the consumer imports GRDB to iterate it.
import GRDB
import SwiftUI

// Scaffold. It proves a document can be created, observed and drawn end to end.
// Delete this file once features 4 and 5 provide the real library and editor.
struct DataThreadView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model = DataThreadModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Documents")
                    .font(.headline)
                Spacer()
                Button("New draft") {
                    model.create(environment.documents)
                }
            }

            if let errorText = model.errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else if model.items.isEmpty {
                Text("No documents yet. The list below updates itself when one is written.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.items) { item in
                    HStack(spacing: 8) {
                        Text(item.title.isEmpty ? "Untitled" : item.title)
                        Text(item.collection.rawValue)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(item.state.rawValue)
                            .foregroundStyle(.secondary)
                        Button("Delete") {
                            model.delete(item.id, environment.documents)
                        }
                        .buttonStyle(.link)
                    }
                    .font(.callout)
                }
            }
        }
        .task {
            await model.start(environment.documents)
        }
    }
}

// The store delivers on the main queue, and this is the main actor hop it leaves to the consumer.
@MainActor @Observable final class DataThreadModel {
    private(set) var items: [DocumentListItem] = []
    private(set) var errorText: String?
    private var started = false

    func start(_ documents: DocumentStore) async {
        guard !started else { return }
        started = true

        do {
            for try await items in try documents.observeList() {
                self.items = items
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    // No refresh call. The observation above picks the write up on its own.
    func create(_ documents: DocumentStore) {
        do {
            _ = try documents.create(collection: .blog)
        } catch {
            errorText = error.localizedDescription
        }
    }

    func delete(_ id: UUID, _ documents: DocumentStore) {
        do {
            try documents.delete(id: id)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
