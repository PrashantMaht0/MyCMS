import Foundation
import GRDB
import SwiftUI

// The library list and everything that narrows it.
// Observes unfiltered on purpose: a narrowed observation could not count the other filters.
@MainActor @Observable final class LibraryModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all, drafts, published, changedOutside
        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: "All"
            case .drafts: "Drafts"
            case .published: "Published"
            case .changedOutside: "Changed outside CMS"
            }
        }

        var shortcut: KeyEquivalent {
            switch self {
            case .all: "1"
            case .drafts: "2"
            case .published: "3"
            case .changedOutside: "4"
            }
        }

        // Changed outside is not a stored state, it is what the last repo scan found, so every
        // filter is answered here rather than by comparing a column.
        func matches(_ item: DocumentListItem, changedOutside: Set<UUID>) -> Bool {
            switch self {
            case .all: true
            case .drafts: item.state == .draft
            case .published: item.state == .published
            case .changedOutside: changedOutside.contains(item.id)
            }
        }
    }

    private(set) var allDocuments: [DocumentListItem] = []
    // Ids the last repo scan found differing from what the app wrote. Derived, never stored.
    var changedOutside: Set<UUID> = []
    private(set) var searchResults: [DocumentListItem]?
    private(set) var errorText: String?

    var collection: Document.Collection = .blog { didSet { persist() } }
    var filter: Filter = .all { didSet { persist() } }
    var selectedID: UUID? { didSet { persist() } }
    var query: String = "" { didSet { scheduleSearch() } }

    private let store: DocumentStore
    private let defaults: UserDefaults
    private var observationTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private let searchDelay: Duration

    init(store: DocumentStore, defaults: UserDefaults = .standard, searchDelay: Duration = .milliseconds(150)) {
        self.store = store
        self.defaults = defaults
        self.searchDelay = searchDelay
        restore()
    }

    // The visible list: the observed rows, narrowed by scope, or the search results narrowed the same way.
    var visibleDocuments: [DocumentListItem] {
        narrow(searchResults ?? allDocuments)
    }

    func count(for filter: Filter, in collection: Document.Collection) -> Int {
        allDocuments.filter {
            $0.collection == collection && filter.matches($0, changedOutside: changedOutside)
        }.count
    }

    func isChangedOutside(_ id: UUID) -> Bool { changedOutside.contains(id) }

    private func narrow(_ items: [DocumentListItem]) -> [DocumentListItem] {
        items.filter {
            $0.collection == collection && filter.matches($0, changedOutside: changedOutside)
        }
    }

    func start() {
        guard observationTask == nil else { return }
        observationTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await items in try store.observeList() {
                    self.allDocuments = items
                    self.dropSelectionIfGone()
                }
            } catch {
                self.errorText = error.localizedDescription
            }
        }
    }

    func dismissError() {
        errorText = nil
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    // A document deleted elsewhere must not stay selected.
    private func dropSelectionIfGone() {
        guard let selectedID, !allDocuments.contains(where: { $0.id == selectedID }) else { return }
        self.selectedID = nil
    }

    func contains(_ id: UUID) -> Bool {
        allDocuments.contains { $0.id == id }
    }

    func create() -> Document? {
        do {
            let document = try store.create(collection: collection)
            selectedID = document.id
            return document
        } catch {
            errorText = error.localizedDescription
            return nil
        }
    }

    func document(id: UUID) -> Document? {
        try? store.fetch(id: id)
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            searchResults = nil
            return
        }

        searchTask = Task { [searchDelay, store] in
            try? await Task.sleep(for: searchDelay)
            guard !Task.isCancelled else { return }
            let found = (try? store.search(text)) ?? []
            guard !Task.isCancelled else { return }
            self.searchResults = found
        }
    }

    // MARK: Restoring where you were

    private enum Key {
        static let collection = "library.collection"
        static let filter = "library.filter"
        static let selected = "library.selectedDocumentID"
    }

    // Every value is read before any is assigned. Assigning one fires persist(), which writes all
    // three, so reading them one at a time would overwrite the later keys before they were read.
    private func restore() {
        let storedCollection = defaults.string(forKey: Key.collection)
            .flatMap(Document.Collection.init(rawValue:))
        let storedFilter = defaults.string(forKey: Key.filter)
            .flatMap(Filter.init(rawValue:))
        let storedSelection = defaults.string(forKey: Key.selected)
            .flatMap(UUID.init(uuidString:))

        if let storedCollection { collection = storedCollection }
        if let storedFilter { filter = storedFilter }
        if let storedSelection { selectedID = storedSelection }
    }

    private func persist() {
        defaults.set(collection.rawValue, forKey: Key.collection)
        defaults.set(filter.rawValue, forKey: Key.filter)
        if let selectedID {
            defaults.set(selectedID.uuidString, forKey: Key.selected)
        } else {
            defaults.removeObject(forKey: Key.selected)
        }
    }
}
