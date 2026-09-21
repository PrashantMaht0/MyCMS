import AppKit
import OSLog

// AC-1 to AC-5. Draws the Markdown without ever changing it: attributes only, bounded by the
// viewport, with a fresh parse only once typing pauses.
final class MarkdownStyler: NSObject, NSTextStorageDelegate {
    // Short enough that a heading styles as you finish typing it, long enough that a burst of
    // keystrokes restyles the last tree rather than re parsing per character.
    static let parsePause: Duration = .milliseconds(150)

    // Styling reaches this far either side of the viewport, so an ordinary scroll lands on style.
    private static let overscan = 2000

    var showMarkers: Bool {
        didSet {
            guard showMarkers != oldValue else { return }
            styleSheet = MarkdownStyleSheet(fontSize: fontSize, showMarkers: showMarkers)
            restyle()
        }
    }

    var fontSize: CGFloat {
        didSet {
            guard fontSize != oldValue else { return }
            styleSheet = MarkdownStyleSheet(fontSize: fontSize, showMarkers: showMarkers)
            restyle()
        }
    }

    private(set) var structure = MarkdownRenderer.parse("")

    // Every change to the characters, for the suggestion engine to shift or retire its anchors.
    var onEdit: ((NSRange, Int) -> Void)?

    private weak var textView: MarkdownEditorTextView?
    private var styleSheet: MarkdownStyleSheet
    private var parseTask: Task<Void, Never>?
    private var restyleScheduled = false
    private var spellingSweepScheduled = false
    // Set while this object is the one editing attributes, so its own edits are not mistaken for
    // the spell checker's or for a keystroke.
    private var isAdjusting = false

    init(fontSize: CGFloat, showMarkers: Bool) {
        self.fontSize = fontSize
        self.showMarkers = showMarkers
        self.styleSheet = MarkdownStyleSheet(fontSize: fontSize, showMarkers: showMarkers)
        super.init()
    }

    func attach(to textView: MarkdownEditorTextView, in scrollView: NSScrollView) {
        self.textView = textView
        textView.textStorage?.delegate = self
        textView.typingAttributes = styleSheet.baseAttributes

        // AC-4. Scrolling brings new text into the viewport, so it has to be styled then too.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewportMoved),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)

        reparse()
    }

    @objc private func viewportMoved() {
        scheduleRestyle()
    }

    // Called when the whole string was replaced from outside, where shifting would mean nothing.
    func textReplaced() {
        parseTask?.cancel()
        reparse()
    }

    // MARK: The text changing

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard !isAdjusting else { return }

        if editedMask.contains(.editedCharacters) {
            // AC-4. The last good tree is moved to match the edit, then restyled, while the
            // parse waits for the pause.
            structure = structure.shifted(after: editedRange.location, by: delta)
            scheduleParse()
            scheduleRestyle()
            // Deferred, because observers must not change state while the storage is mid edit.
            if let onEdit {
                Task { @MainActor in onEdit(editedRange, delta) }
            }
        } else if editedMask.contains(.editedAttributes) {
            scheduleSpellingSweep()
        }
    }

    private func scheduleParse() {
        parseTask?.cancel()
        parseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.parsePause)
            guard !Task.isCancelled else { return }
            self?.reparse()
        }
    }

    private func reparse() {
        guard let textView else { return }
        structure = MarkdownRenderer.parse(textView.string)
        restyle()
    }

    // MARK: Drawing

    private func scheduleRestyle() {
        guard !restyleScheduled else { return }
        restyleScheduled = true

        Task { @MainActor [weak self] in
            self?.restyleScheduled = false
            self?.restyle()
        }
    }

    func restyle() {
        guard let textView, let storage = textView.textStorage, storage.length > 0 else { return }
        let window = styleWindow(textView, length: storage.length)
        guard window.length > 0 else { return }

        isAdjusting = true
        storage.beginEditing()
        for segment in segments(in: window) {
            storage.setAttributes(segment.attributes, range: segment.range)
        }
        storage.endEditing()
        isAdjusting = false

        textView.quoteRanges = structure.runs(in: window)
            .filter { $0.style == .blockQuote }
            .map(\.range)
        textView.typingAttributes = styleSheet.baseAttributes

        sweepSpelling(in: window)
    }

    private struct Segment {
        let range: NSRange
        let attributes: [NSAttributedString.Key: Any]
    }

    // Every run boundary in the window becomes a cut, so each stretch is set once with the
    // combined attributes of everything covering it.
    private func segments(in window: NSRange) -> [Segment] {
        let runs = structure.runs(in: window)
        guard !runs.isEmpty else { return [Segment(range: window, attributes: styleSheet.baseAttributes)] }

        var cuts: Set<Int> = [window.location, window.upperBound]
        for run in runs {
            cuts.insert(run.range.location)
            cuts.insert(run.range.upperBound)
        }

        let ordered = cuts.sorted()
        var built: [Segment] = []

        for (start, end) in zip(ordered, ordered.dropFirst()) where end > start {
            let covering = runs.filter { $0.range.location <= start && $0.range.upperBound >= end }
            built.append(
                Segment(
                    range: NSRange(location: start, length: end - start),
                    attributes: styleSheet.attributes(for: covering.map(\.style))))
        }
        return built
    }

    // AC-4. The viewport plus a margin, widened to whole lines so no paragraph is styled by halves.
    private func styleWindow(_ textView: NSTextView, length: Int) -> NSRange {
        var start = 0
        var end = length

        if let layoutManager = textView.textLayoutManager,
            let contentManager = layoutManager.textContentManager,
            let viewport = layoutManager.textViewportLayoutController.viewportRange {
            let origin = contentManager.documentRange.location
            start = contentManager.offset(from: origin, to: viewport.location)
            end = contentManager.offset(from: origin, to: viewport.endLocation)
        }

        start = max(0, min(max(start, 0), length) - Self.overscan)
        end = min(length, max(min(end, length), 0) + Self.overscan)
        guard end > start else { return NSRange(location: 0, length: 0) }

        return (textView.string as NSString).lineRange(for: NSRange(location: start, length: end - start))
    }

    // MARK: Spell checking

    private func scheduleSpellingSweep() {
        guard !spellingSweepScheduled else { return }
        spellingSweepScheduled = true

        Task { @MainActor [weak self] in
            self?.spellingSweepScheduled = false
            guard let self, let textView = self.textView, let storage = textView.textStorage else { return }
            self.sweepSpelling(in: self.styleWindow(textView, length: storage.length))
        }
    }

    // AC-5. The system checker still runs, it just stops marking anything inside code.
    private func sweepSpelling(in window: NSRange) {
        guard let textView, !structure.codeRanges.isEmpty, window.length > 0 else { return }

        isAdjusting = true
        for code in structure.codeRanges {
            guard let overlap = code.intersection(window), overlap.length > 0 else { continue }
            textView.setSpellingState(0, range: overlap)
        }
        isAdjusting = false
    }
}
