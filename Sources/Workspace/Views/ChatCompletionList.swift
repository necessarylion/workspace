import SwiftUI

/// What the composer is completing right now: the `@` or `/` the caret is
/// sitting inside, and what has been typed after it.
struct ChatCompletionToken: Equatable {
    enum Kind {
        case file, command
    }

    let kind: Kind
    let query: String
    /// UTF-16 offset of the `@` or `/` itself, so accepting a completion knows
    /// what to replace.
    let start: Int

    /// Reads the token out of the text under the caret, or nothing when the
    /// caret is not in one.
    ///
    /// A `@` counts anywhere a word can start. A `/` only counts at the very
    /// beginning of the message, because that is the only place the CLI treats
    /// one as a command — `and/or` half way through a sentence is not an
    /// attempt to run anything.
    static func read(in text: String, caret: Int) -> ChatCompletionToken? {
        guard caret > 0, caret <= text.utf16.count else { return nil }
        let caretIndex = String.Index(utf16Offset: caret, in: text)
        guard caretIndex <= text.endIndex else { return nil }

        let before = text[text.startIndex..<caretIndex]
        let chunkStart = before.lastIndex(where: \.isWhitespace)
            .map { before.index(after: $0) } ?? before.startIndex
        let chunk = before[chunkStart...]
        guard let marker = chunk.first else { return nil }

        let query = String(chunk.dropFirst())
        // A path can hold anything but whitespace, which the chunk has none of;
        // a query that has already run past a line break is not one.
        guard !query.contains("\n") else { return nil }
        let start = chunk.startIndex.utf16Offset(in: text)

        switch marker {
        case "@":
            return ChatCompletionToken(kind: .file, query: query, start: start)
        case "/" where start == 0:
            return ChatCompletionToken(kind: .command, query: query, start: start)
        default:
            return nil
        }
    }
}

/// One row of the list.
struct ChatCompletion: Identifiable, Equatable {
    let id: String
    /// What goes into the box, marker and all.
    let insert: String
    let title: String
    var detail: String = ""
    var symbol: String
    /// The folder a file sits in, drawn behind its name so two files with the
    /// same name can be told apart.
    var trailing: String = ""
    /// A person's picture, where the row is a person: a face is recognised
    /// before a handle is read. Rows that are not people leave it empty and keep
    /// their symbol.
    var avatar: URL?
    /// Whether this row stands for a person at all — a face is still drawn from
    /// their initials when the host has no picture of them.
    var isPerson = false
}

/// The list itself, above the box rather than floating over the transcript: it
/// grows upward from where you are typing, and never covers what was said.
struct ChatCompletionList: View {
    let completions: [ChatCompletion]
    let selected: Int
    let accept: (ChatCompletion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(completions.enumerated()), id: \.element.id) { index, completion in
                row(completion, isSelected: index == selected)
                if completion.id != completions.last?.id {
                    Divider().opacity(0.25)
                }
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    private func row(_ completion: ChatCompletion, isSelected: Bool) -> some View {
        Button {
            accept(completion)
        } label: {
            HStack(spacing: 7) {
                if completion.isPerson {
                    AuthorAvatar(name: completion.title, url: completion.avatar, size: 15)
                } else {
                    Image(systemName: completion.symbol)
                        .font(.caption)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .frame(width: 14)
                }

                Text(completion.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !completion.trailing.isEmpty {
                    Text(completion.trailing)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer(minLength: 6)

                if !completion.detail.isEmpty {
                    Text(completion.detail)
                        .font(.caption2)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 220, alignment: .trailing)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
