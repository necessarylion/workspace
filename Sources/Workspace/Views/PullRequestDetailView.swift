import AppKit
import SwiftUI

/// A pull request: metadata, description, conversation, and its diff.
///
/// A single slim bar says where the pull request comes from and goes to; the
/// tabs that pick what fills the rest of the window live up in the window
/// header, next to back and forward. Down the right, beside whichever tab is
/// open, ``PullRequestSidebar`` keeps the reviewers and the CI runs on screen.
struct PullRequestDetailView: View {
    @Environment(WorkspaceStore.self) private var store
    let item: ViewerItem
    let pr: PullRequest
    let project: Project

    /// How wide the side panel is, in this window. Unlike whether it is open —
    /// which each pull request remembers for itself — a width is a habit of the
    /// window rather than of the thing being read.
    @State private var sidebarWidth: CGFloat = 268

    /// The button that was pressed, waiting to be confirmed. Nothing in the
    /// action bar reaches the host until this has been through the sheet — and
    /// one piece of state for all of them keeps it that way, where four separate
    /// presentations would leave SwiftUI to drop one of them on macOS.
    @State private var pendingAction: PullRequestAction?
    /// Kept out here so the sheet reopens on the way that was picked last.
    @State private var mergeStrategy: PullRequestMergeStrategy = .squash

    /// The description being written, as Markdown — `nil` while it is only being
    /// read, which is what tells the two apart. It starts from what the host
    /// stores rather than from what is on screen, and `isFetchingDescription`
    /// covers the moment in between.
    @State private var descriptionDraft: String?
    @State private var isFetchingDescription = false

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
            // A merged or closed pull request has nothing left to approve,
            // merge or reject, so the whole row goes rather than sitting there
            // greyed out.
            if isOpen {
                actionBar
                    .background(.bar)
                Divider()
            }

