import AppKit
import SwiftUI

/// A pull request: metadata, description, conversation, and its diff.
///
/// A single slim bar says where the pull request comes from and goes to; the
/// tabs that pick what fills the rest of the window live up in the window
/// header, next to back and forward.
struct PullRequestDetailView: View {
    @Environment(WorkspaceStore.self) private var store
    let item: ViewerItem
    let pr: PullRequest
    let project: Project

    /// Thread roots that hang off a line of the diff, keyed by that line. A
    /// thread whose line is no longer in the diff simply does not appear here;
    /// it is still listed in the conversation, so nothing is lost.
    private var inlineThreads: [DiffLineAnchor: [PullRequestCommentNode]] {
        var grouped: [DiffLineAnchor: [PullRequestCommentNode]] = [:]
        for node in PullRequestComment.tree(from: item.comments) {
            guard let anchor = node.comment.anchor else { continue }
            grouped[anchor, default: []].append(node)
        }
        return grouped
    }

    var body: some View {
        VStack(spacing: 0) {
            summaryBar
                .background(.bar)
            Divider()

            switch item.pullRequestTab {
            case .details: detailsTab
            case .diff: diffTab
            case .builds: buildsTab
            }
        }
    }

    // MARK: - Summary bar

    /// One line that stays put: where this pull request comes from and goes to,
    /// and how it stands. Anything longer — the description, the conversation —
    /// belongs to the Details tab.
    private var summaryBar: some View {
        HStack(spacing: 6) {
            sourceBranch
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            branchChip(pr.targetBranch)
            if let additions = pr.additions, let deletions = pr.deletions {
                Text("+\(additions)").foregroundStyle(.green)
                Text("−\(deletions)").foregroundStyle(.red)
            }
            if pr.isDraft {
                badge("Draft", color: .secondary)
            }
            if let review = pr.reviewLabel {
                badge(review, color: review == "Approved" ? .green : .orange)
            }

            Spacer(minLength: 8)

            if item.pullRequestTab == .details, !item.comments.isEmpty {
                Text("\(item.comments.count) comments")
                    .foregroundStyle(.secondary)
            }
            tabPicker
            actionsMenu
        }
        .font(.caption.monospaced())
        // Same inset as the header above it, so the tab picker at this end of
        // the row sits directly under the navigator's.
        .padding(.horizontal, AppMetrics.barHorizontalPadding)
        .padding(.vertical, 7)
    }

