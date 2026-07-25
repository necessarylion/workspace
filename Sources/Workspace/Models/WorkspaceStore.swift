import AppKit
import Foundation

/// Single source of truth for the window.
///
/// The centre of the window shows one item at a time. Opening a file, a diff or
/// a pull request replaces what is on screen and pushes the previous item onto
/// a back stack, the way a browser does.
@MainActor
@Observable
final class WorkspaceStore {
    /// Which list the left sidebar is showing.
    enum NavigatorTab: String, CaseIterable, Identifiable {
        case files, pullRequests, changes, info

        var id: String { rawValue }

        var title: String {
            switch self {
            case .files: "Files"
            case .pullRequests: "PRs"
            case .changes: "Changes"
            case .info: "Info"
            }
        }

        var symbol: String {
            switch self {
            case .files: "folder"
            case .pullRequests: "arrow.triangle.pull"
            case .changes: "plusminus"
            case .info: "info.circle"
            }
        }
    }

    // Projects (right sidebar)
    var projects: [Project] = []
    var selectedProjectID: URL?

    // Navigator (right sidebar)
    var navigatorTab: NavigatorTab = .files
    var fileSearchText = ""

    // Panel visibility, so the View menu can reach it too.
    var showsProjects = true
    var showsNavigator = true

    /// Show the dashboard instead of whatever is open. History is kept, so Back
    /// still returns to it.
    var showsDashboard = true

    // Viewer (centre)
    private var items: [String: ViewerItem] = [:]
    private var history: [String] = []
    private var historyIndex = -1

    /// Render Markdown files instead of editing them.
    var markdownPreview = false
    var wrapsLines = false
    var statusMessage: String?

    private let projectsDefaultsKey = "workspace.projects"
    private let historyLimit = 40

    init() {
        restoreProjects()
    }

    // MARK: - Projects

    var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    func addProject(at url: URL, makeSelected: Bool = true) {
        if let existing = projects.first(where: { $0.url == url }) {
            if makeSelected { selectedProjectID = existing.id }
            return
        }
        let project = Project(url: url)
        projects.append(project)
        if makeSelected || selectedProjectID == nil {
            selectedProjectID = project.id
        }
        persistProjects()
        Task { await project.refresh() }
    }

    func removeProject(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        LanguageServerRegistry.shared.shutdownServices(inside: project.url)

        // Forget anything that belonged to it.
        for (key, item) in items where item.projectID == project.id {
            item.terminals.forEach { $0.terminate() }
            items[key] = nil
        }
        for (key, item) in items {
            guard case .file(let url) = item.kind,
                  url.path.hasPrefix(project.url.path + "/") else { continue }
            items[key] = nil
        }
        history.removeAll { items[$0] == nil }
        historyIndex = min(historyIndex, history.count - 1)

        if selectedProjectID == project.id {
            selectedProjectID = projects.first?.id
        }
        persistProjects()
    }

