import Foundation
import OSLog

/// Runs grammar and punctuation checks over the paragraphs you have touched, while you keep typing.
///
/// It waits for a pause, checks only changed paragraphs, skips any paragraph this model and prompt
/// already judged, and anchors every suggestion to an exact character range. A suggestion whose
/// paragraph moves or changes is retired rather than applied at the wrong place. Everything it
/// proposes has already passed `SuggestionVerifier`.
@Observable final class SuggestionEngine {
    // Why the panel is quiet: still checking, ready, not running, or the model is missing.
    enum Availability: Equatable {
        case checking
        case ready(model: String)
        case notRunning(String)
        case modelMissing(String)
    }

    // AC-68. Room for a small model's cold start, and short enough that a silent server frees the slot.
    @ObservationIgnored var requestTimeout: TimeInterval = 45

    private(set) var availability: Availability = .checking
    private(set) var suggestions: [Suggestion] = []
    private(set) var isChecking = false
    private(set) var dropRate: Double = 0
    // The toolbar toggle: off stops checking and hides the panel, and the editor carries on.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { scheduleCheck(after: .zero) } else { cancel() }
        }
    }

    // Replaces a range only if it still holds the expected text; the editor supplies this so the
    // change goes through undo like any other edit.
    @ObservationIgnored var apply: ((NSRange, String, String) -> Bool)?

    @ObservationIgnored private let store: SuggestionStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let prompts: PromptLibrary
    @ObservationIgnored private let session: DocumentSession
    @ObservationIgnored private let makeClient: (URL) -> OllamaClient
    @ObservationIgnored private var checkedHashes: Set<String> = []
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var flight: Task<Void, Never>?

    init(
        session: DocumentSession, store: SuggestionStore, settings: SettingsStore,
        prompts: PromptLibrary = .shared, makeClient: @escaping (URL) -> OllamaClient = { OllamaClient(baseURL: $0) }
    ) {
        self.session = session
        self.store = store
        self.settings = settings
        self.prompts = prompts
        self.makeClient = makeClient
    }

    // MARK: Settings

    private var model: String {
        ((try? settings.string(forKey: SettingsKey.ollamaModel)) ?? nil) ?? OllamaClient.defaultModel
    }

    private var client: OllamaClient {
        let raw = ((try? settings.string(forKey: SettingsKey.ollamaURL)) ?? nil) ?? ""
        return makeClient(URL(string: raw).flatMap { $0.scheme == nil ? nil : $0 } ?? OllamaClient.defaultBaseURL)
    }

    private func flag(_ key: String) -> Bool {
        ((try? settings.string(forKey: key)) ?? nil) != "false"
    }

    private var delay: Duration {
        let seconds =
            ((try? settings.string(forKey: SettingsKey.aiCheckDelaySeconds)) ?? nil).flatMap(Double.init) ?? 1.5
        return .milliseconds(Int(max(seconds, 0.2) * 1000))
    }

    // MARK: Availability

    // AC-17. A quiet line with Retry; nothing here ever blocks the editor.
    func refreshAvailability() async {
        availability = .checking
        do {
            let installed = try await client.installedModels()
            let wanted = model
            let hasModel = installed.contains(wanted) || installed.contains("\(wanted):latest")
            availability = hasModel ? .ready(model: wanted) : .modelMissing(wanted)
        } catch {
            availability = .notRunning("Ollama isn't running.")
        }
    }

    func retry() {
        Task {
            await refreshAvailability()
            scheduleCheck(after: .zero)
        }
    }

    // MARK: The loop

    // AC-26. An edit that touches a shown suggestion makes it stale; everything after it shifts.
    func textEdited(range edited: NSRange, delta: Int) {
        let before = NSRange(location: edited.location, length: max(edited.length - delta, 0))
        var kept: [Suggestion] = []
        for var suggestion in suggestions {
            let touches =
                suggestion.range.location < before.upperBound && before.location < suggestion.range.upperBound
                || (before.length == 0 && before.location > suggestion.range.location
                    && before.location < suggestion.range.upperBound)
            if touches {
                resolve(suggestion, as: .stale)
                continue
            }
            if suggestion.range.location >= before.upperBound {
                suggestion.range.location += delta
            }
            kept.append(suggestion)
        }
        suggestions = kept
        scheduleCheck(after: delay)
    }

    // AC-18 and AC-20. The pause restarts on every edit, and an edit cancels the request in flight.
    func scheduleCheck(after wait: Duration) {
        debounce?.cancel()
        flight?.cancel()
        guard isEnabled else { return }
        debounce = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.flight = Task { await self.check() }
        }
    }

    private func cancel() {
        debounce?.cancel()
        flight?.cancel()
        isChecking = false
    }

    private func check() async {
        if case .ready = availability {} else { await refreshAvailability() }
        guard case .ready(let model) = availability, isEnabled else { return }

        let body = session.body
        let paragraphs = SuggestionContext.paragraphs(of: body)
        let prompt = prompts.grammar
        let budget = SuggestionContext.characterBudget(promptCharacters: prompt.text.count)

        isChecking = true
        defer { isChecking = false }

        for (index, paragraph) in paragraphs.enumerated() where !paragraph.isCode {
            guard !Task.isCancelled else { return }
            let hash = ContentHash.sha256(Data(paragraph.text.utf8))
            guard !checkedHashes.contains(hash) else { continue }

            // A paragraph this model and prompt already checked is never asked again.
            if (try? store.wasChecked(
                documentID: session.document.id, targetHash: hash, model: model, promptVersion: prompt.version)) == true
            {
                restore(hash: hash, paragraph: paragraph, body: body)
                checkedHashes.insert(hash)
                continue
            }

            let message = SuggestionContext.message(
                title: session.title, subtitle: session.subtitle, paragraphs: paragraphs, target: index, budget: budget)
            let started = ContinuousClock.now
            let reply: String
            do {
                reply = try await client.chat(
                    model: model,
                    messages: [.init(role: "system", content: prompt.text), .init(role: "user", content: message)],
                    format: SuggestionContext.schema, temperature: 0.1, timeout: requestTimeout)
            } catch is CancellationError {
                return
            } catch AIError.modelMissing(let missing) {
                availability = .modelMissing(missing)
                return
            } catch {
                availability = .notRunning(error.localizedDescription)
                Loggers.ai.notice("Suggestion request failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            let latency = Int((ContinuousClock.now - started) / .milliseconds(1))
            guard !Task.isCancelled else { return }

            accept(reply: reply, for: paragraph, hash: hash, model: model, prompt: prompt.version, latency: latency)
            checkedHashes.insert(hash)
        }
        dropRate = (try? store.dropRate(model: model, promptVersion: prompt.version)) ?? 0
    }

    // The gate, then the screen. Everything that arrives ends in a logged state.
    private func accept(
        reply: String, for paragraph: SuggestionContext.Paragraph, hash: String, model: String, prompt: String,
        latency: Int
    ) {
        let log = { (raw: RawSuggestion, outcome: SuggestionStore.Outcome) -> Int64? in
            try? self.store.record(
                AISuggestion(
                    documentId: self.session.document.id, kind: raw.kind, original: raw.original,
                    replacement: raw.replacement, reason: raw.reason, model: model, promptVersion: prompt,
                    latencyMs: latency, outcome: outcome.rawValue, createdAt: Date(), targetHash: hash))
        }
        _ = log(RawSuggestion(kind: SuggestionStore.checkMarker, original: "", replacement: "", reason: ""), .shown)

        guard let proposals = SuggestionVerifier.parse(reply) else {
            Loggers.ai.notice("Dropped a whole response that was not the expected JSON")
            _ = log(RawSuggestion(kind: "unparsed", original: "", replacement: "", reason: ""), .dropped)
            return
        }

        // AC-26. If the paragraph moved while the request was out, nothing from it applies.
        let live = session.body as NSString
        guard paragraph.range.upperBound <= live.length, live.substring(with: paragraph.range) == paragraph.text else {
            for proposal in proposals { _ = log(proposal, .stale) }
            return
        }

        let code = MarkdownRenderer.parse(session.body).codeRanges
        var shown = suggestions.map(\.range)
        for raw in proposals {
            if (try? store.isDismissed(documentID: session.document.id, targetHash: hash, original: raw.original))
                == true
            {
                continue
            }
            switch SuggestionVerifier.verify(
                raw, paragraph: paragraph.text, paragraphStart: paragraph.range.location, code: code, shown: shown)
            {
            case .dropped(let reason):
                Loggers.ai.info("Dropped a suggestion: \(reason.rawValue, privacy: .public)")
                _ = log(raw, .dropped)
            case .shown(let kind, let range):
                let enabled =
                    kind == .punctuation ? flag(SettingsKey.aiPunctuationEnabled) : flag(SettingsKey.aiGrammarEnabled)
                guard enabled else { continue }
                shown.append(range)
                let row = log(raw, .shown)
                suggestions.append(
                    Suggestion(
                        id: UUID(), rowID: row, kind: kind, original: raw.original, replacement: raw.replacement,
                        reason: raw.reason, range: range, targetHash: hash))
            }
        }
        suggestions.sort { $0.range.location < $1.range.location }
    }

    // A cache hit brings back what was still waiting, re verified against the text as it is now.
    private func restore(hash: String, paragraph: SuggestionContext.Paragraph, body: String) {
        guard
            let rows = try? store.pending(
                documentID: session.document.id, targetHash: hash, model: model, promptVersion: prompts.grammar.version)
        else { return }
        let code = MarkdownRenderer.parse(body).codeRanges
        var shown = suggestions.map(\.range)
        for row in rows {
            let raw = RawSuggestion(
                kind: row.kind, original: row.original, replacement: row.replacement, reason: row.reason)
            guard
                case .shown(let kind, let range) = SuggestionVerifier.verify(
                    raw, paragraph: paragraph.text, paragraphStart: paragraph.range.location, code: code, shown: shown)
            else { continue }
            shown.append(range)
            suggestions.append(
                Suggestion(
                    id: UUID(), rowID: row.id, kind: kind, original: row.original, replacement: row.replacement,
                    reason: row.reason, range: range, targetHash: hash))
        }
        suggestions.sort { $0.range.location < $1.range.location }
    }

    // MARK: Acting

    // AC-29. Exactly the anchored range, and only if it still holds what was suggested against.
    func accept(_ suggestion: Suggestion) {
        suggestions.removeAll { $0.id == suggestion.id }
        let applied = apply?(suggestion.range, suggestion.original, suggestion.replacement) ?? false
        resolve(suggestion, as: applied ? .accepted : .stale)
    }

    // AC-31.
    func dismiss(_ suggestion: Suggestion) {
        suggestions.removeAll { $0.id == suggestion.id }
        resolve(suggestion, as: .dismissed)
    }

    // AC-30. Highest offset first, so each replacement leaves the ranges still to come untouched,
    // and each is checked against the live text just before it is applied. Returns what was skipped.
    @discardableResult
    func acceptAllPunctuation() -> Int {
        let batch = suggestions.filter { $0.kind == .punctuation }.sorted { $0.range.location > $1.range.location }
        let ids = Set(batch.map(\.id))
        suggestions.removeAll { ids.contains($0.id) }

        var skipped = 0
        for suggestion in batch {
            let applied = apply?(suggestion.range, suggestion.original, suggestion.replacement) ?? false
            resolve(suggestion, as: applied ? .accepted : .stale)
            if !applied { skipped += 1 }
        }
        return skipped
    }

    private func resolve(_ suggestion: Suggestion, as outcome: SuggestionStore.Outcome) {
        guard let id = suggestion.rowID else { return }
        try? store.resolve(id: id, as: outcome)
    }

    // MARK: Rewrites

    // AC-32. Two or three other ways to say the selected sentence, at a warmer temperature.
    func rewrites(of range: NSRange) async throws -> [String] {
        let body = session.body as NSString
        guard range.length > 0, range.upperBound <= body.length else { return [] }
        let sentence = body.substring(with: range)

        let paragraphs = SuggestionContext.paragraphs(of: session.body)
        let context = paragraphs.filter { !$0.isCode }.map(\.masked).joined(separator: "\n\n")
        let message = """
            <context>
            Title: \(session.title)
            Subtitle: \(session.subtitle)

            \(context)
            </context>

            <target>
            \(sentence)
            </target>
            """

        struct Envelope: Decodable { let alternatives: [String] }
        let reply = try await client.chat(
            model: model,
            messages: [.init(role: "system", content: prompts.rewrite.text), .init(role: "user", content: message)],
            format: SuggestionContext.rewriteSchema, temperature: 0.5, timeout: requestTimeout)
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(reply.utf8)) else {
            throw AIError.unreadableResponse
        }

        var seen: Set<String> = [sentence.trimmingCharacters(in: .whitespacesAndNewlines)]
        return envelope.alternatives
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(3)
            .map { $0 }
    }
}
