import AppKit
import SwiftUI

/// Left sidebar. One project at a time, seen through six tabs.
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
                tabIcon(tab)
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

    /// A glyph for each tab, except Claude's, which gets Claude's own mark —
    /// the same one the dashboard button and the chat carry, rather than the
    /// generic sparkles every app now draws for "AI".
    @ViewBuilder
    private func tabIcon(_ tab: WorkspaceStore.NavigatorTab) -> some View {
        if tab == .claude {
            ClaudeMark(size: 15)
        } else {
            Label(tab.title, systemImage: tab.symbol)
                .labelStyle(.iconOnly)
        }
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
        case .claude:
            ClaudeSessionListView(project: project)
        case .info:
            InfoPanelView(project: project)
        }
    }
}

// MARK: - Files

struct FileListView: View {
    @Environment(WorkspaceStore.self) private var store
    let project: Project

    /// A drag hovering over the list itself, which drops into the repository root.
    @State private var isRootDropTarget = false
    /// Raised whenever the tree should take the keyboard — see
    /// `FileTreeKeyCatcher`, which does the taking.
    @State private var keyboardClaims = 0
    /// What the running query found, grouped by file.
    @State private var searchResults: [FileSearchFileResult] = []
    /// True from the keystroke until its results land, so the box can say so
    /// rather than leaving the last query's hits on screen looking current.
    @State private var isSearching = false

    /// The query, trimmed — an empty one means the tree, not a search.
    private var query: String {
        store.fileSearchText.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            fileList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // One task per (repository, query): typing another letter cancels the
        // one in flight, so only the last query's results ever land.
        .task(id: SearchRequest(project: project.id, query: query, ignored: store.showsIgnoredFiles)) {
            await runSearch()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            FileTreeKeyCatcher(claims: keyboardClaims, handle: handle)
                .frame(width: 0, height: 0)
        )
        // Switching repository leaves a selection of paths that are not in this
        // tree, and a half-typed rename that belongs to the other one.
        .onChange(of: project.id) {
            store.clearFileSelection()
            store.renamingFile = nil
        }
        // The rename box takes the keyboard while it is open; closing it hands
        // the keys back to the list, so ⏎ can rename the next row straight away.
        .onChange(of: store.renamingFile) { _, renaming in
            if renaming == nil { keyboardClaims += 1 }
        }
    }

    /// A click on a row: it takes the keyboard, moves the selection, and — with
    /// no modifier held — opens the file or opens the folder.
    ///
    /// The file opens **without** taking the keyboard, the way VS Code's
    /// explorer does: the keys stay here for ⏎, ⌘⌫ and the arrows until the
    /// editor itself is clicked.
    private func activate(_ node: FileNode, modifiers: NSEvent.ModifierFlags) {
        keyboardClaims += 1
        store.renamingFile = nil
        store.selectFile(node.url, modifiers: modifiers, visible: rowURLs)
        guard modifiers.intersection([.command, .shift]).isEmpty else { return }
        if node.isDirectory {
            node.isExpanded.toggle()
        } else {
            store.openFile(node.url, takingFocus: false)
        }
    }

    /// The rows on screen, in order — what ⇧-click and the arrow keys count in.
    /// A search lists one row per file, whatever the number of hits inside it.
    private var rowURLs: [URL] {
        query.isEmpty ? visibleRows.map(\.node.url) : searchResults.map(\.url)
    }

    /// Runs the query a short pause after the last keystroke. The wait is what
    /// keeps a typed word from starting a search per letter — the results of the
    /// first five would be thrown away the moment the sixth arrived.
    private func runSearch() async {
        guard !query.isEmpty else {
            searchResults = []
            isSearching = false
            // Nothing is being looked for any more, so nothing stays marked in
            // whatever file is open.
            store.searchHighlight = nil
            return
        }
        isSearching = true
        do {
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            return  // Another keystroke cancelled this one.
        }
        let found = await FileSearcher.search(
            query,
            in: project.url,
            includingIgnored: store.showsIgnoredFiles
        )
        guard !Task.isCancelled else { return }
        searchResults = found
        isSearching = false
    }

    /// Opens the file at the line that matched, the way clicking a search result
    /// does everywhere. The keyboard stays with the list, as it does for a click
    /// in the tree.
    ///
    /// `line` is the number the search tools print and the gutter shows, counted
    /// from 1; `revealLine` counts from 0, the way LSP does.
    private func openMatch(_ file: FileSearchFileResult, line: Int?) {
        keyboardClaims += 1
        store.renamingFile = nil
        // The editor marks every occurrence, so the file reads as a set of hits
        // rather than the single line that happened to be clicked.
        store.searchHighlight = query
        store.selectFile(file.url, modifiers: [], visible: rowURLs)
        store.openFile(file.url, revealLine: line.map { max($0 - 1, 0) }, takingFocus: false)
    }