    /// The only way a repository enters the workspace: the user picks a folder.
    func promptForProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose one or more repository folders."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            addProject(at: url, makeSelected: url == panel.urls.first)
        }
    }

    func project(withID id: URL?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func project(containing url: URL) -> Project? {
        projects
            .filter { url.path.hasPrefix($0.url.path) }
            .max { $0.url.path.count < $1.url.path.count }
    }

    func refreshAll() {
        for project in projects {
            Task { await project.refresh() }
        }
    }

    private func persistProjects() {
        UserDefaults.standard.set(projects.map(\.url.path), forKey: projectsDefaultsKey)
    }

    private func restoreProjects() {
        let paths = UserDefaults.standard.stringArray(forKey: projectsDefaultsKey) ?? []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let project = Project(url: URL(fileURLWithPath: path))
            projects.append(project)
            Task { await project.refresh() }
        }
        selectedProjectID = projects.first?.id
    }

    // MARK: - Viewer history

    var current: ViewerItem? {
        guard history.indices.contains(historyIndex) else { return nil }
        return items[history[historyIndex]]
    }

    var canGoBack: Bool {
        if showsDashboard { return current != nil }
        return historyIndex > 0
    }

    var canGoForward: Bool {
        !showsDashboard && historyIndex >= 0 && historyIndex < history.count - 1
    }

    /// Titles of what back and forward would show, for the button tooltips.
    var backTitle: String? {
        // From the dashboard, Back simply returns to what is already open.
        if showsDashboard { return current?.title }
        guard history.indices.contains(historyIndex - 1) else { return nil }
        return items[history[historyIndex - 1]]?.title
    }

    var forwardTitle: String? {
        guard !showsDashboard, history.indices.contains(historyIndex + 1) else { return nil }
        return items[history[historyIndex + 1]]?.title
    }

    func goBack() {
        // Coming back from the dashboard just shows what was open again.
        if showsDashboard, current != nil {
            showsDashboard = false
            return
        }
        guard canGoBack else { return }
        showsDashboard = false
        historyIndex -= 1
    }

    func goForward() {
        guard canGoForward else { return }
        showsDashboard = false
        historyIndex += 1
    }

    /// Closes what is open and returns to the dashboard.
    func closeCurrent() {
        guard let current else {
            showsDashboard = true
            return
        }
        current.terminals.forEach { $0.terminate() }
        items[current.id] = nil
        history.removeAll { $0 == current.id }
        historyIndex = min(historyIndex, history.count - 1)
        showsDashboard = true
    }

    func showDashboard() {
        showsDashboard = true
    }

    /// Shows an item, remembering where we came from.
    private func present(_ item: ViewerItem) {
        items[item.id] = item
        showsDashboard = false

        if current?.id == item.id { return }

        // Opening something new discards the forward history, like a browser.
        if historyIndex >= 0, historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(item.id)
        historyIndex = history.count - 1
        trimHistory()
    }

    /// Keeps memory bounded: drop the oldest entries, but never a file with
    /// unsaved edits.
    private func trimHistory() {
        while history.count > historyLimit {
            guard let oldest = history.first else { break }
            if items[oldest]?.isDirty == true {
                // Keep it, and stop trimming rather than skipping arbitrarily.
                break
            }
            history.removeFirst()
            historyIndex -= 1
            if !history.contains(oldest) {
                items[oldest]?.terminals.forEach { $0.terminate() }
                items[oldest] = nil
            }
        }
    }

    var openDocuments: [OpenDocument] {
        history.compactMap { items[$0]?.document }
    }

    var dirtyDocuments: [OpenDocument] {
        openDocuments.filter(\.isDirty)
    }

    // MARK: - Opening things

    func openFile(_ url: URL, revealLine: Int? = nil) {
        let key = ViewerItem.Kind.file(url).key
        if let existing = items[key] {
            if let revealLine { existing.document?.revealLine = revealLine }
            present(existing)
            return
        }

        let item = ViewerItem(
            kind: .file(url),
            title: url.lastPathComponent,
            subtitle: project(containing: url)?.name
        )
        let document = OpenDocument(url: url)
        document.revealLine = revealLine
        item.document = document
        present(item)

        // Selecting a file in another project should follow the file.
        if let owner = project(containing: url), owner.id != selectedProjectID {
            selectedProjectID = owner.id
        }
    }

    func openWorkingDiff(project: Project, change: GitStatus.Change) {
        let isUntracked = change.label == "Untracked"
        let kind = ViewerItem.Kind.workingDiff(
            projectID: project.id,
            path: change.path,
            isUntracked: isUntracked
        )
        let item = items[kind.key] ?? ViewerItem(
            kind: kind,
            title: (change.path as NSString).lastPathComponent,
            subtitle: "Changes · \(project.name)"
        )
        present(item)
        Task { await loadWorkingDiff(item, project: project, path: change.path, isUntracked: isUntracked) }
    }

    private func loadWorkingDiff(
        _ item: ViewerItem,
        project: Project,
        path: String,
        isUntracked: Bool
    ) async {
        item.isLoading = true
        item.errorMessage = nil
        let text = await GitStatus.diff(path: path, in: project.url, isUntracked: isUntracked)
        item.diff = DiffHighlighter.highlight(DiffParser.parse(text))
        if item.diff?.isEmpty == true {
            item.errorMessage = "No textual changes to show for this file."
        }
        item.isLoading = false
    }

    /// One diff for everything in the working tree, untracked files included.
    /// Identified by an empty path — no real change ever has one.
    func openAllChanges(project: Project) {
        let kind = ViewerItem.Kind.workingDiff(projectID: project.id, path: "", isUntracked: false)
        let item = items[kind.key] ?? ViewerItem(
            kind: kind,
            title: "All Changes",
            subtitle: "Changes · \(project.name)"
        )
        present(item)
        Task { await loadAllChanges(item, project: project) }
    }

    private func loadAllChanges(_ item: ViewerItem, project: Project) async {
        item.isLoading = true
        item.errorMessage = nil
        let untracked = project.gitStatus?.changes
            .filter { $0.label == "Untracked" }
            .map(\.path) ?? []
        let text = await GitStatus.diffAll(in: project.url, untrackedPaths: untracked)
        item.diff = DiffHighlighter.highlight(DiffParser.parse(text))
        if item.diff?.isEmpty == true {
            item.errorMessage = "No textual changes to show."
        }
        item.isLoading = false
    }

    func openPullRequest(_ pr: PullRequest, project: Project) {
        let kind = ViewerItem.Kind.pullRequest(projectID: project.id, number: pr.number)
        let item = items[kind.key] ?? ViewerItem(
            kind: kind,
            title: "#\(pr.number)",
            subtitle: project.name
        )
        item.pullRequest = pr
        present(item)

        if item.diff == nil {
            Task { await loadPullRequestDiff(item, project: project, pr: pr) }
        }
        if item.comments.isEmpty {
            Task { await loadComments(item, project: project, pr: pr) }
        }
    }

    func loadPullRequestDiff(_ item: ViewerItem, project: Project, pr: PullRequest) async {
        item.isLoading = true
        item.errorMessage = nil
        if let text = await PullRequestService.diff(for: pr, in: project.url) {
            item.diff = DiffHighlighter.highlight(DiffParser.parse(text))
        } else {
            item.errorMessage = "Could not load the diff for this pull request."
        }
        item.isLoading = false
    }

    func loadComments(_ item: ViewerItem, project: Project, pr: PullRequest) async {
        item.isLoadingComments = true
        item.commentError = nil
        do {
            item.comments = try await PullRequestService.comments(for: pr, in: project.url)
        } catch {
            item.comments = []
            item.commentError = error.localizedDescription
        }
        item.isLoadingComments = false
    }

    func postComment(_ body: String, on item: ViewerItem, project: Project, pr: PullRequest) async {
        item.isPostingComment = true
        item.commentError = nil
        do {
            try await PullRequestService.postComment(body, on: pr, in: project.url)
            statusMessage = "Comment posted on #\(pr.number)"
            await loadComments(item, project: project, pr: pr)
        } catch {
            item.commentError = error.localizedDescription
        }
        item.isPostingComment = false
    }

    /// Shows the project's terminal. Each project has one terminal viewer item
    /// that holds any number of shell tabs. A plain "Open Terminal" reuses what
    /// is already running; passing a command always starts a fresh tab for it.
    @discardableResult
    func openTerminal(
        in project: Project,
        runningCommand command: String? = nil,
        title: String? = nil
    ) -> ViewerItem {
        let kind = ViewerItem.Kind.terminal(projectID: project.id)
        let item = items[kind.key] ?? ViewerItem(
            kind: kind,
            title: "Terminal",
            subtitle: project.name
        )
        if item.terminals.isEmpty || command != nil || title != nil {
            addTerminalTab(to: item, project: project, runningCommand: command, title: title)
        }
        present(item)
        return item
    }

    /// The + button in the terminal tab bar.
    func newTerminalTab(in item: ViewerItem) {
        guard case .terminal(let projectID) = item.kind,
              let project = project(withID: projectID) else { return }
        addTerminalTab(to: item, project: project)
    }

    private func addTerminalTab(
        to item: ViewerItem,
        project: Project,
        runningCommand command: String? = nil,
        title: String? = nil
    ) {
        let session = TerminalSession(
            directory: project.url,
            title: title ?? "Shell \(item.terminals.count + 1)"
        )
        // When the shell exits (typing `exit`, or the process dies), the tab
        // goes away like in any terminal app.
        session.onExit = { [weak self, weak item, weak session] in
            guard let self, let item, let session else { return }
            self.closeTerminalTab(session, in: item)
        }
        item.terminals.append(session)
        item.selectedTerminalID = session.id
        session.startIfNeeded(runningCommand: command)
    }

    /// Closes one tab; closing the last tab closes the terminal itself.
    func closeTerminalTab(_ session: TerminalSession, in item: ViewerItem) {
        session.terminate()
        guard let index = item.terminals.firstIndex(where: { $0.id == session.id }) else { return }
        item.terminals.remove(at: index)
        if item.selectedTerminalID == session.id {
            let neighbour = min(index, item.terminals.count - 1)
            item.selectedTerminalID = neighbour >= 0 ? item.terminals[neighbour].id : nil
        }

        guard item.terminals.isEmpty else { return }
        items[item.id] = nil
        history.removeAll { $0 == item.id }
        historyIndex = min(historyIndex, history.count - 1)
        if current == nil { showsDashboard = true }
    }

    // MARK: - Document actions

    func saveCurrentDocument() {
        guard let document = current?.document else { return }
        do {
            try document.save()
            statusMessage = "Saved \(document.name)"
            if let project = project(containing: document.url) {
                Task { await project.refreshGitStatus() }
            }
        } catch {
            statusMessage = "Could not save \(document.name): \(error.localizedDescription)"
        }
    }

    // MARK: - External tools

    /// Opens the project in another editor, if it is installed.
    func openExternally(_ project: Project, using tool: ExternalTool) {
        Task {
            let result = await Shell.runScript(
                "\(tool.command) \(Shell.quote(project.url.path))",
                in: project.url,
                timeout: 20
            )
            statusMessage = result.isSuccess
                ? "Opened \(project.name) in \(tool.title)"
                : "\(tool.title) is not installed (\(tool.executable) not on PATH)."
        }
    }

    // MARK: - Sidebar search

    func fileSearchResults(in project: Project) -> [FileNode] {
        let query = fileSearchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return project.root.flattenedLoadedDescendants()
            .filter { !$0.isDirectory && $0.name.localizedCaseInsensitiveContains(query) }
    }
}

/// Editors we offer to hand a project over to.
enum ExternalTool: String, CaseIterable, Identifiable {
    case vscode, cursor, sublime, zed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vscode: "VS Code"
        case .cursor: "Cursor"
        case .sublime: "Sublime Text"
        case .zed: "Zed"
        }
    }

    var executable: String {
        switch self {
        case .vscode: "code"
        case .cursor: "cursor"
        case .sublime: "subl"
        case .zed: "zed"
        }
    }

    var command: String { executable }

    var symbol: String {
        switch self {
        case .vscode: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow.rays"
        case .sublime: "s.square"
        case .zed: "bolt"
        }
    }
}
