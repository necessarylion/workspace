import AppKit
import SwiftUI

/// Left sidebar. One project at a time, seen through five tabs.
struct NavigatorView: View {
    @Environment(WorkspaceStore.self) private var store

    private var project: Project? { store.selectedProject }

    var body: some View {
        VStack(spacing: 0) {
            if project != nil {
                header
                Divider()
            }
            if let project {
                content(project)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No repository", systemImage: "folder.badge.plus")
                } description: {
                    Text("Add a repository folder to get started.")
                } actions: {
                    Button("Add Repository…") { store.promptForProjectFolder() }
                        .pointerCursor()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// The tabs, on the pane they switch. They used to sit at the right end of
    /// the viewer's header, which put the control in one pane and everything it
    /// changed in another; the collapse button stays over there, because when
    /// this pane is hidden there is nothing here to press.
    ///
    /// Same height as the viewer's header and the repositories header, so the
    /// three rows across the top of the window read as one band.
    private var header: some View {
        Picker("", selection: Binding(
            get: { store.navigatorTab },
            set: { store.navigatorTab = $0 }
        )) {
            ForEach(WorkspaceStore.NavigatorTab.allCases) { tab in
                Label(tab.title, systemImage: tab.symbol)
                    .labelStyle(.iconOnly)
                    .help(tab.title)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .pointerCursor()
        .padding(.horizontal, AppMetrics.barHorizontalPadding)
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    @ViewBuilder
    private func content(_ project: Project) -> some View {
        switch store.navigatorTab {
        case .files:
            FileListView(project: project)
        case .pullRequests:
            PullRequestListView(project: project)
        case .changes:
            ChangeListView(project: project)
        case .terminals:
            TerminalListView(project: project)
        case .info:
            InfoPanelView(project: project)
        }
    }
}

// MARK: - Files

struct FileListView: View {
    @Environment(WorkspaceStore.self) private var store
    let project: Project

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            fileList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField(
                "Filter files",
                text: Binding(
                    get: { store.fileSearchText },
                    set: { store.fileSearchText = $0 }
                )
            )
            .textFieldStyle(.plain)
            if !store.fileSearchText.isEmpty {
                Button {
                    store.fileSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
                .pointerCursor()
            }
        }
        .padding(.horizontal, 10)
        // Shorter than the tab bar above it — it is a second row, not a header,
        // and this is the height the repositories filter box uses.
        .frame(height: 34)
    }

    /// One row per visible (expanded) node, depth first. With the ignored files
    /// toggled off, an ignored folder is dropped whole — nothing inside it is
    /// tracked either.
    private var visibleRows: [FileTreeEntry] {
        var result: [FileTreeEntry] = []
        func walk(_ node: FileNode, depth: Int) {
            for child in children(of: node) {
                result.append(FileTreeEntry(node: child, depth: depth))
                if child.isDirectory && child.isExpanded {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(project.root, depth: 0)
        return result
    }

    private func children(of node: FileNode) -> [FileNode] {
        let children = node.children ?? []
        guard !store.showsIgnoredFiles else { return children }
        return children.filter { !project.isIgnored($0.url) }
    }

    // A hand-drawn tree instead of `List`: the sidebar list style forces tall,
    // widely spaced rows and offers no way to compact them.
    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                let query = store.fileSearchText.trimmingCharacters(in: .whitespaces)
                if query.isEmpty {
                    ForEach(visibleRows) { entry in
                        CompactFileRow(
                            node: entry.node,
                            depth: entry.depth,
                            isIgnored: project.isIgnored(entry.node.url)
                        )
                    }
                } else {
                    let results = store.fileSearchResults(in: project)
                    if results.isEmpty {
                        Text("No loaded files match")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                    } else {
                        ForEach(results) { node in
                            CompactFileRow(
                                node: node,
                                depth: 0,
                                isIgnored: project.isIgnored(node.url)
                            )
                        }
                    }
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Text("\(children(of: project.root).count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.showsIgnoredFiles.toggle()
                } label: {
                    Image(systemName: store.showsIgnoredFiles ? "eye" : "eye.slash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.showsIgnoredFiles ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                .help(
                    store.showsIgnoredFiles
                        ? "Hide the files .gitignore covers"
                        : "Show the files .gitignore covers"
                )
                .pointerCursor()
                Button {
                    project.reloadFileTree()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Reload the file tree")
                .pointerCursor()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}

/// A visible node plus its indentation level.
struct FileTreeEntry: Identifiable {
    let node: FileNode
    let depth: Int
    var id: URL { node.url }
}

/// One 19pt row: disclosure chevron, icon, name.
struct CompactFileRow: View {
    @Environment(WorkspaceStore.self) private var store
    let node: FileNode
    let depth: Int
    /// Covered by `.gitignore`: still there, still openable, just faded so the
    /// tracked files stand out.
    var isIgnored = false
    @State private var isHovering = false

    private var isSelected: Bool {
        guard case .file(let url) = store.current?.kind, !store.showsDashboard else { return false }
        return url == node.url
    }

    var body: some View {
        HStack(spacing: 3) {
            Color.clear.frame(width: CGFloat(depth) * 12, height: 1)

            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                    .frame(width: 11)
            } else {
                Color.clear.frame(width: 11, height: 1)
            }

            if !node.isDirectory, let brand = FileIcon.brand(for: node.url) {
                BrandMark(
                    name: brand.name,
                    size: 11,
                    color: isSelected ? .white : brand.color
                )
                .frame(width: 17)
            } else {
                Image(systemName: FileIcon.symbol(for: node.url, isDirectory: node.isDirectory))
                    .foregroundStyle(FileIcon.tint(for: node.url, isDirectory: node.isDirectory))
                    .font(.system(size: 10))
                    .frame(width: 17)
            }

            Text(node.name)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: 19)
        // Fades the row's own content only — the selection fill behind it is
        // added afterwards and stays solid.
        .opacity(isIgnored && !isSelected ? 0.45 : 1)
        .background(
            isSelected
                ? AnyShapeStyle(.tint)
                : isHovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 4)
        )
        .contentShape(Rectangle())
        .pointerCursor()
        .onHover { isHovering = $0 }
        .onTapGesture {
            if node.isDirectory {
                node.isExpanded.toggle()
            } else {
                store.openFile(node.url)
            }
        }
        .contextMenu {
            if !node.isDirectory {
                Button("Open") { store.openFile(node.url) }
                Divider()
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path, forType: .string)
            }
        }
    }
}

// MARK: - Pull requests

struct PullRequestListView: View {
    @Environment(WorkspaceStore.self) private var store
    let project: Project

    var body: some View {
        Group {
            if project.isLoadingPullRequests && project.pullRequests.isEmpty {
                ProgressView("Loading pull requests…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = project.pullRequestError {
                ContentUnavailableView {
                    Label("No pull requests", systemImage: "arrow.triangle.pull")
                } description: {
                    Text(error).font(.callout)
                } actions: {
                    Button("Try Again") { Task { await project.refreshPullRequests() } }
                        .pointerCursor()
                }
            } else if project.pullRequests.isEmpty {
                ContentUnavailableView(
                    "No open pull requests",
                    systemImage: "checkmark.circle",
                    description: Text("Everything is merged.")
                )
            } else {
                // Same card look as the repositories sidebar.
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(project.pullRequests) { pr in
                            PullRequestCard(pr: pr, isSelected: isSelected(pr))
                                .pointerCursor()
                                .onTapGesture { store.openPullRequest(pr, project: project) }
                                .contextMenu {
                                    Button("Open") { store.openPullRequest(pr, project: project) }
                                    if let url = pr.url {
                                        Button("Open in Browser") { NSWorkspace.shared.open(url) }
                                    }
                                }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(project.pullRequests.count) open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if project.isLoadingPullRequests {
                    ProgressView().controlSize(.mini)
                } else {
                    Button {
                        Task { await project.refreshPullRequests() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Reload pull requests")
                    .pointerCursor()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func isSelected(_ pr: PullRequest) -> Bool {
        guard case .pullRequest(_, let number) = store.current?.kind,
              !store.showsDashboard else { return false }
        return number == pr.number
    }
}

/// One pull request, in the same card style as `ProjectCard`.
struct PullRequestCard: View {
    let pr: PullRequest
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                PullRequestNumber(pr: pr)
                Text(pr.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }

            HStack(spacing: 5) {
                AuthorAvatar(name: pr.author, url: pr.avatarURL, size: 14)
                Text(pr.author)
                    .lineLimit(1)
                Image(systemName: "arrow.right").imageScale(.small)
                Text(pr.targetBranch)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if pr.isDraft || pr.reviewLabel != nil {
                HStack(spacing: 5) {
                    if pr.isDraft {
                        Pill(text: "draft", color: .secondary)
                    }
                    if let review = pr.reviewLabel {
                        Pill(text: review, color: review == "Approved" ? .green : .orange)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.quaternary.opacity(0.22)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.2)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Changes

struct ChangeListView: View {
    @Environment(WorkspaceStore.self) private var store
    let project: Project

    /// The file the discard button was pressed for, while its confirmation is
    /// up. Discarding cannot be undone, so it never runs straight off the click.
    @State private var pendingDiscard: GitStatus.Change?

    private var isBusy: Bool { project.isRunningGitCommand }

    private var canCommit: Bool {
        !isBusy
            && !project.stagedChanges.isEmpty
            && !project.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if let status = project.gitStatus {
                if status.changes.isEmpty {
                    ContentUnavailableView(
                        "Working tree clean",
                        systemImage: "checkmark.seal",
                        description: Text("Nothing to commit on \(status.branch).")
                    )
                } else {
                    changeList(status)
                }
            } else {
                ContentUnavailableView(
                    "Not a git repository",
                    systemImage: "questionmark.folder",
                    description: Text("This folder has no .git directory.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            // Shown even on a clean tree: that is exactly the state a branch is
            // in between committing and pushing.
            if project.gitStatus != nil {
                commitBox
            }
        }
        // The working tree moves under us — reload whenever this tab is shown,
        // rather than showing whatever the last scan found.
        .task(id: project.id) {
            await project.refreshGitStatus()
        }
        .confirmationDialog(
            pendingDiscard.map { "Discard changes to \(($0.path as NSString).lastPathComponent)?" } ?? "",
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            presenting: pendingDiscard
        ) { change in
            Button(change.label == "Untracked" ? "Delete File" : "Discard Changes", role: .destructive) {
                discard(change)
            }
            Button("Cancel", role: .cancel) { pendingDiscard = nil }
        } message: { change in
            Text(
                change.label == "Untracked"
                    ? "\(change.path) is not in git, so discarding deletes it. This cannot be undone."
                    : "\(change.path) goes back to its last committed state, staged edits included. This cannot be undone."
            )
        }
    }

    private func discard(_ change: GitStatus.Change) {
        pendingDiscard = nil
        Task {
            guard await project.discard([change.path]) else { return }
            // The diff we were showing for this file no longer exists.
            if let current = store.current,
               case .workingDiff(let projectID, let path, _) = current.kind,
               projectID == project.id, path == change.path {
                store.closeCurrent()
            }
            store.showStatus("Discarded \((change.path as NSString).lastPathComponent)")
        }
    }

    /// Staged first, then the rest, each group with its own bulk action — the
    /// order the two piles are worked through.
    private func changeList(_ status: GitStatus) -> some View {
        // "View All Changes" lives in the diff's own bar in the centre pane,
        // next to the file count.
        List(selection: Binding(
            get: { store.current.flatMap { item -> String? in
                guard case .workingDiff(_, let path, _) = item.kind else { return nil }
                return path
            } },
            set: { path in
                guard let path,
                      let change = status.changes.first(where: { $0.path == path }) else { return }
                store.openWorkingDiff(project: project, change: change)
            }
        )) {
            if !project.stagedChanges.isEmpty {
                Section {
                    ForEach(project.stagedChanges) { row($0) }
                } header: {
                    header("Staged", count: project.stagedChanges.count, action: "Unstage All") {
                        let paths = project.stagedChanges.map(\.path)
                        Task { await project.unstage(paths) }
                    }
                }
            }
            if !project.unstagedChanges.isEmpty {
                Section {
                    ForEach(project.unstagedChanges) { row($0) }
                } header: {
                    header("Changes", count: project.unstagedChanges.count, action: "Stage All") {
                        Task { await project.stageAll() }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // A sidebar list paints its own vibrant background, which read as a
        // different shade to every other tab here.
        .scrollContentBackground(.hidden)
    }

    private func row(_ change: GitStatus.Change) -> some View {
        HStack(spacing: 7) {
            Image(systemName: change.symbol)
                .foregroundStyle(color(for: change))
                .font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text((change.path as NSString).lastPathComponent)
                    .lineLimit(1)
                // A file at the root has no folder above it; an empty line here
                // would still take its height and push the name off centre.
                let directory = (change.path as NSString).deletingLastPathComponent
                if !directory.isEmpty {
                    Text(directory)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer()
            Button {
                pendingDiscard = change
            } label: {
                Image(systemName: change.label == "Untracked" ? "trash" : "arrow.uturn.backward")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isBusy)
            .help(change.label == "Untracked" ? "Delete this untracked file" : "Discard this file's changes")
            .pointerCursor(!isBusy)
            // The label this replaces is in the row's tooltip, and the coloured
            // symbol already says what kind of change it is.
            Button {
                let paths = [change.path]
                Task {
                    if change.isStaged {
                        await project.unstage(paths)
                    } else {
                        await project.stage(paths)
                    }
                }
            } label: {
                Image(systemName: change.isStaged ? "minus.circle" : "plus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isBusy)
            .help(change.isStaged ? "Unstage this file" : "Stage this file")
            .pointerCursor(!isBusy)
        }
        .contentShape(Rectangle())
        .help("\(change.label) · \(change.path)")
        .pointerCursor()
        .tag(change.path)
    }

    private func header(
        _ title: String,
        count: Int,
        action: String,
        run: @escaping () -> Void
    ) -> some View {
        HStack {
            Text("\(title) (\(count))")
            Spacer()
            Button(action, action: run)
                .buttonStyle(.plain)
                .foregroundStyle(isBusy ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                .disabled(isBusy)
                .pointerCursor(!isBusy)
                // A section header is not inset the way the rows below it are,
                // so without this the text sits against the pane's edge.
                .padding(.trailing, 8)
        }
    }

    // MARK: - Commit box

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = project.gitError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if project.changeCount > 0 {
                TextField(
                    "Commit message",
                    text: Binding(
                        get: { project.commitMessage },
                        set: { project.commitMessage = $0 }
                    ),
                    axis: .vertical
                )
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .font(.callout)
            }

            HStack(spacing: 8) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if isBusy {
                    ProgressView().controlSize(.mini)
                }
                Button("Commit") {
                    Task {
                        if await project.commit() {
                            store.showStatus("Committed")
                        }
                    }
                }
                .disabled(!canCommit)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Commit the staged files (⌘⏎)")
                .pointerCursor(canCommit)

                Button {
                    Task {
                        if await project.push() {
                            store.showStatus("Pushed")
                        }
                    }
                } label: {
                    Label(pushTitle, systemImage: "arrow.up")
                }
                .disabled(isBusy)
                .help("Push this branch to its remote")
                .pointerCursor(!isBusy)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// What git has: staged, unstaged, and commits waiting to go out.
    private var summary: String {
        var parts: [String] = []
        if !project.stagedChanges.isEmpty { parts.append("\(project.stagedChanges.count) staged") }
        if !project.unstagedChanges.isEmpty { parts.append("\(project.unstagedChanges.count) changed") }
        if parts.isEmpty { parts.append("clean") }
        return parts.joined(separator: " · ")
    }

    private var pushTitle: String {
        guard let ahead = project.gitStatus?.ahead, ahead > 0 else { return "Push" }
        return "Push \(ahead)"
    }

    private func color(for change: GitStatus.Change) -> Color {
        switch change.label {
        case "Added": .green
        case "Deleted": .red
        case "Renamed": .blue
        case "Untracked": .secondary
        case "Conflict": .orange
        default: .orange
        }
    }
}

// MARK: - Terminals

/// The shells of **one** folder, newest first: the repository you are in, or the
/// home folder while a home shell is on screen. Never both at once — a list that
/// mixed every repository's shells was impossible to read — and the shells of
/// the other repositories are shown when you switch to them.
///
/// Terminals outlive the viewer, so this list is how the user gets back to one
/// they left.
struct TerminalListView: View {
    @Environment(WorkspaceStore.self) private var store
    /// The repository whose shells to list, unless a home shell is on screen.
    let project: Project

    private var scope: TerminalScope {
        store.visibleTerminalScope ?? .project(project.id)
    }

    private var terminals: [RecentTerminal] { store.terminals(in: scope) }

    private var footerSummary: String {
        let running = terminals.count { $0.session.isRunning }
        let saved = terminals.count - running
        let head = "\(running) running in \(store.name(of: scope))"
        return saved == 0 ? head : "\(head) · \(saved) saved"
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                // The first card starts a shell here; the rest are the open ones.
                NewTerminalCard(
                    scope: store.name(of: scope),
                    symbol: scope == .home ? "house" : "plus"
                ) {
                    store.newTerminal(in: scope)
                }

                ForEach(terminals) { terminal in
                    TerminalCard(
                        title: terminal.session.title,
                        position: terminal.position,
                        isSelected: store.isShowing(terminal),
                        isRunning: terminal.session.isRunning,
                        close: { store.closeTerminal(terminal) }
                    )
                    .pointerCursor()
                    .onTapGesture { store.showTerminal(terminal) }
                    .contextMenu {
                        Button("Show") { store.showTerminal(terminal) }
                        Button("Close") { store.closeTerminal(terminal) }
                    }
                }

                if terminals.isEmpty {
                    Text("Shells you open stay here until you close them — quitting the app included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom) {
            HStack {
                // Restored tabs count separately: their shell only starts when
                // the tab is first shown.
                Text(footerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }
}

/// The card that starts another shell in the folder the list is about, at the
/// top of it.
struct NewTerminalCard: View {
    /// Where the shell would start — a repository name, or "Home".
    let scope: String
    let symbol: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.callout.weight(.medium))
                Text("New Terminal")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 0)
                Text(scope)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.tint)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(.tint.opacity(isHovering ? 0.16 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.tint.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Start another shell in \(scope)")
        .pointerCursor()
    }
}

/// One running shell, in the same card style as `PullRequestCard`.
struct TerminalCard: View {
    let title: String
    /// Its place among the folder's tabs: two shells in the same folder are
    /// named the same once their prompts have renamed them.
    let position: Int
    let isSelected: Bool
    /// False for a tab brought back from the last run of the app, whose shell
    /// starts the moment it is shown.
    let isRunning: Bool
    let close: () -> Void

    @State private var isHovering = false

    private var iconStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.tint) }
        return AnyShapeStyle(isRunning ? .secondary : .tertiary)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.callout)
                .foregroundStyle(iconStyle)

            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            // The folder is the same for every card in the list, so the tab's
            // number is what is worth showing instead.
            Text("\(position)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0)
            .help("Close this terminal")
            .pointerCursor()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.quaternary.opacity(0.22)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.2)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(isRunning ? title : "\(title) — saved, opens a shell when shown")
    }
}
