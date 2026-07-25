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
    let onReply: (PullRequestComment, String) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(threads) { thread in
                CommentThread(
                    node: thread,
                    depth: 0,
                    replyingTo: $replyingTo,
                    isPosting: isPosting,
                    onReply: onReply
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
    }
}

/// The box for a brand new comment on a line of the diff.
struct DiffCommentComposer: View {
    let anchor: DiffLineAnchor
    let isPosting: Bool
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
                prompt: "Comment on this line…",
                sendTitle: "Comment",
                sendSymbol: "paperplane",
                isPosting: isPosting,
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
    }
}

/// A text box with Cancel and a send button. Used for replies in a thread and
/// for new comments on a line, which differ only in their wording.
struct CommentComposer: View {
    let prompt: String
    let sendTitle: String
    var sendSymbol = "arrowshape.turn.up.left"
    let isPosting: Bool
    let onCancel: () -> Void
    let onSend: (String) async -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    private var isEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $draft)
                .font(.callout)
                .frame(minHeight: 48, maxHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(5)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(prompt)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 11)
                            .allowsHitTesting(false)
                    }
                }
                .focused($isFocused)

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
                .keyboardShortcut(.return, modifiers: .command)
                .pointerCursor(!isPosting && !isEmpty)
                .help("Post (⌘↩)")
            }
        }
        .onAppear { isFocused = true }
    }

    private func send() async {
        guard !isEmpty else { return }
        await onSend(draft)
    }
}
