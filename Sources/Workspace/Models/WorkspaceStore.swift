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
        case files, pullRequests, changes, terminals, info

        var id: String { rawValue }

        var title: String {
            switch self {
            case .files: "Files"
            case .pullRequests: "PRs"
            case .changes: "Changes"
            case .terminals: "Terminals"
            case .info: "Info"
            }
        }

        var symbol: String {
            switch self {
            case .files: "folder"
            case .pullRequests: "arrow.triangle.pull"
            case .changes: "plusminus"
            case .terminals: "terminal"
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

    /// Whether the file tree lists what `.gitignore` covers. On by default —
    /// those files are still part of the folder — and the files pane has a
    /// toggle for the times they are only noise.
    var showsIgnoredFiles = true

    // Panel visibility, so the View menu can reach it too.
    var showsProjects = true
    var showsNavigator = true

    // Viewer (centre)
    private var items: [String: ViewerItem] = [:]

    /// Where one repository's viewer was left: its back/forward stack and
    /// whether the dashboard was on top. Each repository keeps its own, so
    /// switching repositories lands back on the page that repository was on.
    private struct ViewerState {
        var history: [String] = []
        var index = -1
        var showsDashboard = true
    }

    private var viewerStates: [URL: ViewerState] = [:]
    /// Used while no repository is selected (none added yet).
    private var detachedState = ViewerState()

    private var viewer: ViewerState {
        get {
            guard let id = selectedProjectID else { return detachedState }
            // A repository not visited yet starts on its dashboard.
            return viewerStates[id] ?? ViewerState()
        }
        set {
            if let id = selectedProjectID {
                viewerStates[id] = newValue
            } else {
                detachedState = newValue
            }
        }
    }

    /// Show the dashboard instead of whatever is open. History is kept, so Back
    /// still returns to it.
    var showsDashboard: Bool {
        get { viewer.showsDashboard }
        set { viewer.showsDashboard = newValue }
    }

    /// Render Markdown files instead of editing them.
    var markdownPreview = false
    var wrapsLines = false
    /// The toast at the bottom of the window. Set it through `showStatus` or
    /// `showError` so the kind is never left over from the message before.
    var statusMessage: StatusToast?

    func showStatus(_ text: String) {
        statusMessage = StatusToast(text: text)
    }

    /// For anything that failed — the toast draws itself in red and stays up
    /// longer, because a git error is several lines worth reading.
    func showError(_ text: String) {
        statusMessage = StatusToast(text: text, kind: .failure)
    }

    // GitHub accounts
    /// Every account `gh` is logged in to, loaded once on demand.
    var gitHubAccounts: [GitHubAccount] = []
    /// Set when a newly added repository still needs an account picked.
    var gitHubAccountPrompt: GitHubAccountPrompt?
    /// Repositories added in the same batch, waiting their turn to be asked.
    private var gitHubAccountQueue: [URL] = []

    private let projectsDefaultsKey = "workspace.projects"
    private let gitHubAccountsDefaultsKey = "workspace.githubAccounts"
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
        Task {
            // The remote has to be known before we can tell whether this is a
            // GitHub repository worth asking about, and the pull requests are
            // only worth loading once the account is settled.
            await project.refresh(loadPullRequests: false)
            let asked = await askForGitHubAccountIfNeeded(project)
            if !asked { await project.refreshPullRequests() }
        }
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
        viewerStates[project.id] = nil
        for (projectID, var state) in viewerStates {
            state.history.removeAll { items[$0] == nil }
            state.index = min(state.index, state.history.count - 1)
            viewerStates[projectID] = state
        }
        detachedState.history.removeAll { items[$0] == nil }
        detachedState.index = min(detachedState.index, detachedState.history.count - 1)

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
        let accounts = UserDefaults.standard.dictionary(forKey: gitHubAccountsDefaultsKey) as? [String: String] ?? [:]
        let paths = UserDefaults.standard.stringArray(forKey: projectsDefaultsKey) ?? []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let project = Project(url: URL(fileURLWithPath: path))
            project.gitHubAccount = accounts[path]
            projects.append(project)
        }
        selectedProjectID = projects.first?.id

        // The accounts have to reach `GitHubAccounts` before the first `gh`
        // call, so the refreshes wait behind that one await.
        let restored = projects
        Task {
            await GitHubAccounts.shared.replaceSelections(accounts)
            for project in restored {
                Task { await project.refresh() }
            }
        }
    }

    // MARK: - GitHub accounts

    /// Remembers which account this repository uses and reloads its pull
    /// requests as that account.
    func setGitHubAccount(_ login: String?, for project: Project) {
        guard project.gitHubAccount != login else { return }
        project.gitHubAccount = login

        var stored = UserDefaults.standard.dictionary(forKey: gitHubAccountsDefaultsKey) as? [String: String] ?? [:]
        stored[project.url.path] = login
        UserDefaults.standard.set(stored, forKey: gitHubAccountsDefaultsKey)

        Task {
            await GitHubAccounts.shared.select(login, forRepositoryAt: project.url.path)
            await project.refreshPullRequests()
        }
    }

    /// Loads the account list, so the pickers have something to show.
    @discardableResult
    func loadGitHubAccounts(reloading: Bool = false) async -> [GitHubAccount] {
        gitHubAccounts = await GitHubAccounts.shared.available(reloading: reloading)
        return gitHubAccounts
    }

    /// Asks which account a freshly added GitHub repository belongs to.
    /// Returns whether it will be asked about — with only one account logged in
    /// there is nothing to choose, so it never is.
    @discardableResult
    func askForGitHubAccountIfNeeded(_ project: Project) async -> Bool {
        guard project.host == .github, project.gitHubAccount == nil else { return false }
        let accounts = await loadGitHubAccounts()
        guard accounts.count > 1, projects.contains(where: { $0.id == project.id }) else { return false }

        // Adding several folders at once queues them up: one sheet, answered in
        // turn, rather than each replacing the last.
        guard gitHubAccountPrompt == nil else {
            if !gitHubAccountQueue.contains(project.id) { gitHubAccountQueue.append(project.id) }
            return true
        }
        gitHubAccountPrompt = prompt(for: project, accounts: accounts)
        return true
    }

    private func prompt(for project: Project, accounts: [GitHubAccount]) -> GitHubAccountPrompt {
        GitHubAccountPrompt(
            projectID: project.id,
            suggested: accounts.first(where: \.isActive)?.login ?? accounts[0].login
        )
    }

    /// The user answered the sheet, or dismissed it — dismissing leaves the
    /// repository on `gh`'s active account and asks again next time it is added.
    func resolveGitHubAccountPrompt(_ login: String?) {
        guard let answered = gitHubAccountPrompt else { return }
        gitHubAccountPrompt = nil

        if let project = project(withID: answered.projectID) {
            if let login {
                setGitHubAccount(login, for: project)
            } else {
                Task { await project.refreshPullRequests() }
            }
        }

        // Whatever else was added in the same batch comes next.
        while let next = gitHubAccountQueue.first {
            gitHubAccountQueue.removeFirst()
            guard let project = project(withID: next), project.gitHubAccount == nil,
                  !gitHubAccounts.isEmpty else { continue }
            gitHubAccountPrompt = prompt(for: project, accounts: gitHubAccounts)
            return
        }
    }

    // MARK: - Viewer history

    var current: ViewerItem? {
        let viewer = viewer
        guard viewer.history.indices.contains(viewer.index) else { return nil }
        return items[viewer.history[viewer.index]]
    }

    // The dashboard is the root of the history: Back from the oldest open item
    // lands there, the way a browser's home page would, and Forward returns.
    var canGoBack: Bool {
        !showsDashboard && current != nil
    }

    var canGoForward: Bool {
        if showsDashboard { return current != nil }
        return viewer.index >= 0 && viewer.index < viewer.history.count - 1
    }

    /// Titles of what back and forward would show, for the button tooltips.
    var backTitle: String? {
        guard canGoBack else { return nil }
        let viewer = viewer
        guard viewer.history.indices.contains(viewer.index - 1) else { return "the dashboard" }
        return items[viewer.history[viewer.index - 1]]?.title
    }

    var forwardTitle: String? {
        if showsDashboard { return current?.title }
        let viewer = viewer
        guard viewer.history.indices.contains(viewer.index + 1) else { return nil }
        return items[viewer.history[viewer.index + 1]]?.title
    }

    func goBack() {
        guard canGoBack else { return }
        // At the oldest item, Back leaves it open and shows the dashboard.
        if viewer.index <= 0 {
            showsDashboard = true
            return
        }
        viewer.index -= 1
    }

    func goForward() {
        guard canGoForward else { return }
        // From the dashboard, Forward returns to whatever was open.
        if showsDashboard {
            showsDashboard = false
            return
        }
        viewer.index += 1
    }

    /// Closes what is open and returns to the dashboard.
    func closeCurrent() {
        guard let current else {
            showsDashboard = true
            return
        }
        // A terminal is only ever closed tab by tab, by the user. This puts the
        // dashboard back and leaves its shells running, ready in the Terminals
        // tab.
        if current.isTerminal {
            showsDashboard = true
            return
        }
        items[current.id] = nil
        forgetItem(current.id)
        showsDashboard = true
    }

    /// Drops a closed item from every repository's history.
    private func forgetItem(_ id: String) {
        for (projectID, var state) in viewerStates {
            state.history.removeAll { $0 == id }
            state.index = min(state.index, state.history.count - 1)
            viewerStates[projectID] = state
        }
        detachedState.history.removeAll { $0 == id }
        detachedState.index = min(detachedState.index, detachedState.history.count - 1)
    }

    func showDashboard() {
        showsDashboard = true
    }

    /// Shows an item, remembering where we came from.
    private func present(_ item: ViewerItem) {
        items[item.id] = item

        // An item belongs to one repository, so showing it selects that
        // repository and the item joins that repository's own history.
        if let owner = owningProjectID(of: item), owner != selectedProjectID {
            selectedProjectID = owner
        }
        showsDashboard = false

        if current?.id == item.id { return }

        // Opening something new discards the forward history, like a browser.
        if viewer.index >= 0, viewer.index < viewer.history.count - 1 {
            viewer.history.removeSubrange((viewer.index + 1)...)
        }
        viewer.history.append(item.id)
        viewer.index = viewer.history.count - 1
        trimHistory()
    }

    /// Which repository's history an item belongs in.
    private func owningProjectID(of item: ViewerItem) -> URL? {
        switch item.kind {
        case .file(let url): project(containing: url)?.id
        case .workingDiff(let projectID, _, _): projectID
        case .pullRequest(let projectID, _): projectID
        case .terminal(let projectID): projectID
        }
    }

    /// Keeps memory bounded: drop the oldest entries of the current
    /// repository's history, but never a file with unsaved edits.
    private func trimHistory() {
        while viewer.history.count > historyLimit {
            guard let oldest = viewer.history.first else { break }
            if items[oldest]?.isDirty == true {
                // Keep it, and stop trimming rather than skipping arbitrarily.
                break
            }
            viewer.history.removeFirst()
            viewer.index -= 1
            // A terminal outlives its history entry: its shells keep running
            // until the user closes their tabs.
            if !isOpenAnywhere(oldest), items[oldest]?.isTerminal != true {
                items[oldest] = nil
            }
        }
    }

    private func isOpenAnywhere(_ id: String) -> Bool {
        viewerStates.values.contains { $0.history.contains(id) }
            || detachedState.history.contains(id)
    }

    var openDocuments: [OpenDocument] {
        items.values.compactMap(\.document)
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
        // The header names the pull request by its title alone — the number and
        // the repository are already on screen in the pane below and in the
        // repositories sidebar.
        let item = items[kind.key] ?? ViewerItem(kind: kind, title: pr.title)
        item.pullRequest = pr
        present(item)
        // The viewer shows one pull request, so the navigator switches to the
        // list of the rest — the same move opening a terminal makes.
        navigatorTab = .pullRequests

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

    func postComment(
        _ body: String,
        on item: ViewerItem,
        project: Project,
        pr: PullRequest,
        replyingTo parent: PullRequestComment? = nil
    ) async {
        item.isPostingComment = true
        item.commentError = nil
        do {
            try await PullRequestService.postComment(
                body,
                on: pr,
                replyingTo: parent,
                in: project.url
            )
            showStatus(parent == nil
                ? "Comment posted on #\(pr.number)"
                : "Reply posted on #\(pr.number)")
            await loadComments(item, project: project, pr: pr)
        } catch {
            item.commentError = error.localizedDescription
        }
        item.isPostingComment = false
    }

    /// Comments on one line of the diff, starting a new thread there.
    func postInlineComment(
        _ body: String,
        at anchor: DiffLineAnchor,
        on item: ViewerItem,
        project: Project,
        pr: PullRequest
    ) async {
        item.isPostingComment = true
        item.commentError = nil
        do {
            try await PullRequestService.postInlineComment(
                body,
                on: pr,
                at: anchor,
                in: project.url
            )
            showStatus("Comment posted on \(anchor.path):\(anchor.line)")
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
        } else if let session = item.selectedTerminal {
            selectTerminal(session, in: item)
        }
        present(item)
        // The viewer shows one shell and has no tab bar, so the navigator
        // switches to the list of the rest.
        navigatorTab = .terminals
        return item
    }

    /// Every shell still running, most recently used first. Terminal items are
    /// never dropped on their own, so this outlives closing the viewer and
    /// switching repositories.
    var recentTerminals: [RecentTerminal] {
        items.values
            .filter(\.isTerminal)
            .flatMap { item in item.terminals.map { RecentTerminal(session: $0, item: item) } }
            .sorted { $0.session.lastUsedAt > $1.session.lastUsedAt }
    }

    /// Puts one shell from the terminals list back on screen.
    func showTerminal(_ recent: RecentTerminal) {
        selectTerminal(recent.session, in: recent.item)
        present(recent.item)
    }

    /// Makes a tab the visible one and marks it as the newest in the list.
    func selectTerminal(_ session: TerminalSession, in item: ViewerItem) {
        item.selectedTerminalID = session.id
        session.lastUsedAt = Date()
    }

    /// Whether this exact shell is what the viewer is showing.
    func isShowing(_ recent: RecentTerminal) -> Bool {
        !showsDashboard
            && current?.id == recent.item.id
            && recent.item.selectedTerminal?.id == recent.session.id
    }

    func closeTerminal(_ recent: RecentTerminal) {
        closeTerminalTab(recent.session, in: recent.item)
    }

    /// Always starts a fresh shell for a repository, next to any it already has.
    func newTerminal(in project: Project) {
        let kind = ViewerItem.Kind.terminal(projectID: project.id)
        let item = items[kind.key] ?? ViewerItem(
            kind: kind,
            title: "Terminal",
            subtitle: project.name
        )
        addTerminalTab(to: item, project: project)
        present(item)
        navigatorTab = .terminals
    }

    /// ⌘T while a terminal is on screen: another shell for the same repository.
    func newTerminalTab(in item: ViewerItem) {
        guard case .terminal(let projectID) = item.kind,
              let project = project(withID: projectID) else { return }
        addTerminalTab(to: item, project: project)
        navigatorTab = .terminals
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
        forgetItem(item.id)
        if current == nil { showsDashboard = true }
    }

    // MARK: - Document actions

    func saveCurrentDocument() {
        guard let document = current?.document else { return }
        do {
            try document.save()
            showStatus("Saved \(document.name)")
            if let project = project(containing: document.url) {
                Task { await project.refreshGitStatus() }
            }
        } catch {
            showError("Could not save \(document.name): \(error.localizedDescription)")
        }
    }

    // MARK: - External tools

    /// The Claude desktop app, only used to borrow its icon.
    static let claudeBundleIdentifier = "com.anthropic.claudefordesktop"

    /// Starts Claude Code on this repository, in its own terminal tab.
    func openClaude(in project: Project) {
        openTerminal(in: project, runningCommand: "claude", title: "Claude")
    }

    /// Opens the project in another editor, if it is installed.
    func openExternally(_ project: Project, using tool: ExternalTool) {
        Task {
            let result = await Shell.runScript(
                "\(tool.command) \(Shell.quote(project.url.path))",
                in: project.url,
                timeout: 20
            )
            if result.isSuccess {
                showStatus("Opened \(project.name) in \(tool.title)")
            } else {
                showError("\(tool.title) is not installed (\(tool.executable) not on PATH).")
            }
        }
    }

    // MARK: - Sidebar search

    func fileSearchResults(in project: Project) -> [FileNode] {
        let query = fileSearchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return project.root.flattenedLoadedDescendants()
            .filter { !$0.isDirectory && $0.name.localizedCaseInsensitiveContains(query) }
            .filter { showsIgnoredFiles || !project.isIgnored($0.url) }
    }
}

/// A short-lived message at the bottom of the window. The kind only decides how
/// it is drawn and how long it stays: a failure is worth noticing, a
/// confirmation is not.
struct StatusToast: Equatable {
    enum Kind {
        case success, failure
    }

    var text: String
    var kind: Kind = .success
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
