import AppKit
import SwiftUI

/// The centre of the window: exactly one item at a time.
struct ViewerView: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            if let item = store.current, !store.showsDashboard {
                header(item)
                Divider()
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
        // sidebars. Editor and terminal still draw their standard background.
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - Header

    /// Breadcrumb for the open item, with ✕ on the right.
    private func header(_ item: ViewerItem) -> some View {
        HStack(spacing: 7) {
            Image(systemName: item.symbol)
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(item.title)
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
            Spacer()
            Button {
                store.closeCurrent()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close and go back to the dashboard (⇧⌘W)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
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
                    Image(systemName: project.host.symbol)
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
                    store.openExternally(project, using: .vscode)
                } label: {
                    Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            .buttonStyle(.bordered)

            if !project.pullRequests.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Open pull requests")
                        .font(.headline)
                    ForEach(project.pullRequests.prefix(6)) { pr in
                        Button {
                            store.openPullRequest(pr, project: project)
                        } label: {
                            HStack(spacing: 8) {
                                Text("#\(pr.number)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(pr.title)
                                    .lineLimit(1)
                                Spacer()
                                Text(pr.author)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
    }
}
