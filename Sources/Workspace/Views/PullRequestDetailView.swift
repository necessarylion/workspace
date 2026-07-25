import AppKit
import SwiftUI

/// A pull request: metadata, description, conversation, and its diff.
struct PullRequestDetailView: View {
    @Environment(WorkspaceStore.self) private var store
    let item: ViewerItem
    let pr: PullRequest
    let project: Project

    private enum Pane: String, CaseIterable, Identifiable {
        case diff, conversation
        var id: String { rawValue }
        var title: String { self == .diff ? "Diff" : "Conversation" }
        var symbol: String { self == .diff ? "plusminus" : "bubble.left.and.bubble.right" }
    }

    @State private var pane: Pane = .diff

    var body: some View {
        VSplitView {
            header
                .frame(minHeight: 150, idealHeight: 230)
            VStack(spacing: 0) {
                panePicker
                Divider()
                switch pane {
                case .diff: diffSection
                case .conversation: ConversationView(item: item, pr: pr, project: project)
                }
            }
            .frame(minHeight: 220)
        }
    }

    // MARK: - Header

    private var header: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("#\(pr.number)")
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(pr.title)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Label(pr.author, systemImage: "person.crop.circle")
                    Label(pr.host.displayName, systemImage: pr.host.symbol)
                    if pr.isDraft {
                        badge("Draft", color: .secondary)
                    }
                    if let review = pr.reviewLabel {
                        badge(review, color: review == "Approved" ? .green : .orange)
                    }
                    if let updated = pr.updatedAt {
                        Text("updated \(updated.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)

                HStack(spacing: 6) {
                    branchChip(pr.sourceBranch)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    branchChip(pr.targetBranch)
                    if let additions = pr.additions, let deletions = pr.deletions {
                        Text("+\(additions)").foregroundStyle(.green)
                        Text("−\(deletions)").foregroundStyle(.red)
                    }
                }
                .font(.caption.monospaced())

                actions

                if !pr.body.isEmpty {
                    Divider()
                    // The header already scrolls; render the blocks directly
                    // instead of nesting a second scroll view.
                    MarkdownText(text: pr.body)
                        .font(.callout)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if let url = pr.url {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
            }
            Button {
                checkout()
            } label: {
                Label("Check Out Branch", systemImage: "arrow.down.circle")
            }
            Button {
                reviewWithClaude()
            } label: {
                Label("Review with Claude Code", systemImage: "sparkles")
            }
            Button {
                Task { await store.loadPullRequestDiff(item, project: project, pr: pr) }
            } label: {
                Label("Reload Diff", systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var panePicker: some View {
        HStack {
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { option in
                    Label(option.title, systemImage: option.symbol).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)

            Spacer()

            switch pane {
            case .diff:
                if let diff = item.diff, !diff.isEmpty {
                    Text("+\(diff.addedLines)").foregroundStyle(.green)
                    Text("−\(diff.removedLines)").foregroundStyle(.red)
                    DiffLayoutPicker(
                        layout: Binding(get: { item.diffLayout }, set: { item.diffLayout = $0 })
                    )
                }
            case .conversation:
                Text("\(item.comments.count) comments")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var diffSection: some View {
        if item.isLoading {
            ProgressView("Loading diff…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diff = item.diff, !diff.isEmpty {
            DiffView(
                diff: diff,
                layout: Binding(get: { item.diffLayout }, set: { item.diffLayout = $0 }),
                showsControls: false
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

    private func checkout() {
        let command: String
        switch pr.host {
        case .github: command = "gh pr checkout \(pr.number)"
        case .bitbucket: command = "bkt pr checkout \(pr.number)"
        case .unknown: command = "git fetch origin \(Shell.quote(pr.sourceBranch))"
        }
        store.openTerminal(in: project, runningCommand: command, title: "Checkout #\(pr.number)")
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
struct ConversationView: View {
    @Environment(WorkspaceStore.self) private var store
    let item: ViewerItem
    let pr: PullRequest
    let project: Project

    @State private var draft = ""
    @FocusState private var isComposing: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
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

                    ForEach(item.comments) { comment in
                        CommentBubble(comment: comment)
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
}

struct CommentBubble: View {
    let comment: PullRequestComment

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: comment.kind.symbol)
                    .foregroundStyle(tint)
                Text(comment.author)
                    .font(.callout.weight(.medium))
                if case .review(let state) = comment.kind {
                    Text(state.replacingOccurrences(of: "_", with: " ").lowercased())
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(tint.opacity(0.16), in: Capsule())
                        .foregroundStyle(tint)
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
