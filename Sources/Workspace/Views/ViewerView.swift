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
                Divider()
                StatusBar(item: item)
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
            .pointerCursor()
            .help("Show or hide the repositories sidebar (⌘0)")

            Button {
                store.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!store.canGoBack)
            .pointerCursor(store.canGoBack)
            .help(store.backTitle.map { "Back to \($0)" } ?? "Back")

            Button {
                store.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!store.canGoForward)
            .pointerCursor(store.canGoForward)
            .help(store.forwardTitle.map { "Forward to \($0)" } ?? "Forward")

            if let item = store.current, !store.showsDashboard {
                openItem(item)
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
                .pointerCursor()
                .help("Preview Markdown")
            }

            if let item = store.current, !store.showsDashboard {
                Button {
                    store.closeCurrent()
                } label: {
                    Image(systemName: "xmark")
                }
                .pointerCursor()
                .help(
                    item.isTerminal
                        ? "Back to the dashboard — the shells keep running (⇧⌘W)"
                        : "Close and go back to the dashboard (⇧⌘W)"
                )
            }

            if store.selectedProject != nil, store.showsNavigator {
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
                .frame(width: 165)
                .pointerCursor()
            }

            // Last in the row, so it stays put as the tabs come and go.
            Button {
                withAnimation { store.showsNavigator.toggle() }
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .pointerCursor()
            .help("Show or hide files, PRs and info (⌥⌘0)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(.bar)
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
        }
        .padding(.leading, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ item: ViewerItem) -> some View {
        switch item.kind {
        case .file:
            fileContent(item)
        case .workingDiff:
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
                layout: Binding(get: { item.diffLayout }, set: { item.diffLayout = $0 })
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

struct StatusBar: View {
    let item: ViewerItem

    var body: some View {
        HStack(spacing: 12) {
            if let document = item.document, case .text = document.content {
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
            } else if item.diff != nil {
                // Counts live in the diff's own bar; don't repeat them here.
                Text(item.subtitle ?? item.title)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer()
            } else {
                Text(item.subtitle ?? item.title)
                    .lineLimit(1)
                Spacer()
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
        // dashboard is shown rather than trusting the last scan.
        .task(id: store.selectedProject?.id) {
            await store.selectedProject?.refreshPorts()
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
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.largeTitle.weight(.semibold))
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
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                spacing: 12
            ) {
                StatTile(
                    title: "Open PRs",
                    value: "\(project.pullRequests.count)",
                    symbol: "arrow.triangle.pull",
                    tint: .accentColor
                ) { store.navigatorTab = .pullRequests }

                StatTile(
                    title: "Changed files",
                    value: "\(project.changeCount)",
                    symbol: "plusminus",
                    tint: project.changeCount == 0 ? .green : .orange
                ) { store.navigatorTab = .changes }

                StatTile(
                    title: "Ports",
                    value: "\(project.ports.count)",
                    symbol: "network",
                    tint: .green
                ) { store.navigatorTab = .info }

                StatTile(
                    title: "Files",
                    value: "\(project.root.children?.count ?? 0)",
                    symbol: "folder",
                    tint: .blue
                ) { store.navigatorTab = .files }
            }

            HStack(spacing: 8) {
                Button {
                    store.openTerminal(in: project)
                } label: {
                    Label("Open Terminal", systemImage: "terminal")
                }
                Button {
                    store.openClaude(in: project)
                } label: {
                    AppIconLabel(
                        title: "Open in Claude",
                        bundleIdentifier: WorkspaceStore.claudeBundleIdentifier,
                        fallbackSymbol: "sparkles"
                    )
                }
                .help("Start Claude Code in a terminal tab for this repository")
                Button {
                    store.openExternally(project, using: .vscode)
                } label: {
                    Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            .buttonStyle(.bordered)
            .pointerCursor()

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
                    // reads as one board rather than a board and a list.
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 240), spacing: 12)],
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
        }
        .padding(28)
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// One open pull request on the dashboard, as a tile.
struct PullRequestTile: View {
    let pr: PullRequest
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("#\(pr.number)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if pr.isDraft {
                        Pill(text: "draft", color: .secondary)
                    }
                    if let review = pr.reviewLabel {
                        Pill(text: review, color: review == "Approved" ? .green : .orange)
                    }
                }

                Text(pr.title)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    Image(systemName: "person.crop.circle")
                    Text(pr.author)
                        .lineLimit(1)
                    Image(systemName: "arrow.right").imageScale(.small)
                    Text(pr.targetBranch)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let additions = pr.additions, let deletions = pr.deletions {
                        Text("+\(additions)").foregroundStyle(.green)
                        Text("−\(deletions)").foregroundStyle(.red)
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .quaternary.opacity(isHovering ? 0.4 : 0.25),
                in: RoundedRectangle(cornerRadius: 11)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovering = $0 }
        .help(pr.title)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
