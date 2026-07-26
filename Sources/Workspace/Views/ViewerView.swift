import AppKit
import SwiftUI

/// The centre of the window: exactly one item at a time.
struct ViewerView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
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
        .frame(minWidth: 480, minHeight: 360)
        // A shade of its own, so the centre pane reads apart from the two
        // sidebars. Editor and diff draw the same colour; the terminal is
        // darker still.
        .background(Color(nsColor: AppColors.viewerBackground))
    }

    // MARK: - Header

    /// The window has no title bar, so this row carries what used to be in the
    /// toolbar: navigation on the left, the open item next to it, and the
    /// navigator's own controls on the right.
    private var headerBar: some View {
        HStack(spacing: 6) {
            // The traffic lights float over whichever pane is leftmost. When
            // the repositories panel is hidden, that is this one.
            if !store.showsProjects {
                Color.clear.frame(width: 68, height: 1)
            }

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

            if store.current?.document?.isMarkdown == true {
                Toggle(isOn: Binding(
                    get: { store.markdownPreview },
                    set: { store.markdownPreview = $0 }
                )) {
                    Image(systemName: "eye")
                }
                .toggleStyle(.button)
                .help("Preview Markdown")
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
                        ? "Back to the dashboard — the shells keep running (⇧⌘W)"
                        : "Close and go back to the dashboard (⇧⌘W)"
                )
                .pointerCursor()
            }

            // The tabs it used to sit beside now live on the navigator itself.
            // This stays: with that pane hidden, it is the only way back to it.
            // Its width is fixed, and the pull request bar below ends in a
            // control of the same width and padding, so that bar's segmented
            // picker keeps its right edge whatever glyph this button uses.
            Button {
                withAnimation { store.showsNavigator.toggle() }
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
            ? (item.selectedTerminal?.title ?? item.title)
            : item.title

        return HStack(spacing: 7) {
            Image(systemName: item.symbol)
                .foregroundStyle(.secondary)
                .font(.caption)
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
        case .pullRequest(let projectID, _):
            if let pr = item.pullRequest, let project = store.project(withID: projectID) {
                PullRequestDetailView(item: item, pr: pr, project: project)
            } else {
                ContentUnavailableView("Pull request unavailable", systemImage: "arrow.triangle.pull")
            }
        case .terminal:
            if item.terminals.isEmpty {
                ContentUnavailableView("Terminal ended", systemImage: "terminal")
            } else {
                TerminalContainerView(item: item)
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
                } else {
                    CodeEditorView(
                        document: document,
                        projectRoot: store.project(containing: document.url)?.url,
                        wrapsLines: store.wrapsLines,
                        font: AppearanceSettings.shared.editorFont,
                        lineHeight: AppearanceSettings.shared.editorLineHeight,
                        onOpenLocation: { url, line in
                            store.openFile(url, revealLine: line)
                        }
                    )
                }
            case .image:
                imagePreview(document.url)
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
                selectedFile: Binding(get: { item.diffFile }, set: { item.diffFile = $0 })
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
            if !document.languageServerStatus.isEmpty {
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

    var body: some View {
        ScrollView {
            if let project = store.selectedProject {
                projectOverview(project)
            } else {
                emptyWorkspace
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Ports come and go while the app is open, so rescan every time the
        // dashboard is shown rather than trusting the last scan. The history
        // moves just as often — a commit made in the terminal belongs here the
        // moment the dashboard comes back.
        .task(id: store.selectedProject?.id) {
            showsEveryCommit = false
            await store.selectedProject?.refreshPorts()
        }
        .task(id: store.selectedProject?.id) {
            await store.selectedProject?.refreshCommits()
        }
    }

    private var emptyWorkspace: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 46))
                .foregroundStyle(.tertiary)
            Text("No repository yet")
                .font(.title2.weight(.semibold))
            Text("Add a repository folder from your Mac. Nothing shows up here until you do.")
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
        }
        .padding(60)
        .frame(maxWidth: .infinity)
    }

    private func projectOverview(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            // The name itself is in the header bar above. What is left is where
            // the repository lives and which branch it is on.
            HStack(spacing: 6) {
                GitHostIcon(host: project.host, size: 14)
                Text(project.remote?.fullName ?? project.url.path)
                if let status = project.gitStatus {
                    Text("·")
                    Image(systemName: "arrow.triangle.branch")
                    Text(status.branch)
                }
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
                ) { store.showNavigator(.pullRequests) }

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

            if !project.pullRequests.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Open pull requests")
                            .font(.headline)
                        Text("\(project.pullRequests.count)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    // Same tile grid as the stats above it, so the dashboard
                    // reads as one board rather than a board and a list. The
                    // tiles are wider than the stats': a title, a branch pair
                    // and a diff stat all have to fit across one.
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 300), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(project.pullRequests) { pr in
                            PullRequestTile(pr: pr) {
                                store.openPullRequest(pr, project: project)
                            }
                        }
                    }
                }
            }

            commitHistory(project)
        }
        .padding(28)
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(day.title)
                                .font(.subheadline.weight(.medium))
                            Text(day.commits.count == 1 ? "1 commit" : "\(day.commits.count) commits")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            // A hairline carries the eye across to the count and
                            // marks where one day ends and the next begins.
                            Rectangle()
                                .fill(.quaternary)
                                .frame(height: 1)
                        }
                        ForEach(day.commits) { commit in
                            RepositoryCommitRow(commit: commit) {
                                store.openCommit(commit, project: project)
                            }
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

/// One commit of the repository's history on the dashboard. The whole row opens
/// what that commit changed.
struct RepositoryCommitRow: View {
    let commit: RepositoryCommit
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                Text(commit.shortSHA)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))

                Text(commit.headline)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                // The day is already in the heading above, so the row only needs
                // the hour it landed at.
                if let date = commit.date {
                    Text(date.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(.tertiary)
                }
                Text(commit.author)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                .quaternary.opacity(isHovering ? 0.34 : 0.18),
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

/// One open pull request on the dashboard, as a tile.
///
/// A tile is meant to be read top to bottom in one glance: what state the
/// request is in and when it last moved, what it is called, then who is taking
/// what where and how big it is. The stripe down the left says the state in
/// colour alone, so a wall of tiles can be scanned without reading a word.
struct PullRequestTile: View {
    let pr: PullRequest
    let open: () -> Void

    @State private var isHovering = false

    private let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)

    /// The colour the whole tile is keyed to: green once it is approved, orange
    /// while it is waiting on the author, grey while it is only a draft, and the
    /// accent for a plain open request nobody has ruled on yet.
    private var accent: Color {
        if pr.isDraft { return .secondary }
        switch pr.reviewLabel {
        case "Approved": return .green
        case "Changes requested": return .orange
        case "Review required": return .blue
        default: return .accentColor
        }
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(accent.opacity(pr.isDraft ? 0.45 : 0.9))
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 8) {
                    statusRow
                    title
                    Divider().opacity(0.4)
                    footerRow
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(isHovering ? 0.38 : 0.22))
            .clipShape(shape)
            // The border only appears under the pointer, in the tile's own
            // colour, so hovering reads as "this one" rather than as a change of
            // brightness that every tile could have made.
            .overlay {
                shape.strokeBorder(accent.opacity(isHovering ? 0.5 : 0), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(pr.title)
        .pointerCursor()
        .contextMenu {
            Button("Open Pull Request", action: open)
            if let url = pr.url {
                Button("Open in Browser") { NSWorkspace.shared.open(url) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            Button("Copy Branch Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pr.sourceBranch, forType: .string)
            }
        }
    }

    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            PullRequestNumber(pr: pr)
            if pr.isDraft {
                Pill(text: "draft", color: .secondary)
            }
            if let review = pr.reviewLabel {
                Pill(text: review, color: accent)
            }
            Spacer(minLength: 4)
            if let updated = pr.updatedAt {
                Text(updated.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    /// Two lines' worth of room whether the title needs them or not, so a row of
    /// tiles keeps one baseline instead of stepping up and down.
    private var title: some View {
        Text(pr.title)
            .font(.callout.weight(.medium))
            .multilineTextAlignment(.leading)
            .lineLimit(2, reservesSpace: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footerRow: some View {
        HStack(spacing: 6) {
            AuthorBadge(name: pr.author)
            Text(pr.author)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 6)

            branches

            if let additions = pr.additions, let deletions = pr.deletions {
                DiffStat(additions: additions, deletions: deletions)
                    .layoutPriority(1)
            }
        }
    }

    /// Where the work is going. The source branch is the one that can be long
    /// and the one a reviewer already knows, so it is the one that gives way.
    private var branches: some View {
        HStack(spacing: 3) {
            Text(pr.sourceBranch)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "arrow.right").imageScale(.small)
            Text(pr.targetBranch)
                .lineLimit(1)
                .fixedSize()
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.tertiary)
    }
}

/// The author's initials in a tinted disc — an avatar without a download. The
/// colour comes from the name itself, so the same person is the same colour on
/// every tile.
struct AuthorBadge: View {
    let name: String
    var size: CGFloat = 16

    private var initials: String {
        let words = name
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "." })
            .prefix(2)
        let letters = words.compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    /// A stable hue per name: the same string always lands on the same wheel
    /// position, and no name lands on a colour the states above already use for
    /// meaning — those are read, this one is only told apart.
    private var tint: Color {
        let hash = name.unicodeScalars.reduce(UInt32(7)) { $0 &* 31 &+ $1.value }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.45, brightness: 0.75)
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.22), in: Circle())
    }
}

/// Added and removed lines, with a bar in the proportion they landed in — the
/// numbers say how much, the bar says which way, and the bar is the faster read.
struct DiffStat: View {
    let additions: Int
    let deletions: Int

    private let barWidth: CGFloat = 26

    private var addedShare: CGFloat {
        let total = additions + deletions
        guard total > 0 else { return 0.5 }
        return CGFloat(additions) / CGFloat(total)
    }

    var body: some View {
        HStack(spacing: 5) {
            Text("+\(additions)").foregroundStyle(.green)
            Text("−\(deletions)").foregroundStyle(.red)
            HStack(spacing: 1) {
                Capsule().fill(.green).frame(width: max(2, barWidth * addedShare))
                Capsule().fill(.red)
            }
            .frame(width: barWidth, height: 4)
        }
        .font(.caption2.monospacedDigit())
        .help("\(additions) lines added, \(deletions) removed")
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