    /// The branch the pull request comes from, followed by the two things one
    /// actually does with it. The target branch stays a plain chip: there is
    /// nothing to check out there.
    private var sourceBranch: some View {
        HStack(spacing: 4) {
            branchChip(pr.sourceBranch)
            barButton("doc.on.doc", help: "Copy “\(pr.sourceBranch)”") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pr.sourceBranch, forType: .string)
                store.showStatus("Branch copied")
            }
            barButton(
                "arrow.down.circle",
                help: "Check out “\(pr.sourceBranch)”"
            ) {
                checkout()
            }
            .disabled(project.isRunningGitCommand)
        }
    }

    private func barButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.callout)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        // Before `pointerCursor`, not after: the pointer style claims the
        // hover region, and a `help` added on top of it never shows a tooltip.
        .help(help)
        .pointerCursor()
    }

    /// Details, diff and builds, at the right end of the bar — the title of the
    /// pull request they belong to is up in the window header.
    private var tabPicker: some View {
        Picker("", selection: Binding(
            get: { item.pullRequestTab },
            set: { item.pullRequestTab = $0 }
        )) {
            ForEach(ViewerItem.PullRequestTab.allCases) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // A segmented control centres itself in whatever width it is given
        // rather than filling it, so ask for its own width and let the
        // branches at the other end give way instead.
        .fixedSize()
        .font(.callout)
        .pointerCursor()
    }

    /// What is left once copy and check out have their own buttons, folded into a
    /// menu so the bar stays one line tall.
    private var actionsMenu: some View {
        Menu {
            if let url = pr.url {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
            }
            Button {
                reviewWithClaude()
            } label: {
                Label("Review with Claude Code", systemImage: "sparkles")
            }
            Divider()
            Button {
                Task { await store.loadPullRequestDiff(item, project: project, pr: pr) }
            } label: {
                Label("Reload Diff", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // Same width as the navigator toggle that ends the header, which is
        // what puts this bar's tab picker under that one.
        .frame(width: AppMetrics.barTrailingControlWidth)
        .help("Actions for this pull request")
        .pointerCursor()
    }

    // MARK: - Tabs

    /// The description rides at the top of the conversation's own scroll rather
    /// than above it, so only one thing here ever scrolls.
    private var detailsTab: some View {
        ConversationView(item: item, pr: pr, project: project) {
            VStack(alignment: .leading, spacing: 10) {
                // No title here: the window header already names the pull
                // request, and the description reads as its own thing.
                HStack(spacing: 8) {
                    Label(pr.author, systemImage: "person.crop.circle")
                    Label {
                        Text(pr.host.displayName)
                    } icon: {
                        GitHostIcon(host: pr.host, size: 13)
                    }
                    if let updated = pr.updatedAt {
                        Text("updated \(updated.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)

                if !pr.body.isEmpty {
                    MarkdownText(text: pr.body)
                        .font(.callout)
                }

                Divider()
            }
        }
    }

    /// Placeholder until build status is read from the host.
    private var buildsTab: some View {
        ContentUnavailableView {
            Label("Pipeline builds", systemImage: "hammer")
        } description: {
            Text("Build status for this pull request is not here yet. For now the pipeline lives on \(pr.host.displayName).")
        } actions: {
            if let url = pr.url {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointerCursor()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var diffTab: some View {
        if item.isLoading {
            ProgressView("Loading diff…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diff = item.diff, !diff.isEmpty {
            DiffView(
                diff: diff,
                layout: Binding(get: { item.diffLayout }, set: { item.diffLayout = $0 }),
                comments: DiffComments(
                    threads: inlineThreads,
                    isPosting: item.isPostingComment,
                    add: { anchor, body in
                        await store.postInlineComment(
                            body,
                            at: anchor,
                            on: item,
                            project: project,
                            pr: pr
                        )
                    },
                    reply: { parent, body in
                        await store.postComment(
                            body,
                            on: item,
                            project: project,
                            pr: pr,
                            replyingTo: parent
                        )
                    }
                )
            )
        } else {
            ContentUnavailableView(
                "No diff",
                systemImage: "plusminus",
                description: Text(item.errorMessage ?? "This pull request has no textual changes.")
            )
        }
    }

    private func branchChip(_ name: String) -> some View {
        Text(name)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    /// Plain git, the same for every host: `gh pr checkout` and `bkt pr checkout`
    /// both go out to the host for a branch name git already knows. It runs
    /// without a terminal — the toast says whether it worked, and git's own
    /// message says why it did not.
    private func checkout() {
        Task {
            if await project.checkout(pr.sourceBranch) {
                store.showStatus("Checked out \(pr.sourceBranch)")
            } else {
                store.showError(project.gitError
                    ?? "Could not check out \(pr.sourceBranch).")
            }
        }
    }

    private func reviewWithClaude() {
        let prompt = "Review pull request #\(pr.number) (\(pr.title)) in this repository and summarise the risks."
        store.openTerminal(
            in: project,
            runningCommand: "claude \(Shell.quote(prompt))",
            title: "Claude · #\(pr.number)"
        )
    }
}

// MARK: - Conversation

/// Existing comments, plus a box to add one.
///
/// `header` is rendered as the first thing inside the same scroll — the pull
/// request's description goes there, so the page scrolls as one.
struct ConversationView<Header: View>: View {
    @Environment(WorkspaceStore.self) private var store
    let item: ViewerItem
    let pr: PullRequest
    let project: Project
    let header: () -> Header

    init(
        item: ViewerItem,
        pr: PullRequest,
        project: Project,
        @ViewBuilder header: @escaping () -> Header
    ) {
        self.item = item
        self.pr = pr
        self.project = project
        self.header = header
    }

    @State private var draft = ""
    @FocusState private var isComposing: Bool
    /// The comment whose inline reply box is open, if any.
    @State private var replyingTo: PullRequestComment?

    private var threads: [PullRequestCommentNode] {
        PullRequestComment.tree(from: item.comments)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    header()

                    if item.isLoadingComments {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Loading conversation…").foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                    } else if let error = item.commentError, item.comments.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    } else if item.comments.isEmpty {
                        Text("No comments yet.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }

                    ForEach(threads) { thread in
                        CommentThread(
                            node: thread,
                            depth: 0,
                            replyingTo: $replyingTo,
                            isPosting: item.isPostingComment,
                            onReply: { parent, body in
                                await post(body, replyingTo: parent)
                            }
                        )
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            composer
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let error = item.commentError, !item.comments.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 58, maxHeight: 130)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Write a comment…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
                .focused($isComposing)

            HStack {
                Text(pr.host == .github ? "Posted with gh" : "Posted with bkt")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    Task { await post() }
                } label: {
                    if item.isPostingComment {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Comment", systemImage: "paperplane")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(
                    item.isPostingComment ||
                    draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .keyboardShortcut(.return, modifiers: .command)
                .pointerCursor(
                    !item.isPostingComment &&
                    !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .help("Post the comment (⌘↩)")
            }
        }
        .padding(12)
        .background(.bar)
    }

    private func post() async {
        let body = draft
        await store.postComment(body, on: item, project: project, pr: pr)
        if item.commentError == nil {
            draft = ""
        }
    }

    /// Posts a reply and closes the inline box once it lands.
    private func post(_ body: String, replyingTo parent: PullRequestComment) async {
        await store.postComment(body, on: item, project: project, pr: pr, replyingTo: parent)
        if item.commentError == nil {
            replyingTo = nil
        }
    }
}

// MARK: - Threads

/// One comment and, indented beneath it, everything that replies to it.
struct CommentThread: View {
    let node: PullRequestCommentNode
    let depth: Int
    @Binding var replyingTo: PullRequestComment?
    let isPosting: Bool
    let onReply: (PullRequestComment, String) async -> Void

    /// Stop indenting past this depth so deep threads stay readable.
    private static let maxIndentedDepth = 4
    private static let indent: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CommentBubble(
                comment: node.comment,
                replyCount: depth == 0 ? totalReplies : 0,
                isReplying: replyingTo == node.comment,
                onReplyTapped: {
                    replyingTo = replyingTo == node.comment ? nil : node.comment
                }
            )

            if replyingTo == node.comment {
                CommentComposer(
                    prompt: "Reply to \(node.comment.author)…",
                    sendTitle: "Reply",
                    isPosting: isPosting,
                    onCancel: { replyingTo = nil },
                    onSend: { body in await onReply(node.comment, body) }
                )
                .padding(.leading, Self.indent)
            }

            if !node.replies.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(node.replies) { reply in
                        CommentThread(
                            node: reply,
                            depth: depth + 1,
                            replyingTo: $replyingTo,
                            isPosting: isPosting,
                            onReply: onReply
                        )
                    }
                }
                .padding(.leading, depth < Self.maxIndentedDepth ? Self.indent : 0)
                .overlay(alignment: .leading) {
                    // The rule that ties a reply back to what it answers.
                    Rectangle()
                        .fill(.quaternary)
                        .frame(width: 1)
                        .padding(.vertical, 2)
                }
            }
        }
    }

    /// Every descendant, not just the direct children.
    private var totalReplies: Int {
        node.replies.reduce(node.replies.count) { total, reply in
            total + reply.replies.reduce(0) { $0 + 1 + $1.replies.count }
        }
    }
}

struct CommentBubble: View {
    let comment: PullRequestComment
    /// Shown on a thread root so a collapsed-looking thread still reads as one.
    var replyCount: Int = 0
    var isReplying = false
    var onReplyTapped: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: comment.kind.symbol)
                    .foregroundStyle(tint)
                Text(comment.author)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(comment.authorColor)
                if case .review(let state) = comment.kind {
                    Text(state.replacingOccurrences(of: "_", with: " ").lowercased())
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(tint.opacity(0.16), in: Capsule())
                        .foregroundStyle(tint)
                }
                if replyCount > 0 {
                    Label("\(replyCount)", systemImage: "arrowshape.turn.up.left")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let date = comment.createdAt {
                    Text(date.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let path = comment.path {
                Text(path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            if comment.body.isEmpty {
                Text("(no message)")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                MarkdownText(text: comment.body)
                    .font(.callout)
            }

            if comment.canReply, let onReplyTapped {
                Button(action: onReplyTapped) {
                    Label(
                        isReplying ? "Cancel reply" : "Reply",
                        systemImage: "arrowshape.turn.up.left"
                    )
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .pointerCursor()
                .padding(.top, 1)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
    }

    private var tint: Color {
        switch comment.kind {
        case .comment: .secondary
        case .review(let state):
            switch state.uppercased() {
            case "APPROVED": .green
            case "CHANGES_REQUESTED": .orange
            default: .blue
            }
        }
    }
}