    /// ⏎ renames, ⌘⌫ trashes, ↑↓ walk the rows and ⇧↑↓ extend the selection —
    /// the same keys the Finder answers.
    private func handle(_ key: FileTreeKey) -> Bool {
        // With the rename box open every one of these keys is the box's: ⏎
        // commits the new name, ⎋ drops it, and the arrows move the caret.
        guard store.renamingFile == nil else { return false }
        let selected = store.selectedFiles
        switch key {
        case .rename:
            guard selected.count == 1, let url = selected.first else { return false }
            store.renamingFile = url
            return true
        case .trash:
            guard !selected.isEmpty else { return false }
            store.deleteFiles(Array(selected), project: project)
            return true
        case .move(let delta, let extending):
            store.moveFileSelection(by: delta, extending: extending, visible: rowURLs)
            return true
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField(
                "Search",
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
                .help("Clear the search")
                .pointerCursor()
            }
        }
        .padding(.horizontal, 10)
        // Shorter than the tab bar above it — it is a second row, not a header,
        // and this is the height the repositories filter box uses. With no rule
        // under it, the row is kept tight so it does not read as a gap.
        .frame(height: 28)
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

    /// The line under the list: what the tree holds, or what the query found.
    private var summary: String {
        guard !query.isEmpty else { return "\(children(of: project.root).count) items" }
        if searchResults.isEmpty { return isSearching ? "Searching…" : "No results" }
        let matches = searchResults.reduce(0) { $0 + $1.matches.count }
        let files = searchResults.count
        return "\(matches) result\(matches == 1 ? "" : "s") in "
            + "\(files) file\(files == 1 ? "" : "s")"
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
                if query.isEmpty {
                    ForEach(visibleRows) { entry in
                        CompactFileRow(
                            project: project,
                            node: entry.node,
                            depth: entry.depth,
                            isIgnored: project.isIgnored(entry.node.url),
                            activate: { activate(entry.node, modifiers: $0) }
                        )
                    }
                } else if searchResults.isEmpty {
                    Text(isSearching ? "Searching…" : "No results")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)
                } else {
                    ForEach(searchResults) { file in
                        SearchResultFileRow(
                            file: file,
                            open: { openMatch(file, line: file.matches.first?.line) }
                        )
                        ForEach(file.matches) { match in
                            SearchMatchRow(
                                text: match.text,
                                query: query,
                                open: { openMatch(file, line: match.line) }
                            )
                        }
                    }
                }
            }
            .padding(.bottom, 3)
            .padding(.horizontal, 6)
        }
        // The empty space below the rows is still the repository folder, so a
        // drop there lands in its root. Rows sit on top of this and take their
        // own drops first.
        .dropDestination(for: URL.self) { urls, _ in
            store.importFiles(urls, into: project.url, project: project)
            return true
        } isTargeted: { isRootDropTarget = $0 }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isRootDropTarget ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5)
                .padding(2)
                .allowsHitTesting(false)
        )
        // Clicking past the last row lets the selection go, the way clicking the
        // empty part of a Finder window does.
        .contentShape(Rectangle())
        .onTapGesture {
            keyboardClaims += 1
            store.renamingFile = nil
            store.clearFileSelection()
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

/// What one search run is for. Changing any part of it starts another run and
/// cancels the one before.
private struct SearchRequest: Equatable {
    let project: URL
    let query: String
    let ignored: Bool
}

/// The header of one file's hits: icon, name, the folder it sits in, and how
/// many lines inside it matched.
struct SearchResultFileRow: View {
    let file: FileSearchFileResult
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            if let brand = FileIcon.brand(for: file.url) {
                BrandMark(name: brand.name, size: 11, color: brand.color)
                    .frame(width: 15)
            } else {
                Image(systemName: FileIcon.symbol(for: file.url, isDirectory: false))
                    .foregroundStyle(FileIcon.tint(for: file.url, isDirectory: false))
                    .font(.system(size: 10))
                    .frame(width: 15)
            }
            Text(file.url.lastPathComponent)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            if !file.folder.isEmpty {
                Text(file.folder)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            Text("\(file.matches.count)")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .background(Capsule().fill(.quaternary))
        }
        .padding(.horizontal, 4)
        .frame(height: 19)
        .background(
            isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 4)
        )
        .contentShape(Rectangle())
        .pointerCursor()
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
    }
}

