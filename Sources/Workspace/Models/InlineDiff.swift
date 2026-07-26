import Foundation

/// Word-level differences between the two halves of a changed line.
///
/// A line that was edited usually differs in only a few tokens. Painting the
/// whole line one colour hides that, so the parser asks for the ranges that
/// actually changed and the diff view paints those a shade stronger.
enum InlineDiff {
    /// The changed ranges on each side, as offsets in `Character`s — which is
    /// what the view walks when it applies them to the highlighted line.
    static func ranges(old: String, new: String) -> (old: [Range<Int>], new: [Range<Int>]) {
        guard old != new, !old.isEmpty, !new.isEmpty else { return ([], []) }

        let oldTokens = tokenize(old)
        let newTokens = tokenize(new)
        var oldChanged = [Bool](repeating: false, count: oldTokens.count)
        var newChanged = [Bool](repeating: false, count: newTokens.count)

        // Trim the matching head and tail first. Most edits sit in the middle of
        // an otherwise identical line, and this leaves the quadratic pass below
        // a far smaller problem — usually nothing at all.
        var head = 0
        while head < oldTokens.count, head < newTokens.count,
              oldTokens[head].text == newTokens[head].text {
            head += 1
        }
        var tail = 0
        while tail < oldTokens.count - head, tail < newTokens.count - head,
              oldTokens[oldTokens.count - 1 - tail].text == newTokens[newTokens.count - 1 - tail].text {
            tail += 1
        }

        let oldMiddle = head..<(oldTokens.count - tail)
        let newMiddle = head..<(newTokens.count - tail)

        if oldMiddle.count * newMiddle.count <= maxCells {
            markDifferences(
                old: oldTokens, oldMiddle, changed: &oldChanged,
                new: newTokens, newMiddle, changed: &newChanged
            )
        } else {
            // A pathologically long pair of lines: the head/tail match is all
            // the detail worth the time.
            for index in oldMiddle { oldChanged[index] = true }
            for index in newMiddle { newChanged[index] = true }
        }

        let oldRanges = merge(oldTokens, changed: oldChanged)
        let newRanges = merge(newTokens, changed: newChanged)

        // When nearly all of both lines changed there is no "the rest of the
        // line" left to contrast against, and a second shade over the whole row
        // just reads as noise. The plain line colour says it better.
        if coverage(oldRanges, of: old) > 0.85, coverage(newRanges, of: new) > 0.85 {
            return ([], [])
        }
        return (oldRanges, newRanges)
    }

    /// Ceiling on the size of the LCS table, so one enormous line can't stall
    /// the parse of a whole pull request.
    private static let maxCells = 40_000

    // MARK: - Tokens

    private struct Token {
        var text: Substring
        /// Character offsets into the line the token came from.
        var start: Int
        var end: Int
    }

    private enum Kind { case word, space, symbol }

    /// Splits a line into identifier-ish words, runs of whitespace, and single
    /// symbols. Diffing whole tokens rather than characters is what keeps the
    /// result readable: an edited name lights up as a name, not as the three
    /// letters inside it that happen to differ.
    private static func tokenize(_ line: String) -> [Token] {
        var tokens: [Token] = []
        var index = line.startIndex
        var offset = 0
        while index < line.endIndex {
            let start = index
            let startOffset = offset
            let kind = classify(line[index])
            repeat {
                index = line.index(after: index)
                offset += 1
            } while index < line.endIndex && kind != .symbol && classify(line[index]) == kind
            tokens.append(Token(text: line[start..<index], start: startOffset, end: offset))
        }
        return tokens
    }

    private static func classify(_ character: Character) -> Kind {
        if character.isWhitespace { return .space }
        if character.isLetter || character.isNumber || character == "_" { return .word }
        return .symbol
    }

    // MARK: - Matching

    /// Longest common subsequence over the two middles; whatever it can't pair
    /// up is what changed.
    private static func markDifferences(
        old: [Token], _ oldMiddle: Range<Int>, changed oldChanged: inout [Bool],
        new: [Token], _ newMiddle: Range<Int>, changed newChanged: inout [Bool]
    ) {
        let a = oldMiddle.map { old[$0].text }
        let b = newMiddle.map { new[$0].text }
        guard !a.isEmpty, !b.isEmpty else {
            for index in oldMiddle { oldChanged[index] = true }
            for index in newMiddle { newChanged[index] = true }
            return
        }

        // lengths[i][j] — length of the LCS of a[i...] and b[j...].
        var lengths = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                oldChanged[oldMiddle.lowerBound + i] = true
                i += 1
            } else {
                newChanged[newMiddle.lowerBound + j] = true
                j += 1
            }
        }
        while i < a.count {
            oldChanged[oldMiddle.lowerBound + i] = true
            i += 1
        }
        while j < b.count {
            newChanged[newMiddle.lowerBound + j] = true
            j += 1
        }
    }

    // MARK: - Ranges

    /// Changed tokens, joined up where they touch so a run of them is one block
    /// of colour rather than several with seams between them.
    private static func merge(_ tokens: [Token], changed: [Bool]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for (index, token) in tokens.enumerated() where changed[index] {
            if let last = ranges.last, last.upperBound == token.start {
                ranges[ranges.count - 1] = last.lowerBound..<token.end
            } else {
                ranges.append(token.start..<token.end)
            }
        }
        return ranges
    }

    private static func coverage(_ ranges: [Range<Int>], of line: String) -> Double {
        let length = line.count
        guard length > 0 else { return 0 }
        return Double(ranges.reduce(0) { $0 + $1.count }) / Double(length)
    }
}
