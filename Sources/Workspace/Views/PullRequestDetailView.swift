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

    /// The button that was pressed, waiting to be confirmed. Nothing in the
    /// action bar reaches the host until this has been through the sheet — and
    /// one piece of state for all of them keeps it that way, where four separate
    /// presentations would leave SwiftUI to drop one of them on macOS.
    @State private var pendingAction: PullRequestAction?
    /// Kept out here so the sheet reopens on the way that was picked last.
    @State private var mergeStrategy: PullRequestMergeStrategy = .squash

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
            actionBar
                .background(.bar)
            Divider()

            switch item.pullRequestTab {
            case .details: detailsTab
            case .diff: diffTab
            case .commits: commitsTab
            case .builds: buildsTab
            }
        }
        // Every button in the action bar ends up here first: one sheet, one
        // shape, and nothing sent to the host until it is confirmed.
        .sheet(item: $pendingAction) { action in
            PullRequestActionSheet(
                action: action,
                pr: pr,
                syncState: item.syncState,
                strategy: $mergeStrategy,
                onCancel: { pendingAction = nil },
                onConfirm: { comment in
                    pendingAction = nil
                    perform(action, comment: comment)
                }
            )
        }
    }

    /// Runs what the sheet confirmed.
    private func perform(_ action: PullRequestAction, comment: String) {
        Task {
            switch action {
            case .merge:
                await store.mergePullRequest(
                    item,
                    project: project,
                    pr: pr,
                    using: mergeStrategy
                )
            case .review(let decision):
                await store.reviewPullRequest(
                    item,
                    project: project,
                    pr: pr,
                    decision: decision,
                    comment: comment
                )
            case .reject:
                await store.rejectPullRequest(
                    item,
                    project: project,
                    pr: pr,
                    reason: comment
                )
            case .updateBranch:
                await store.updateBranchFromBase(item, project: project, pr: pr)
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
            if item.pullRequestTab == .commits, !item.commits.isEmpty {
                Text("\(item.commits.count) commits")
                    .foregroundStyle(.secondary)
            }
            if item.pullRequestTab == .builds, !item.builds.isEmpty {
                Text("\(item.builds.count) builds")
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

    // MARK: - Action bar

    /// What one does to a pull request, on a row of its own under the summary:
    /// the review verdicts on the left, and what ends it on the right. They are
    /// buttons rather than menu items because they are the point of the window,
    /// and each of them asks before anything goes out to the host.
    private var actionBar: some View {
        HStack(spacing: 7) {
            actionButton(
                "Approve",
                symbol: "checkmark.seal",
                tint: .green,
                help: "Approve #\(pr.number) on \(pr.host.displayName)"
            ) {
                pendingAction = .review(.approve)
            }
            actionButton(
                "Request Changes",
                symbol: "exclamationmark.bubble",
                tint: .orange,
                help: "Ask for changes on #\(pr.number)"
            ) {
                pendingAction = .review(.requestChanges)
            }

            Spacer(minLength: 8)

            // A merge or a sync takes a moment on the host; the bar says so
            // rather than looking as if the button did nothing.
            if item.isRunningPullRequestAction {
                ProgressView().controlSize(.small)
            }
            if let state = item.syncState, state.isBehind {
                actionButton(
                    "\(behindPhrase(state.behind)) behind \(pr.targetBranch), sync now",
                    symbol: "arrow.triangle.2.circlepath",
                    tint: .orange,
                    help: "Bring \(pr.targetBranch) into \(pr.sourceBranch)"
                ) {
                    pendingAction = .updateBranch
                }
            }
            actionButton(
                "Reject",
                symbol: "xmark.circle",
                tint: .red,
                help: "Close #\(pr.number) without merging"
            ) {
                pendingAction = .reject
            }
            actionButton(
                "Merge",
                symbol: "arrow.triangle.merge",
                tint: .accentColor,
                isProminent: true,
                help: "Merge #\(pr.number) into \(pr.targetBranch)"
            ) {
                pendingAction = .merge
            }
        }
        .padding(.horizontal, AppMetrics.barHorizontalPadding)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        symbol: String,
        tint: Color,
        isProminent: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
        }
        .controlSize(.small)
        .buttonBorderShape(.capsule)
        .tint(tint)
        .disabled(item.isRunningPullRequestAction)
        .help(help)
        .pointerCursor(!item.isRunningPullRequestAction)

        // Filled for the one that ends the review the way it is meant to end;
        // the rest stay outlined until they are wanted.
        if isProminent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    /// How far behind, in words. The count only ever appears on the button that
    /// acts on it — a badge saying the same thing next to it was one thing too
    /// many to read.
    private func behindPhrase(_ count: Int) -> String {
        count == 1 ? "1 commit" : "\(count) commits"
    }

    /// The menu entry that re-counts the drift, which doubles as the place the
    /// count is spelled out when the branch is up to date and the badge is
    /// keeping quiet.
    private var syncStatusTitle: String {
        if item.isCheckingSync { return "Checking \(pr.targetBranch)…" }
        guard let state = item.syncState else {
            return "Check Sync with \(pr.targetBranch)"
        }
        return "\(state.summary(target: pr.targetBranch)) Check Again"
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
                // Symbols alone: four words at this end of the bar crowd out the
                // branch names at the other. The title stays on the label, so
                // VoiceOver still reads "Details" rather than a symbol name.
                Label(tab.title, systemImage: tab.symbol)
                    .labelStyle(.iconOnly)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Details, diff, commits and builds")
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
            // Merging, rejecting and updating the branch have buttons of their
            // own in the bar below; what is left here is what has none.
            Button {
                pendingAction = .updateBranch
            } label: {
                Label("Update Branch from \(pr.targetBranch)", systemImage: "arrow.down.to.line")
            }
            Button {
                Task {
                    await store.refreshSyncState(item, project: project, pr: pr, fetching: true)
                }
            } label: {
                Label(syncStatusTitle, systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(item.isCheckingSync)
            Divider()

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
            Button {
                Task { await store.loadCommits(item, project: project, pr: pr) }
            } label: {
                Label("Reload Commits", systemImage: "arrow.clockwise")
            }
            Button {
                Task { await store.loadBuilds(item, project: project, pr: pr) }
            } label: {
                Label("Reload Builds", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
        }
        // One command at a time: a merge, a rejection or a sync in flight
        // closes the menu to the rest of them.
        .disabled(item.isRunningPullRequestAction)
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
                    Label {
                        Text(pr.author)
                    } icon: {
                        AuthorAvatar(name: pr.author, url: pr.avatarURL, size: 16)
                    }
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

    /// The CI runs on the pull request's head commit. Failures sort to the top:
    /// this tab is opened because something went red, and a long green list
    /// should not bury it.
    @ViewBuilder
    private var buildsTab: some View {
        Group {
            if item.isLoadingBuilds && item.builds.isEmpty {
                ProgressView("Loading builds…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if item.builds.isEmpty {
                noBuilds
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(item.builds) { BuildRow(build: $0) }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: AppColors.viewerBackground))
            }
        }
        // Fetched the first time the tab is opened, like the commits; the
        // reload lives in the actions menu and in the empty state.
        .task {
            guard item.builds.isEmpty, !item.isLoadingBuilds, item.buildsError == nil else {
                return
            }
            await store.loadBuilds(item, project: project, pr: pr)
        }
    }

    private var noBuilds: some View {
        ContentUnavailableView {
            Label("No builds", systemImage: "hammer")
        } description: {
            Text(item.buildsError
                ?? "Nothing has run against this pull request's head commit on \(pr.host.displayName).")
        } actions: {
            Button("Try Again") {
                Task { await store.loadBuilds(item, project: project, pr: pr) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointerCursor()
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
                selectedFile: Binding(get: { item.diffFile }, set: { item.diffFile = $0 }),
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

    // MARK: - Commits

    /// The list of commits, or — once one is picked — what that commit changed.
    /// One thing at a time, as everywhere else in the viewer: a diff wants the
    /// whole window rather than what is left beside a list.
    @ViewBuilder
    private var commitsTab: some View {
        Group {
            if let commit = item.selectedCommit {
                commitDetail(commit)
            } else {
                commitList
            }
        }
        // Fetched the first time the tab is opened; a failure is not retried on
        // its own, which is what the reload button in the list is for.
        .task {
            guard item.commits.isEmpty, !item.isLoadingCommits, item.commitsError == nil else {
                return
            }
            await store.loadCommits(item, project: project, pr: pr)
        }
    }

    @ViewBuilder
    private var commitList: some View {
        if item.isLoadingCommits && item.commits.isEmpty {
            ProgressView("Loading commits…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.commits.isEmpty {
            ContentUnavailableView {
                Label("No commits", systemImage: "clock.arrow.circlepath")
            } description: {
                Text(item.commitsError ?? "This pull request has no commits.")
            } actions: {
                Button("Try Again") {
                    Task { await store.loadCommits(item, project: project, pr: pr) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointerCursor()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(item.commits) { commit in
                        CommitRow(
                            commit: commit,
                            onOpen: {
                                Task {
                                    await store.showCommit(commit, on: item, project: project, pr: pr)
                                }
                            },
                            openPullRequest: { store.openPullRequest(number: $0, project: project) }
                        )
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: AppColors.viewerBackground))
        }
    }

    /// One commit: its message and who wrote it, above the patch itself.
    private func commitDetail(_ commit: PullRequestCommit) -> some View {
        VStack(spacing: 0) {
            commitDetailBar(commit)
                .background(.bar)
            Divider()

            if let diff = item.commitDiffs[commit.sha], !diff.isEmpty {
                DiffView(
                    diff: diff,
                    layout: Binding(get: { item.diffLayout }, set: { item.diffLayout = $0 }),
                    selectedFile: Binding(
                        get: { item.commitDiffFile },
                        set: { item.commitDiffFile = $0 }
                    ),
                    // One commit of a pull request reads like any other commit:
                    // the file index waits until it is asked for.
                    showsFiles: Binding(
                        get: { item.showsDiffFileList },
                        set: { item.showsDiffFileList = $0 }
                    )
                )
            } else if item.isLoadingCommitDiff {
                ProgressView("Loading changes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No changes",
                    systemImage: "plusminus",
                    description: Text(
                        item.commitDiffError ?? "This commit has no textual changes."
                    )
                )
            }
        }
    }

    private func commitDetailBar(_ commit: PullRequestCommit) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Button {
                    item.selectedCommit = nil
                } label: {
                    Label("Commits", systemImage: "chevron.left")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back to the list of commits")
                .pointerCursor()

                Text(commit.shortSHA)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))

                barButton("doc.on.doc", help: "Copy “\(commit.shortSHA)”") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commit.sha, forType: .string)
                    store.showStatus("Commit hash copied")
                }
                if let url = commit.url {
                    barButton("safari", help: "Open this commit on \(pr.host.displayName)") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Spacer(minLength: 8)

                if let date = commit.date {
                    Text(date.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // The face leads the message, the way it leads every commit row.
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                AuthorAvatar(name: commit.author, url: commit.avatarURL, size: 16)
                    .alignmentGuide(.firstTextBaseline) { $0.height * 0.8 }
                CommitMessageText(
                    text: commit.headline,
                    font: .preferredFont(forTextStyle: .callout).weighted(.medium),
                    lineLimit: 2,
                    openReference: { store.openPullRequest(number: $0, project: project) }
                )
            }
            if !commit.body.isEmpty {
                CommitMessageText(
                    text: commit.body,
                    font: .preferredFont(forTextStyle: .caption1),
                    color: .secondaryLabelColor,
                    lineLimit: 4,
                    openReference: { store.openPullRequest(number: $0, project: project) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppMetrics.barHorizontalPadding)
        .padding(.vertical, 7)
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

// MARK: - Confirming an action

/// One of the things the action bar can do, on its way to being confirmed.
enum PullRequestAction: Identifiable, Hashable {
    case merge
    case review(PullRequestReviewDecision)
    case reject
    case updateBranch

    var id: String {
        switch self {
        case .merge: "merge"
        case .review(let decision): "review-\(decision.rawValue)"
        case .reject: "reject"
        case .updateBranch: "update-branch"
        }
    }
}

/// The one modal every button in the action bar goes through: what is about to
/// happen, room to say why, and the last chance to change one's mind.
///
/// A single sheet for all of them rather than an alert here and a dialog there,
/// so nothing reaches the host unconfirmed and every confirmation reads alike.
struct PullRequestActionSheet: View {
    let action: PullRequestAction
    let pr: PullRequest
    /// Warns on a merge when the branch is behind the one it targets — the host
    /// may refuse it, and what lands was not reviewed against where the target
    /// branch is now.
    let syncState: PullRequestSyncState?
    @Binding var strategy: PullRequestMergeStrategy
    let onCancel: () -> Void
    /// The comment goes with the review or the rejection; a merge and a branch
    /// update ignore it.
    let onConfirm: (String) -> Void

    /// Local to the sheet, so every confirmation starts on an empty box.
    @State private var comment = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if case .merge = action {
                VStack(spacing: 7) {
                    ForEach(PullRequestMergeStrategy.allCases) { option in
                        choice(option)
                    }
                }
            }

            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let prompt = commentPrompt {
                commentBox(prompt)
            }

            if case .merge = action, let syncState, syncState.isBehind {
                Label(
                    syncState.summary(target: pr.targetBranch)
                        + " Update the branch first if the host refuses.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
                Button(confirmTitle) { onConfirm(comment) }
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
                    .pointerCursor(canConfirm)
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint == .accentColor ? .primary : tint)
            HStack(spacing: 5) {
                Text(pr.sourceBranch)
                Image(systemName: "arrow.right")
                Text(pr.targetBranch)
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
    }

    private func commentBox(_ prompt: String) -> some View {
        TextEditor(text: $comment)
            .font(.body)
            .frame(height: 72)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .topLeading) {
                if comment.isEmpty {
                    Text(prompt)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
    }

    /// One way to merge, as a row that reads like what it does.
    private func choice(_ option: PullRequestMergeStrategy) -> some View {
        let isSelected = option == strategy
        return Button {
            strategy = option
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Label(option.title, systemImage: option.symbol)
                        .font(.callout.weight(.medium))
                    Text(option.detail(target: pr.targetBranch))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                .quaternary.opacity(isSelected ? 0.4 : 0.18),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - What this sheet is asking

    private var title: String {
        switch action {
        case .merge: "Merge #\(pr.number)"
        case .review(let decision): "\(decision.title) on #\(pr.number)"
        case .reject: "Reject #\(pr.number)"
        case .updateBranch: "Update \(pr.sourceBranch)"
        }
    }

    private var symbol: String {
        switch action {
        case .merge: "arrow.triangle.merge"
        case .review(let decision): decision.symbol
        case .reject: "xmark.circle"
        case .updateBranch: "arrow.down.to.line"
        }
    }

    private var tint: Color {
        switch action {
        case .merge: .accentColor
        case .review(let decision): decision == .approve ? .green : .orange
        case .reject: .red
        case .updateBranch: .orange
        }
    }

    private var explanation: String {
        switch action {
        case .merge:
            "The source branch is left alone; nothing is deleted."
        case .review(.approve):
            "Your approval is posted on \(pr.host.displayName), with the comment if you write one."
        case .review(.requestChanges):
            "Posted on \(pr.host.displayName) as a review asking for changes. It needs a comment saying what."
        case .reject:
            pr.host == .github
                ? "Closed without merging. It can be reopened on GitHub, and the source branch is left alone."
                : "Declined without merging. It can be reopened on Bitbucket, and the source branch is left alone."
        case .updateBranch:
            pr.host == .github
                ? "GitHub merges \(pr.targetBranch) into the pull request's branch. Your checkout is not touched."
                : "Bitbucket cannot do this on the server, so it runs in your checkout: fetch \(pr.targetBranch), merge it into \(pr.sourceBranch), and push. The branch must be checked out with nothing uncommitted."
        }
    }

    /// The placeholder in the comment box, or nil when this action takes none.
    private var commentPrompt: String? {
        switch action {
        case .review(let decision):
            decision.needsComment ? "What needs changing" : "Comment (optional)"
        case .reject:
            "Reason (optional)"
        case .merge, .updateBranch:
            nil
        }
    }

    private var confirmTitle: String {
        switch action {
        case .merge: strategy.title
        case .review(let decision): decision.title
        case .reject: "Reject Pull Request"
        case .updateBranch: "Update Branch"
        }
    }

    /// Only "request changes" insists on something being written first.
    private var canConfirm: Bool {
        guard case .review(let decision) = action, decision.needsComment else { return true }
        return !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Commits

/// One line of the commit list: hash, message, and who wrote it when. Clicking
/// anywhere on it opens that commit's own diff.
struct CommitRow: View {
    let commit: PullRequestCommit
    let onOpen: () -> Void
    /// Following a `#123` written in the message.
    let openPullRequest: (Int) -> Void

    @State private var isHovering = false
    /// The message draws itself in AppKit and reports the pointer separately,
    /// so the row keeps its highlight while the pointer is over the text.
    @State private var isHoveringMessage = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 9) {
                // Leads the row, as on the dashboard. The name is not written
                // out — hovering the face says it.
                AuthorAvatar(name: commit.author, url: commit.avatarURL, size: 16)

                Text(commit.shortSHA)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    // Held at its full size: a very long subject would otherwise
                    // squeeze the hash down to a stripe.
                    .fixedSize()

                VStack(alignment: .leading, spacing: 3) {
                    CommitMessageText(
                        text: commit.headline,
                        lineLimit: 2,
                        openReference: openPullRequest,
                        otherClick: onOpen,
                        hoverChanged: { isHoveringMessage = $0 }
                    )
                    HStack(spacing: 5) {
                        if let date = commit.date {
                            Text(date.formatted(.relative(presentation: .named)))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                // The subject gets the room the row has left over, rather than
                // splitting it with the gap that follows.
                .layoutPriority(1)

                Spacer(minLength: 6)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                .quaternary.opacity(isHovering || isHoveringMessage ? 0.34 : 0.22),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerCursor()
        .help("Show what \(commit.shortSHA) changed")
    }
}

/// One CI run: how it ended, what it is called, and the way to its log.
///
/// The whole row opens the log on the host — the arrow at its end is a sign of
/// where it goes, not the only thing that goes there. A build the host gave no
/// page for stays a plain row, since there would be nothing to open.
struct BuildRow: View {
    let build: PullRequestBuild

    @State private var isHovering = false

    var body: some View {
        if let url = build.url {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                content
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .pointerCursor()
            .help("Open \(build.name) on \(build.url?.host() ?? "the host")")
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: build.state.symbol)
                .foregroundStyle(color)
                .font(.callout)
                // Steady width, so the names line up down a mixed list rather
                // than shifting with each glyph.
                .frame(width: 16)
                // A running job says so by moving; the rest are still.
                .symbolEffect(.pulse, isActive: build.state == .running)

            VStack(alignment: .leading, spacing: 3) {
                Text(build.name)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(build.state.title)
                        .foregroundStyle(color)
                    if let detail = build.detail {
                        Text(detail).lineLimit(1)
                    }
                    if let duration = build.durationLabel {
                        Text(duration).foregroundStyle(.tertiary)
                    }
                    if let started = build.startedAt {
                        Text(started.formatted(.relative(presentation: .named)))
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            if build.url != nil {
                Image(systemName: "arrow.up.forward.app")
                    .font(.callout)
                    .foregroundStyle(isHovering ? .secondary : .tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .quaternary.opacity(isHovering ? 0.34 : 0.22),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private var color: Color {
        switch build.state {
        case .passed: .green
        case .failed: .red
        case .running: .blue
        case .pending: .orange
        case .cancelled, .skipped, .unknown: .secondary
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
                AuthorAvatar(name: comment.author, url: comment.avatarURL, size: 20)
                Text(comment.author)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(comment.authorColor)
                // The face already says a person wrote this, so the plain
                // comment icon is dropped; a review keeps its icon, which is
                // what carries approved versus changes requested.
                if case .review(let state) = comment.kind {
                    Image(systemName: comment.kind.symbol)
                        .foregroundStyle(tint)
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
