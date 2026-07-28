import AppKit
import SwiftUI

/// The centre of the window: exactly one item at a time.
struct ViewerView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            mainContent
        }
        .frame(minWidth: 480, minHeight: 360)
        // A shade of its own, so the centre pane reads apart from the two
        // sidebars. Editor and diff draw the same colour; the terminal is
        // darker still.
        .background(Color(nsColor: AppColors.viewerBackground))
        // ⎋ is the close button: it does what the ✕ in the header does. A
        // focused terminal, the editor's completion list and the comment boxes
        // keep their own escapes — see `EscapeKey.leavesEscapeAlone` — and
        // while the ⌃⇥ row is up, ⎋ belongs to it.
        .onEscapeKey(
            when: store.current != nil
                && !store.showsDashboard
                && !store.isSwitchingProjects
        ) {
            store.closeCurrent()
        }
    }

    /// The open item, or the dashboard when there is none. It carries the
    /// pane's colour itself — the window's own background sits below it.
    private var mainContent: some View {
        VStack(spacing: 0) {
            if let item = store.current, !store.showsDashboard {
                content(item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Only an editor has a status bar. For everything else the row
                // had nothing to say but the repository's name, which the
                // sidebar and the breadcrumb both already show.
                if let document = item.document, case .text = document.content {
                    Divider()
                    StatusBar(document: document)
                }
            } else {
                WelcomeView()
            }
        }
        .background(Color(nsColor: AppColors.viewerBackground))
    }

    // MARK: - Header

    /// The window has no title bar, so this row carries what used to be in the
    /// toolbar: navigation on the left, the open item next to it, and the
    /// navigator's own controls on the right.
    private var headerBar: some View {
        HStack(spacing: 6) {
            // No room is left for the traffic lights: this pane is never the
            // leftmost one. Folding the repositories pane leaves the rail behind,
            // and the rail is wide enough to hold them — see
            // ``CollapsedProjectsRail``.
            Button {
                withAnimation { store.showsProjects.toggle() }
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .help("Show or hide the repositories sidebar (⌘0)")
            .pointerCursor()

            Button {
                store.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!store.canGoBack)
            .help(store.backTitle.map { "Back to \($0)" } ?? "Back")
            .pointerCursor(store.canGoBack)

            Button {
                store.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!store.canGoForward)
            .help(store.forwardTitle.map { "Forward to \($0)" } ?? "Forward")
            .pointerCursor(store.canGoForward)

            if let item = store.current, !store.showsDashboard {
                openItem(item)
            } else if let project = store.selectedProject {
                dashboardTitle(project)
            }

            Spacer(minLength: 12)

            // Only while the preview is up: what the button saves is the page
            // being read, not the source behind it.
            if store.visibleDocument?.isMarkdown == true, store.markdownPreview {
                Button {
                    store.saveCurrentDocumentAsPDF()
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .help("Save this preview as a PDF (⇧⌘E)")
                .pointerCursor()
            }

            if let preview = previewToggle {
                Toggle(isOn: preview) {
                    Image(systemName: "eye")
                }
                .toggleStyle(.button)
                .help(
                    store.visibleDocument?.isDrawio == true
                        ? "Draw the diagram instead of showing its XML"
                        : "Preview Markdown"
                )
                .pointerCursor()
            }

            if let item = store.current, !store.showsDashboard {
                Button {
                    store.closeCurrent()
                } label: {
                    Image(systemName: "xmark")
                }
                .help(
                    item.isTerminal
                        ? "Back to the dashboard — the shells keep running (⎋ or ⇧⌘W)"
                        : store.backTitle.map { "Close and go back to \($0) (⎋ or ⇧⌘W)" }
                            ?? "Close and go back to the dashboard (⎋ or ⇧⌘W)"
                )
                .pointerCursor()
            }

            // The tabs it used to sit beside now live on the navigator itself.
            // This stays: with that pane hidden, it is the only way back to it.
            // Its width is fixed, and the pull request bar below ends in a
            // control of the same width and padding, so that bar's segmented
            // picker keeps its right edge whatever glyph this button uses.
            Button {
                withAnimation { store.toggleNavigator() }
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .frame(width: AppMetrics.barTrailingControlWidth)
            .help("Show or hide files, PRs and info (⌥⌘0)")
            .pointerCursor()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, AppMetrics.barHorizontalPadding)
        .frame(height: 38)
        .background(.bar)
    }

    /// The eye in the header row, or nothing when the open file has no rendered
    /// form. One switch, but which flag it holds depends on the file: Markdown
    /// opens as its source and a diagram opens drawn, so they cannot share one.
    private var previewToggle: Binding<Bool>? {
        guard let document = store.visibleDocument else { return nil }
        if document.isMarkdown {
            return Binding(get: { store.markdownPreview }, set: { store.markdownPreview = $0 })
        }
        if document.isDrawio {
            return Binding(get: { store.drawioPreview }, set: { store.drawioPreview = $0 })
        }
        return nil
    }

    /// What the header says while the dashboard is up: the repository the board
    /// belongs to, in the slot and the shape the open item's breadcrumb uses, so
    /// the row never reads as empty and the name never moves.
    private func dashboardTitle(_ project: Project) -> some View {
        HStack(spacing: 7) {
            GitHostIcon(host: project.host, size: 13)
            Text(project.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let status = project.gitStatus {
                Text(status.branch)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.leading, 6)
    }

    /// Breadcrumb for the open item. Closing it lives over on the right, next
    /// to the navigator's controls.
    private func openItem(_ item: ViewerItem) -> some View {
        // The terminal has no tab bar of its own, so the breadcrumb is what
        // names the shell on screen.
        let title = item.isTerminal
            ? (item.selectedTerminal?.displayTitle ?? item.title)
            : item.title

        return HStack(spacing: 7) {
            // A commit is one person's work, so the face says more than the
            // glyph every other kind of item gets.
            if let author = item.authorName {
                AuthorAvatar(name: author, url: item.authorAvatarURL, size: 16)
            } else if let brand = item.brand {
                BrandMark(name: brand.name, size: 13, color: brand.color)
            } else {
                Image(systemName: item.symbol)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if item.isDirty {
                Circle().fill(.orange).frame(width: 6, height: 6)
            }
            // Only a pull request has a page to link to, and this is where its
            // number and title are — the link is for pasting into a chat or a
            // ticket, so it belongs next to what it points at.
            if let url = item.pullRequest?.url {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    store.showStatus("Pull request link copied")
                } label: {
                    Image(systemName: "link")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .help("Copy the link to \(item.title)")
                .pointerCursor()
            }
            // A commit gets the same treatment, for the same reason: the hash is
            // what a `git` command or a ticket wants, and the breadcrumb only
            // shows the short form of it.
            if let sha = item.commitSHA {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sha, forType: .string)
                    store.showStatus("Commit hash copied")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .help("Copy the full commit hash")
                .pointerCursor()
            }
        }
        .padding(.leading, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ item: ViewerItem) -> some View {
        switch item.kind {
        case .file:
            fileContent(item)
        case .workingDiff, .commit:
            diffContent(item)
        case .pullRequest(let projectID, let number):
            if let pr = item.pullRequest, let project = store.project(withID: projectID) {
                PullRequestDetailView(item: item, pr: pr, project: project)
            } else if item.isLoading {
                // Opened by number, from a `#123` in a commit message: the host
                // has not said what it is yet.
                ProgressView("Loading pull request #\(number)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unavailablePullRequest(number, projectID: projectID, message: item.errorMessage)
            }
        case .terminal:
            if item.terminals.isEmpty {
                ContentUnavailableView("Terminal ended", systemImage: "terminal")
            } else {
                TerminalContainerView(item: item)
            }
        }
    }

    /// A pull request the host would not give up. Its page is still worth an
    /// offer — the CLI may simply not be signed in to that repository.
    @ViewBuilder
    private func unavailablePullRequest(
        _ number: Int,
        projectID: URL,
        message: String?
    ) -> some View {
        let url = store.project(withID: projectID)?.remote?.pullRequestURL(number: number)
        ContentUnavailableView {
            Label("Pull request #\(number) unavailable", systemImage: "arrow.triangle.pull")
        } description: {
            Text(message ?? "The host did not answer for this pull request.")
        } actions: {
            if let url {
                Button("Open in Browser") { NSWorkspace.shared.open(url) }
                    .pointerCursor()
            }
        }
    }

    @ViewBuilder
    private func fileContent(_ item: ViewerItem) -> some View {
        if let document = item.document {
            switch document.content {
            case .text:
                if document.isMarkdown && store.markdownPreview {
                    MarkdownPreview(text: document.text)
                } else if document.isDrawio && store.drawioPreview {
                    DrawioPreview(xml: document.text)
                } else {
                    // ⌘F, the find bar, and marking every occurrence of the file
                    // search's query are all the editor's own now — the package
                    // ships a find and replace panel, so the app no longer puts
                    // a bar of its own over the text or hands it a query.
                    CodeEditorView(
                        document: document,
                        wrapsLines: store.wrapsLines,
                        theme: AppearanceSettings.shared.editorTheme
                    )
                }
            case .image:
                imagePreview(document.url)
            case .pdf:
                PDFPreview(url: document.url)
            case .unsupported(let reason):
                ContentUnavailableView(
                    "Cannot show this file",
                    systemImage: "doc.questionmark",
                    description: Text(reason)
                )
            }
        }
    }

    @ViewBuilder
    private func diffContent(_ item: ViewerItem) -> some View {
        if item.isLoading {
            ProgressView("Loading diff…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diff = item.diff, !diff.isEmpty {
            DiffView(
                diff: diff,
                layout: Binding(get: { item.diffLayout }, set: { item.diffLayout = $0 }),
                selectedFile: Binding(get: { item.diffFile }, set: { item.diffFile = $0 }),
                // A commit and the combined "All Changes" diff each keep their
                // own, which starts hidden — the navigator is already listing
                // the same files beside the latter. A single file's diff stays
                // on the window-wide preference.
                showsFiles: item.isCommit || item.isAllChanges
                    ? Binding(get: { item.showsDiffFileList }, set: { item.showsDiffFileList = $0 })
                    : nil
            )
        } else {
            ContentUnavailableView(
                "No changes",
                systemImage: "plusminus",
                description: Text(item.errorMessage ?? "This file has no textual changes.")
            )
        }
    }

    @ViewBuilder
    private func imagePreview(_ url: URL) -> some View {
        if let image = NSImage(contentsOf: url) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
            }
        } else {
            ContentUnavailableView("Could not decode image", systemImage: "photo.badge.exclamationmark")
        }
    }
}

// MARK: - Status bar

/// Where the caret is and what the language server makes of the file. Shown
/// under the editor only.
struct StatusBar: View {
    let document: OpenDocument

    var body: some View {
        HStack(spacing: 12) {
            Text("Ln \(document.caretLine), Col \(document.caretColumn)")
            Text(document.languageName)
            if document.errorCount > 0 {
                Label("\(document.errorCount)", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            if document.warningCount > 0 {
                Label("\(document.warningCount)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            // Why the file looks plain, in the one place that already explains
            // what the editor is and is not doing with it.
            if let note = document.largeFileNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if !document.languageServerStatus.isEmpty {
                Text(document.languageServerStatus)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("\(document.lineCount) lines")
            if document.isDirty {
                Text("Unsaved").foregroundStyle(.orange)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

// MARK: - Welcome

/// Shown when nothing is open: an overview of the selected repository.
struct WelcomeView: View {
    @Environment(WorkspaceStore.self) private var store

    /// The history starts short so the board stays readable; the button under it
    /// opens the rest. Switching repository folds it back.
    @State private var showsEveryCommit = false

    /// How many commits the folded list shows.
    private let collapsedCommitCount = 8

    /// What the Open PRs counter scrolls to.
    private static let pullRequestAnchor = "dashboard.pullRequests"

    var body: some View {
        // The reader is here for the Open PRs counter: the pull requests are on
        // this same page now, so the tile scrolls down to them instead of
        // switching a pane that no longer has them.
        ScrollViewReader { scroll in
            ScrollView {
                if let project = store.selectedProject {
                    projectOverview(project, scroll: scroll)
                } else {
                    emptyWorkspace
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The board is torn out of the tree while anything else is in the
        // centre pane, so this runs on every landing as well as on every change
        // of repository — which is the point. Nothing on the dashboard holds
        // still while it is off screen: ports come and go, a commit is made in
        // the terminal, a branch is checked out, a pull request is merged by
        // somebody else. What the board reads at the moment it appears is the
        // only thing that can be trusted, so it reads all of it. See
        // ``Project/refreshDashboard()`` for what that costs.
        .task(id: store.selectedProject?.id) {
            showsEveryCommit = false
            // Before the reads, not after them: the servers are the slow thing
            // to start and the dashboard's own reads are not waiting on them.
            // It returns at once — the walk and the launches are its own work.
            if let project = store.selectedProject {
                LanguageServerRegistry.shared.prewarm(root: project.url)
            }
            await store.selectedProject?.refreshDashboard()
        }
    }

    private var emptyWorkspace: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 46))
                .foregroundStyle(.tertiary)
            Text("No repository yet")
                .font(.title2.weight(.semibold))
            Text("Add a folder from your Mac, start an empty repository, or clone one from GitHub or Bitbucket.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button {
                store.promptForProjectFolder()
            } label: {
                Label("Add Repository…", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .pointerCursor()
            .padding(.top, 4)
            HStack(spacing: 16) {
                Button("New empty repository") { store.showNewRepository(.create) }
                    .pointerCursor()
                Button("Clone from a URL") { store.showNewRepository(.clone) }
                    .pointerCursor()
            }
            .buttonStyle(.link)
        }
        .padding(60)
        .frame(maxWidth: .infinity)
    }

    private func projectOverview(_ project: Project, scroll: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            // The name itself is in the header bar above. What is left is where
            // the repository lives and which branch it is on — and, at the end
            // of the row, the way into Claude.
            HStack(spacing: 6) {
                GitHostIcon(host: project.host, size: 14)
                Text(project.remote?.fullName ?? project.url.path)
                if let status = project.gitStatus {
                    Text("·")
                    Image(systemName: "arrow.triangle.branch")
                    Text(status.branch)
                }
                // Next to the branch it changes, and only while there is a
                // change to make — on the default branch already, the button is
                // not drawn at all. The branch is named on the button rather
                // than called "the default": which branch that is differs per
                // repository — `main` here, `develop` there — and the host is
                // what said so, so the button says it too.
                if let target = project.defaultBranchToSwitchTo {
                    BranchActionButton(
                        title: "Switch to \(target)",
                        symbol: "arrow.uturn.backward",
                        help: "Check out “\(target)”, this repository's default branch",
                        isRunning: project.isRunningGitCommand
                    ) {
                        switchToDefaultBranch(project, branch: target)
                    }
                }
                // And next to that, the same branch brought up to date. Drawn
                // only for a repository that has a remote to pull from: without
                // an `origin` the command has nowhere to go.
                if project.gitStatus != nil, project.remote != nil {
                    BranchActionButton(
                        title: "Pull",
                        symbol: "arrow.down",
                        help: "Pull the current branch from its remote",
                        isRunning: project.isRunningGitCommand
                    ) {
                        pull(project)
                    }
                }
                Spacer(minLength: 12)
                AskClaudeButton { store.openClaude(in: project) }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            // Narrower tiles than the board started with: five of them share the
            // row now, and a count is a short thing to draw.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 128), spacing: 10)],
                spacing: 10
            ) {
                StatTile(
                    title: "Open PRs",
                    value: "\(project.pullRequests.count)",
                    symbol: "arrow.triangle.pull",
                    tint: .accentColor
                ) {
                    withAnimation { scroll.scrollTo(Self.pullRequestAnchor, anchor: .top) }
                }

                StatTile(
                    title: "Changed files",
                    value: "\(project.changeCount)",
                    symbol: "plusminus",
                    tint: project.changeCount == 0 ? .green : .orange
                ) { store.showNavigator(.changes) }

                StatTile(
                    title: "Terminals",
                    value: "\(store.terminalCount(in: project))",
                    symbol: "terminal",
                    tint: .purple
                ) { store.showTerminals(in: project) }

                StatTile(
                    title: "Ports",
                    value: "\(project.ports.count)",
                    symbol: "network",
                    tint: .green
                ) { store.showNavigator(.info) }

                StatTile(
                    title: "Files",
                    value: "\(project.root.children?.count ?? 0)",
                    symbol: "folder",
                    tint: .blue
                ) { store.showNavigator(.files) }
            }

            // Drawn for a repository with a remote whether or not anything is
            // open: this is the only place pull requests are listed now, so an
            // empty table saying so beats the section vanishing.
            if project.host != .unknown {
                sectionDivider
                PullRequestTable(project: project)
                    .id(Self.pullRequestAnchor)
            }

            // The history draws nothing at all for a folder with no commits yet,
            // so its rule is asked for on the same condition — a divider with
            // nothing under it would read as the board being cut short.
            if project.isLoadingCommits || !project.recentCommits.isEmpty {
                sectionDivider
            }
            commitHistory(project)
        }
        .padding(28)
        // The board takes the whole pane rather than stopping at a reading
        // width: it is tiles, not prose, and the grids below are adaptive — the
        // width folding the navigator away gives back becomes another column of
        // pull requests instead of a margin.
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The rule between two sections of the board. Faint on purpose: it is there
    /// to group what is already spaced apart, not to draw a line across the page.
    private var sectionDivider: some View {
        Divider()
            .opacity(0.6)
            .padding(.vertical, 2)
    }

    /// Plain git, the same as the pull request's own checkout button: fetch
    /// first when the branch is only on the remote, then check it out. Nothing
    /// is forced — git refuses over uncommitted work, and its own words are
    /// what the toast says.
    private func switchToDefaultBranch(_ project: Project, branch: String) {
        Task {
            if await project.checkout(branch) {
                store.showStatus("Switched to \(branch)")
            } else {
                store.showError(project.gitError ?? "Could not switch to \(branch).")
            }
        }
    }

    /// Plain `git pull` on whatever branch the line above names. The status
    /// says which branch it was, because the pull can take long enough for the
    /// board to have been left behind by then.
    private func pull(_ project: Project) {
        let branch = project.gitStatus?.branch
        Task {
            if await project.pull() {
                store.showStatus(branch.map { "Pulled \($0)" } ?? "Pulled")
            } else {
                store.showError(project.gitError ?? "Could not pull.")
            }
        }
    }

    // MARK: - History

    /// The branch's own commits, a day at a time. Only the folder's history is
    /// involved, so this shows for every repository, remote or not.
    @ViewBuilder
    private func commitHistory(_ project: Project) -> some View {
        if project.isLoadingCommits && project.recentCommits.isEmpty {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Reading history…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if !project.recentCommits.isEmpty {
            let shown = showsEveryCommit
                ? project.recentCommits
                : Array(project.recentCommits.prefix(collapsedCommitCount))

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Recent commits")
                        .font(.headline)
                    if let branch = project.gitStatus?.branch {
                        Text("on \(branch)")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                ForEach(CommitDay.group(shown)) { day in
                    VStack(alignment: .leading, spacing: 6) {
                        CommitDayHeading(title: day.title, count: day.commits.count)
                        ForEach(day.commits) { commit in
                            RepositoryCommitRow(
                                commit: commit,
                                open: { store.openCommit(commit, project: project) },
                                openPullRequest: { store.openPullRequest(number: $0, project: project) }
                            )
                        }
                    }
                }

                commitHistoryFooter(project, shownCount: shown.count)
            }
        }
    }

    /// Under the list: first unfold what is already read, then read further back
    /// into the history. They are two different things, so they are two buttons —
    /// only the one that has something left to do is on screen.
    @ViewBuilder
    private func commitHistoryFooter(_ project: Project, shownCount: Int) -> some View {
        let unread = project.recentCommits.count - shownCount

        HStack(spacing: 12) {
            if unread > 0 || showsEveryCommit {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { showsEveryCommit.toggle() }
                } label: {
                    Label(
                        showsEveryCommit ? "Show fewer" : "Show \(unread) more",
                        systemImage: showsEveryCommit ? "chevron.up" : "chevron.down"
                    )
                }
                .pointerCursor()
            }

            // Loading a page and then hiding it behind "Show more" would be a
            // button that seems to do nothing, so this unfolds the list too.
            if project.hasMoreCommits {
                Button {
                    showsEveryCommit = true
                    Task { await project.loadMoreCommits() }
                } label: {
                    Label(
                        "Load \(RepositoryCommit.pageSize) older",
                        systemImage: "arrow.down.circle"
                    )
                }
                .disabled(project.isLoadingMoreCommits)
                .pointerCursor(!project.isLoadingMoreCommits)
                .help("Read another \(RepositoryCommit.pageSize) commits further back")
            }

            if project.isLoadingMoreCommits {
                ProgressView().controlSize(.small)
            }
        }
        .font(.callout)
        .buttonStyle(.borderless)
        .pointerCursor()
    }
}

/// One of the git commands the repository line offers — back to the branch the
/// repository calls its own, or the current branch brought up to date. They sit
/// in a line of secondary text rather than a toolbar, so they are drawn as
/// quiet pills instead of controls, and they share the one shape because they
/// stand side by side. The running spinner takes the glyph's place: every one
/// of these is a git command, and `Project` runs one at a time.
struct BranchActionButton: View {
    let title: String
    let symbol: String
    let help: String
    /// A git command of the app's own is already running; two at once is what
    /// `Project` refuses anyway, so the button says as much before it is
    /// clicked.
    let isRunning: Bool
    let run: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: run) {
            HStack(spacing: 4) {
                if isRunning {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: symbol)
                }
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background(
                .quaternary.opacity(isHovering && !isRunning ? 0.5 : 0.3),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(isRunning)
        .onHover { isHovering = $0 }
        .pointerCursor(!isRunning)
        .help(help)
        .fixedSize()
    }
}

/// The way into Claude Code, at the top of the dashboard: it starts `claude` in
/// a terminal tab of its own. It carries Claude's own icon rather than a glyph,
/// so it is found by looking rather than by reading — which is the point of
/// putting it above everything else on the board.
struct AskClaudeButton: View {
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                ClaudeMark(size: 14)
                Text("Ask Claude")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                .quaternary.opacity(isHovering ? 0.5 : 0.3),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerCursor()
        .help("Start a Claude Code conversation about this repository, in a terminal")
        .fixedSize()
    }
}

/// The line that heads a day in a list of commits — the day, how many landed on
/// it, and a rule across to the edge. Shared by the dashboard's history and the
/// pull request's Commits tab, which is what keeps the two lists reading alike.
struct CommitDayHeading: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            Text(count == 1 ? "1 commit" : "\(count) commits")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            // A hairline carries the eye across to the count and marks where one
            // day ends and the next begins.
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
        }
    }
}

/// One commit of the repository's history on the dashboard. The whole row opens
/// what that commit changed.
struct RepositoryCommitRow: View {
    let commit: RepositoryCommit
    let open: () -> Void
    /// Following a `#123` written in the message.
    let openPullRequest: (Int) -> Void

    @State private var isHovering = false
    /// The message draws itself in AppKit, so it reports the pointer separately
    /// — without this the row would drop its highlight over the message.
    @State private var isHoveringMessage = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                // Leads the row: the rows line up into a column of faces, which
                // is the fastest way to find your own commits in a long day.
                // The name is not written out — hovering the face says it, and
                // the subject deserves the width instead.
                AuthorAvatar(name: commit.displayAuthor, url: commit.avatarURL, size: 16)

                Text(commit.shortSHA)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    // Held at its full size: a 200-character merge subject would
                    // otherwise squeeze the hash down to a stripe.
                    .fixedSize()

                CommitMessageText(
                    text: commit.headline,
                    openReference: openPullRequest,
                    otherClick: open,
                    hoverChanged: { isHoveringMessage = $0 }
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
            .contentShape(Rectangle())
            .background(
                .quaternary.opacity(isHovering || isHoveringMessage ? 0.34 : 0.18),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerCursor()
        .help("Show what \(commit.shortSHA) changed — \(commit.headline)")
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
}

struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    @State private var isHovering = false

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // The longest of these ("Changed files") is what decides how
                    // narrow a tile can be; letting it shrink a little keeps all
                    // five on one row instead of wrapping the last one alone.
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(value)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(isHovering ? 0.4 : 0.25), in: shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerCursor()
    }
}

