import AppKit
import SwiftUI

/// Left sidebar. One project at a time, seen through five tabs.
struct NavigatorView: View {
    @Environment(WorkspaceStore.self) private var store

    private var project: Project? { store.selectedProject }

    var body: some View {
        VStack(spacing: 0) {
            if let project {
                // Both the tab picker and the collapse button live in the
                // window toolbar, on the same row.
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
                .pointerCursor()
            }
        }
        .padding(.horizontal, 10)
        // Same height as the header rows in the other two panes, so the tops
        // of all three line up.
        .frame(height: 38)
    }

    /// One row per visible (expanded) node, depth first.
    private var visibleRows: [FileTreeEntry] {
        var result: [FileTreeEntry] = []
        func walk(_ node: FileNode, depth: Int) {
            for child in node.children ?? [] {
                result.append(FileTreeEntry(node: child, depth: depth))
                if child.isDirectory && child.isExpanded {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(project.root, depth: 0)
        return result
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
            HStack {
                Text("\(project.root.children?.count ?? 0) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    project.reloadFileTree()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Reload the file tree")
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
                    .pointerCursor()
                    .help("Reload pull requests")
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
                Text("#\(pr.number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(pr.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }

            HStack(spacing: 5) {
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
                    // "View All Changes" lives in the diff's own bar in the
                    // centre pane, next to the file count.
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
                        ForEach(status.changes) { change in
                            HStack(spacing: 7) {
                                Image(systemName: change.symbol)
                                    .foregroundStyle(color(for: change))
                                    .font(.caption)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((change.path as NSString).lastPathComponent)
                                        .lineLimit(1)
                                    // A file at the root has no folder above
                                    // it; an empty line here would still take
                                    // its height and push the name off centre.
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
                                Text(change.label)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                            .pointerCursor()
                            .tag(change.path)
                            .help(change.path)
                        }
                    }
                    .listStyle(.sidebar)
                    // A sidebar list paints its own vibrant background, which
                    // read as a different shade to every other tab here.
                    .scrollContentBackground(.hidden)
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
            HStack {
                Text("\(project.changeCount) changed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await project.refreshGitStatus() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Reload git status")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
        // The working tree moves under us — reload whenever this tab is shown,
        // rather than showing whatever the last scan found.
        .task(id: project.id) {
            await project.refreshGitStatus()
        }
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

/// Every shell still running, newest first. Terminals outlive the viewer, so
/// this list is how the user gets back to one they left — including shells
/// belonging to the other repositories.
struct TerminalListView: View {
    @Environment(WorkspaceStore.self) private var store
    let project: Project

    private var terminals: [RecentTerminal] { store.recentTerminals }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                // The first card starts a shell; the rest are the running ones.
                NewTerminalCard(repository: project.name) {
                    store.newTerminal(in: project)
                }

                ForEach(terminals) { terminal in
                    TerminalCard(
                        title: terminal.session.title,
                        repository: store.project(withID: terminal.item.projectID)?.name
                            ?? terminal.session.directory.lastPathComponent,
                        isSelected: store.isShowing(terminal),
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
                    Text("Shells you open keep running here until you close them.")
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
                Text("\(terminals.count) running")
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

/// The card that starts another shell, at the top of the terminals list.
struct NewTerminalCard: View {
    let repository: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.callout.weight(.medium))
                Text("New Terminal")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 0)
                Text(repository)
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
        .pointerCursor()
        .onHover { isHovering = $0 }
        .help("Start another shell in \(repository) (⌘T)")
    }
}

/// One running shell, in the same card style as `PullRequestCard`.
struct TerminalCard: View {
    let title: String
    let repository: String
    let isSelected: Bool
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.callout)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(repository)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0)
            .pointerCursor()
            .help("Close this terminal")
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
        .help(title)
    }
}