/// One matching line. The part that matched is picked out of the rest, which is
/// the whole reason to show the line instead of just its number.
struct SearchMatchRow: View {
    let text: String
    let query: String
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        Text(highlighted)
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 21)
            .padding(.trailing, 4)
            .frame(height: 18)
            .background(
                isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .contentShape(Rectangle())
            .pointerCursor()
            .onHover { isHovering = $0 }
            .onTapGesture(perform: open)
    }

    /// The line dimmed, with every occurrence of the query left bright and
    /// tinted. Case-insensitive, because the search itself is.
    private var highlighted: AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = .secondary
        guard !query.isEmpty else { return result }
        var searched = result.startIndex..<result.endIndex
        while let found = result[searched].range(of: query, options: .caseInsensitive) {
            result[found].foregroundColor = .primary
            result[found].backgroundColor = .accentColor.opacity(0.28)
            guard found.upperBound < result.endIndex else { break }
            searched = found.upperBound..<result.endIndex
        }
        return result
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
    let project: Project
    let node: FileNode
    let depth: Int
    /// Covered by `.gitignore`: still there, still openable, just faded so the
    /// tracked files stand out.
    var isIgnored = false
    /// A click on the row, with whatever modifier was held — the list does the
    /// selecting, since a ⇧-range only means something in the order it draws.
    var activate: (NSEvent.ModifierFlags) -> Void = { _ in }
    @State private var isHovering = false
    @State private var isDropTarget = false

    /// Picked in the tree. Not the same as being open in the viewer: a
    /// selection is what the next action works on, and it can be several rows.
    private var isSelected: Bool { store.selectedFiles.contains(node.url) }

    /// Showing in the viewer right now.
    private var isOpen: Bool {
        guard case .file(let url) = store.current?.kind, !store.showsDashboard else { return false }
        return url == node.url
    }

    private var isRenaming: Bool { store.renamingFile == node.url }

    /// The rows this row's menu, keys and drags act on: the whole selection when
    /// it is part of it, itself alone when it is not.
    private var targets: [URL] { store.fileActionTargets(node.url) }

    /// Where a drop on this row lands. A file row takes its folder, the way
    /// Finder and every file tree does it — the row is where the pointer is, the
    /// folder it sits in is what can hold a file.
    private var dropFolder: URL {
        node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    var body: some View {
        HStack(spacing: 3) {
            Color.clear.frame(width: CGFloat(depth) * 14, height: 1)

            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                    .frame(width: 12)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }

            if !node.isDirectory, let brand = FileIcon.brand(for: node.url) {
                BrandMark(
                    name: brand.name,
                    size: 13,
                    color: isSelected ? .white : brand.color
                )
                .frame(width: 19)
            } else {
                Image(systemName: FileIcon.symbol(for: node.url, isDirectory: node.isDirectory))
                    // The selected row is filled with the accent colour, which a
                    // tinted glyph can be close enough to to disappear into.
                    .foregroundStyle(
                        isSelected
                            ? AnyShapeStyle(.white)
                            : AnyShapeStyle(FileIcon.tint(for: node.url, isDirectory: node.isDirectory))
                    )
                    .font(.system(size: 12))
                    .frame(width: 19)
            }

            if isRenaming {
                nameField
            } else {
                Text(node.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
        // Fades the row's own content only — the selection fill behind it is
        // added afterwards and stays solid.
        .opacity(isIgnored && !isSelected ? 0.45 : 1)
        .background(
            background,
            in: RoundedRectangle(cornerRadius: 4)
        )
        // While a drag is over the row, the folder it would land in is outlined
        // — on a file row that is the row's own folder, which is why the fill
        // goes with it rather than just a border.
        .background(
            isDropTarget ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isDropTarget ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .pointerCursor()
        .onHover { isHovering = $0 }
        // The modifier is read off the event that is still being handled, which
        // is how ⌘-click and ⇧-click are told apart from a plain one. A click
        // inside the open rename box belongs to the box.
        .onTapGesture { if !isRenaming { activate(NSEvent.modifierFlags) } }
        // Dragging a row out hands over the real file, so it can be dropped in
        // Finder, in another folder here, or in any app that takes files. Only
        // the row under the pointer travels — a drop back into the tree picks up
        // the rest of the selection from the store.
        .draggable(startDrag()) {
            Label(
                targets.count > 1 ? "\(targets.count) items" : node.name,
                systemImage: FileIcon.symbol(for: node.url, isDirectory: node.isDirectory)
            )
            .font(.system(size: 11.5))
            .padding(4)
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.importFiles(urls, into: dropFolder, project: project)
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
            // Hovering over a closed folder opens it, so a file can be dropped
            // further in without letting go of the drag first.
            if targeted && node.isDirectory && !node.isExpanded {
                openOnHover()
            }
        }
        .contextMenu {
            // Named for how many rows it will touch, so a menu opened on one row
            // of several never looks like it applies to that row alone.
            let many = targets.count > 1 ? " \(targets.count) Items" : ""
            if !node.isDirectory, targets.count == 1 {
                Button("Open") { store.openFile(node.url) }
                Divider()
            }
            Button("Rename…") { store.renamingFile = node.url }
                .disabled(targets.count > 1)
            Button("Duplicate\(many)") {
                store.duplicateFiles(targets, project: project)
            }
            Button("Move\(many.isEmpty ? "" : many) to Trash") {
                store.deleteFiles(targets, project: project)
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(targets)
            }
            Button("Copy Path\(targets.count > 1 ? "s" : "")") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(targets.map(\.path).joined(separator: "\n"), forType: .string)
            }
        }
    }

    /// The file this drag carries, noting the rest of the selection on the way
    /// out. Evaluated when the drag actually starts, not while the row is drawn.
    private func startDrag() -> URL {
        store.beginFileDrag(targets)
        return node.url
    }

    /// Selected wins over open, and both over the hover: a row can be all three
    /// at once, and the selection is what the next key or menu item acts on.
    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.tint) }
        if isOpen { return AnyShapeStyle(.tint.opacity(0.2)) }
        return isHovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear)
    }

    /// The name, editable in place — ⏎ renames, ⎋ leaves it as it was, and so
    /// does clicking away, because an abandoned box should not rename anything.
    private var nameField: some View {
        RenameField(
            text: node.name,
            selectsBaseName: !node.isDirectory,
            commit: { name in
                store.renamingFile = nil
                store.renameFile(node.url, to: name, project: project)
            },
            cancel: { store.renamingFile = nil }
        )
        .frame(height: 17)
    }

    /// Spring-loaded folders: opens after a short hold, and only if the drag is
    /// still over the row by then.
    private func openOnHover() {
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard isDropTarget, !node.isExpanded else { return }
            node.isExpanded = true
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
            && !project.isWritingCommitMessage
            && !project.stagedChanges.isEmpty
            && !project.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// There has to be a change to describe, and only one message can be on its
    /// way at a time.
    private var canWriteCommitMessage: Bool {
        !isBusy && !project.isWritingCommitMessage && project.changeCount > 0
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
                    : "\(change.displayPath) goes back to its last committed state, staged edits included. This cannot be undone."
            )
        }
    }

    private func discard(_ change: GitStatus.Change) {
        pendingDiscard = nil
        Task {
            guard await project.discard(change.gitPaths) else { return }
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
                        let paths = project.stagedChanges.flatMap(\.gitPaths)
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
                // A rename spends this line on where the file came from — the
                // new name alone says nothing about what happened. Otherwise the
                // folder, except at the root, where an empty line would still
                // take its height and push the name off centre.
                let directory = (change.path as NSString).deletingLastPathComponent
                if let originalPath = change.originalPath, originalPath != change.path {
                    Text("from \(originalPath)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else if !directory.isEmpty {
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
                let paths = change.gitPaths
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
        .help("\(change.label) · \(change.displayPath)")
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
                commitField
            }

            HStack(spacing: 8) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if isBusy {
                    ProgressView().controlSize(.mini)
                }

                // Claude writes the message from the same change the Commit
                // button beside it would take. Its own spinner replaces the
                // mark, so the row keeps its width while it thinks.
                Button {
                    Task { await project.writeCommitMessage() }
                } label: {
                    if project.isWritingCommitMessage {
                        ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                    } else {
                        ClaudeMark(size: 14)
                    }
                }
                .disabled(!canWriteCommitMessage)
                .help("Write the commit message with Claude")
                .pointerCursor(canWriteCommitMessage)

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

    /// The message being written.
    ///
    /// A `TextField` was the obvious control and the wrong one: it grows to the
    /// four lines it is allowed and then simply stops, so a longer message —
    /// exactly what a subject plus a body is, and what the Claude button writes
    /// — could only be walked through with the arrow keys, never scrolled and
    /// never seen whole. A `TextEditor` scrolls, so the same four lines of space
    /// now show any part of the message you like. The border is drawn here
    /// because a text editor, unlike a text field, has no bordered style.
    private var commitField: some View {
        TextEditor(
            text: Binding(
                get: { project.commitMessage },
                set: { project.commitMessage = $0 }
            )
        )
        .font(.callout)
        .scrollContentBackground(.hidden)
        .padding(.vertical, 4)
        .padding(.horizontal, 3)
        .frame(height: 70)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
        .overlay(alignment: .topLeading) {
            // A text editor has no prompt of its own.
            if project.commitMessage.isEmpty {
                Text("Commit message")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
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

/// The shells of **one** folder, in the order they were started: the repository
/// you are in, or the home folder while a home shell is on screen. Never both at
/// once — a list that mixed every repository's shells was impossible to read —
/// and the shells of the other repositories are shown when you switch to them.
///
/// The order never changes while shells are shown, so a card stays under the
/// pointer instead of jumping to the top the moment it is clicked.
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

    private var terminals: [OpenTerminal] { store.terminals(in: scope) }

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
