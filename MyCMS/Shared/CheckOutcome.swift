import Foundation

// The last result of one launch check, kept in settings so a relaunch can show it without rerunning.
nonisolated struct CheckOutcome: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case ok
        case failed
        case skipped
    }

    var outcome: Outcome
    var detail: String
    var at: Date

    static func ok(_ detail: String, at: Date = Date()) -> CheckOutcome {
        CheckOutcome(outcome: .ok, detail: detail, at: at)
    }

    static func failed(_ detail: String, at: Date = Date()) -> CheckOutcome {
        CheckOutcome(outcome: .failed, detail: detail, at: at)
    }

    static func skipped(_ detail: String, at: Date = Date()) -> CheckOutcome {
        CheckOutcome(outcome: .skipped, detail: detail, at: at)
    }
}
