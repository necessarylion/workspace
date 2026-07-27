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
    /// The panes the navigator switches between. There was a PRs tab here too,
    /// listing the open pull requests as cards; the dashboard's table says
    /// everything it said and four columns more, in a pane wide enough for
    /// them, so a second list of the same thing was only a place to lose track
    /// of which one you were looking at.
    enum NavigatorTab: String, CaseIterable, Identifiable {
        case files, changes, terminals, claude, info

        var id: String { rawValue }

        var title: String {
            switch self {
            case .files: "Files"
            case .changes: "Changes"
            case .terminals: "Terminals"
            case .claude: "Claude"
            case .info: "Info"
            }
        }

        var symbol: String {
            switch self {
            case .files: "folder"
            case .changes: "plusminus"
            case .terminals: "terminal"
            case .claude: "sparkles"
            case .info: "info.circle"
            }
        }
    }

    // Projects (right sidebar)
    var projects: [Project] = []
    var selectedProjectID: URL?
    /// Filter for the repositories sidebar. Only narrows what is listed — the
    /// stored order and the selection are left alone.
    var projectSearchText = ""

    // Navigator (right sidebar)
    var navigatorTab: NavigatorTab = .files
    var fileSearchText = ""

    /// What the file search found, kept for the editor: a file opened from a
    /// result marks every occurrence, not only the line that was clicked. Set
    /// when a result is opened, dropped when the search box is emptied.
    var searchHighlight: String?

    /// ⌘F in the editor. One for the app, because there is one editor — and it
    /// lives here rather than in the file view so ⎋ can tell "close the find
    /// bar" from "close the file".
    let editorFind = EditorFind()

    /// Whether the file tree lists what `.gitignore` covers. Off by default —
    /// build output and caches bury the files actually worked on — and the files
    /// pane has a toggle for the times one of them is wanted.
    var showsIgnoredFiles = false

    /// Whether the Claude tab lists the conversations on disk under the ones
    /// open in this window. On by default — resuming an old conversation is
    /// most of what the tab is for — but a repository Claude has been used on
    /// for months has a long tail of them, and someone working in one live
    /// conversation should be able to put that tail away. Remembered between
    /// launches: a list you closed should stay closed.
    var showsPastClaudeConversations = true {
        didSet {
            UserDefaults.standard.set(
                showsPastClaudeConversations,
                forKey: pastClaudeConversationsDefaultsKey
            )
        }
    }

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
    /// Draw `.drawio` files instead of editing them. On by default, the other
    /// way round from Markdown: nobody opens a diagram to read its XML.
    var drawioPreview = true
    var wrapsLines = false
    /// Show the file index beside a diff that touches more than one file. A
    /// window-wide preference rather than a per-diff one: it is a way of
    /// working, not a property of the pull request being read.
    var showsDiffFiles = true
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
    private let pinnedProjectsDefaultsKey = "workspace.pinnedProjects"
    private let gitHubAccountsDefaultsKey = "workspace.githubAccounts"
    private let terminalsDefaultsKey = "workspace.terminals"
    private let pastClaudeConversationsDefaultsKey = "workspace.showsPastClaudeConversations"
    private let historyLimit = 40
    /// Pending write of the terminal list, see `scheduleTerminalPersist`.
    @ObservationIgnored private var terminalPersistTask: Task<Void, Never>?

    init() {
        // Read before the setter can write it back: an absent key means nobody
        // has chosen, which is the default rather than false.
        if UserDefaults.standard.object(forKey: pastClaudeConversationsDefaultsKey) != nil {
            showsPastClaudeConversations = UserDefaults.standard.bool(
                forKey: pastClaudeConversationsDefaultsKey
            )
        }
        restoreProjects()
        restoreTerminals()
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

        // Forget anything that belonged to it, its shells and its Claude
        // conversation included — the window-wide terminal is untouched, it
        // belongs to no repository.
        for (key, item) in items where item.projectID == project.id {
            item.terminals.forEach { $0.terminate() }
            item.claudes.forEach { $0.shutDown() }
            items[key] = nil
        }
        persistTerminals()
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

    /// What the repositories sidebar lists: every repository, or the ones
    /// matching the filter. The folder path counts as a match too — two
    /// repositories can share a name.
    var visibleProjects: [Project] {
        let query = projectSearchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return projects }
        return projects.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.url.path.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: - Repository switcher (⌃⇥)

    /// Which repository the ⌃⇥ switcher is pointing at, as an index into
    /// `projects`. `nil` while the switcher is away, which is most of the time.
    ///
    /// Nothing is selected until ⌃ is let go: the whole point of holding the key
    /// is to look down the row first, and switching on every press would reload
    /// each repository on the way past.
    private(set) var switcherIndex: Int?

    var isSwitchingProjects: Bool { switcherIndex != nil }

    /// The repository the switcher is on, for the overlay to ring.
    var switcherProject: Project? {
        guard let switcherIndex, projects.indices.contains(switcherIndex) else { return nil }
        return projects[switcherIndex]
    }

    /// ⌃⇥ — opens the switcher on the next repository, and moves one along for
    /// every further press while ⌃ is still down. ⇧ turns it around. The list is
    /// the sidebar's own order, the one the user dragged the cards into, and it
    /// wraps at both ends.
    ///
    /// The filter box is ignored on purpose: it narrows what is *listed*, and a
    /// switcher that could only reach some of the repositories would be a trap.
    func cycleProjectSwitcher(backwards: Bool = false) {
        guard projects.count > 1 else { return }
        let from = switcherIndex
            ?? projects.firstIndex { $0.id == selectedProjectID }
            ?? 0
        let step = backwards ? -1 : 1
        switcherIndex = (from + step + projects.count) % projects.count
    }

    /// ← and → while the switcher is up, for picking one by eye rather than by
    /// counting presses.
    func moveProjectSwitcher(by step: Int) {
        guard switcherIndex != nil else { return }
        cycleProjectSwitcher(backwards: step < 0)
    }

    /// Puts the ring on one tile, for the pointer — clicking a tile picks it
    /// whether or not ⇥ ever walked that far.
    func moveProjectSwitcher(to index: Int) {
        guard projects.indices.contains(index) else { return }
        switcherIndex = index
    }

    /// ⌃ let go, or ⏎: the repository under the ring becomes the selected one.
    /// Its viewer comes back exactly as it was left — each repository keeps its
    /// own history — so this is a switch, not a reload.
    func commitProjectSwitcher() {
        guard let project = switcherProject else {
            switcherIndex = nil
            return
        }
        switcherIndex = nil
        selectedProjectID = project.id
    }

    /// ⎋: the switcher goes away and the selection stays where it was.
    func cancelProjectSwitcher() {
        switcherIndex = nil
    }

    /// Starring a repository. Pinned ones are kept at the top of the sidebar in
    /// alphabetical order, so this reorders the list as well as saving the flag.
    func togglePin(_ project: Project) {
        project.isPinned.toggle()
        applyPinOrdering()
        persistProjects()
    }

    /// Pinned repositories first, by name; everything else keeps the order the
    /// user dragged it into. The array itself is sorted, so every reader — the
    /// sidebar, the counts, the drag indices — sees the same order.
    private func applyPinOrdering() {
        let pinned = projects
            .filter(\.isPinned)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        projects = pinned + projects.filter { !$0.isPinned }
    }

    /// Drag and drop in the sidebar: puts one repository where another one is,
    /// pushing that one out of the way. Called every time the drag crosses a
    /// card, and saved right away — the order on screen is the order kept, even
    /// if the drag is then let go outside the window.
    ///
    /// Pinned repositories sit out: their order is the alphabet, not the drag.
    func moveProject(withID id: URL, toPositionOf target: URL) {
        guard id != target,
              let from = projects.firstIndex(where: { $0.id == id }),
              let to = projects.firstIndex(where: { $0.id == target }),
              !projects[from].isPinned, !projects[to].isPinned else { return }
        let moved = projects.remove(at: from)
        // `to` still points at the wanted slot: indices before `from` did not
        // move, and one past it shifted down by exactly the removed element.
        projects.insert(moved, at: to)
        persistProjects()
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
        UserDefaults.standard.set(
            projects.filter(\.isPinned).map(\.url.path),
            forKey: pinnedProjectsDefaultsKey
        )
    }

    private func restoreProjects() {
        let accounts = UserDefaults.standard.dictionary(forKey: gitHubAccountsDefaultsKey) as? [String: String] ?? [:]
        let paths = UserDefaults.standard.stringArray(forKey: projectsDefaultsKey) ?? []
        let pinned = Set(UserDefaults.standard.stringArray(forKey: pinnedProjectsDefaultsKey) ?? [])
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let project = Project(url: URL(fileURLWithPath: path))
            project.gitHubAccount = accounts[path]
            project.isPinned = pinned.contains(path)
            projects.append(project)
        }
        applyPinOrdering()
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

    /// Whether a pull request is the thing on screen. The dashboard takes the
    /// window back, so a pull request left open behind it does not count.
    var isShowingPullRequest: Bool {
        !showsDashboard && current?.isPullRequest == true
    }

    /// Shows or folds the navigator by hand — the button in the viewer's header
    /// and the View menu. Nothing else moves the pane: where it is left is where
    /// it stays, whatever the viewer goes on to show.
    func toggleNavigator() {
        showsNavigator.toggle()
    }

    /// The conversation open for the selected repository, if one has been
    /// started. The viewer keeps this one item mounted under whatever else is
    /// showing rather than swapping it out — see `ViewerView.body`.
    var openClaudeItem: ViewerItem? {
        guard let projectID = selectedProjectID else { return nil }
        return items[ViewerItem.Kind.claude(projectID: projectID).key]
    }

    /// The document the viewer is actually showing. The open item survives a
    /// trip to the dashboard — that is what Forward goes back to — so anything
    /// that acts on what is *on screen* (the preview toggle, Save as PDF) has
    /// to ask for this rather than `current`, or it stays up over the board.
    var visibleDocument: OpenDocument? {
        showsDashboard ? nil : current?.document
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

    /// Closes what is open and steps back to whatever was showing before it —
    /// the dashboard only when there is nothing behind it.
    func closeCurrent() {
        guard let current else {
            showsDashboard = true
            return
        }
        // A terminal is only ever closed tab by tab, by the user, and a Claude
        // conversation is only ever thrown away from inside it. This puts the
        // dashboard back and leaves both running.
        if current.survivesClosing {
            showsDashboard = true
            return
        }
        // Remembered by id, not by index: closing drops the item from the
        // history, which shifts everything after it along.
        let behind = viewer.history.indices.contains(viewer.index - 1)
            ? viewer.history[viewer.index - 1]
            : nil
        items[current.id] = nil
        forgetItem(current.id)
        // Back, not home. A file opened from a conversation, a diff or a search
        // result should hand the pane back to what sent us there, the way Back
        // would have; the dashboard is only where the oldest item lands.
        guard let behind, let index = viewer.history.firstIndex(of: behind) else {
            showsDashboard = true
            return
        }
        viewer.index = index
        showsDashboard = false
    }

    /// Leaves one file open, and only one.
    ///
    /// The pane has always shown a single thing, but every file ever opened
    /// stayed behind it: its whole text, its diagnostics and symbols, its place
    /// in the history. A morning of clicking through a repository left dozens
    /// of documents alive, and the app was slower for every one of them. The
    /// editor is one slot now — opening a file closes the file before it, and
    /// ⎋ or ✕ closes that one outright.
    ///
    /// **A file with unsaved edits is never dropped.** Nothing else in the app
    /// would warn about them, so closing it here would be losing work without
    /// saying so; it keeps its slot until it is saved or closed by hand. Only
    /// files are touched — a shell and a Claude conversation have something
    /// running behind them, and a diff or a pull request costs a title and a
    /// patch rather than a live editor.
    private func closeOtherFiles(keeping id: String) {
        for (key, item) in items where key != id && item.isFile && !item.isDirty {
            items[key] = nil
            forgetItem(key)
        }
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
        closeOtherFiles(keeping: item.id)

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
        case .commit(let projectID, _): projectID
        case .pullRequest(let projectID, _): projectID
        case .terminal(let projectID): projectID
        case .claude(let projectID): projectID
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
            // until the user closes their tabs. So does a Claude conversation.
            if !isOpenAnywhere(oldest), items[oldest]?.survivesClosing != true {
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

    /// Whether the editor takes the keyboard as it appears. Set by `openFile`
    /// and read by the viewer: opening from the file tree leaves the keys there,
    /// so ⏎, ⌘⌫ and the arrows keep working on the tree until the editor itself
    /// is clicked — the way VS Code's explorer behaves. Everything else (a
    /// search result, go-to-definition, a diff) opens ready to type in.
    private(set) var editorTakesFocus = true

    func openFile(_ url: URL, revealLine: Int? = nil, takingFocus: Bool = true) {
        editorTakesFocus = takingFocus
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
        Task {
            await loadWorkingDiff(
                item,
                project: project,
                paths: change.gitPaths,
                isUntracked: isUntracked
            )
        }
    }

    private func loadWorkingDiff(
        _ item: ViewerItem,
        project: Project,
        paths: [String],
        isUntracked: Bool
    ) async {
        item.isLoading = true
        item.errorMessage = nil
        let text = await GitStatus.diff(paths: paths, in: project.url, isUntracked: isUntracked)
        item.diff = DiffHighlighter.highlight(await DiffParser.parseInBackground(text))
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
        item.diff = DiffHighlighter.highlight(await DiffParser.parseInBackground(text))
        if item.diff?.isEmpty == true {
            item.errorMessage = "No textual changes to show."
        }
        item.isLoading = false
    }

    /// Opens what one commit of the repository's own history changed. The patch
    /// never changes, so an item already loaded is simply shown again.
    func openCommit(_ commit: RepositoryCommit, project: Project) {
        let kind = ViewerItem.Kind.commit(projectID: project.id, sha: commit.sha)
        let item = items[kind.key] ?? ViewerItem(
            kind: kind,
            title: commit.headline,
            subtitle: "\(commit.shortSHA) · \(project.name)"
        )
        // Re-set on every open: the host may have said who this address belongs
        // to since the item was first made.
        item.authorName = commit.displayAuthor
        item.authorAvatarURL = commit.avatarURL
        present(item)
        if item.diff == nil {
            Task { await loadCommitDiff(item, project: project, sha: commit.sha) }
        }
    }

    private func loadCommitDiff(_ item: ViewerItem, project: Project, sha: String) async {
        item.isLoading = true
        item.errorMessage = nil
        let text = await RepositoryCommit.diff(sha: sha, in: project.url)
        item.diff = DiffHighlighter.highlight(await DiffParser.parseInBackground(text))
        if item.diff?.isEmpty == true {
            item.errorMessage = "This commit changed no text."
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
        // The navigator is left on whatever tab it was: the pull requests are
        // listed on the dashboard now, so there is no list here to move to.

        if item.diff == nil {
            Task { await loadPullRequestDiff(item, project: project, pr: pr) }
        }
        if item.comments.isEmpty {
            Task { await loadComments(item, project: project, pr: pr) }
        }
        if item.reviewers.isEmpty {
            Task { await loadReviewers(item, project: project, pr: pr) }
        }
        if item.syncState == nil {
            Task { await refreshSyncState(item, project: project, pr: pr) }
        }
        // The list bkt answered with names a mention by account id only; this
        // trades one call for the names, and returns straight away when the
        // description has no mention in it.
        Task {
            guard let named = await PullRequestService.namedMentions(in: pr, directory: project.url)
            else { return }
            item.pullRequest?.body = named
        }
    }

    /// Opens a pull request known only by its number — a `#123` written in a
    /// commit message. The list the navigator holds is of open requests only,
    /// and a commit usually names one that has already merged, so anything not
    /// in that list is fetched from the host on the spot.
    func openPullRequest(number: Int, project: Project) {
        let kind = ViewerItem.Kind.pullRequest(projectID: project.id, number: number)
        if let pr = project.pullRequests.first(where: { $0.number == number })
            ?? items[kind.key]?.pullRequest {
            openPullRequest(pr, project: project)
            return
        }

        // The number is all there is to show until the host answers.
        let item = items[kind.key] ?? ViewerItem(kind: kind, title: "#\(number)", subtitle: project.name)
        item.isLoading = true
        item.errorMessage = nil
        present(item)

        Task {
            guard let remote = project.remote, remote.kind != .unknown else {
                item.isLoading = false
                item.errorMessage = PullRequestError.unsupportedHost.localizedDescription
                return
            }
            do {
                let pr = try await PullRequestService.load(number: number, for: remote, in: project.url)
                item.pullRequest = pr
                item.title = pr.title
                item.subtitle = nil
                item.isLoading = false
                openPullRequest(pr, project: project)
            } catch {
                item.isLoading = false
                item.errorMessage = error.localizedDescription
            }
        }
    }

    func loadPullRequestDiff(_ item: ViewerItem, project: Project, pr: PullRequest) async {
        item.isLoading = true
        item.errorMessage = nil
        if let text = await PullRequestService.diff(for: pr, in: project.url) {
            item.diff = DiffHighlighter.highlight(await DiffParser.parseInBackground(text))
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

    /// Who has been asked to review, and what each of them has said. Loaded with
    /// the pull request itself: the count of approvals belongs to the summary
    /// bar, which is on screen whichever tab is open.
    func loadReviewers(_ item: ViewerItem, project: Project, pr: PullRequest) async {
        // The board already asked. Both hosts now hand the reviewers over with
        // the list itself, so opening a pull request off it and immediately
        // asking again was a call spent re-reading what was already on screen —
        // and the panel would flash from the real list, to empty, and back.
        if !pr.reviewers.isEmpty {
            item.reviewers = pr.reviewers
            return
        }
        item.isLoadingReviewers = true
        item.reviewersError = nil
        do {
            item.reviewers = try await PullRequestService.reviewers(for: pr, in: project.url)
        } catch {
            item.reviewers = []
            item.reviewersError = error.localizedDescription
        }
        item.isLoadingReviewers = false
    }

    /// The people the reviewer picker offers. Read once per pull request, when
    /// the picker is first opened — and an empty answer is still an answer, since
    /// a handle can always be typed in by hand.
    func loadReviewerCandidates(_ item: ViewerItem, project: Project, pr: PullRequest) async {
        guard !item.hasLoadedReviewerCandidates, !item.isLoadingReviewerCandidates else { return }
        item.isLoadingReviewerCandidates = true
        item.reviewerCandidates = await PullRequestService.reviewerCandidates(
            for: pr,
            in: project.url
        )
        item.hasLoadedReviewerCandidates = true
        item.isLoadingReviewerCandidates = false
    }

    /// Asks the host to add reviewers, then reads the list back from it rather
    /// than assuming what it did — a handle the host resolved differently, or a
    /// person who was already on the list, then reads correctly here too.
    func addReviewers(
        _ handles: [String],
        on item: ViewerItem,
        project: Project,
        pr: PullRequest
    ) async {
        await runPullRequestAction(on: item, project: project, pr: pr) {
            try await PullRequestService.addReviewers(handles, to: pr, in: project.url)
        } onSuccess: {
            self.showStatus(handles.count == 1
                ? "\(handles[0]) asked to review #\(pr.number)"
                : "\(handles.count) reviewers added to #\(pr.number)")
            Task { await self.loadReviewers(item, project: project, pr: pr) }
        }
    }

    /// The description the editor opens on — the Markdown the host stores,
    /// which on Bitbucket is not always the text on screen. See
    /// ``PullRequestService/editableDescription(for:in:)``.
    func editableDescription(project: Project, pr: PullRequest) async -> String {
        await PullRequestService.editableDescription(for: pr, in: project.url)
    }

    /// Writes the description back to the host. `true` once it has landed, which
    /// is what closes the editor — a refusal leaves what was typed where it is,
    /// so nothing written is thrown away.
    func updateDescription(
        _ body: String,
        on item: ViewerItem,
        project: Project,
        pr: PullRequest
    ) async -> Bool {
        guard !item.isRunningPullRequestAction else { return false }
        item.isRunningPullRequestAction = true
        defer { item.isRunningPullRequestAction = false }

        do {
            try await PullRequestService.updateDescription(body, on: pr, in: project.url)
        } catch {
            showError(error.localizedDescription)
            return false
        }

        // The host has taken it, so show it here rather than waiting for the
        // list to come back around with it.
        var updated = pr
        updated.body = body
        item.pullRequest = updated
        showStatus("Description updated on #\(pr.number)")

        // What was just saved is the raw text, where Bitbucket names a mention
        // by account id; this asks for the names back, and costs nothing when
        // there is no mention in it.
        if let named = await PullRequestService.namedMentions(in: updated, directory: project.url) {
            item.pullRequest?.body = named
        }
        Task { await project.refreshPullRequests() }
        return true
    }

    /// The pull request's commits. Loaded when the Commits tab is first shown
    /// rather than alongside the diff: it is one more call to the host, and a
    /// review that never opens the tab should not pay for it.
    func loadCommits(_ item: ViewerItem, project: Project, pr: PullRequest) async {
        item.isLoadingCommits = true
        item.commitsError = nil
        do {
            item.commits = try await PullRequestService.commits(for: pr, in: project.url)
        } catch {
            item.commits = []
            item.commitsError = error.localizedDescription
        }
        item.isLoadingCommits = false
    }

    func loadBuilds(_ item: ViewerItem, project: Project, pr: PullRequest) async {
        item.isLoadingBuilds = true
        item.buildsError = nil
        do {
            item.builds = try await PullRequestService.builds(for: pr, in: project.url)
        } catch {
            item.builds = []
            item.buildsError = error.localizedDescription
        }
        item.isLoadingBuilds = false
    }

    /// Opens one commit inside the Commits tab and fetches its patch.
    func showCommit(
        _ commit: PullRequestCommit,
        on item: ViewerItem,
        project: Project,
        pr: PullRequest
    ) async {
        item.selectedCommit = commit
        item.commitDiffError = nil
        guard item.commitDiffs[commit.sha] == nil else { return }

        item.isLoadingCommitDiff = true
        let text = await PullRequestService.diff(forCommit: commit.sha, of: pr, in: project.url)
        // The tab may have gone back to the list, or on to another commit,
        // while this was in flight — the patch is still worth keeping.
        if let text {
            item.commitDiffs[commit.sha] = DiffHighlighter.highlight(await DiffParser.parseInBackground(text))
        } else if item.selectedCommit?.sha == commit.sha {
            item.commitDiffError = "Could not load the changes in \(commit.shortSHA)."
        }
        // Whoever is on screen now owns the spinner, so a load that has been
        // overtaken leaves it alone.
        if item.selectedCommit?.sha == commit.sha {
            item.isLoadingCommitDiff = false
        }
    }

    // MARK: - Merging, rejecting, syncing

    /// Counts how far the pull request's branch is behind the one it targets.
    /// `fetching` asks git for fresh refs first, which only matters on the hosts
    /// that are counted locally — GitHub answers from the server either way.
    func refreshSyncState(
        _ item: ViewerItem,
        project: Project,
        pr: PullRequest,
        fetching: Bool = false
    ) async {
        guard !item.isCheckingSync else { return }
        item.isCheckingSync = true
        item.syncState = await PullRequestService.syncState(
            for: pr,
            in: project.url,
            fetching: fetching
        )
        item.isCheckingSync = false
    }

    /// Merges the pull request and closes it here: it is no longer open, and the
    /// list in the navigator reloads to say so.
    func mergePullRequest(
        _ item: ViewerItem,
        project: Project,
        pr: PullRequest,
        using strategy: PullRequestMergeStrategy
    ) async {
        await runPullRequestAction(on: item, project: project, pr: pr) {
            try await PullRequestService.merge(pr, using: strategy, in: project.url)
        } onSuccess: {
            self.showStatus("#\(pr.number) merged into \(pr.targetBranch)")
            self.close(item)
        }
    }

    /// Closes the pull request without merging — `reason`, when given, is posted
    /// as the closing comment.
    func rejectPullRequest(
        _ item: ViewerItem,
        project: Project,
        pr: PullRequest,
        reason: String
    ) async {
        await runPullRequestAction(on: item, project: project, pr: pr) {
            try await PullRequestService.reject(pr, reason: reason, in: project.url)
        } onSuccess: {
            self.showStatus("#\(pr.number) rejected")
            self.close(item)
        }
    }

    /// Brings the target branch's commits into the pull request's branch.
    func updateBranchFromBase(_ item: ViewerItem, project: Project, pr: PullRequest) async {
        await runPullRequestAction(on: item, project: project, pr: pr) {
            try await PullRequestService.updateFromBase(pr, in: project.url)
        } onSuccess: {
            self.showStatus("\(pr.sourceBranch) updated from \(pr.targetBranch)")
            Task {
                await self.refreshSyncState(item, project: project, pr: pr, fetching: true)
                await self.loadCommits(item, project: project, pr: pr)
                await self.loadPullRequestDiff(item, project: project, pr: pr)
            }
        }
    }

    /// Approves the pull request, or asks for changes on it. Unlike a merge or a
    /// rejection this leaves the pull request open — the review joins the
    /// conversation, so that is reloaded too.
    func reviewPullRequest(
        _ item: ViewerItem,
        project: Project,
        pr: PullRequest,
        decision: PullRequestReviewDecision,
        comment: String
    ) async {
        await runPullRequestAction(on: item, project: project, pr: pr) {
            try await PullRequestService.review(
                pr,
                decision: decision,
                comment: comment,
                in: project.url
            )
        } onSuccess: {
            self.showStatus(decision == .approve
                ? "#\(pr.number) approved"
                : "Changes requested on #\(pr.number)")
            Task { await self.loadComments(item, project: project, pr: pr) }
        }
    }

    /// The shape every one of these shares: one command against the host, a
    /// toast either way, and a reloaded pull request list afterwards — which is
    /// also where the item's own copy of the pull request comes from, so the bar
    /// shows the review state the host now has.
    private func runPullRequestAction(
        on item: ViewerItem,
        project: Project,
        pr: PullRequest,
        _ action: () async throws -> Void,
        onSuccess: () -> Void
    ) async {
        guard !item.isRunningPullRequestAction else { return }
        item.isRunningPullRequestAction = true
        defer { item.isRunningPullRequestAction = false }
        do {
            try await action()
            onSuccess()
        } catch {
            showError(error.localizedDescription)
        }
        await project.refreshPullRequests()
        if let fresh = project.pullRequests.first(where: { $0.number == pr.number }) {
            item.pullRequest = fresh
        }
    }

    /// Closes one item wherever it is, unlike `closeCurrent` which only reaches
    /// what is on screen.
    private func close(_ item: ViewerItem) {
        let wasOnScreen = current?.id == item.id
        items[item.id] = nil
        forgetItem(item.id)
        // Dropping it from the history would otherwise leave whichever item the
        // index lands on next in the viewer, which is not what was asked for.
        if wasOnScreen { showsDashboard = true }
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

    /// Where the shells that belong to no repository start.
    static let globalTerminalDirectory = FileManager.default.homeDirectoryForCurrentUser
    /// What those shells are called in the lists, in place of a repository name.
    static let globalTerminalScope = "Home"

    /// Shows the project's terminal. Each project has one terminal viewer item
    /// that holds any number of shell tabs. A plain "Open Terminal" reuses what
    /// is already running; passing a command always starts a fresh tab for it.
    @discardableResult
    func openTerminal(
        in project: Project,
        runningCommand command: String? = nil,
        title: String? = nil
    ) -> ViewerItem {
        openTerminal(
            projectID: project.id,
            directory: project.url,
            runningCommand: command,
            title: title
        )
    }

    /// The same, for the window-wide terminal: a shell in the home folder,
    /// belonging to no repository. It is how you get a prompt before any
    /// repository has been added, and it survives removing them all.
    @discardableResult
    func openGlobalTerminal(
        runningCommand command: String? = nil,
        title: String? = nil
    ) -> ViewerItem {
        openTerminal(
            projectID: nil,
            directory: Self.globalTerminalDirectory,
            runningCommand: command,
            title: title
        )
    }

    @discardableResult
    private func openTerminal(
        projectID: URL?,
        directory: URL,
        runningCommand command: String?,
        title: String?
    ) -> ViewerItem {
        let item = terminalItem(projectID: projectID)
        if item.terminals.isEmpty || command != nil || title != nil {
            addTerminalTab(to: item, directory: directory, runningCommand: command, title: title)
        } else if let session = item.selectedTerminal {
            selectTerminal(session, in: item)
        }
        present(item)
        // The viewer shows one shell and has no tab bar, so the navigator
        // switches to the list of the rest.
        navigatorTab = .terminals
        return item
    }

    /// The one item that holds this scope's shell tabs, found or made.
    private func terminalItem(projectID: URL?) -> ViewerItem {
        let kind = ViewerItem.Kind.terminal(projectID: projectID)
        if let existing = items[kind.key] { return existing }
        return ViewerItem(
            kind: kind,
            title: "Terminal",
            subtitle: projectID.flatMap { project(withID: $0)?.name } ?? Self.globalTerminalScope
        )
    }

    /// Every shell still open, in the order they were started. The order is
    /// deliberately fixed: showing a shell must not move its card, or the list
    /// reshuffles under the pointer on every click. Terminal items are never
    /// dropped on their own, so this outlives closing the viewer and switching
    /// repositories — and, being saved, quitting the app.
    var openTerminals: [OpenTerminal] {
        items.values
            .filter(\.isTerminal)
            .sorted { $0.id < $1.id }
            .flatMap { item in
                item.terminals.enumerated().map {
                    OpenTerminal(session: $0.element, item: item, position: $0.offset + 1)
                }
            }
    }

    /// The shells of one folder, oldest first. The navigator lists one scope at
    /// a time: a repository's shells never sit among another repository's, and
    /// the home ones are their own list.
    func terminals(in scope: TerminalScope) -> [OpenTerminal] {
        openTerminals.filter {
            switch scope {
            case .project(let id): $0.item.projectID == id
            case .home: $0.item.projectID == nil
            }
        }
    }

    /// Which scope the Terminals tab is about: the shell on screen belongs to
    /// one, and with anything else open it is the selected repository's.
    var visibleTerminalScope: TerminalScope? {
        if !showsDashboard, let item = current, item.isTerminal {
            return item.projectID.map { TerminalScope.project($0) } ?? .home
        }
        return selectedProjectID.map { TerminalScope.project($0) }
    }

    /// What that scope is called on screen: the repository's name, or "Home".
    func name(of scope: TerminalScope) -> String {
        switch scope {
        case .project(let id): project(withID: id)?.name ?? id.lastPathComponent
        case .home: Self.globalTerminalScope
        }
    }

    /// Starts another shell in that scope.
    func newTerminal(in scope: TerminalScope) {
        switch scope {
        case .project(let id):
            guard let project = project(withID: id) else { return }
            newTerminal(in: project)
        case .home:
            newGlobalTerminal()
        }
    }

    /// How many shells one repository has running, for the dashboard's count.
    /// The terminals list itself is window-wide — a shell outlives the
    /// repository being switched away from — but a repository's own board
    /// should count its own.
    func terminalCount(in project: Project) -> Int {
        openTerminals.count { $0.item.projectID == project.id }
    }

    /// Opens one of the navigator's lists, unfolding the pane if it is away.
    /// Everything that sends the user there goes through this: setting the tab
    /// alone does nothing visible while the pane is hidden.
    func showNavigator(_ tab: NavigatorTab) {
        navigatorTab = tab
        showsNavigator = true
    }

    /// The terminals list, and — when this repository already has a shell — its
    /// most recent one back in the viewer. Opening the list without showing
    /// anything asks for a second click to reach what the count just promised.
    /// Nothing is started here: a repository with no shell only gets the list,
    /// where the first card is the one that starts one.
    func showTerminals(in project: Project) {
        showNavigator(.terminals)
        // The list itself no longer moves the last shell used to the top, so the
        // one to bring back is looked up by `lastUsedAt` here.
        let recent = openTerminals
            .filter { $0.item.projectID == project.id }
            .max { $0.session.lastUsedAt < $1.session.lastUsedAt }
        if let recent { showTerminal(recent) }
    }

    /// Puts one shell from the terminals list back on screen.
    func showTerminal(_ terminal: OpenTerminal) {
        selectTerminal(terminal.session, in: terminal.item)
        present(terminal.item)
    }

    /// Makes a tab the visible one and marks it as the newest in the list. This
    /// is also where a tab restored from the last run of the app gets its shell:
    /// they are listed on launch but nothing is spawned until one is looked at.
    func selectTerminal(_ session: TerminalSession, in item: ViewerItem) {
        item.selectedTerminalID = session.id
        session.lastUsedAt = Date()
        session.startIfNeeded()
        persistTerminals()
    }

    /// Whether this exact shell is what the viewer is showing.
    func isShowing(_ terminal: OpenTerminal) -> Bool {
        !showsDashboard
            && current?.id == terminal.item.id
            && terminal.item.selectedTerminal?.id == terminal.session.id
    }

    func closeTerminal(_ terminal: OpenTerminal) {
        closeTerminalTab(terminal.session, in: terminal.item)
    }

    /// ⌃` — in and out of the selected repository's shells, the way an editor's
    /// terminal panel works. From anywhere else it shows them, starting one when
    /// the repository has none; from inside them it puts the dashboard back, and
    /// the shells keep running. With no repository selected it is the home
    /// terminal, so the key does something before any repository is added.
    func toggleTerminal() {
        if !showsDashboard, let current, current.isTerminal {
            closeCurrent()
        } else if let project = selectedProject {
            openTerminal(in: project)
        } else {
            openGlobalTerminal()
        }
    }

    /// Always starts a fresh shell for a repository, next to any it already has.
    func newTerminal(in project: Project) {
        newTerminal(projectID: project.id, directory: project.url)
    }

    /// Another shell in the home folder, belonging to no repository.
    func newGlobalTerminal() {
        newTerminal(projectID: nil, directory: Self.globalTerminalDirectory)
    }

    private func newTerminal(projectID: URL?, directory: URL) {
        let item = terminalItem(projectID: projectID)
        addTerminalTab(to: item, directory: directory)
        present(item)
        navigatorTab = .terminals
    }

    /// ⌘T while a terminal is on screen: another shell in the same folder.
    func newTerminalTab(in item: ViewerItem) {
        guard case .terminal(let projectID) = item.kind else { return }
        // A repository removed while its terminal is open leaves nowhere to
        // start; the window-wide terminal always has the home folder.
        let directory = projectID == nil
            ? Self.globalTerminalDirectory
            : projectID.flatMap { project(withID: $0)?.url }
        guard let directory else { return }
        addTerminalTab(to: item, directory: directory)
        navigatorTab = .terminals
    }

    private func addTerminalTab(
        to item: ViewerItem,
        directory: URL,
        runningCommand command: String? = nil,
        title: String? = nil
    ) {
        let session = makeSession(
            directory: directory,
            title: title ?? "Shell \(item.terminals.count + 1)",
            in: item
        )
        item.terminals.append(session)
        item.selectedTerminalID = session.id
        // Terminal items are the one kind kept outside the history, so a brand
        // new one is registered here rather than waiting to be presented.
        items[item.id] = item
        session.startIfNeeded(runningCommand: command)
        persistTerminals()
    }

    /// A tab wired into the store: it removes itself when its shell exits, and
    /// keeps the saved list in step with the name the shell gives itself.
    private func makeSession(
        directory: URL,
        title: String,
        in item: ViewerItem
    ) -> TerminalSession {
        let session = TerminalSession(directory: directory, title: title)
        // When the shell exits (typing `exit`, or the process dies), the tab
        // goes away like in any terminal app.
        session.onExit = { [weak self, weak item, weak session] in
            guard let self, let item, let session else { return }
            self.closeTerminalTab(session, in: item)
        }
        session.onTitleChange = { [weak self] in
            self?.scheduleTerminalPersist()
        }
        return session
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
        persistTerminals()

        guard item.terminals.isEmpty else { return }
        items[item.id] = nil
        forgetItem(item.id)
        if current == nil { showsDashboard = true }
    }

    // MARK: - Saved terminals

    /// One shell tab as it is written to disk. The shell itself cannot be saved,
    /// so what comes back is a tab in the same folder, with the same name,
    /// waiting to be shown.
    private struct StoredTerminal: Codable {
        /// The repository it belongs to; `nil` is the window-wide terminal.
        var projectPath: String?
        var directory: String
        var title: String
        var lastUsedAt: Date
        var isSelected: Bool
    }

    /// Titles arrive from the shell — a prompt can rename a tab on every
    /// command — so those are collected up rather than written straight away.
    private func scheduleTerminalPersist() {
        terminalPersistTask?.cancel()
        terminalPersistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.persistTerminals()
        }
    }

    private func persistTerminals() {
        let stored: [StoredTerminal] = items.values.flatMap { item -> [StoredTerminal] in
            guard case .terminal(let projectID) = item.kind else { return [] }
            return item.terminals.map { session in
                StoredTerminal(
                    projectPath: projectID?.path,
                    directory: session.directory.path,
                    title: session.title,
                    lastUsedAt: session.lastUsedAt,
                    isSelected: session.id == item.selectedTerminalID
                )
            }
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: terminalsDefaultsKey)
    }

    /// Brings back the tabs of the last run, without starting a single shell:
    /// they are listed in the Terminals tab, and each one starts when it is
    /// first shown. Called after the projects, whose names these tabs borrow.
    private func restoreTerminals() {
        guard let data = UserDefaults.standard.data(forKey: terminalsDefaultsKey),
              let stored = try? JSONDecoder().decode([StoredTerminal].self, from: data) else { return }

        for entry in stored {
            // A repository no longer in the workspace, or a folder that has
            // moved, has nothing left to restore.
            if let path = entry.projectPath, !projects.contains(where: { $0.url.path == path }) {
                continue
            }
            guard FileManager.default.fileExists(atPath: entry.directory) else { continue }

            let item = terminalItem(projectID: entry.projectPath.map { URL(fileURLWithPath: $0) })
            items[item.id] = item
            let session = makeSession(
                directory: URL(fileURLWithPath: entry.directory),
                title: entry.title,
                in: item
            )
            session.lastUsedAt = entry.lastUsedAt
            item.terminals.append(session)
            if entry.isSelected { item.selectedTerminalID = session.id }
        }

        // Whatever was on screen last time may not have made it back.
        for item in items.values where item.isTerminal && item.selectedTerminalID == nil {
            item.selectedTerminalID = item.terminals.last?.id
        }
        // Deliberately no write here. Building a store must not touch what is
        // saved: SwiftUI can build a second, throwaway one, and an empty store
        // saving itself would wipe the list the live one is holding.
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

    /// Writes the open Markdown file out as a PDF — the rendered document, not
    /// the source, diagrams and all. Nothing happens for any other file.
    func saveCurrentDocumentAsPDF() {
        guard let document = visibleDocument, document.isMarkdown else { return }
        let name = document.url.deletingPathExtension().lastPathComponent
        MarkdownPDF.save(markdown: document.text, suggestedName: name) { [weak self] result in
            switch result {
            case .success(let url):
                self?.showStatus("Saved \(url.lastPathComponent)")
            case .failure(let error):
                self?.showError("Could not save the PDF: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - External tools

    /// Starts Claude Code on this repository, in its own terminal tab.
    func openClaude(in project: Project) {
        openTerminal(in: project, runningCommand: "claude", title: "Claude")
    }

    /// Opens the repository's Claude conversation in the viewer — the same
    /// `claude`, driven rather than typed at. Kept alive like a terminal, so
    /// leaving it and coming back finds the transcript and the half-written
    /// prompt where they were.
    ///
    /// Returns to the conversation already on screen rather than starting a
    /// second one; ``newClaudeChat(in:)`` is how another is added.
    @discardableResult
    func openClaudeChat(in project: Project) -> ViewerItem {
        let item = claudeItem(for: project)
        if item.claudes.isEmpty {
            addClaudeSession(to: item, in: project)
        }
        present(item)
        // The viewer shows one conversation, so the navigator shows the rest —
        // the same move opening a terminal or a pull request makes.
        navigatorTab = .claude
        return item
    }

    /// Another conversation about the same repository, running beside the ones
    /// already open. Each has its own `claude` process, so a turn under way in
    /// one carries on while this one is typed into.
    @discardableResult
    func newClaudeChat(in project: Project) -> ClaudeSession {
        let item = claudeItem(for: project)
        let session = addClaudeSession(to: item, in: project)
        present(item)
        navigatorTab = .claude
        return session
    }

    /// Puts one of the open conversations back on screen. The others keep
    /// running: nothing is stopped by looking away from it.
    func selectClaudeChat(_ session: ClaudeSession, in project: Project) {
        let item = claudeItem(for: project)
        guard item.claudes.contains(where: { $0.id == session.id }) else { return }
        item.selectedClaudeID = session.id
        present(item)
        navigatorTab = .claude
    }

    /// Ends one conversation and forgets it, leaving the rest alone. Closing the
    /// last one leaves the item with none, which is what the viewer reads as
    /// "no chat here" — the transcript itself is on disk either way, so it can
    /// be resumed from the list afterwards.
    func closeClaudeChat(_ session: ClaudeSession, in project: Project) {
        let item = claudeItem(for: project)
        guard let index = item.claudes.firstIndex(where: { $0.id == session.id }) else { return }
        session.shutDown()
        item.claudes.remove(at: index)
        if item.selectedClaudeID == session.id {
            // The one before it, so closing down a row of chats walks back up
            // the list instead of jumping to the end each time.
            let next = min(max(index - 1, 0), item.claudes.count - 1)
            item.selectedClaudeID = item.claudes.indices.contains(next) ? item.claudes[next].id : nil
        }
        if item.claudes.isEmpty, current?.id == item.id {
            closeCurrent()
        }
    }

    /// A repository's conversations, in the order they were started. Empty until
    /// one is opened: listing them must not start anything.
    func claudeSessions(in project: Project) -> [ClaudeSession] {
        items[ViewerItem.Kind.claude(projectID: project.id).key]?.claudes ?? []
    }

    /// The conversation on screen for this repository, if any. The sessions list
    /// asks with this rather than making one.
    func claudeSession(for project: Project) -> ClaudeSession? {
        items[ViewerItem.Kind.claude(projectID: project.id).key]?.claude
    }

    /// The one item that holds this repository's conversations, made on demand.
    /// Like a terminal, it lives outside the history's clean-up, so it is
    /// registered as soon as it exists rather than waiting to be presented.
    private func claudeItem(for project: Project) -> ViewerItem {
        let kind = ViewerItem.Kind.claude(projectID: project.id)
        if let existing = items[kind.key] { return existing }
        let item = ViewerItem(kind: kind, title: "Claude", subtitle: project.name)
        items[item.id] = item
        return item
    }

    @discardableResult
    private func addClaudeSession(to item: ViewerItem, in project: Project) -> ClaudeSession {
        let session = ClaudeSession(directory: project.url)
        item.claudes.append(session)
        item.selectedClaudeID = session.id
        return session
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

    // MARK: - File tree selection

    /// The rows picked in the Files tab. Every action there — drag, duplicate,
    /// trash — works on this whole set when the row it started from is in it,
    /// and on that row alone when it is not, which is how a Finder window and
    /// every file tree behave.
    var selectedFiles: Set<URL> = []
    /// The row a ⇧-click measures its range from: the last one clicked without
    /// ⇧, not the nearest end of the selection.
    private var fileSelectionAnchor: URL?
    /// The row whose name is being edited in place, if any.
    var renamingFile: URL?
    /// What is being dragged out of the tree right now. A drag carries one row's
    /// URL even when several are picked — one SwiftUI view can only offer one
    /// item — so the rest of the selection is remembered here and picked back up
    /// when the drop lands inside the tree.
    private var draggingFiles: Set<URL>?

    /// A click on a row, with whatever modifier was held. `visible` is the rows
    /// in the order they are on screen, which is what a ⇧-range is measured in.
    func selectFile(_ url: URL, modifiers: NSEvent.ModifierFlags, visible: [URL]) {
        if modifiers.contains(.command) {
            if selectedFiles.contains(url) {
                selectedFiles.remove(url)
            } else {
                selectedFiles.insert(url)
            }
            fileSelectionAnchor = url
        } else if modifiers.contains(.shift),
                  let anchor = fileSelectionAnchor,
                  let from = visible.firstIndex(of: anchor),
                  let to = visible.firstIndex(of: url) {
            // The anchor stays put, so dragging the shift-click up and down
            // grows and shrinks one range instead of leaving a trail.
            selectedFiles = Set(visible[min(from, to)...max(from, to)])
        } else {
            selectedFiles = [url]
            fileSelectionAnchor = url
        }
    }

    /// ↑ and ↓ in the tree. With ⇧ the range grows from the anchor, without it
    /// the selection becomes the one row moved to.
    func moveFileSelection(by delta: Int, extending: Bool, visible: [URL]) {
        guard !visible.isEmpty else { return }
        let current = fileSelectionAnchor.flatMap { visible.firstIndex(of: $0) }
            ?? selectedFiles.compactMap { visible.firstIndex(of: $0) }.min()
        let next = min(max((current ?? -1) + delta, 0), visible.count - 1)
        let url = visible[next]
        if extending, let anchor = fileSelectionAnchor, let from = visible.firstIndex(of: anchor) {
            selectedFiles = Set(visible[min(from, next)...max(from, next)])
        } else {
            selectedFiles = [url]
            fileSelectionAnchor = url
        }
    }

    func selectFiles(_ urls: [URL]) {
        selectedFiles = Set(urls)
        fileSelectionAnchor = urls.last
    }

    func clearFileSelection() {
        selectedFiles = []
        fileSelectionAnchor = nil
    }

    /// What a menu item, a key or a drag started on `url` applies to.
    func fileActionTargets(_ url: URL) -> [URL] {
        guard selectedFiles.contains(url), selectedFiles.count > 1 else { return [url] }
        // Sorted only so the toast and any error name them in a stable order.
        return selectedFiles.sorted { $0.path < $1.path }
    }

    /// Called as a drag leaves a row, so a drop back inside the tree can move
    /// everything that was picked rather than the one row under the pointer.
    func beginFileDrag(_ urls: [URL]) {
        draggingFiles = Set(urls)
    }

    // MARK: - File actions

    /// Files dropped on a folder in the Files tab. A file already inside this
    /// repository moves, anything else is copied in — see `FileOperations`.
    ///
    /// The work runs off the main actor, because a dropped folder can be large.
    func importFiles(_ urls: [URL], into folder: URL, project: Project) {
        var dropped = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        // One of our own rows, dragged while several were picked: the drag only
        // carried that row, the selection is what the user meant.
        if dropped.count == 1, let dragged = draggingFiles, dragged.contains(dropped[0]) {
            dropped = dragged.sorted { $0.path < $1.path }
        }
        draggingFiles = nil
        // `let` so the copy below can leave the main actor with it.
        let sources = dropped
        guard !sources.isEmpty else { return }
        let root = project.url.standardizedFileURL.path + "/"

        // Mixed drags are rare enough not to split into two passes: as soon as
        // one file comes from outside, the whole drop is a copy, which is the
        // safe half of the pair.
        let kind: FileOperations.Transfer =
            sources.allSatisfy { $0.path.hasPrefix(root) } ? .move : .copy

        Task {
            let result = await Task.detached {
                FileOperations.transfer(kind, sources, into: folder)
            }.value

            // A move empties the folders the files came from as well.
            for parent in Set(sources.map { $0.deletingLastPathComponent() }) {
                project.refreshFileTree(at: parent)
            }
            project.refreshFileTree(at: folder)
            if kind == .move {
                // Dragging the open file into another folder keeps it open, at
                // its new path — the same as renaming it. Only for a single
                // file: with several moving at once there is no telling which
                // destination belongs to which source.
                let showAgain = sources.count == 1 && result.finished.count == 1
                    ? openPath(under: sources[0], movedTo: result.finished[0])
                    : nil
                for source in sources { closeItems(under: source) }
                if let showAgain { openFile(showAgain, takingFocus: false) }
            }
            await project.refreshGitStatus()
            // Leave what landed picked, so the next action carries on with the
            // files just dropped rather than with where they came from.
            if !result.finished.isEmpty { selectFiles(result.finished) }

            report(result, action: kind.pastTense, verb: kind.verb, place: "to \(folder.lastPathComponent)")
        }
    }

    /// Renames one file or folder from the Files tab. What was open under the
    /// old name is closed — the editor is holding a path that no longer exists.
    func renameFile(_ url: URL, to name: String, project: Project) {
        Task {
            let outcome = await Task.detached { FileOperations.rename(url, to: name) }.value
            switch outcome {
            case .renamed(let renamed):
                // The file itself has not changed, only its name — so what was
                // on screen comes back under the new one instead of the viewer
                // dropping to the dashboard. The keyboard stays in the tree,
                // which is where the rename was typed.
                let showAgain = openPath(under: url, movedTo: renamed)
                closeItems(under: url)
                // The whole loaded tree, not just the folder: renaming a folder
                // moves everything under it too.
                project.refreshFileTree()
                await project.refreshGitStatus()
                selectFiles([renamed])
                if let showAgain { openFile(showAgain, takingFocus: false) }
                showStatus("Renamed to \(renamed.lastPathComponent)")
            case .unchanged:
                break
            case .failed(let message):
                showError("Could not rename \(url.lastPathComponent) — \(message)")
            }
        }
    }

    /// Copies each file beside itself, as "name 2".
    func duplicateFiles(_ urls: [URL], project: Project) {
        guard !urls.isEmpty else { return }
        Task {
            let result = await Task.detached { FileOperations.duplicate(urls) }.value

            for parent in Set(urls.map { $0.deletingLastPathComponent() }) {
                project.refreshFileTree(at: parent)
            }
            await project.refreshGitStatus()
            if !result.finished.isEmpty { selectFiles(result.finished) }
            // Named after the copies, not the originals: "Created foo 2.swift"
            // is the answer to "where did it go".
            report(result, action: "Created", verb: "duplicate", place: "")
        }
    }

    /// Moves files to the Trash from the Files tab, and closes whatever they had
    /// open. Recoverable in Finder, which is why it does not ask first.
    func deleteFiles(_ urls: [URL], project: Project) {
        guard !urls.isEmpty else { return }
        Task {
            let result = await Task.detached { FileOperations.trash(urls) }.value

            for url in result.finished { closeItems(under: url) }
            for parent in Set(urls.map { $0.deletingLastPathComponent() }) {
                project.refreshFileTree(at: parent)
            }
            await project.refreshGitStatus()
            selectedFiles.subtract(result.finished)

            report(result, action: "Moved", verb: "delete", place: "to the Trash")
        }
    }

    /// Where the file on screen has just moved to, if it is `url` or sits under
    /// it — the answer to "what should the viewer show once this rename is
    /// done". Nothing when the viewer is showing something else entirely.
    private func openPath(under url: URL, movedTo destination: URL) -> URL? {
        guard case .file(let open)? = current?.kind, !showsDashboard else { return nil }
        let from = url.standardizedFileURL.path
        let path = open.standardizedFileURL.path
        if path == from { return destination }
        guard path.hasPrefix(from + "/") else { return nil }
        return destination.appendingPathComponent(String(path.dropFirst(from.count + 1)))
    }

    /// Closes every open file at `url` or under it — used when it has just been
    /// renamed, moved or deleted, so the viewer never shows a path that is gone.
    private func closeItems(under url: URL) {
        let path = url.standardizedFileURL.path
        // Over a copy: `close` takes items out of the dictionary as we go.
        for item in Array(items.values) {
            guard case .file(let open) = item.kind else { continue }
            let openPath = open.standardizedFileURL.path
            guard openPath == path || openPath.hasPrefix(path + "/") else { continue }
            close(item)
        }
    }

    /// One toast for a batch: the first error if anything failed, otherwise what
    /// went through. A run that only skipped says nothing — it means the files
    /// were dropped where they already were, and nothing happened.
    private func report(
        _ result: FileOperations.Result,
        action: String,
        verb: String,
        place: String
    ) {
        if let error = result.errors.first {
            showError(result.errors.count == 1
                ? "Could not \(verb) \(error)"
                : "Could not \(verb) \(result.errors.count) items — \(error)")
        } else if result.finished.count == 1, let only = result.finished.first {
            showStatus("\(action) \(only.lastPathComponent) \(place)".trimmingCharacters(in: .whitespaces))
        } else if result.finished.count > 1 {
            showStatus("\(action) \(result.finished.count) items \(place)".trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - Go to file (⌘P)

    // The palette searches the *whole* selected repository, which is what makes
    // it worth having next to the navigator's filter: the tree reads a folder no
    // sooner than it is expanded, so a filter over it only ever sees the part of
    // the repository you already walked into.

    /// Whether the palette is up.
    private(set) var isFindingFiles = false

    /// What has been typed into it. Every change re-ranks and lands the
    /// selection back on the first row — the old row means nothing in a new list.
    var fileFinderQuery = "" {
        didSet {
            guard fileFinderQuery != oldValue else { return }
            fileFinderSelection = 0
            searchFiles()
        }
    }

    private(set) var fileFinderMatches: [FileFinder.Match] = []
    /// Which row ⏎ opens.
    private(set) var fileFinderSelection = 0
    /// Set only while a repository's list is being read for the very first time,
    /// so a huge repository can say so rather than look broken.
    private(set) var isListingFiles = false

    /// One prepared path list per repository, read when the palette opens on it
    /// and read again on every open after that: a file added since is the one
    /// you are most likely reaching for, and the list already there stays usable
    /// while the new one is being read.
    @ObservationIgnored private var fileFinderIndexes: [URL: FileFinder.Index] = [:]
    @ObservationIgnored private var fileListTask: Task<Void, Never>?
    @ObservationIgnored private var fileSearchTask: Task<Void, Never>?

    /// ⌘P both opens and closes it, the way a shortcut for a panel should.
    func toggleFileFinder() {
        if isFindingFiles {
            closeFileFinder()
        } else {
            openFileFinder()
        }
    }

    func openFileFinder() {
        guard let project = selectedProject else { return }
        isFindingFiles = true
        fileFinderQuery = ""
        fileFinderSelection = 0
        fileFinderMatches = recentFiles(in: project)
        listFiles(in: project)
    }

    func closeFileFinder() {
        // Closed first, so emptying the query below does not start a search on
        // the way out.
        isFindingFiles = false
        fileListTask?.cancel()
        fileSearchTask?.cancel()
        fileFinderQuery = ""
        fileFinderMatches = []
        fileFinderSelection = 0
    }

    /// Wraps at both ends: with ten rows on screen, ↑ from the first is a
    /// shorter way to the last than ↓ nine times.
    func moveFileFinderSelection(by delta: Int) {
        let count = fileFinderMatches.count
        guard count > 0 else { return }
        fileFinderSelection = (fileFinderSelection + delta % count + count) % count
    }

    func openSelectedFile() {
        guard fileFinderMatches.indices.contains(fileFinderSelection) else { return }
        open(fileFinderMatches[fileFinderSelection])
    }

    /// Opens a row. Unlike the file tree this hands the keyboard to the editor:
    /// the palette is a way of *getting* to a file, so you arrive ready to type
    /// in it rather than back where you started.
    func open(_ match: FileFinder.Match) {
        guard let project = selectedProject else { return }
        let url = project.url.appendingPathComponent(match.path)
        closeFileFinder()
        openFile(url)
    }

    /// How many files the palette is searching, for its footer.
    var fileFinderCount: Int {
        guard let project = selectedProject else { return 0 }
        return fileFinderIndexes[project.url]?.count ?? 0
    }

    private func listFiles(in project: Project) {
        fileListTask?.cancel()
        let root = project.url
        isListingFiles = fileFinderIndexes[root] == nil
        fileListTask = Task { [weak self] in
            // Listed, then folded once for the whole repository — a keystroke
            // should only have to compare, never to prepare.
            let paths = await ClaudeCompletions.files(in: root)
            let index = await FileFinder.index(paths)
            guard !Task.isCancelled else { return }
            self?.apply(index, for: root)
        }
    }

    private func apply(_ index: FileFinder.Index, for root: URL) {
        fileFinderIndexes[root] = index
        isListingFiles = false
        // Anything typed while the list was still being read has had nothing to
        // search until now.
        guard isFindingFiles, selectedProject?.url == root else { return }
        searchFiles()
    }

    private func searchFiles() {
        fileSearchTask?.cancel()
        guard isFindingFiles, let project = selectedProject else { return }
        let query = fileFinderQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            fileFinderMatches = recentFiles(in: project)
            return
        }
        // Nothing to rank yet: what is on screen stays rather than blinking
        // empty, and `apply` runs this again the moment the list lands.
        guard let index = fileFinderIndexes[project.url] else { return }

        fileSearchTask = Task { [weak self] in
            let matches = await FileFinder.search(query, in: index)
            guard !Task.isCancelled else { return }
            self?.show(matches, for: query)
        }
    }

    /// Only if the query is still the one that was searched for: a slow ranking
    /// must never overwrite the results of a later, faster one.
    private func show(_ matches: [FileFinder.Match], for query: String) {
        guard isFindingFiles,
              fileFinderQuery.trimmingCharacters(in: .whitespaces) == query
        else { return }
        fileFinderMatches = matches
        fileFinderSelection = min(fileFinderSelection, max(matches.count - 1, 0))
    }

    /// What the palette lists before anything is typed: the files of this
    /// repository that have been open, newest first. The one on screen is left
    /// out — it is the row you would never pick — which makes ⌘P⏎ the way back
    /// to the file you were just in.
    private func recentFiles(in project: Project, limit: Int = 20) -> [FileFinder.Match] {
        let root = project.url.standardizedFileURL.path + "/"
        let onScreen = showsDashboard ? nil : current?.id
        var seen = Set<String>()
        var recent: [FileFinder.Match] = []

        for key in viewer.history.reversed() where key != onScreen {
            guard let item = items[key], case .file(let url) = item.kind else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root) else { continue }
            let relative = String(path.dropFirst(root.count))
            guard seen.insert(relative).inserted else { continue }
            recent.append(FileFinder.Match(path: relative, highlighted: []))
            if recent.count >= limit { break }
        }
        return recent
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
