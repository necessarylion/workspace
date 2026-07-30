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

    /// The button that was pressed, waiting to be confirmed. Nothing in the
    /// action bar reaches the host until this has been through the sheet — and
    /// one piece of state for all of them keeps it that way, where four separate
    /// presentations would leave SwiftUI to drop one of them on macOS.
    @State private var pendingAction: PullRequestAction?
    /// Kept out here so the sheet reopens on the way that was picked last.
    @State private var mergeStrategy: PullRequestMergeStrategy = .squash

    /// The description the editor was opened on, as Markdown — `nil` while it is
    /// only being read, which is what tells the two apart. It starts from what
    /// the host stores rather than from what is on screen, and
    /// `isFetchingDescription` covers the moment in between.
    ///
    /// What is *typed* lives in the editor's own state rather than here: a
    /// keystroke landing on this view would redraw the conversation under it,
    /// comment by comment, on every letter.
    @State private var descriptionDraft: String?
    @State private var isFetchingDescription = false

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
                    .transition(.opacity)
                Divider()
                    .transition(.opacity)
            }

            // The tab fills the window, with the panel beside it on Details
            // only: a diff and a commit's patch are read across the whole
            // width, so a second column of anything there is a column taken
            // from the code.
            HStack(spacing: 0) {
                // The transition rides on each tab rather than on the `Group`
                // around them. The group is always here; what arrives and
                // leaves is the branch, and a transition only runs on the view
                // actually being inserted or removed.
                Group {
                    switch item.pullRequestTab {
                    case .details: detailsTab.transition(ViewerMotion.contentArrival)
                    case .diff: diffTab.transition(ViewerMotion.contentArrival)
                    case .commits: commitsTab.transition(ViewerMotion.contentArrival)
                    }
                }
                // A tab is a lighter thing than opening a pull request: the two
                // bars above and the panel beside stay exactly where they are,
                // so the arriving tab only fades up rather than rising the way
                // a whole new item does.
                //
                // The animation is scoped to this view rather than put on the
                // row on purpose. The panel comes and goes with Details, and an
                // animated row would drag the width of whatever is open through
                // every frame of that — a diff re-laying a thousand rows to end
                // up where it already was. Here the row snaps to its new widths
                // at once and only the contents fade.
                .animation(ViewerMotion.contentChange, value: item.pullRequestTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if item.pullRequestTab == .details {
                    PullRequestSidebarPane(
                        item: item,
                        pr: pr,
                        project: project,
                        isOpen: isOpen,
                        onAddReviewers: { pendingAction = .addReviewers }
                    )
                }
            }
        }
        // Merging or rejecting takes a whole bar out from under everything
        // below it, and the page used to jump the height of it. Keyed to
        // `isOpen` and nothing else: the only update that ever runs inside this
        // transaction is the one that ended the pull request, so a build tick,
        // a keystroke or a comment landing still redraws with nothing animated.
        .animation(ViewerMotion.contentChange, value: isOpen)
        // Set once for the whole page: the description, every comment and every
        // reply nested under one are all this repository's Markdown, so a
        // `#123` in any of them is this repository's pull request.
        .environment(\.markdownLinks, MarkdownLinks(remote: project.remote))
        // A half-written description belongs to the pull request it was opened
        // on, and this one view is reused as the viewer moves between them.
        .onChange(of: item.id) {
            descriptionDraft = nil
            isFetchingDescription = false
        }
        .task(id: item.id) { await watchBuilds() }
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

    /// Reads the CI runs, and goes on reading them for as long as this pull
    /// request is the one on screen.
    ///
    /// The app watches for things rather than polling for them, and this is the
    /// deliberate exception: a build finishing is not an event either host
    /// tells us about, so the window asks. It asks narrowly — SwiftUI cancels
    /// this task when the pull request is closed or another takes its place, so
    /// the loop dies with what it belongs to, and a window nobody is in front
    /// of spends nothing on the host.
    ///
    /// It lives here rather than in the panel that draws the runs because the
    /// badge in the summary bar reads them too, and that bar is on screen on
    /// the Diff and Commits tabs, where the panel is not.
    private func watchBuilds() async {
        if item.builds.isEmpty, !item.isLoadingBuilds, item.buildsError == nil {
            await store.loadBuilds(item, project: project, pr: pr)
        }

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            // Nothing behind a hidden window, and nothing on top of a reload
            // already on its way with a spinner of its own. Either way the next
            // tick tries again.
            guard NSApplication.shared.isActive, !item.isLoadingBuilds else { continue }
            await store.refreshBuilds(item, project: project, pr: pr)
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
                Text("+\(additions)")
                    .foregroundStyle(.green)
                    .transition(ViewerMotion.contentArrival)
                Text("−\(deletions)")
                    .foregroundStyle(.red)
                    .transition(ViewerMotion.contentArrival)
            }
            if let state = pr.state.badge {
                badge(state, color: pr.state == .merged ? .purple : .red)
                    .transition(ViewerMotion.contentArrival)
            }
            if pr.isDraft {
                badge("Draft", color: .secondary)
                    .transition(ViewerMotion.contentArrival)
            }
            if let review = pr.reviewLabel {
                badge(review, color: review == "Approved" ? .green : .orange)
                    .transition(ViewerMotion.contentArrival)
            }
            approvalsBadge
            // Its own view, and it is the view that reads the runs: the ticker
            // behind them writes every ten seconds, and this bar is the top of
            // the page the conversation hangs under.
            PullRequestBuildsBadge(item: item) { item.pullRequestTab = .details }

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
            refreshButton
            actionsMenu
        }
        .font(.caption.monospaced())
        // The badges arrive one after another as the host answers, and each of
        // them widens the row. What fades is the badge, never the row: the
        // transition is on each of them, and the transaction here is keyed to
        // which badges there are — so the ten-second build tick and every
        // keystroke in the page below still land with nothing animated.
        .animation(ViewerMotion.badgeChange, value: badgeSignature)
        // Same inset as the header above it, so the tab picker at this end of
        // the row sits directly under the navigator's.
        .padding(.horizontal, AppMetrics.barHorizontalPadding)
        .padding(.vertical, 7)
    }

    /// Which badges the bar is showing, as one value to key the fade on.
    ///
    /// Deliberately not the pull request itself: a refresh rewrites every field
    /// of it, and animating on the whole thing would put a fade on a title that
    /// came back the same. `item.builds` is not in here either — reading it
    /// would make this view one that the ticker redraws, which is the whole
    /// reason ``PullRequestBuildsBadge`` is a view of its own.
    private var badgeSignature: String {
        """
        \(pr.state.badge ?? "")|\(pr.isDraft)|\(pr.reviewLabel ?? "")\
        |\(pr.additions ?? -1)|\(pr.deletions ?? -1)|\(item.reviewers.isEmpty)
        """
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
                    .transition(ViewerMotion.contentArrival)
            } else {
                approvalsChip
                    .help(approvalsHelp)
                    .transition(ViewerMotion.contentArrival)
            }
        } else if isOpen, !item.isLoadingReviewers, item.reviewersError == nil {
            Button { pendingAction = .addReviewers } label: { approvalsChip }
                .buttonStyle(.plain)
                .help(approvalsHelp)
                .pointerCursor()
                .transition(ViewerMotion.contentArrival)
        }
    }

    private var approvalsChip: some View {
        HStack(spacing: 3) {
            Image(systemName: item.reviewers.isEmpty ? "person.badge.plus" : "checkmark.seal")
            if !item.reviewers.isEmpty {
                // An approval landing is the one number in this bar worth
                // watching change, so the digits roll rather than swap.
                Text("\(item.reviewers.approvedCount)/\(item.reviewers.count)")
                    .contentTransition(.numericText())
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(approvalsColor.opacity(0.18), in: Capsule())
        .foregroundStyle(approvalsColor)
        // Scoped to the chip, and keyed to the two things it draws: the count
        // it says and the colour it says it in. Nothing else in the bar is
        // inside this, so nothing else is ever animated by it.
        .animation(ViewerMotion.badgeChange, value: item.reviewers.approvalSummary)
        .animation(ViewerMotion.badgeChange, value: approvalsColor)
    }

    /// Green once everybody asked has approved, orange while anyone wants
    /// changes, and plain otherwise — nobody has said no, it is just not done.
    private var approvalsColor: Color {
        if item.reviewers.hasChangesRequested { return .orange }
        if item.reviewers.isFullyApproved { return .green }
        return .secondary
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

    /// Everything about the pull request, read again from the host. It is the
    /// one thing here that is wanted often enough to be worth a click rather
    /// than a trip through the menu, so it sits in the bar as well.
    private var refreshButton: some View {
        // Stacked rather than swapped in the row. Both are alive for the length
        // of the fade, and side by side in the bar they would push the menu
        // beside them along and back again; in one slot the bar is as wide
        // either way, and at rest there is only ever one of them in it.
        ZStack {
            // Same treatment the action bar gives a merge or a sync: while it is
            // in flight the bar says so, and there is nothing to press.
            if item.isRefreshingPullRequest {
                ProgressView()
                    .controlSize(.small)
                    .transition(ViewerMotion.contentArrival)
            } else {
                barButton(
                    "arrow.clockwise",
                    help: "Reload #\(pr.number) from \(pr.host.displayName)"
                ) {
                    refresh()
                }
                .disabled(item.isRunningPullRequestAction)
                .transition(ViewerMotion.contentArrival)
            }
        }
        .animation(ViewerMotion.badgeChange, value: item.isRefreshingPullRequest)
    }

    private func refresh() {
        Task { await store.refreshPullRequest(item, project: project, pr: pr) }
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
                refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
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

                // The drawn description and the box it is edited in are the same
                // words twice over, so the one becomes the other rather than
                // being replaced. Keyed to which of them is open and to nothing
                // else — the box grows with what is typed into it, and a height
                // on a curve is a text view laid out again on every letter.
                Group {
                    if let draft = descriptionDraft {
                        PullRequestDescriptionEditor(
                            initialText: draft,
                            host: pr.host,
                            isSaving: item.isRunningPullRequestAction,
                            onCancel: { descriptionDraft = nil },
                            onSave: { text in await saveDescription(text) }
                        )
                        .transition(ViewerMotion.contentArrival)
                    } else if !pr.body.isEmpty {
                        MarkdownText(text: pr.body)
                            .environment(
                                \.markdownTaskToggle,
                                MarkdownTaskToggle(
                                    target: "pr-\(pr.number)-description",
                                    // The action below asks the host for the
                                    // description when it runs, so nothing
                                    // stale can be captured — but the body is
                                    // still what it was built for, and saying
                                    // so keeps every one of these honest.
                                    content: pr.body,
                                    perform: toggleDescriptionTask
                                )
                            )
                            .font(.callout)
                            .transition(ViewerMotion.contentArrival)
                    }
                }
                .animation(ViewerMotion.contentChange, value: descriptionDraft == nil)

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

    /// Sends the description to the host, and closes the editor once it is
    /// there. A refusal leaves the box open with the text still in it.
    private func saveDescription(_ draft: String) async {
        let saved = await store.updateDescription(draft, on: item, project: project, pr: pr)
        if saved { descriptionDraft = nil }
    }

    /// Ticking a box in the description. There is no half of a description to
    /// save, so the whole of it is written back — from what the host holds
    /// rather than from what is drawn, for the same reason the edit box opens
    /// on that: replacing a Bitbucket mention with the name beside it would
    /// post the name as words and lose the mention.
    private func toggleDescriptionTask(line: Int, isDone: Bool) {
        Task {
            let source = await store.editableDescription(project: project, pr: pr)
            guard let updated = MarkdownTask.toggling(line: line, to: isDone, in: source) else { return }
            _ = await store.updateDescription(updated, on: item, project: project, pr: pr)
        }
    }

    private var diffTab: some View {
        // The spinner and the diff share the pane, so the one gives way to the
        // other rather than being cut to it. Keyed to `isLoading` alone: a diff
        // already on screen redraws with nothing animated, which is what keeps
        // the rows out of it.
        Group {
            if item.isLoading {
                placeholder {
                    ProgressView("Loading diff…")
                }
                .transition(ViewerMotion.contentArrival)
            } else if let diff = item.diff, !diff.isEmpty {
                DiffView(
                    diff: diff,
                    layout: Binding(get: { item.diffLayout }, set: { item.diffLayout = $0 }),
                    selectedFile: Binding(get: { item.diffFile }, set: { item.diffFile = $0 }),
                    comments: DiffComments(
                        threads: item.inlineCommentThreads,
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
                        },
                        resolve: { comment, resolved in
                            await store.setCommentResolved(
                                resolved,
                                for: comment,
                                on: item,
                                project: project,
                                pr: pr
                            )
                        },
                        edit: { comment, body in
                            await store.updateComment(
                                body,
                                of: comment,
                                on: item,
                                project: project,
                                pr: pr
                            )
                        }
                    )
                )
                .transition(ViewerMotion.contentArrival)
            } else {
                placeholder {
                    ContentUnavailableView(
                        "No diff",
                        systemImage: "plusminus",
                        description: Text(
                            item.errorMessage ?? "This pull request has no textual changes."
                        )
                    )
                }
                .transition(ViewerMotion.contentArrival)
            }
        }
        .animation(ViewerMotion.contentChange, value: item.isLoading)
    }

    /// A tab with nothing in it yet — reading, or nothing to read.
    ///
    /// It carries the pane's own colour, which is what the diff and the commit
    /// list both paint for themselves. A tab arriving has to cover the one it
    /// replaces rather than come up through it, and these stand where those two
    /// would be.
    private func placeholder<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: AppColors.viewerBackground))
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

    private var commitList: some View {
        Group {
            if item.isLoadingCommits && item.commits.isEmpty {
                placeholder {
                    ProgressView("Loading commits…")
                }
                .transition(ViewerMotion.contentArrival)
            } else if item.commits.isEmpty {
                placeholder {
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
                }
                .transition(ViewerMotion.contentArrival)
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
                .transition(ViewerMotion.contentArrival)
            }
        }
        // The list arriving over the spinner, and nothing else: the rows
        // themselves are never in a transaction of their own.
        .animation(ViewerMotion.contentChange, value: item.isLoadingCommits)
    }

    /// One commit: its message and who wrote it, above the patch itself.
    private func commitDetail(_ commit: PullRequestCommit) -> some View {
        VStack(spacing: 0) {
            commitDetailBar(commit)
                .background(.bar)
                // Opaque while it arrives — see `DiffLayoutBar`, which carries
                // the same colour under the same material for the same reason.
                .background(Color(nsColor: AppColors.viewerBackground))
            Divider()

            Group {
                if let diff = item.commitDiffs[commit.sha], !diff.isEmpty {
                    DiffView(
                        diff: diff,
                        layout: Binding(get: { item.diffLayout }, set: { item.diffLayout = $0 }),
                        selectedFile: Binding(
                            get: { item.commitDiffFile },
                            set: { item.commitDiffFile = $0 }
                        ),
                        // One commit of a pull request reads like any other
                        // commit: the file index waits until it is asked for.
                        showsFiles: Binding(
                            get: { item.showsDiffFileList },
                            set: { item.showsDiffFileList = $0 }
                        )
                    )
                    .transition(ViewerMotion.contentArrival)
                } else if item.isLoadingCommitDiff {
                    placeholder {
                        ProgressView("Loading changes…")
                    }
                    .transition(ViewerMotion.contentArrival)
                } else {
                    placeholder {
                        ContentUnavailableView(
                            "No changes",
                            systemImage: "plusminus",
                            description: Text(
                                item.commitDiffError ?? "This commit has no textual changes."
                            )
                        )
                    }
                    .transition(ViewerMotion.contentArrival)
                }
            }
            .animation(ViewerMotion.contentChange, value: item.isLoadingCommitDiff)
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

// MARK: - The bar's own pieces

/// How CI stands, in one glyph beside the approvals. It is the reason the
/// Builds tab could go: the news is in the bar whichever tab is open, and
/// clicking it goes to the list — back to Details, where the panel is. Nothing
/// is drawn until something has run: an empty badge would only be one more
/// thing to read.
///
/// A view of its own so that **this** is what reads `builds`. The list is
/// re-read every ten seconds for as long as the pull request is open, and while
/// the badge lived in the bar's own body every one of those ticks that found a
/// job had moved on redrew the page of comments below it.
struct PullRequestBuildsBadge: View {
    let item: ViewerItem
    let onTap: () -> Void

    @ViewBuilder
    var body: some View {
        if !item.builds.isEmpty {
            let state = worstState
            Button(action: onTap) {
                HStack(spacing: 3) {
                    Image(systemName: state.symbol)
                    // A job appearing or dropping off is a number changing, and
                    // it changes while nobody is looking at it — so the digits
                    // roll rather than being replaced between two frames.
                    Text("\(item.builds.count)")
                        .contentTransition(.numericText())
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(state.color.opacity(0.18), in: Capsule())
                .foregroundStyle(state.color)
                // The one place on the page it is safe to animate the ticker:
                // this view is the whole of what the ten-second read redraws,
                // and the transaction reaches nothing outside it.
                .animation(ViewerMotion.badgeChange, value: item.builds.count)
                .animation(ViewerMotion.badgeChange, value: state)
            }
            .buttonStyle(.plain)
            .help(help)
            .pointerCursor()
        }
    }

    /// The worst news among the runs — a single failure decides the badge, the
    /// same way it decides whether the pull request can be merged.
    private var worstState: PullRequestBuild.State {
        for state in [PullRequestBuild.State.failed, .running, .pending] where
            item.builds.contains(where: { $0.state == state }) {
            return state
        }
        return item.builds.contains { $0.state == .passed } ? .passed : .unknown
    }

    private var help: String {
        let names = item.builds
            .prefix(8)
            .map { "\($0.name) — \($0.state.title.lowercased())" }
            .joined(separator: "\n")
        return "\(item.builds.count) builds on the head commit\n\(names)"
    }
}

/// The side panel, and the seam that sizes it.
///
/// One view for the two of them because of what the seam does: a drag writes a
/// width many times a second, and every one of those writes redraws whatever
/// view holds it. Held a level up, beside the tab, that was the conversation —
/// each frame of the drag rebuilding every comment on the pull request. Here
/// the width reaches nothing but the panel it is the width of.
struct PullRequestSidebarPane: View {
    let item: ViewerItem
    let pr: PullRequest
    let project: Project
    let isOpen: Bool
    let onAddReviewers: () -> Void

    /// How wide the panel is, in this window. Unlike whether it is open — which
    /// each pull request remembers for itself — a width is a habit of the window
    /// rather than of the thing being read.
    @State private var width: CGFloat = 268

    var body: some View {
        HStack(spacing: 0) {
            PaneResizer(width: $width, range: 210...420, growsLeftwards: true)
            PullRequestSidebar(
                item: item,
                pr: pr,
                project: project,
                isOpen: isOpen,
                onAddReviewers: onAddReviewers
            )
            .frame(width: width)
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - The description

/// The description as its Markdown source: what is typed here is what the host
/// stores, and the drawn version comes back once it is saved.
///
/// A view of its own so that the text being written lives beside the box it is
/// written in. Held a level up, in the whole pull request's view, every letter
/// redrew the summary bar, the side panel and every comment on the page.
struct PullRequestDescriptionEditor: View {
    /// What the host has, which is what the box opens on — see
    /// `PullRequestService.editableDescription`.
    let initialText: String
    let host: GitHostKind
    /// A save is already on its way, so nothing else may be asked.
    let isSaving: Bool
    let onCancel: () -> Void
    let onSave: (String) async -> Void

    @State private var draft: String

    init(
        initialText: String,
        host: GitHostKind,
        isSaving: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) async -> Void
    ) {
        self.initialText = initialText
        self.host = host
        self.isSaving = isSaving
        self.onCancel = onCancel
        self.onSave = onSave
        _draft = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextEditor(text: $draft)
                .font(.system(.callout, design: .monospaced))
                .frame(height: editorHeight)
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
                Text(host == .github ? "Markdown, saved with gh" : "Markdown, saved with bkt")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                    .pointerCursor(!isSaving)
                Button {
                    Task { await onSave(draft) }
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Save", systemImage: "checkmark")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isSaving)
                // Post belongs to the comment box further down the same page, so
                // saving takes the app's Save key instead.
                .shortcut(.save)
                .pointerCursor(!isSaving)
                .shortcutHelp("Save the description", .save)
            }
        }
    }

    /// How tall the box stands: as tall as what is in it, within reason. A box
    /// that scrolls inside a page that scrolls is two scrolls fighting for the
    /// same wheel, so a description of any usual length gets to be one page.
    private var editorHeight: CGFloat {
        let lines = draft.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        return min(560, max(140, CGFloat(lines) * 17 + 20))
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

    /// The comment whose inline reply box is open, if any.
    @State private var replyingTo: PullRequestComment?
    /// The comment being rewritten, if any.
    @State private var editing: PullRequestComment?

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

                    // What the page says while there is nothing to say. The
                    // transaction is on this group alone and keyed to the read
                    // itself: the stack around it holds every comment on the
                    // pull request, and a fade put there would run over all of
                    // them every time a letter is typed in the box below.
                    Group {
                        if item.isLoadingComments {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text("Loading conversation…").foregroundStyle(.secondary)
                            }
                            .padding(.top, 8)
                            .transition(ViewerMotion.contentArrival)
                        } else if let error = item.commentError, item.comments.isEmpty {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .transition(ViewerMotion.contentArrival)
                        } else if item.comments.isEmpty {
                            Text("No comments yet.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .transition(ViewerMotion.contentArrival)
                        }
                    }
                    .animation(ViewerMotion.contentChange, value: item.isLoadingComments)

                    // Threaded once, where the comments landed — see
                    // `ViewerItem.commentThreads`.
                    ForEach(item.commentThreads) { thread in
                        CommentThread(
                            node: thread,
                            depth: 0,
                            replyingTo: $replyingTo,
                            editing: $editing,
                            isPosting: item.isPostingComment,
                            mentions: mentions,
                            onReply: { parent, body in
                                await post(body, replyingTo: parent)
                            },
                            onResolve: { comment, resolved in
                                await store.setCommentResolved(
                                    resolved,
                                    for: comment,
                                    on: item,
                                    project: project,
                                    pr: pr
                                )
                            },
                            onEdit: { comment, body in
                                await store.updateComment(
                                    body,
                                    of: comment,
                                    on: item,
                                    project: project,
                                    pr: pr
                                )
                            }
                        )
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            // Its own view, so that what is being typed stays in the box: this
            // one holds every comment on the pull request, and a letter landing
            // here would draw all of them again.
            ConversationComposer(
                host: pr.host,
                // Only once there is something above it to have failed against;
                // an empty conversation says so where the comments would be.
                error: item.comments.isEmpty ? nil : item.commentError,
                isPosting: item.isPostingComment,
                mentions: mentions,
                onPost: post
            )
            // The draft lives inside the composer, so this is the only way to
            // end it: a half-written comment belongs to the pull request it was
            // written on, and this whole view is reused as the viewer moves
            // between them. Without it the text typed for one is still in the
            // box on the next, and the button posts it there.
            .id(item.id)
        }
        // The same argument for the reply box that is open under a comment. It
        // is held here rather than inside the composer, so it can simply be put
        // down; the comment it names is not on the pull request that arrived.
        .onChange(of: item.id) {
            replyingTo = nil
            editing = nil
        }
        // The pane's own colour, which the diff and the commit list each paint
        // for themselves and the conversation did not. It is the same shade the
        // viewer already draws behind all three, so nothing looks different at
        // rest — what it buys is a tab arriving over this one covering it,
        // instead of a page of comments coming up through a page of code.
        .background(Color(nsColor: AppColors.viewerBackground))
    }

    /// Posts what was written, and says whether it landed — which is what
    /// empties the box.
    private func post(_ body: String) async -> Bool {
        await store.postComment(body, on: item, project: project, pr: pr)
        return item.commentError == nil
    }

    /// Posts a reply and closes the inline box once it lands.
    private func post(_ body: String, replyingTo parent: PullRequestComment) async {
        await store.postComment(body, on: item, project: project, pr: pr, replyingTo: parent)
        if item.commentError == nil {
            replyingTo = nil
        }
    }
}

/// The box at the foot of the conversation, and the button that sends it.
///
/// It owns the text being written. The conversation above it is a page of
/// comments, each of them a rendered piece of Markdown, and a draft held up
/// there meant redrawing all of it on every keystroke.
struct ConversationComposer: View {
    let host: GitHostKind
    /// What the host said about the last attempt, when there is a conversation
    /// above for it to have failed against.
    let error: String?
    let isPosting: Bool
    var mentions: MentionSource = .none
    /// Sends the comment, and says whether it landed. It empties the box only
    /// when it did — a refusal leaves what was written where it is.
    let onPost: (String) async -> Bool

    @State private var draft = ""

    private var isEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let error {
                // It lands a moment after Post was pressed, and the eye is on
                // the button rather than on the line above it — so it comes up
                // from the box instead of simply being there.
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
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
                Text(host == .github ? "Posted with gh" : "Posted with bkt")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    Task { await post() }
                } label: {
                    if isPosting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Comment", systemImage: "paperplane")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isPosting || isEmpty)
                .shortcut(.submit)
                .pointerCursor(!isPosting && !isEmpty)
                .shortcutHelp("Post the comment", .submit)
            }
        }
        .padding(12)
        .background(.bar)
        // Keyed to what the host said and nothing else, so the box below it is
        // never in a transaction while it is being typed in.
        .animation(ViewerMotion.badgeChange, value: error)
    }

    private func post() async {
        if await onPost(draft) { draft = "" }
    }
}

// MARK: - Threads

/// One comment and, indented beneath it, everything that replies to it.
struct CommentThread: View {
    let node: PullRequestCommentNode
    let depth: Int
    @Binding var replyingTo: PullRequestComment?
    /// The comment whose text is being rewritten. Shared across the whole
    /// conversation like `replyingTo`, so opening one box closes the last.
    @Binding var editing: PullRequestComment?
    let isPosting: Bool
    var mentions: MentionSource = .none
    /// Drawn in the diff rather than in the conversation, where there is less
    /// room and the file is already known.
    var isInline = false
    let onReply: (PullRequestComment, String) async -> Void
    /// Settles the thread, or opens it again. Nil where the host gave no way.
    var onResolve: ((PullRequestComment, Bool) async -> Void)?
    /// Replaces what a comment says. Nil where nothing here may be edited.
    var onEdit: ((PullRequestComment, String) async -> Void)?

    /// Whether a settled thread has been opened up to be read. It is deliberately
    /// not remembered: a reload brings the conversation back the way the host
    /// tells it, which is with the answered parts out of the way.
    @State private var isExpanded = false

    /// Stop indenting past this depth so deep threads stay readable.
    private static let maxIndentedDepth = 4
    private static let indent: CGFloat = 18

    /// Only a root stands for a thread, and only a thread can be resolved — a
    /// reply under it is part of what was settled, not a thing of its own.
    private var isSettled: Bool { depth == 0 && node.isResolved }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isSettled {
                ResolvedThreadRow(
                    node: node,
                    isExpanded: isExpanded,
                    showsPath: !isInline,
                    // On the toggle, not on the stack around it: this is one
                    // thread opening, and the page it sits on is every comment
                    // on the pull request.
                    onTap: {
                        withAnimation(ViewerMotion.contentChange) { isExpanded.toggle() }
                    }
                )
            }

            if !isSettled || isExpanded {
                thread
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var thread: some View {
        CommentBubble(
            comment: node.comment,
            replyCount: depth == 0 ? node.totalReplies : 0,
            isReplying: replyingTo == node.comment,
            isEditing: isEditing,
            isBusy: isPosting,
            mentions: mentions,
            onReplyTapped: openReply,
            onResolveTapped: resolveAction,
            onEditTapped: editAction,
            onEditCancelled: { setEditing(nil) },
            onEditSubmitted: onEdit.map { edit in
                { body in await edit(node.comment, body) }
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
            .transition(.opacity)
        }

        if !node.replies.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(node.replies) { reply in
                    CommentThread(
                        node: reply,
                        depth: depth + 1,
                        replyingTo: $replyingTo,
                        editing: $editing,
                        isPosting: isPosting,
                        mentions: mentions,
                        isInline: isInline,
                        onReply: onReply,
                        onResolve: onResolve,
                        onEdit: onEdit
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

    /// Opens the reply box under this comment, or closes the one that is open.
    ///
    /// It fades in in the conversation and appears at once in the diff, which
    /// is not an oversight. Inline, `replyingTo` belongs to the view that holds
    /// the flattened diff — an animated transaction on it is one that reaches
    /// every row of the file being read, and a ten-thousand-line diff is what
    /// that stack is flat for.
    private func openReply() {
        let next = replyingTo == node.comment ? nil : node.comment
        if isInline {
            replyingTo = next
        } else {
            withAnimation(ViewerMotion.contentChange) { replyingTo = next }
        }
        if next != nil { setEditing(nil) }
    }

    /// What the Resolve button does, or nil where it is not drawn at all.
    private var resolveAction: (() -> Void)? {
        guard depth == 0, node.comment.canResolve, let onResolve else { return nil }
        return { Task { await onResolve(node.comment, !node.isResolved) } }
    }

    private var isEditing: Bool { editing == node.comment }

    /// What the Edit button does, or nil when this comment is not the reader's
    /// to change.
    private var editAction: (() -> Void)? {
        guard node.comment.canEdit, onEdit != nil else { return nil }
        return {
            setEditing(isEditing ? nil : node.comment)
            replyingTo = nil
        }
    }

    /// Opening the box is the same transaction question as opening a reply box —
    /// see ``openReply``.
    ///
    /// Nothing closes it on the way back: an edit that lands reloads the
    /// conversation, and the comment that arrives says something else, so it is
    /// no longer the one `editing` names. An edit the host refused leaves the
    /// comment exactly as it was, and the box stays open with the text still in
    /// it — which is the whole point of not clearing it here.
    private func setEditing(_ comment: PullRequestComment?) {
        if isInline {
            editing = comment
        } else {
            withAnimation(ViewerMotion.contentChange) { editing = comment }
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

    /// Everything the rows are drawn from, worked out once for the pass that
    /// draws them.
    ///
    /// Each of these was a computed property before, and the body read them
    /// several times over — `alreadyAsked` once per row, which built the set of
    /// who is on the pull request as many times as there are people to offer.
    /// A keystroke in the search box redraws all of this, so it is worked out
    /// once and handed down.
    private struct Offer {
        /// Everybody the host offered, minus the author: nobody reviews their
        /// own pull request. The list itself keeps them, because an `@` in a
        /// comment names the author more often than it names anyone else.
        var candidates: [ReviewerCandidate] = []
        var matches: [ReviewerCandidate] = []
        /// The typed handle itself, offered as a row when it is not in the list
        /// — which is the only way in on a host that answered with nobody.
        var typedHandle: String?
        /// Whoever is already on the pull request, keyed the way the rows are,
        /// so a row can say so instead of offering them again.
        var alreadyAsked: Set<String> = []
    }

    private func readOffer() -> Offer {
        var offer = Offer()
        offer.candidates = item.reviewerCandidates.filter {
            $0.name.caseInsensitiveCompare(pr.author) != .orderedSame
                && $0.handle.caseInsensitiveCompare(pr.author) != .orderedSame
        }
        offer.matches = offer.candidates.filter { $0.matches(query) }
        offer.alreadyAsked = Set(item.reviewers.map { $0.id.lowercased() })

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.count > 1 {
            let isKnown = offer.candidates.contains {
                $0.handle.caseInsensitiveCompare(trimmed) == .orderedSame
                    || $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
            }
            offer.typedHandle = isKnown ? nil : trimmed
        }
        return offer
    }

    var body: some View {
        let offer = readOffer()
        return VStack(alignment: .leading, spacing: 12) {
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
            if !offer.candidates.isEmpty {
                Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "Suggested — \(offer.candidates.count) people who can review"
                    : "\(offer.matches.count) of \(offer.candidates.count) match “\(query)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            candidateList(offer)

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

    private func candidateList(_ offer: Offer) -> some View {
        Group {
            if item.isLoadingReviewerCandidates {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Reading who can review…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 150, alignment: .top)
                .transition(ViewerMotion.contentArrival)
            } else if offer.matches.isEmpty && offer.typedHandle == nil {
                Text(offer.candidates.isEmpty
                    ? "\(pr.host.displayName) did not say who can review this. Type a handle above and it is sent as it is."
                    : "Nobody here matches “\(query)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 150, alignment: .top)
                    .transition(ViewerMotion.contentArrival)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        if let typedHandle = offer.typedHandle {
                            row(
                                handle: typedHandle,
                                name: "Ask “\(typedHandle)”",
                                detail: "Sent to \(pr.host.displayName) as typed",
                                avatarURL: nil,
                                alreadyAsked: offer.alreadyAsked
                            )
                        }
                        ForEach(offer.matches) { candidate in
                            row(
                                handle: candidate.handle,
                                name: candidate.name,
                                detail: candidate.detail,
                                avatarURL: candidate.avatarURL,
                                alreadyAsked: offer.alreadyAsked
                            )
                        }
                    }
                }
                .frame(height: 150)
                .transition(ViewerMotion.contentArrival)
            }
        }
        // The list coming up over the spinner, and only that. Keyed to the read
        // rather than to what is in the box: the rows below are rebuilt on
        // every letter typed into the search field, and none of that is
        // anything to animate.
        .animation(ViewerMotion.contentChange, value: item.isLoadingReviewerCandidates)
    }

    /// One person the picker offers. Someone already on the pull request stays
    /// on the list, greyed out and saying so, rather than quietly missing.
    private func row(
        handle: String,
        name: String,
        detail: String?,
        avatarURL: URL?,
        alreadyAsked: Set<String>
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
    /// Whether the box that rewrites this comment is open in place of its text.
    var isEditing = false
    /// A write is already on its way to the host, so nothing else may be asked.
    var isBusy = false
    /// Who an `@` names in that box.
    var mentions: MentionSource = .none
    var onReplyTapped: (() -> Void)?
    /// Settles the thread this comment heads, or opens it again. Nil where the
    /// host offers no handle for it, and then no button is drawn.
    var onResolveTapped: (() -> Void)?
    /// Opens the box, or puts it away again. Nil where this comment is not the
    /// reader's to change.
    var onEditTapped: (() -> Void)?
    var onEditCancelled: (() -> Void)?
    /// Sends the rewritten text. The box is drawn only when this is given.
    var onEditSubmitted: ((String) async -> Void)?

    /// Ticking a box in a comment: the flip is made on the Markdown the *host*
    /// holds — which on Bitbucket is not quite what is on screen, see
    /// ``PullRequestComment/rawBody`` — and the whole comment is posted back.
    /// The line numbers agree because a mention put back in its account-id form
    /// is a replacement within a line, not a line of its own.
    ///
    /// Nothing at all for a comment nobody here may edit, which is most of them:
    /// a bot's review, and everyone else's words.
    private var taskToggle: MarkdownTaskToggle? {
        guard let onEditSubmitted else { return nil }
        let body = comment.editableBody
        // `content` is that same body, so that ticking a second box after the
        // conversation has come back from the host builds its answer on what
        // the host now holds rather than on what this closure captured.
        return MarkdownTaskToggle(target: "comment-\(comment.id)", content: body) { line, isDone in
            guard let updated = MarkdownTask.toggling(line: line, to: isDone, in: body) else { return }
            Task { await onEditSubmitted(updated) }
        }
    }

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

            if isEditing, let onEditSubmitted {
                // In place of the text rather than under it: what is in the box
                // *is* the comment, and showing both reads as two of them. The
                // header above still says whose it is and when it was written.
                CommentComposer(
                    prompt: "Edit this comment…  @ to name someone",
                    sendTitle: "Save",
                    sendSymbol: "checkmark",
                    isPosting: isBusy,
                    mentions: mentions,
                    startingFrom: comment.editableBody,
                    onCancel: { onEditCancelled?() },
                    onSend: onEditSubmitted
                )
            } else if comment.body.isEmpty {
                Text("(no message)")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                MarkdownText(text: comment.body)
                    // A checklist in a comment is only tickable by whoever
                    // could edit the comment anyway — the tick *is* an edit,
                    // and it goes back through the same path the box does.
                    .environment(\.markdownTaskToggle, taskToggle)
                    .font(.callout)
            }

            // While the box is open it carries its own Cancel and Save, and a
            // row of other verbs under it is only in the way.
            if !isEditing, hasActions {
                HStack(spacing: 12) {
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
                    }

                    if comment.canEdit, let onEditTapped {
                        Button(action: onEditTapped) {
                            Label("Edit", systemImage: "pencil")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(isBusy)
                        .pointerCursor(!isBusy)
                        .help("Change what this comment says")
                    }

                    if let onResolveTapped {
                        Button(action: onResolveTapped) {
                            Label(
                                comment.isResolved ? "Unresolve" : "Resolve",
                                systemImage: comment.isResolved
                                    ? "arrow.uturn.backward.circle"
                                    : "checkmark.circle"
                            )
                            .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(comment.isResolved ? Color.secondary : Color.green)
                        .disabled(isBusy)
                        .pointerCursor(!isBusy)
                        .help(comment.isResolved
                            ? "Mark this thread unresolved"
                            : "Mark this thread resolved")
                    }
                }
                .padding(.top, 1)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
    }

    /// Whether anything at all can be done to this comment from here.
    private var hasActions: Bool {
        (comment.canReply && onReplyTapped != nil)
            || (comment.canEdit && onEditTapped != nil)
            || onResolveTapped != nil
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
