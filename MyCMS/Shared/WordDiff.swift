import Foundation

// AC-51. What changed between two texts, in words rather than characters, so a one word edit reads
// as one word and not as a rewritten paragraph.
nonisolated enum WordDiff {
    // One stretch of the diff: kept, added, or taken away.
    enum Run: Equatable, Sendable {
        case same(String)
        case inserted(String)
        case removed(String)
    }

    // Words keep their punctuation and the whitespace after them, so joining the runs back gives
    // the text exactly.
    static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inSpace = false
        for character in text {
            if character.isWhitespace {
                inSpace = true
                current.append(character)
            } else {
                if inSpace {
                    result.append(current)
                    current = ""
                    inSpace = false
                }
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    // From the old text to the new one, merged into runs of the same kind.
    static func diff(from old: String, to new: String) -> [Run] {
        let before = words(old)
        let after = words(new)
        // Compared without trailing whitespace, so a word that only moved to a new line is unchanged.
        let difference = after.map(trimmed).difference(from: before.map(trimmed))

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var runs: [Run] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < before.count || newIndex < after.count {
            if oldIndex < before.count, removed.contains(oldIndex) {
                append(.removed(before[oldIndex]), to: &runs)
                oldIndex += 1
            } else if newIndex < after.count, inserted.contains(newIndex) {
                append(.inserted(after[newIndex]), to: &runs)
                newIndex += 1
            } else {
                if newIndex < after.count { append(.same(after[newIndex]), to: &runs) }
                oldIndex += 1
                newIndex += 1
            }
        }
        return runs
    }

    private static func trimmed(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func append(_ run: Run, to runs: inout [Run]) {
        switch (runs.last, run) {
        case (.same(let a)?, .same(let b)): runs[runs.count - 1] = .same(a + b)
        case (.inserted(let a)?, .inserted(let b)): runs[runs.count - 1] = .inserted(a + b)
        case (.removed(let a)?, .removed(let b)): runs[runs.count - 1] = .removed(a + b)
        default: runs.append(run)
        }
    }
}
