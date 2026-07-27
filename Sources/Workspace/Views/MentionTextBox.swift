import SwiftUI

/// The people an `@` can name, and how to go and find them.
///
/// Every box that writes a comment carries one of these — the conversation's
/// composer, a reply inside a thread, and the box that starts a thread on a line
/// of the diff — so a mention is written the same way wherever it is written.
struct MentionSource {
    /// Everyone the host offered for this pull request. The same list the
    /// reviewer picker uses, the author included: an `@` names them more often
    /// than it names anybody else.
    var people: [ReviewerCandidate] = []
    /// Which host, because the two write a mention differently — see
    /// ``ReviewerCandidate/mention(on:)``.
    var host: GitHostKind = .unknown
    /// Asked for the first time an `@` is typed, and never again: reading who is
    /// on a repository costs several calls, and most comments name nobody.
    var load: () async -> Void = {}

    /// Nobody at all: a box with no pull request behind it completes nothing.
    /// Made each time it is asked for rather than held, since it carries a
    /// closure and nothing that holds a closure is safe to share.
    static var none: MentionSource { MentionSource() }
}

/// The `@…` the caret is sitting inside, and what has been typed after it.
///
/// The same idea as ``ChatCompletionToken``, which does this for the chat's
/// files and slash commands; this one knows only about people, and so is happy
/// with an `@` anywhere a word can start.
struct MentionToken: Equatable {
    let query: String
    /// UTF-16 offset of the `@` itself, so accepting a name knows what to
    /// replace.
    let start: Int

    /// Reads the token under the caret, or nothing when there is none there.
    ///
    /// The `@` has to *start* its word, which is what keeps an email address out
    /// of it: in `ada@example.com` the caret's word begins with `a`, not with
    /// the `@`, so nothing is offered.
    static func read(in text: String, caret: Int) -> MentionToken? {
        guard caret > 0, caret <= text.utf16.count else { return nil }
        let caretIndex = String.Index(utf16Offset: caret, in: text)
        guard caretIndex <= text.endIndex else { return nil }

        let before = text[text.startIndex..<caretIndex]
        let wordStart = before.lastIndex(where: \.isWhitespace)
            .map { before.index(after: $0) } ?? before.startIndex
        let word = before[wordStart...]
        guard word.first == "@" else { return nil }

        return MentionToken(
            query: String(word.dropFirst()),
            start: word.startIndex.utf16Offset(in: text)
        )
    }
}

/// A box for writing a comment, where **`@` names a person**.
///
/// Type `@`, and who can be named on this pull request appears above the box —
/// faces and handles, ↑ ↓ to walk them, ⏎ or ⇥ to take one, ⎋ to close the list.
/// **What goes into the text is the name**, on every host. Bitbucket Cloud
/// wants an id instead — `@{712020:297e58ad-…}` — but that is put on as the
/// comment is sent (``BitbucketMarkup/encodingMentions(in:people:)``), not
/// typed into the box: an id in the middle of a sentence you are still writing
/// reads as a bug, and says nothing about who you just named.
///
/// AppKit underneath (``ChatInputField``) rather than a `TextEditor`, because a
/// completion list has to know where the caret is and be offered the arrow keys
/// before the text view acts on them — neither of which a `TextEditor` says a
/// word about. It grows with what is written, as the chat's box does.
struct MentionTextBox: View {
    @Binding var text: String
    let prompt: String
    var mentions: MentionSource = .none
    /// How tall the box is before anything is written; it grows from there.
    var minHeight: CGFloat = 29
    /// How far it grows before it starts scrolling instead.
    var maxLines = 6
    var focusesOnAppear = false
    /// What ⎋ does once there is no completion list left for it to close.
    var onEscape: () -> Void = {}

    @State private var height = ChatInputField.singleLineHeight
    @State private var caret = 0
    @State private var selected = 0
    /// The token ⎋ was pressed on, so the list stays shut until the caret moves
    /// somewhere else rather than springing back on the next keystroke.
    @State private var dismissed: MentionToken?

    /// How many names are offered at once. Enough to pick from without the list
    /// growing over the conversation it is written under.
    private static let rowLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !completions.isEmpty {
                ChatCompletionList(
                    completions: completions,
                    selected: min(selected, completions.count - 1),
                    accept: accept
                )
            }

            ChatInputField(
                text: $text,
                height: $height,
                caret: $caret,
                placeholder: prompt,
                maxLines: maxLines,
                submitsOnReturn: false,
                focusesOnAppear: focusesOnAppear,
                onEscape: onEscape,
                onCompletionKey: handle
            )
            .frame(height: max(minHeight, height))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
        }
        // A different `@` is a different list, so the highlight goes back to the
        // top rather than staying on the fourth row of the last one.
        .onChange(of: token) { selected = 0 }
        // The people are read the first time somebody reaches for them, and the
        // store only ever goes and gets them once per pull request.
        .task(id: token != nil) {
            guard token != nil else { return }
            await mentions.load()
        }
    }

    private var token: MentionToken? {
        let found = MentionToken.read(in: text, caret: caret)
        return found == dismissed ? nil : found
    }

    /// Who matches what has been typed after the `@`.
    ///
    /// Whoever the query *starts* comes first — `@ad` should reach "adam" before
    /// "vladimir" — and the host's own ranking breaks the tie, so a bare `@`
    /// opens on the people closest to this repository.
    private var completions: [ChatCompletion] {
        guard let token else { return [] }
        let needle = token.query.lowercased()
        return mentions.people
            .filter { $0.matches(token.query) }
            .sorted { lhs, rhs in
                let first = lhs.name.lowercased().hasPrefix(needle)
                let second = rhs.name.lowercased().hasPrefix(needle)
                if first != second { return first }
                return lhs.relevance < rhs.relevance
            }
            .prefix(Self.rowLimit)
            .map { person in
                ChatCompletion(
                    id: "person:" + person.handle,
                    insert: person.mentionDisplay,
                    title: person.name,
                    detail: person.detail ?? "",
                    symbol: "at",
                    avatar: person.avatarURL,
                    isPerson: true
                )
            }
    }

    /// Puts the mention in place of what was typed, and leaves a space after it
    /// so the next word does not run into the name.
    private func accept(_ completion: ChatCompletion) {
        guard let token else { return }
        let start = String.Index(utf16Offset: token.start, in: text)
        let end = String.Index(utf16Offset: min(caret, text.utf16.count), in: text)
        guard start <= end, end <= text.endIndex else { return }

        let replacement = completion.insert + " "
        text = text.replacingCharacters(in: start..<end, with: replacement)
        caret = token.start + replacement.utf16.count
        dismissed = nil
        selected = 0
    }

    /// ↑ ↓ ⏎ ⇥ ⎋, when a list is up. Returning false lets the box have them.
    private func handle(_ key: ChatCompletionKey) -> Bool {
        let rows = completions
        guard !rows.isEmpty else { return false }
        switch key {
        case .up:
            selected = max(0, selected - 1)
        case .down:
            selected = min(rows.count - 1, selected + 1)
        case .accept:
            accept(rows[min(selected, rows.count - 1)])
        case .dismiss:
            dismissed = token
        }
        return true
    }
}