            // The tab fills the window, with the panel beside it on Details
            // only: a diff and a commit's patch are read across the whole
            // width, so a second column of anything there is a column taken
            // from the code.
            HStack(spacing: 0) {
                Group {
                    switch item.pullRequestTab {
                    case .details: detailsTab
                    case .diff: diffTab
                    case .commits: commitsTab
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if item.pullRequestTab == .details {
                    PaneResizer(width: $sidebarWidth, range: 210...420, growsLeftwards: true)
                    PullRequestSidebar(
                        item: item,
                        pr: pr,
                        project: project,
                        isOpen: isOpen,
                        onAddReviewers: { pendingAction = .addReviewers }
                    )
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity)
                }
            }
        }
        // A half-written description belongs to the pull request it was opened
        // on, and this one view is reused as the viewer moves between them.
        .onChange(of: item.id) {
            descriptionDraft = nil
            isFetchingDescription = false
        }
        // Every button in the action bar ends up here first: one sheet, one
        // shape, and nothing sent to the host until it is confirmed.
        .sheet(item: $pendingAction) { action in
            // The one action that asks for names rather than for a comment has
            // its own sheet, presented through the same state as the rest.
            if case .addReviewers = action {
                PullRequestReviewerSheet(
                    item: item,
                    pr: pr,
                    project: project,
                    onCancel: { pendingAction = nil },
                    onAdd: { handles in
                        pendingAction = nil
                        Task {
                            await store.addReviewers(
                                handles,
                                on: item,
                                project: project,
                                pr: pr
                            )
                        }
                    }
                )
            } else {
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
            case .addReviewers:
                // Confirmed by its own sheet, which hands over the people it
                // picked rather than a comment.
                break
            }
        }
    }

    // MARK: - Summary bar

    /// Whether anything can still be done to this pull request on the host.
    /// Once it is merged or closed, approving, rejecting, merging and syncing
    /// the branch would all be refused — so none of them is offered. What is
    /// left to do is read it, which every other part of the view still does.
    private var isOpen: Bool { pr.state == .open }

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
            if let state = pr.state.badge {
                badge(state, color: pr.state == .merged ? .purple : .red)
            }
            if pr.isDraft {
                badge("Draft", color: .secondary)
            }
            if let review = pr.reviewLabel {
                badge(review, color: review == "Approved" ? .green : .orange)
            }
            approvalsBadge
            buildsBadge

            Spacer(minLength: 8)

            if item.pullRequestTab == .details, !item.comments.isEmpty {
                Text("\(item.comments.count) comments")
                    .foregroundStyle(.secondary)
            }
            if item.pullRequestTab == .commits, !item.commits.isEmpty {
                Text("\(item.commits.count) commits")
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

    /// How many of the people asked have approved, in the bar that stays on
    /// screen whichever tab is open — the one thing a reviewer checks before
    /// anything else. It is a button: clicking it opens the list of who they are
    /// and adds more.
    @ViewBuilder
    private var approvalsBadge: some View {
        // While the count is still being fetched the badge stays away rather
        // than reading "0/0" for a moment, and a host that would not answer
        // leaves it away altogether. A merged or closed request keeps the count
        // it ended on — there is nobody left to ask, so it stops being a button.
        if !item.reviewers.isEmpty {
            if isOpen {
                Button { pendingAction = .addReviewers } label: { approvalsChip }
                    .buttonStyle(.plain)
                    .help(approvalsHelp)
                    .pointerCursor()
            } else {
                approvalsChip.help(approvalsHelp)
            }
        } else if isOpen, !item.isLoadingReviewers, item.reviewersError == nil {
            Button { pendingAction = .addReviewers } label: { approvalsChip }
                .buttonStyle(.plain)
                .help(approvalsHelp)
                .pointerCursor()
        }
    }

    private var approvalsChip: some View {
        HStack(spacing: 3) {
            Image(systemName: item.reviewers.isEmpty ? "person.badge.plus" : "checkmark.seal")
            if !item.reviewers.isEmpty {
                Text("\(item.reviewers.approvedCount)/\(item.reviewers.count)")
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(approvalsColor.opacity(0.18), in: Capsule())
        .foregroundStyle(approvalsColor)
    }

    /// Green once everybody asked has approved, orange while anyone wants
    /// changes, and plain otherwise — nobody has said no, it is just not done.
    private var approvalsColor: Color {
        if item.reviewers.hasChangesRequested { return .orange }
        if item.reviewers.isFullyApproved { return .green }
        return .secondary
    }

    /// How CI stands, in one glyph beside the approvals. It is the reason the
    /// Builds tab could go: the news is in the bar whichever tab is open, and
    /// clicking it goes to the list — back to Details, where the panel is.
    /// Nothing is drawn until something has run: an empty badge would only be
    /// one more thing to read.
    @ViewBuilder
    private var buildsBadge: some View {
        if !item.builds.isEmpty {
            let state = worstBuildState
            Button {
                item.pullRequestTab = .details
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: state.symbol)
                    Text("\(item.builds.count)")
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(state.color.opacity(0.18), in: Capsule())
                .foregroundStyle(state.color)
            }
            .buttonStyle(.plain)
            .help(buildsHelp)
            .pointerCursor()
        }
    }

    /// The worst news among the runs — a single failure decides the badge, the
    /// same way it decides whether the pull request can be merged.
    private var worstBuildState: PullRequestBuild.State {
        for state in [PullRequestBuild.State.failed, .running, .pending] where
            item.builds.contains(where: { $0.state == state }) {
            return state
        }
        return item.builds.contains { $0.state == .passed } ? .passed : .unknown
    }

    private var buildsHelp: String {
        let names = item.builds
            .prefix(8)
            .map { "\($0.name) — \($0.state.title.lowercased())" }
            .joined(separator: "\n")
        return "\(item.builds.count) builds on the head commit\n\(names)"
    }

    private var approvalsHelp: String {
        guard !item.reviewers.isEmpty else {
            return isOpen
                ? "Nobody is reviewing #\(pr.number) yet — click to ask someone"
                : "Nobody reviewed #\(pr.number)"
        }
        let names = item.reviewers.byStanding
            .map { "\($0.name) — \($0.state.title.lowercased())" }
            .joined(separator: "\n")
        return "\(item.reviewers.approvalSummary)\n\(names)"
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

    /// Details, diff and commits, at the right end of the bar — the title of the
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
        .help("Details, diff and commits")
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

                    Spacer(minLength: 8)

                    if descriptionDraft == nil {
                        editDescriptionButton
                    }
                }
                .font(.callout)

                // Who is reviewing used to be a row here; it lives in the panel
                // down the right now, where it is on screen for the diff too.

                if let draft = descriptionDraft {
                    descriptionEditor(draft)
                } else if !pr.body.isEmpty {
                    MarkdownText(text: pr.body)
                        .font(.callout)
                }

                Divider()
            }
        }
    }

    // MARK: - The description

    /// Opens the editor on what the host has, which is not always what is on
    /// screen — see `PullRequestService.editableDescription`.
    private var editDescriptionButton: some View {
        Button {
            Task {
                isFetchingDescription = true
                let text = await store.editableDescription(project: project, pr: pr)
                isFetchingDescription = false
                descriptionDraft = text
            }
        } label: {
            if isFetchingDescription {
                ProgressView().controlSize(.small)
            } else {
                Label(
                    pr.body.isEmpty ? "Add a description" : "Edit",
                    systemImage: "square.and.pencil"
                )
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isFetchingDescription)
        .help("Edit the description as Markdown")
        .pointerCursor(!isFetchingDescription)
    }

    /// The description as its Markdown source: what is typed here is what the
    /// host stores, and the drawn version comes back once it is saved.
    private func descriptionEditor(_ draft: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            TextEditor(text: Binding(
                get: { descriptionDraft ?? "" },
                set: { descriptionDraft = $0 }
            ))
            .font(.system(.callout, design: .monospaced))
            .frame(height: editorHeight(for: draft))
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Describe the change, in Markdown…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 8) {
                Text(pr.host == .github ? "Markdown, saved with gh" : "Markdown, saved with bkt")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { descriptionDraft = nil }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                    .disabled(item.isRunningPullRequestAction)
                    .pointerCursor(!item.isRunningPullRequestAction)
                Button {
                    Task { await saveDescription(draft) }
                } label: {
                    if item.isRunningPullRequestAction {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Save", systemImage: "checkmark")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(item.isRunningPullRequestAction)
                // ⌘↩ belongs to the comment box further down the same page, so
                // saving takes the other key a Mac saves with.
                .keyboardShortcut("s", modifiers: .command)
                .pointerCursor(!item.isRunningPullRequestAction)
                .help("Save the description (⌘S)")
            }
        }
    }

    /// Sends the description to the host, and closes the editor once it is
    /// there. A refusal leaves the box open with the text still in it.
    private func saveDescription(_ draft: String) async {
        let saved = await store.updateDescription(draft, on: item, project: project, pr: pr)
        if saved { descriptionDraft = nil }
    }

    /// How tall the box stands: as tall as what is in it, within reason. A box
    /// that scrolls inside a page that scrolls is two scrolls fighting for the
    /// same wheel, so a description of any usual length gets to be one page.
    private func editorHeight(for draft: String) -> CGFloat {
        let lines = draft.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        return min(560, max(140, CGFloat(lines) * 17 + 20))
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
                    mentions: MentionSource(
                        people: item.reviewerCandidates,
                        host: pr.host,
                        load: {
                            await store.loadReviewerCandidates(item, project: project, pr: pr)
                        }
                    ),
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
            // A day at a time, headed the way the dashboard heads its own
            // history: the same list of the same thing, so it reads the same.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(CommitDay.group(item.commits)) { day in
                        VStack(alignment: .leading, spacing: 6) {
                            CommitDayHeading(
                                title: day.title,
                                count: day.commits.count
                            )
                            ForEach(day.commits) { commit in
                                CommitRow(
                                    commit: commit,
                                    onOpen: {
                                        Task {
                                            await store.showCommit(
                                                commit,
                                                on: item,
                                                project: project,
                                                pr: pr
                                            )
                                        }
                                    },
                                    openPullRequest: {
                                        store.openPullRequest(number: $0, project: project)
                                    }
                                )
                            }
                        }
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
    /// The comment whose inline reply box is open, if any.
    @State private var replyingTo: PullRequestComment?

    private var threads: [PullRequestCommentNode] {
        PullRequestComment.tree(from: item.comments)
    }

    /// Who an `@` names here, in the composer and in every reply box under it.
    private var mentions: MentionSource {
        MentionSource(
            people: item.reviewerCandidates,
            host: pr.host,
            load: { await store.loadReviewerCandidates(item, project: project, pr: pr) }
        )
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
                            mentions: mentions,
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

            // A line and a bit at rest, growing with what is written. Most
            // comments here are a sentence, and the box was taking room from
            // the thread above it to stand ready for an essay.
            MentionTextBox(
                text: $draft,
                prompt: "Write a comment…  @ to name someone",
                mentions: mentions,
                minHeight: 29,
                maxLines: 5
            )

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
    var mentions: MentionSource = .none
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
                    prompt: "Reply to \(node.comment.author)…  @ to name someone",
                    sendTitle: "Reply",
                    isPosting: isPosting,
                    mentions: mentions,
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
                            mentions: mentions,
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

// MARK: - Reviewers

/// The colour a reviewer's standing is drawn in, the same in the row of faces,
/// the badge in the bar, and the sheet.
extension PullRequestReviewer.State {
    var color: Color {
        switch self {
        case .approved: .green
        case .changesRequested: .orange
        case .commented: .blue
        case .pending: .secondary
        }
    }
}

/// One reviewer as a face with their verdict in the corner. The name is not
/// written out — hovering says it, the way a commit row does.
struct ReviewerFace: View {
    let reviewer: PullRequestReviewer
    var size: CGFloat = 22

    var body: some View {
        Group {
            if reviewer.isGroup {
                // A team has no single face; its own mark stands in for one.
                Image(systemName: "person.2.fill")
                    .font(.system(size: size * 0.5))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(.quaternary, in: Circle())
            } else {
                AuthorAvatar(name: reviewer.name, url: reviewer.avatarURL, size: size)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: reviewer.state.symbol)
                .font(.system(size: size * 0.42))
                .foregroundStyle(reviewer.state.color)
                // The glyph sits on the pane rather than on the face, so a dark
                // photograph behind it does not swallow it.
                .background(
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .frame(width: size * 0.58, height: size * 0.58)
                )
                .offset(x: 2, y: 2)
        }
        .help("\(reviewer.name) — \(reviewer.state.title)")
    }
}

/// Asking more people to review.
///
/// The list is a convenience, not the only way in: a host that will not hand
/// over its members leaves it empty, and the box at the top doubles as a place
/// to type a handle the list does not have.
struct PullRequestReviewerSheet: View {
    @Environment(WorkspaceStore.self) private var store
    let item: ViewerItem
    let pr: PullRequest
    let project: Project
    let onCancel: () -> Void
    /// The handles that were picked, in the order they will be sent.
    let onAdd: ([String]) -> Void

    @State private var query = ""
    @State private var picked: [String] = []
    @FocusState private var isSearching: Bool

    /// Whoever is already on the pull request, keyed the way the picker's rows
    /// are, so those rows can say so instead of offering them again.
    private var alreadyAsked: Set<String> {
        Set(item.reviewers.map { $0.id.lowercased() })
    }

    /// Everybody the host offered, minus the author: nobody reviews their own
    /// pull request. The list itself keeps them, because an `@` in a comment
    /// names the author more often than it names anyone else.
    private var candidates: [ReviewerCandidate] {
        item.reviewerCandidates.filter {
            $0.name.caseInsensitiveCompare(pr.author) != .orderedSame
                && $0.handle.caseInsensitiveCompare(pr.author) != .orderedSame
        }
    }

    private var matches: [ReviewerCandidate] {
        candidates.filter { $0.matches(query) }
    }

    /// The typed handle itself, offered as a row when it is not in the list —
    /// which is the only way in on a host that answered with nobody.
    private var typedHandle: String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count > 1 else { return nil }
        let isKnown = candidates.contains {
            $0.handle.caseInsensitiveCompare(trimmed) == .orderedSame
                || $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        return isKnown ? nil : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !item.reviewers.isEmpty {
                current
            }

            TextField(
                pr.host == .github
                    ? "Search or type a GitHub login"
                    : "Search or type a Bitbucket username",
                text: $query
            )
            .textFieldStyle(.roundedBorder)
            .focused($isSearching)

            // Says what the rows below are: with the box empty they are a
            // suggestion, and once something is typed they are what matched.
            if !candidates.isEmpty {
                Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "Suggested — \(candidates.count) people who can review"
                    : "\(matches.count) of \(candidates.count) match “\(query)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            candidateList

            if !picked.isEmpty {
                Text(picked.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Text(pr.host == .github ? "Sent with gh pr edit" : "Sent with bkt pr edit")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
                Button(confirmTitle) { onAdd(picked) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty)
                    .pointerCursor(!picked.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 440)
        // The list costs a call to the host, so it is read here rather than
        // alongside the pull request — and only once per pull request.
        .task {
            isSearching = true
            await store.loadReviewerCandidates(item, project: project, pr: pr)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Reviewers on #\(pr.number)", systemImage: "person.2.badge.plus")
                .font(.title3.weight(.semibold))
            Text(item.reviewers.approvalSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Who is on it already, and what each of them said. This is the full list
    /// the row of faces in the Details tab only shows the first few of.
    private var current: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(item.reviewers.byStanding) { reviewer in
                HStack(spacing: 7) {
                    ReviewerFace(reviewer: reviewer, size: 20)
                    Text(reviewer.name)
                        .font(.callout)
                    Spacer(minLength: 6)
                    Text(reviewer.state.title)
                        .font(.caption)
                        .foregroundStyle(reviewer.state.color)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var candidateList: some View {
        if item.isLoadingReviewerCandidates {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Reading who can review…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 150, alignment: .top)
        } else if matches.isEmpty && typedHandle == nil {
            Text(candidates.isEmpty
                ? "\(pr.host.displayName) did not say who can review this. Type a handle above and it is sent as it is."
                : "Nobody here matches “\(query)”.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(height: 150, alignment: .top)
        } else {
            ScrollView {
                VStack(spacing: 4) {
                    if let typedHandle {
                        row(
                            handle: typedHandle,
                            name: "Ask “\(typedHandle)”",
                            detail: "Sent to \(pr.host.displayName) as typed",
                            avatarURL: nil
                        )
                    }
                    ForEach(matches) { candidate in
                        row(
                            handle: candidate.handle,
                            name: candidate.name,
                            detail: candidate.detail,
                            avatarURL: candidate.avatarURL
                        )
                    }
                }
            }
            .frame(height: 150)
        }
    }

    /// One person the picker offers. Someone already on the pull request stays
    /// on the list, greyed out and saying so, rather than quietly missing.
    private func row(
        handle: String,
        name: String,
        detail: String?,
        avatarURL: URL?
    ) -> some View {
        let isAsked = alreadyAsked.contains(handle.lowercased())
        let isPicked = picked.contains { $0.caseInsensitiveCompare(handle) == .orderedSame }
        return Button {
            if isPicked {
                picked.removeAll { $0.caseInsensitiveCompare(handle) == .orderedSame }
            } else {
                picked.append(handle)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isPicked ? Color.accentColor : .secondary)
                AuthorAvatar(name: name, url: avatarURL, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.callout)
                        .lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if isAsked {
                    Text("Already asked")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                .quaternary.opacity(isPicked ? 0.35 : 0.12),
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
        .buttonStyle(.plain)
        .disabled(isAsked)
        .opacity(isAsked ? 0.55 : 1)
        .pointerCursor(!isAsked)
    }

    private var confirmTitle: String {
        switch picked.count {
        case 0, 1: "Add Reviewer"
        default: "Add \(picked.count) Reviewers"
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
    /// Asking other people to review. It rides in the same state as the rest so
    /// that only one sheet is ever presented — see `pendingAction` — but it
    /// carries a list of people rather than a comment, so it gets its own sheet.
    case addReviewers

    var id: String {
        switch self {
        case .merge: "merge"
        case .review(let decision): "review-\(decision.rawValue)"
        case .reject: "reject"
        case .updateBranch: "update-branch"
        case .addReviewers: "add-reviewers"
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
        // Reviewers have a sheet of their own; this one never shows them.
        case .addReviewers: "Add reviewers to #\(pr.number)"
        }
    }

    private var symbol: String {
        switch action {
        case .merge: "arrow.triangle.merge"
        case .review(let decision): decision.symbol
        case .reject: "xmark.circle"
        case .updateBranch: "arrow.down.to.line"
        case .addReviewers: "person.2.badge.plus"
        }
    }

    private var tint: Color {
        switch action {
        case .merge: .accentColor
        case .review(let decision): decision == .approve ? .green : .orange
        case .reject: .red
        case .updateBranch: .orange
        case .addReviewers: .accentColor
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
        case .addReviewers:
            "The people you pick are asked to review on \(pr.host.displayName)."
        }
    }

    /// The placeholder in the comment box, or nil when this action takes none.
    private var commentPrompt: String? {
        switch action {
        case .review(let decision):
            decision.needsComment ? "What needs changing" : "Comment (optional)"
        case .reject:
            "Reason (optional)"
        case .merge, .updateBranch, .addReviewers:
            nil
        }
    }

    private var confirmTitle: String {
        switch action {
        case .merge: strategy.title
        case .review(let decision): decision.title
        case .reject: "Reject Pull Request"
        case .updateBranch: "Update Branch"
        case .addReviewers: "Add Reviewers"
        }
    }

    /// Only "request changes" insists on something being written first.
    private var canConfirm: Bool {
        guard case .review(let decision) = action, decision.needsComment else { return true }
        return !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Commits

/// One line of the pull request's commit list: face, hash, subject, and the
/// hour it landed — the same row the dashboard draws for the repository's own
/// history, so the two lists of the same thing read alike.
///
/// What differs is where the click goes. On the dashboard the whole row opens
/// the commit; here **only the hash does**, and it is drawn as a link to say so.
/// The row is a place to read the pull request's history rather than a stack of
/// buttons, and the subject is full of `#123` references that go somewhere else
/// entirely.
struct CommitRow: View {
    let commit: PullRequestCommit
    let onOpen: () -> Void
    /// Following a `#123` written in the message.
    let openPullRequest: (Int) -> Void

    @State private var isHoveringHash = false

    var body: some View {
        HStack(spacing: 9) {
            // Leads the row, as on the dashboard: the faces line up into a
            // column, which is the fastest way to find one person's commits.
            // The name is not written out — hovering the face says it.
            AuthorAvatar(name: commit.author, url: commit.avatarURL, size: 16)

            hash

            CommitMessageText(
                text: commit.headline,
                openReference: openPullRequest
            )
            // The subject gets the room the row has left over, rather than
            // splitting it with the gap that follows.
            .layoutPriority(1)

            Spacer(minLength: 8)

            // The day is already in the heading above, so the row only needs
            // the hour it landed at.
            if let date = commit.date {
                Text(date.formatted(date: .omitted, time: .shortened))
                    .foregroundStyle(.tertiary)
                    // For the same reason as the hash: the hour reads across,
                    // never one letter to a line.
                    .fixedSize()
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Copy Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.sha, forType: .string)
            }
            Button("Copy Message") {
                NSPasteboard.general.clearContents()
                let message = commit.body.isEmpty
                    ? commit.headline
                    : "\(commit.headline)\n\n\(commit.body)"
                NSPasteboard.general.setString(message, forType: .string)
            }
        }
    }

    /// The one thing on the row that goes somewhere. Blue and underlined under
    /// the pointer, the same as a `#123` in the subject beside it — the link
    /// colour is what says which parts of a row are worth clicking.
    private var hash: some View {
        Button(action: onOpen) {
            Text(commit.shortSHA)
                .font(.caption.monospaced())
                .foregroundStyle(Color(nsColor: .linkColor))
                .underline(isHoveringHash)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(RoundedRectangle(cornerRadius: 4))
                // Held at its full size: a 200-character merge subject would
                // otherwise squeeze the hash down to a stripe.
                .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { isHoveringHash = $0 }
        .pointerCursor()
        .help("Show what \(commit.shortSHA) changed")
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
