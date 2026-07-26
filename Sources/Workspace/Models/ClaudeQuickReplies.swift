import Foundation

/// One option offered at the end of a reply, as something to click.
struct ClaudeQuickReply: Identifiable, Equatable {
    let number: Int
    /// What is shown, and what gets sent — the same thing, so what you clicked
    /// is what appears in the transcript as your answer.
    let text: String

    var id: Int { number }
}

/// Turns "…which would you like? 1. … 2. …" at the end of a reply into buttons.
///
/// A `-p` session has no interactive question tool, so Claude asks for a
/// decision by writing the choices out — see `ClaudeSession.chatContext`, which
/// is what asks it for a numbered list. Reading that list back gives the same
/// one-click answer without a tool to call.
///
/// Deliberately hard to trigger. A reply that merely *ends in a numbered list*
/// is usually a summary of what was done, and putting buttons under that would
/// be nonsense — so the list has to be numbered from 1 in order, and the line
/// above it has to read like a question.
enum ClaudeQuickReplies {
    /// The most options worth drawing. Past this it is a document, not a
    /// question.
    private static let limit = 8

    static func read(from reply: String) -> [ClaudeQuickReply] {
        var lines = reply.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }

        // Walk up from the bottom for as long as the lines are numbered items.
        var items: [(number: Int, text: String)] = []
        var index = lines.count - 1
        while index >= 0, let item = numbered(lines[index]) {
            items.append(item)
            index -= 1
        }
        items.reverse()

        guard items.count >= 2, items.count <= limit else { return [] }
        // 1, 2, 3 … in order. A list starting at 3, or one where the numbers
        // repeat, is part of some other document that happens to end here.
        for (offset, item) in items.enumerated() where item.number != offset + 1 {
            return []
        }
        guard asksAQuestion(above: index, in: lines) else { return [] }

        return items.map { ClaudeQuickReply(number: $0.number, text: clean($0.text)) }
    }

    /// `1. Something` or `2) Something`, with a little room to be indented.
    private static func numbered(_ line: String) -> (number: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard line.prefix(while: { $0 == " " }).count <= 3 else { return nil }

        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2, let number = Int(digits) else { return nil }

        var rest = trimmed.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }

        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (number, text)
    }

    /// Words that make a colon a choice rather than an introduction.
    private static let choosing = [
        "which", "choose", "pick", "prefer", "option", "want", "shall", "should", "rather",
    ]

    /// Whether what comes above the list reads like it is asking for one of
    /// them.
    ///
    /// A question mark settles it. A colon on its own does not — "Here's what I
    /// changed:" is followed by a numbered list in half the replies ever
    /// written, and buttons under *that* would be nonsense — so a colon only
    /// counts when the same line is visibly asking for a choice.
    private static func asksAQuestion(above index: Int, in lines: [String]) -> Bool {
        var cursor = index
        while cursor >= 0 {
            let line = lines[cursor].trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                cursor -= 1
                continue
            }
            let stripped = clean(line)
            if stripped.hasSuffix("?") { return true }
            guard stripped.hasSuffix(":") else { return false }
            let lowered = stripped.lowercased()
            return choosing.contains { lowered.contains($0) }
        }
        // Nothing above it at all: a bare list is not a question.
        return false
    }

    /// The option as a person reads it. A lead-in in bold is the name of the
    /// choice and the rest is the explanation of it — "**OAuth** (Google,
    /// GitHub…)" is offering OAuth — so where there is one, that is the answer.
    private static func clean(_ text: String) -> String {
        if let bold = boldLeadIn(text) { return bold }
        return text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func boldLeadIn(_ text: String) -> String? {
        guard text.hasPrefix("**"), let end = text.dropFirst(2).range(of: "**") else { return nil }
        let inner = String(text.dropFirst(2)[..<end.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? nil : inner
    }
}
