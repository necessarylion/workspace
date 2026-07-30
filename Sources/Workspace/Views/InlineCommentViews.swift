import SwiftUI

extension PullRequestComment {
    /// A colour of the author's own, so who said what is readable at a glance
    /// down a long thread.
    ///
    /// Picked from the name rather than from the order comments arrive in: the
    /// same person keeps the same colour across every thread and every launch.
    /// Swift's own `hashValue` is seeded per process and would not.
    var authorColor: Color {
        Self.authorPalette[Self.stableHash(author.lowercased()) % Self.authorPalette.count]
    }

    /// Red and green are what the diff uses for removed and added lines, so
    /// they stay out of this.
    private static let authorPalette: [Color] = [
        .blue, .purple, .pink, .orange, .teal, .indigo, .brown, .cyan, .mint,
    ]

    /// FNV-1a, which is short, stable, and spreads short names well.
    private static func stableHash(_ text: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(Int.max))
    }
}

/// The comment threads anchored to one line, drawn between that line and the
/// next one. Same thread rendering as the conversation tab, so a reply nests
/// under what it answers here too.
struct DiffCommentThreads: View {
    let threads: [PullRequestCommentNode]
    let isPosting: Bool
    @Binding var replyingTo: PullRequestComment?
    /// The comment whose text is being rewritten, if any.
    @Binding var editing: PullRequestComment?
    var mentions: MentionSource = .none
    let onReply: (PullRequestComment, String) async -> Void
    var onResolve: ((PullRequestComment, Bool) async -> Void)?
    var onEdit: ((PullRequestComment, String) async -> Void)?
    var onDelete: ((PullRequestComment) async -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(threads) { thread in
                CommentThread(
                    node: thread,
                    depth: 0,
                    replyingTo: $replyingTo,
                    editing: $editing,
                    isPosting: isPosting,
                    mentions: mentions,
                    // The line it hangs under already says which file this is.
                    isInline: true,
                    onReply: onReply,
                    onResolve: onResolve,
                    onEdit: onEdit,
                    onDelete: onDelete
                )
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.05))
        .overlay(alignment: .leading) {
            // Ties the block to the line above it rather than letting it float
            // between two rows of code.
            Rectangle()
                .fill(.tint.opacity(0.5))
                .frame(width: 2)
        }
        // The block itself fades; the lines below it move at once. Anything
        // more would have to be an animation on the flattened stack this hangs
        // in, and that stack is every line of the diff.
        .transition(.opacity)
    }
}

/// The green mark a settled thread wears, drawn like the review states beside
/// it: a word in a tinted capsule.
struct ResolvedChip: View {
    var resolvedBy: String?

    var body: some View {
        Label("Resolved", systemImage: "checkmark.circle.fill")
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.green.opacity(0.16), in: Capsule())
            .foregroundStyle(.green)
            .help(resolvedBy.map { "Resolved by \($0)" } ?? "Resolved")
    }
}

/// The single row a settled thread is shown as until someone asks for the rest
/// of it.
///
/// A resolved thread is answered business, and a long review leaves a page of
/// them between the parts still worth reading — so it keeps only what says
/// whose it was, that it is closed, and how much is behind the row.
struct ResolvedThreadRow: View {
    let node: PullRequestCommentNode
    let isExpanded: Bool
    /// Inline in the diff the path is dropped: the line it is drawn under is
    /// the file, and there is no room for it.
    var showsPath = true
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                // One glyph turned rather than two glyphs swapped. A symbol
                // whose *name* changes has nothing to move between, so the
                // twisty on a settled thread was the one disclosure in the
                // window that could not animate at all.
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(ViewerMotion.disclosure, value: isExpanded)
                AuthorAvatar(name: node.comment.author, url: node.comment.avatarURL, size: 18)
                Text(node.comment.author)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(node.comment.authorColor)
                ResolvedChip(resolvedBy: node.comment.resolvedBy)

                if showsPath, let path = node.comment.path {
                    Text(path)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        // The preview is what the row is read for; the path
                        // gives up its width first.
                        .layoutPriority(-1)
                }

                if !isExpanded, !node.preview.isEmpty {
                    Text(node.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if node.totalReplies > 0 {
                    Label("\(node.totalReplies)", systemImage: "arrowshape.turn.up.left")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(isExpanded ? "Hide this resolved thread" : "Show this resolved thread")
    }
}

/// The box for a brand new comment on a line of the diff.
struct DiffCommentComposer: View {
    let anchor: DiffLineAnchor
    let isPosting: Bool
    var mentions: MentionSource = .none
    let onCancel: () -> Void
    let onSend: (String) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "\(anchor.path):\(anchor.line)"
                    + (anchor.side == .old ? " (before the change)" : ""),
                systemImage: "text.bubble"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)

            CommentComposer(
                prompt: "Comment on this line…  @ to name someone",
                sendTitle: "Comment",
                sendSymbol: "paperplane",
                isPosting: isPosting,
                mentions: mentions,
                onCancel: onCancel,
                onSend: onSend
            )
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.05))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.tint.opacity(0.5))
                .frame(width: 2)
        }
        // As for the threads above: the box fades, the code under it moves at
        // once. See ``DiffCommentThreads``.
        .transition(.opacity)
    }
}

/// A text box with Cancel and a send button. Used for replies in a thread, for
/// new comments on a line, and for rewriting a comment already posted — which
/// differ only in their wording and in what the box starts out holding.
struct CommentComposer: View {
    let prompt: String
    let sendTitle: String
    let sendSymbol: String
    let isPosting: Bool
    let mentions: MentionSource
    let onCancel: () -> Void
    let onSend: (String) async -> Void

    @State private var draft: String

    /// `text` is what the box opens with — empty for anything being written for
    /// the first time, and the comment as the host stores it for an edit. It is
    /// spelled out rather than left to the memberwise initialiser because a
    /// `@State` needs its starting value here, before the view is on screen.
    init(
        prompt: String,
        sendTitle: String,
        sendSymbol: String = "arrowshape.turn.up.left",
        isPosting: Bool,
        mentions: MentionSource = .none,
        startingFrom text: String = "",
        onCancel: @escaping () -> Void,
        onSend: @escaping (String) async -> Void
    ) {
        self.prompt = prompt
        self.sendTitle = sendTitle
        self.sendSymbol = sendSymbol
        self.isPosting = isPosting
        self.mentions = mentions
        self.onCancel = onCancel
        self.onSend = onSend
        _draft = State(initialValue: text)
    }

    private var isEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MentionTextBox(
                text: $draft,
                prompt: prompt,
                mentions: mentions,
                minHeight: 44,
                maxLines: 6,
                // A reply box is opened in order to type in it, and ⎋ closes it
                // again — the same key that closes everything else in the window.
                focusesOnAppear: true,
                onEscape: onCancel
            )

            HStack(spacing: 7) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerCursor()
                Button {
                    Task { await send() }
                } label: {
                    if isPosting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(sendTitle, systemImage: sendSymbol)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isPosting || isEmpty)
                .shortcut(.submit)
                .shortcutHelp("Post", .submit)
                .pointerCursor(!isPosting && !isEmpty)
            }
        }
    }

    private func send() async {
        guard !isEmpty else { return }
        await onSend(draft)
    }
}
