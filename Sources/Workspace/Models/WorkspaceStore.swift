import AppKit
import Foundation
import SwiftUI

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

        /// Claude's is never drawn: `NavigatorView` gives that tab ``ClaudeMark``
        /// instead, which is artwork and not a symbol name. It stays here so
        /// every tab can answer the question, and so a caller that only has a
        /// `String` to hand has something to fall back on.
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
    /// Which of the navigator's lists is showing. Kept per repository, next to
    /// the viewer's own history: reading a file in one repository and a
    /// terminal in another are two places to be, and switching between them
    /// should land back where each was left rather than dragging one
    /// repository's pane onto the other.
    var navigatorTab: NavigatorTab {
        get { viewer.navigatorTab }
        set { viewer.navigatorTab = newValue }
    }

    var fileSearchText = ""

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
        /// Which navigator list this repository was left on.
        var navigatorTab: NavigatorTab = .files
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

    // New repository
    /// Set while the New Repository sheet is up — `git init` in a new folder, or
    /// a clone of one that is already on a host. `nil` the rest of the time,
    /// which is what keeps the sheet away.
    var newRepository: NewRepositoryRequest?

    private let projectsDefaultsKey = "workspace.projects"
    private let pinnedProjectsDefaultsKey = "workspace.pinnedProjects"
    private let gitHubAccountsDefaultsKey = "workspace.githubAccounts"
    private let pastClaudeConversationsDefaultsKey = "workspace.showsPastClaudeConversations"
    /// The tab list older versions of the app saved. Only cleared now — see
    /// `Saved terminals` below for why nothing comes back any more.
    private let legacyTerminalsDefaultsKey = "workspace.terminals"
    private let historyLimit = 40

    init() {
        // Read before the setter can write it back: an absent key means nobody
        // has chosen, which is the default rather than false.
        if UserDefaults.standard.object(forKey: pastClaudeConversationsDefaultsKey) != nil {
            showsPastClaudeConversations = UserDefaults.standard.bool(
                forKey: pastClaudeConversationsDefaultsKey
            )
        }
        UserDefaults.standard.removeObject(forKey: legacyTerminalsDefaultsKey)
        restoreProjects()
        // Clicking a banner has to land on the shell it was about, and the
        // notifier knows nothing but its id.
        TerminalNotifier.shared.onOpen = { [weak self] id in
            self?.revealTerminal(id: id)
        }
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
        watchWorkingTree(of: project)
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

        // A floating conversation is rooted in the folder being removed, so it
        // goes with it rather than being left over a repository that is gone.
        for panel in chats where panel.projectID == project.id {
            panel.session.terminate()
        }
        chats.removeAll { $0.projectID == project.id }

        // Forget anything that belonged to it, its shells included — the
        // window-wide terminal is untouched, it belongs to no repository.
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

    /// A repository that is already on this Mac: the user picks its folder.
    /// ``showNewRepository(_:)`` is the other way in, for one that is not.
    func promptForProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        // A repository can be made here as well as found: the picker's own New
        // Folder button was off, which is why an empty one could not be started
        // from this side at all.
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose one or more repository folders."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            addProject(at: url, makeSelected: url == panel.urls.first)
        }
    }

    // MARK: - New repository

    /// Opens the New Repository sheet. `mode` is which of the two halves it
    /// starts on; both are one press apart inside it.
    func showNewRepository(_ mode: NewRepository.Mode = .create) {
        newRepository = NewRepositoryRequest(mode: mode)
    }

    func dismissNewRepository() {
        newRepository = nil
    }

    /// The folder the sheet has just made. Added like any other repository, and
    /// selected: one is made in order to work in it.
    func adoptNewRepository(at url: URL, cloned: Bool) {
        newRepository = nil
        addProject(at: url)
        showStatus(cloned
            ? "Cloned into \(url.lastPathComponent)"
            : "Created \(url.lastPathComponent)")
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

    /// Reads every repository again. `quietly` is the sweep on a clock: the same
    /// reads, with no spinner put up for them — see `Project.refresh`.
    func refreshAll(quietly: Bool = false) {
        lastAutoRefresh = Date()
        for project in projects {
            Task { await project.refresh(quietly: quietly) }
        }
    }

    // MARK: - Refreshing on a clock

    /// How often every repository in the sidebar is read again — the branch it
    /// is on, how many files have changed, how many pull requests are open.
    private static let autoRefreshInterval: TimeInterval = 5 * 60

    /// Live for as long as the window is; see ``startAutomaticRefresh``.
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?
    /// When the last sweep went out, by the clock rather than by the loop: a
    /// tick skipped while the app was in the background must not push the next
    /// one five minutes further away.
    @ObservationIgnored private var lastAutoRefresh = Date()
    /// Set by a due tick that found the app behind something else, so the sweep
    /// it owed goes out on the first tick after the app is in front again.
    @ObservationIgnored private var missedAutoRefresh = false

    /// The one re-read of the diff on screen; see ``reloadPresentedWorkingDiff``.
    @ObservationIgnored private var presentedDiffReload: Task<Void, Never>?

    /// The five-minute sweep of the sidebar. Called once, from the window's
    /// `task` — starting it from `init` would put a `gh` call per repository on
    /// the launch, and would run in the throwaway store SwiftUI can build.
    ///
    /// **Only while the app is in front.** A pull request read costs a call to
    /// GitHub or Bitbucket per repository, and a workspace left open for a week
    /// behind a browser would spend a few thousand of them on a sidebar nobody
    /// is looking at. What matters is that the numbers are right when the user
    /// comes back, so a tick that fell due in the background is remembered and
    /// paid on the first tick after the app is in front — however long it was
    /// away, that is one sweep rather than one per five minutes missed.
    func startAutomaticRefresh() {
        guard autoRefreshTask == nil else { return }
        startReloadingOnReturningToFront()

        autoRefreshTask = Task { [weak self] in
            // The loop runs a minute at a time and decides by the clock, so a
            // sweep the user asked for by hand pushes the next one out too.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                let due = Date().timeIntervalSince(lastAutoRefresh) >= Self.autoRefreshInterval
                guard due || missedAutoRefresh else { continue }
                guard NSApp.isActive else {
                    missedAutoRefresh = true
                    continue
                }
                missedAutoRefresh = false
                // Quietly: nobody asked for this one, so nothing on screen
                // should start spinning to announce it.
                refreshAll(quietly: true)
            }
        }
    }

    // MARK: - Files written outside the app

    /// Hooks a project up to what it cannot do for itself.
    ///
    /// `Project` owns the watcher and reloads its own git status and file tree
    /// — that much is its business. The editor showing one of those files and
    /// the diff in the centre of the window are the store's, and the project
    /// has no reference back to the store on purpose: the store is the single
    /// source of truth, so it reaches down rather than being reached up to.
    /// Both references are weak: the closure lives on the project it is about,
    /// so holding it strongly would be a project that can never be removed.
    private func watchWorkingTree(of project: Project) {
        project.onWorkingTreeChanged = { [weak self, weak project] changed in
            guard let self, let project else { return }
            filesChangedOnDisk(in: project, changed: changed)
        }
    }

    /// `changed` nil means something changed and nobody knows what, so
    /// everything on screen is checked.
    private func filesChangedOnDisk(in project: Project, changed: Set<URL>?) {
        reloadOpenDocuments(changed: changed)
        reloadPresentedWorkingDiff(of: project)
    }

    /// Re-reads the open editors whose file moved underneath them. The document
    /// decides whether it actually will — see `reloadFromDiskIfChanged`, which
    /// is what keeps unsaved edits and our own saves safe.
    private func reloadOpenDocuments(changed: Set<URL>?) {
        for document in openDocuments {
            if let changed, !changed.contains(document.url.standardizedFileURL) { continue }
            document.reloadFromDiskIfChanged()
        }
    }

    /// Re-runs the load behind the working-tree diff on screen. The parsed patch
    /// is cached on the item and an item already presented is never loaded
    /// again, so without this the diff of a file Claude Code just rewrote keeps
    /// showing the version before it.
    ///
    /// Only the item actually being looked at: a diff sitting in the back stack
    /// costs a `git diff` to refresh and will be reloaded when it is opened
    /// again anyway.
    ///
    /// One reload at a time, and the newest wins. The debounce in front of this
    /// is 400ms and a `git diff` over a large file while Claude Code works can
    /// take longer, so two reads can be in flight — and without the cancel it is
    /// whichever finishes last, not whichever was asked for last, that ends up
    /// on screen.
    private func reloadPresentedWorkingDiff(of project: Project) {
        guard !showsDashboard,
              let item = current,
              case .workingDiff(let projectID, let path, let isUntracked) = item.kind,
              projectID == project.id
        else { return }

        presentedDiffReload?.cancel()
        guard !path.isEmpty else {
            presentedDiffReload = Task { await loadAllChanges(item, project: project, quietly: true) }
            return
        }
        // The change list is the fresher answer for a renamed file's second
        // path, and for a file that has been staged since the diff was opened;
        // the item's own `isUntracked` is only the fallback for one git no
        // longer lists at all.
        let change = project.gitStatus?.changes.first { $0.path == path }
        presentedDiffReload = Task {
            await loadWorkingDiff(
                item,
                project: project,
                paths: change?.gitPaths ?? [path],
                isUntracked: change.map { $0.label == "Untracked" } ?? isUntracked,
                quietly: true
            )
        }
    }

    /// Belt and braces for the app coming back to the front. FSEvents reaches a
    /// background app too, but a stream can coalesce a long absence into less
    /// than it was, and the reload is one `git status` per repository — cheap
    /// enough to pay for the certainty that what the user is looking at when
    /// they return is what is on disk.
    ///
    /// Registered from `startAutomaticRefresh` for the same reason that one is
    /// called from the window rather than from `init`: the store SwiftUI builds
    /// and throws away must not leave an observer behind.
    private func startReloadingOnReturningToFront() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadEveryProjectFromDisk() }
        }
    }

    private func reloadEveryProjectFromDisk() {
        for project in projects {
            Task { await project.reloadAfterReturningToFront() }
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
            watchWorkingTree(of: project)
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
        // A terminal is only ever closed tab by tab, by the user. This puts
        // the dashboard back and leaves its shells running.
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
    /// files are touched — a shell has something running behind it, and a diff
    /// or a pull request costs a title and a patch rather than a live editor.
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

        // Reading a repository's changes is **one** place in the history,
        // however many files it takes. Clicking down the Changes list is not
        // going somewhere new each time — it is the same page showing another
        // file — and stacking an entry per file meant ⎋ had to be pressed once
        // per file read to get out, and Back walked the whole morning's list
        // backwards. So one diff takes the other's slot, and the way out lands
        // on whatever sent you into the diff.
        if let outgoing = current, isAnotherFileOfTheSameDiff(outgoing, item) {
            // Unified or split is how the diff is being *read*, so it carries
            // to the next file rather than snapping back to split — the pane
            // is the same page, and the outgoing item is about to be dropped.
            item.diffLayout = outgoing.diffLayout
            viewer.history[viewer.index] = item.id
            items[outgoing.id] = nil
            forgetItem(outgoing.id)
            // The slot is the newest entry — the forward history has just gone
            // — but dropping the outgoing diff may have taken an older entry
            // for it out from under the index.
            viewer.index = viewer.history.count - 1
            return
        }

        viewer.history.append(item.id)
        viewer.index = viewer.history.count - 1
        trimHistory()
    }

    /// Whether showing `item` is the diff on screen moving to another file
    /// rather than a page of its own: both are the working tree of the same
    /// repository, which is the Changes list being read down.
    ///
    /// A commit and a pull request are left out on purpose. Each is a thing in
    /// its own right that happens to be shown as a diff, and stepping between
    /// two of them is somewhere to be able to go Back from.
    private func isAnotherFileOfTheSameDiff(_ outgoing: ViewerItem, _ item: ViewerItem) -> Bool {
        guard case .workingDiff(let left, _, _) = outgoing.kind,
              case .workingDiff(let right, _, _) = item.kind else { return false }
        return left == right
    }

    /// Which repository's history an item belongs in.
    private func owningProjectID(of item: ViewerItem) -> URL? {
        switch item.kind {
        case .file(let url): project(containing: url)?.id
        case .workingDiff(let projectID, _, _): projectID
        case .commit(let projectID, _): projectID
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

    /// Both reveal arguments count from zero, the way LSP does.
    func openFile(_ url: URL, revealLine: Int? = nil, revealColumn: Int? = nil) {
        let key = ViewerItem.Kind.file(url).key
        if let existing = items[key] {
            if let revealLine {
                existing.document?.revealLine = revealLine
                existing.document?.revealColumn = revealColumn
            }
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
        document.revealColumn = revealColumn
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

    /// `quietly` is the reload nobody asked for — a file changed on disk under a
    /// diff that is already on screen. `isLoading` swaps the whole patch for a
    /// spinner, which for a diff being read while Claude Code works through the
    /// repository would mean the pane blinking every few seconds; the new patch
    /// simply replaces the old one when it lands.
    private func loadWorkingDiff(
        _ item: ViewerItem,
        project: Project,
        paths: [String],
        isUntracked: Bool,
        quietly: Bool = false
    ) async {
        if !quietly { item.isLoading = true }
        item.errorMessage = nil
        let text = await GitStatus.diff(paths: paths, in: project.url, isUntracked: isUntracked)
        let parsed = DiffHighlighter.highlight(await DiffParser.parseInBackground(text))
        // A read this one was started to replace; leaving the item alone is the
        // whole point of having been cancelled. Only a quiet reload is ever
        // cancelled, so there is no spinner left running by returning here.
        guard !Task.isCancelled else { return }
        item.diff = parsed
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

    private func loadAllChanges(_ item: ViewerItem, project: Project, quietly: Bool = false) async {
        if !quietly { item.isLoading = true }
        item.errorMessage = nil
        let untracked = project.gitStatus?.changes
            .filter { $0.label == "Untracked" }
            .map(\.path) ?? []
        let text = await GitStatus.diffAll(in: project.url, untrackedPaths: untracked)
        let parsed = DiffHighlighter.highlight(await DiffParser.parseInBackground(text))
        guard !Task.isCancelled else { return }
        item.diff = parsed
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

    /// Reads everything this pull request is made of again, from the host.
    ///
    /// The same things ``openPullRequest(_:project:)`` fetches the first time
    /// round, minus the shortcuts it takes: the request itself — its title,
    /// state, draft flag, approvals and description all live on that one object
    /// — the diff, the conversation, who is reviewing, the CI runs and how far
    /// the branch has drifted. The commits come along only if the tab that
    /// shows them has already been opened; a review that never went there
    /// should not start paying for the call now.
    ///
    /// They are independent reads, so they go out together the way the
    /// dashboard's do: the wait is the slowest host call rather than the sum of
    /// them, and each writes what it owns as it lands.
    func refreshPullRequest(_ item: ViewerItem, project: Project, pr: PullRequest) async {
        // Not while a merge, a rejection or a sync is on its way: what comes
        // back would be the state from before it landed. One refresh at a time,
        // too — the button is easy to lean on.
        guard !item.isRefreshingPullRequest, !item.isRunningPullRequestAction else { return }
        item.isRefreshingPullRequest = true
        defer { item.isRefreshingPullRequest = false }

        async let request: Void = reloadPullRequest(item, project: project, pr: pr)
        async let diff: Void = loadPullRequestDiff(item, project: project, pr: pr)
        async let comments: Void = loadComments(item, project: project, pr: pr)
        async let builds: Void = loadBuilds(item, project: project, pr: pr)
        async let commits: Void = reloadCommitsIfShown(item, project: project, pr: pr)
        // Fetching first, because the branch may well have moved on the host
        // since it was last counted here.
        async let sync: Void = refreshSyncState(item, project: project, pr: pr, fetching: true)
        _ = await (request, diff, comments, builds, commits, sync)

        showStatus("#\(pr.number) refreshed")
    }

    /// The pull request object itself, re-read from the host. It is what the
    /// summary bar and the header are drawn from, so a refresh that left it
    /// alone would reload the diff under a title, a state and an approvals
    /// count from whenever the request was opened.
    private func reloadPullRequest(_ item: ViewerItem, project: Project, pr: PullRequest) async {
        guard let remote = project.remote, remote.kind != .unknown else { return }
        var latest = pr
        do {
            latest = try await PullRequestService.load(
                number: pr.number,
                for: remote,
                in: project.url
            )
            item.pullRequest = latest
            // The header names the pull request by its title, and a title is
            // one of the things that can have changed on the host.
            item.title = latest.title
        } catch {
            // Whatever else lands is still worth showing, so this says what
            // went wrong and leaves the rest of the refresh to finish.
            showError(error.localizedDescription)
        }
        // Both hosts hand the reviewers over with the request, so this usually
        // costs nothing beyond the call just made.
        await loadReviewers(item, project: project, pr: latest)
        if let named = await PullRequestService.namedMentions(in: latest, directory: project.url) {
            item.pullRequest?.body = named
        }
    }

    /// The commits, but only for a Commits tab that has already been opened —
    /// see ``loadCommits(_:project:pr:)`` for why they are not fetched with
    /// everything else in the first place.
    private func reloadCommitsIfShown(_ item: ViewerItem, project: Project, pr: PullRequest) async {
        guard !item.commits.isEmpty else { return }
        await loadCommits(item, project: project, pr: pr)
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
            item.setComments(try await PullRequestService.comments(for: pr, in: project.url))
        } catch {
            item.setComments([])
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

    /// The CI runs, read out loud: the spinner turns while it is in flight, and
    /// a refusal replaces the list with what the host said. This is the first
    /// look at the panel and the reload button — both are somebody waiting for
    /// an answer, so both are allowed to say they are working and to fail
    /// visibly.
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

    /// The same runs, read quietly, for the panel's ticker.
    ///
    /// Nobody asked for this one, so it says nothing: no spinner to flash every
    /// ten seconds, and a `gh` or `bkt` that stumbles once leaves the last good
    /// list where it is rather than emptying the panel under someone reading it.
    /// The list is only assigned when it has actually changed, so a tick that
    /// finds the same jobs redraws nothing.
    func refreshBuilds(_ item: ViewerItem, project: Project, pr: PullRequest) async {
        guard let builds = try? await PullRequestService.builds(for: pr, in: project.url) else {
            return
        }
        if item.builds != builds { item.builds = builds }
        // The host is answering again, so whatever the last failure left on
        // screen is out of date.
        if item.buildsError != nil { item.buildsError = nil }
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
            item.cacheCommitDiff(
                DiffHighlighter.highlight(await DiffParser.parseInBackground(text)),
                for: commit.sha
            )
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
                mentioning(body, on: item, pr: pr),
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
                mentioning(body, on: item, pr: pr),
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

    /// Settles a comment thread, or opens it again. The conversation is read
    /// back afterwards rather than edited in place: resolution is the host's
    /// word, and a thread someone else has already touched should come back
    /// saying so.
    func setCommentResolved(
        _ resolved: Bool,
        for comment: PullRequestComment,
        on item: ViewerItem,
        project: Project,
        pr: PullRequest
    ) async {
        item.isPostingComment = true
        item.commentError = nil
        do {
            try await PullRequestService.setResolved(
                resolved,
                for: comment,
                on: pr,
                in: project.url
            )
            showStatus(resolved
                ? "Thread resolved on #\(pr.number)"
                : "Thread reopened on #\(pr.number)")
            await loadComments(item, project: project, pr: pr)
        } catch {
            item.commentError = error.localizedDescription
        }
        item.isPostingComment = false
    }

    /// A comment with its mentions in the form the host wants.
    ///
    /// The composer writes the **name**, because that is what the person typing
    /// needs to see; Bitbucket Cloud notifies nobody unless the raw Markdown
    /// carries an `@{account_id}`, so the swap happens here, at the one point
    /// every comment — new, reply, and inline — passes through on its way out.
    ///
    /// GitHub is left alone: there the name and the login are the same string,
    /// and what was typed is already right.
    private func mentioning(_ body: String, on item: ViewerItem, pr: PullRequest) -> String {
        guard pr.host == .bitbucket else { return body }
        return BitbucketMarkup.encodingMentions(in: body, people: item.reviewerCandidates)
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
        let reusable = command == nil && title == nil ? plainShell(of: item) : nil
        if let reusable {
            selectTerminal(reusable, in: item)
        } else {
            addTerminalTab(to: item, directory: directory, runningCommand: command, title: title)
        }
        present(item)
        // The viewer shows one shell and has no tab bar, so the navigator
        // switches to the list of the rest.
        navigatorTab = .terminals
        return item
    }

    /// The shell this item should come back to when a plain terminal is asked
    /// for: the tab it was left on when that is not a conversation, and
    /// otherwise the shell used most recently. Nothing, when every tab it has
    /// is a conversation — the caller starts one instead.
    private func plainShell(of item: ViewerItem) -> TerminalSession? {
        if let selected = item.selectedTerminal, !selected.runsClaude { return selected }
        return item.terminals
            .filter { !$0.runsClaude }
            .max { $0.lastUsedAt < $1.lastUsedAt }
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

    /// The same list without the conversations, numbered from 1 again.
    ///
    /// Nothing puts a conversation in a terminal tab any more — they float over
    /// the window (see ``chats``) — so on a live window this filters nothing
    /// out. It stays because it is the promise the whole Terminals list is
    /// built on: what is listed here is a shell the user opened, and never a
    /// chat wearing a shell's clothes. Everything the user thinks of as "the
    /// terminals" — the list, the counts, the shell a plain "Open Terminal"
    /// comes back to — reads this.
    func shellTerminals(in scope: TerminalScope) -> [OpenTerminal] {
        // Renumbered rather than filtered alone: the number is only there to
        // tell same-named shells apart, and a list that ran 1, 3, 4 would read
        // as though two of them had been lost.
        terminals(in: scope)
            .filter { !$0.session.runsClaude }
            .enumerated()
            .map { OpenTerminal(session: $1.session, item: $1.item, position: $0 + 1) }
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
        shellTerminals(in: .project(project.id)).count
    }

    /// Opens one of the navigator's lists, unfolding the pane if it is away.
    /// Everything that sends the user there goes through this: setting the tab
    /// alone does nothing visible while the pane is hidden.
    func showNavigator(_ tab: NavigatorTab) {
        navigatorTab = tab
        showsNavigator = true
    }

    /// Switching the navigator by hand — the tab bar, or the View menu.
    ///
    /// The two session lists also put their most recent session back in the
    /// centre. Both tabs are the way back to something that is already running,
    /// so landing on the list with the dashboard still up asks for a second
    /// click on the one card that was ever going to be clicked.
    func selectNavigatorTab(_ tab: NavigatorTab) {
        showNavigator(tab)
        showMostRecentSession(of: tab)
    }

    /// The newest of one list's sessions, back where it can be read. Nothing is
    /// started: a repository with no shells — or no conversations — only gets
    /// its list, where the first row is the one that starts one.
    private func showMostRecentSession(of tab: NavigatorTab) {
        switch tab {
        case .terminals:
            // The scope the list itself shows, so what comes back is one of the
            // cards standing under the pointer rather than another folder's.
            guard let scope = visibleTerminalScope,
                  let recent = shellTerminals(in: scope)
                      .max(by: { $0.session.lastUsedAt < $1.session.lastUsedAt }),
                  !isShowing(recent)
            else { return }
            showTerminal(recent)
        case .claude:
            // A conversation is never in the centre pane, so there is nothing to
            // put back there — the panels are already over the window. Bringing
            // the newest forward is exactly the click the list was about to be
            // given: off the dock if it is folded, and out from under the others
            // if it is not.
            guard let project = selectedProject,
                  let recent = chats(in: project).max(by: { $0.depth < $1.depth })
            else { return }
            unfoldChatPanel(recent)
        default:
            return
        }
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
        let recent = shellTerminals(in: .project(project.id))
            .max { $0.session.lastUsedAt < $1.session.lastUsedAt }
        if let recent { showTerminal(recent) }
    }

    /// Puts one shell from the terminals list back on screen.
    func showTerminal(_ terminal: OpenTerminal) {
        selectTerminal(terminal.session, in: terminal.item)
        present(terminal.item)
    }

    /// Makes a tab the visible one and marks it as the newest in the list.
    func selectTerminal(_ session: TerminalSession, in item: ViewerItem) {
        item.selectedTerminalID = session.id
        session.lastUsedAt = Date()
        session.startIfNeeded()
    }

    /// Whether this exact shell is what the viewer is showing.
    func isShowing(_ terminal: OpenTerminal) -> Bool {
        isShowingTerminal(terminal.session, in: terminal.item)
    }

    private func isShowingTerminal(_ session: TerminalSession, in item: ViewerItem) -> Bool {
        !showsDashboard && current?.id == item.id && item.selectedTerminal?.id == session.id
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
            // Counted over the shells alone, to match the list they are named
            // for: conversations are named after what they are about and sit
            // in a list of their own.
            title: title ?? "Shell \(item.terminals.count { !$0.runsClaude } + 1)",
            in: item
        )
        item.terminals.append(session)
        item.selectedTerminalID = session.id
        // Terminal items are the one kind kept outside the history, so a brand
        // new one is registered here rather than waiting to be presented.
        items[item.id] = item
        session.startIfNeeded(runningCommand: command)
    }

    /// A tab wired into the store: it removes itself when its shell exits.
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
        session.onAttention = { [weak self, weak item, weak session] body in
            guard let self, let item, let session else { return }
            announce(session, in: item, saying: body)
        }
        return session
    }

    /// Puts a Notification Centre banner up for a shell that wants the user
    /// back — unless the user is already looking straight at it, which is the
    /// one case where a banner says nothing the screen does not.
    private func announce(_ session: TerminalSession, in item: ViewerItem, saying body: String) {
        guard !(NSApp.isActive && isShowingTerminal(session, in: item)) else { return }
        TerminalNotifier.shared.notify(
            title: session.notificationTitle,
            // The repository the shell belongs to, or "Home" — with several
            // conversations going the name alone rarely says which is which.
            subtitle: item.subtitle,
            body: body,
            sessionID: session.id
        )
    }

    /// Brings a shell back on screen from outside the app — a banner clicked
    /// while Workspace was behind something else.
    func revealTerminal(id: UUID) {
        // A conversation is nowhere in the terminal lists: it is a panel, so
        // being reached from a banner means unfolding it and putting it in
        // front rather than opening anything. `raiseChatPanel` is also what
        // brings back one that had dropped out of sight behind two newer ones.
        if let panel = chats.first(where: { $0.session.id == id }) {
            unfoldChatPanel(panel)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            return
        }
        guard let terminal = openTerminals.first(where: { $0.session.id == id }) else { return }
        showTerminal(terminal)
        // The list the tab belongs to, so the rest of them are to hand too.
        showNavigator(terminal.session.runsClaude ? .claude : .terminals)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
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

    // MARK: - Saved terminals
    //
    // There are none, on purpose. Tabs used to be written to `UserDefaults` and
    // listed again on the next launch, but the shell behind them dies with the
    // app, so what came back was an empty tab wearing the name of something
    // that had gone — and a Claude Code tab came back worst of all: nothing on
    // disk said it had been one, so a finished conversation reappeared in the
    // Terminals list as a shell that had never run. A launch now starts with no
    // terminals at all, and the past conversations that are still on disk are
    // read from the transcripts themselves (see `ClaudeSessionsIndex`), which
    // can say truthfully what they are.

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
        MarkdownPDF.save(
            markdown: document.text,
            suggestedName: name,
            relativeTo: document.url
        ) { [weak self] result in
            switch result {
            case .success(let url):
                self?.showStatus("Saved \(url.lastPathComponent)")
            case .failure(let error):
                self?.showError("Could not save the PDF: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - External tools

    /// Starts Claude Code on this repository, in a floating panel of its own.
    ///
    /// A conversation is a shell here, not a pane of its own: `claude` is a
    /// terminal program, and the app used to drive it through a stream of JSON
    /// and redraw the whole transcript in SwiftUI — which cost far more to keep
    /// on screen than the thing it was imitating. Reaching for the real CLI
    /// means the transcript is drawn by the terminal, and every version of
    /// Claude Code works, flags and all, without the app having to know about
    /// any of them.
    ///
    /// **It floats, and there is no other way to open one.** Asking Claude
    /// about a repository is asking about the file you are looking at, and a
    /// conversation in the centre pane took that file off the screen to answer
    /// a question about it. Over the window it does not, which is the whole of
    /// why every route in — this, the navigator's New Conversation, the
    /// dashboard button, ⇧⌘L — lands here.
    ///
    /// **Always a new conversation.** As many can run at once as you care to
    /// start — separate processes in separate shells, so a turn working away in
    /// one carries on while another is typed into. Only two are on screen at a
    /// time (see ``chats``); the Claude list is how you get back to the rest.
    ///
    /// The conversation is given its **id up front** (`--session-id`) rather
    /// than being left to name itself. Without one there is no way to tell the
    /// transcript it is writing from a conversation that merely ended: the
    /// history would list a row for the chat that is running in front of you,
    /// and clicking it would start a second `claude` on the same file. A CLI too
    /// old for the flag simply goes without, and takes that duplicate row.
    func openClaude(in project: Project) {
        // The panel is made now and the command typed in a moment later. The
        // shell needs about a second to draw its prompt either way, so asking
        // the CLI what it accepts costs nothing that was not already being
        // waited for — and the panel is on screen while it happens.
        let panel = floatChat(in: project, title: "Claude")
        startClaude(in: panel.session)
    }

    /// Starts a brand new conversation in a panel's shell: the flags this Mac's
    /// `claude` takes, then the command. A resumed one skips this — it already
    /// knows its session id, so there is nothing to ask about.
    private func startClaude(in session: TerminalSession) {
        // Up before the question is even asked: what is behind it until the
        // answer lands is a shell prompt this tab was never opened for.
        session.beginClaudeStartup()

        Task {
            let cli = await ClaudeCLI.shared.info()
            guard cli.supportsSessionID else {
                session.runClaude("claude")
                return
            }
            let id = UUID().uuidString.lowercased()
            session.claudeSessionID = id
            session.runClaude("claude --session-id \(id)")
        }
    }

    /// Picks a past conversation up where it was left, in a panel of its own.
    ///
    /// A running conversation is remembered by session id, so clicking the same
    /// row again comes back to the shell already running it rather than starting
    /// a second `claude` on the same transcript — which the CLI would let you
    /// do, and which would leave two of them writing to one file. Coming back to
    /// it is a raise, not a restart, whether its panel was on screen, folded
    /// away or behind two newer ones.
    func resumeClaude(_ past: ClaudePastSession, in project: Project) {
        if let running = chats.first(where: { $0.session.claudeSessionID == past.id }) {
            unfoldChatPanel(running)
            return
        }
        // The first prompt of a conversation is its title, and a prompt can be a
        // paragraph. The shell renames the panel itself within a second or two;
        // this is only what it is called until then.
        let title = past.title.count > 32
            ? String(past.title.prefix(32)) + "…"
            : past.title
        let panel = floatChat(in: project, title: title)
        panel.session.claudeSessionID = past.id
        // Typed here rather than handed to the shell, so this start is covered
        // by the same spinner a new conversation gets.
        panel.session.runClaude("claude --resume \(Shell.quote(past.id))")
    }

    /// Every conversation this repository has running, in the order they were
    /// started — the ones on screen and the ones that have fallen behind them
    /// alike. What the Claude list shows above the history.
    func chats(in project: Project) -> [ChatPanel] {
        chats.filter { $0.projectID == project.id }
    }

    /// How many of this repository's conversations are mid-turn, for the badge
    /// on its card. A turn can run for minutes with the window somewhere else
    /// entirely, so the sidebar is where "something is still going" belongs —
    /// the banner only arrives once it is over.
    func workingClaudeCount(in project: Project) -> Int {
        chats(in: project).count { $0.session.isWorking }
    }

    // MARK: - Floating chats

    /// Every conversation alive in this window, in the order they were started.
    ///
    /// A chat is the same thing a shell is — a `TerminalSession` running the
    /// real CLI — put somewhere you can keep reading code next to it. It is
    /// deliberately **not** one of a terminal item's tabs: the shell's view is a
    /// single `NSView` that lives on the session, so a conversation offered both
    /// in a panel and in the centre would be one view two places want to host,
    /// and whichever drew it last would tear it out of the other.
    ///
    /// **Every conversation here is drawn** — ``visibleChats`` is this list — so
    /// nothing is ever pushed out of sight to make room. The only way a running
    /// conversation is off screen is folded to the dock, which the reader does
    /// on purpose and *nothing else happens to it*: its shell, its process and
    /// its transcript carry on exactly as they were, and unfolding it, or
    /// raising it from the Claude list, brings the panel back with the turn it
    /// was running still running. Ending a conversation is one thing and one
    /// thing only, and that is the ✕.
    var chats: [ChatPanel] = []

    /// What the overlay draws: every conversation, in ``chats`` order rather
    /// than front-to-back.
    ///
    /// **There is no ceiling.** There used to be two, on the argument that a
    /// third panel over a three-pane window leaves no window to read — but that
    /// is the reader's call to make and they have the fold, the dock and the ✕
    /// to make it with. A cap could only ever guess, and guessing wrong meant a
    /// running conversation pushed somewhere the user had to go and find.
    ///
    /// What the ceiling really costs is the machine, not the screen: each panel
    /// is a live `GhosttySurfaceView` on its own `CAMetalLayer`, **folded or
    /// not**. Folding used to take the terminal out of the window and that is
    /// what made coming back from the dock slow — a surface re-added to a window
    /// re-applies its scale and its size and has to draw before anything is
    /// there. The cost of keeping it is an idle Metal layer per conversation,
    /// paid so that unfolding is instant; ending one is still the ✕.
    ///
    /// The order matters more than it looks. `ForEach` builds the view tree in
    /// the order of the array it is given, so sorting this by depth would move
    /// a panel's terminal inside the view hierarchy every time the front one
    /// changed — and a `GhosttySurfaceView` pulled out and put back loses the
    /// keyboard mid-sentence. Which panel is in front is ``ChatPanel/depth``
    /// and `zIndex`, never position.
    var visibleChats: [ChatPanel] { chats }

    /// Whether this conversation is showing its terminal rather than sitting on
    /// the dock. Every panel is drawn now — see ``visibleChats`` — so folded is
    /// the only way one is out of sight, and it is the only thing the Claude
    /// list has left to tell the reader about.
    func isOnScreen(_ panel: ChatPanel) -> Bool {
        !panel.isCollapsed
    }

    /// What every change to a panel that is not a drag eases with. Opening,
    /// closing, folding to the dock and coming back from it, and one panel
    /// giving way to another all move the same way, so they read as one
    /// behaviour rather than four. Dragging and resizing are deliberately not on
    /// this list: those follow the pointer, and a cursor the panel lags behind
    /// by a fifth of a second feels broken.
    static let chatPanelMotion = Animation.easeInOut(duration: 0.22)

    /// The window's own size, as the overlay last laid itself out in. Kept here
    /// because a panel is opened from a menu item, which knows nothing about any
    /// window — and a corner cannot be measured from without one. The default
    /// window size stands in until the overlay has been laid out once, and the
    /// clamp the overlay does on its first pass corrects anything placed before
    /// then.
    private var chatPanelBounds = CGSize(width: 1360, height: 860)

    /// The centre pane's own rectangle, in those same coordinates. Where the
    /// dock runs.
    ///
    /// The window is the wrong place for it: the bottom-right corner of the
    /// window belongs to the navigator, and a bar parked there sits on top of
    /// the tools at the foot of that pane. The viewer is the one region nothing
    /// else claims a corner of. ``ContentView`` reports it from the viewer's own
    /// geometry, so folding a side pane away or dragging a seam moves the dock
    /// with it rather than leaving the bars behind.
    ///
    /// A **free-floating** panel is not confined to it, deliberately: that one is
    /// placed by hand, and a window-like thing you may not drop where you like is
    /// not one. Only the dock — the placement the app does for you — is held to
    /// the pane.
    private var reportedDockRegion: CGRect?

    /// The whole window until the viewer has been laid out once, which is what
    /// this was before there was a viewer to ask.
    var chatDockRegion: CGRect {
        reportedDockRegion ?? CGRect(origin: .zero, size: chatPanelBounds)
    }

    /// The centre pane has been laid out, or moved. Called from `onAppear` and
    /// `onChange` rather than from the layout itself: writing to the store while
    /// the view tree is being built is a mutation inside an observation, and the
    /// runtime says so out loud.
    func chatDockDidLayout(_ rect: CGRect) {
        guard rect.width > 0, rect.height > 0, rect != reportedDockRegion else { return }
        reportedDockRegion = rect
    }

    /// Where a panel is drawn right now.
    ///
    /// A folded panel does not stay where it was: it goes down to the bottom of
    /// the **centre pane**, where ``ChatDockStrip`` draws its bar — out of the
    /// way of the code, and in the one place you would think to look for it. Its
    /// stored ``ChatPanel/frame`` is left alone by that, so unfolding puts the
    /// panel back exactly where and how big it was rather than approximately.
    ///
    /// What comes back here for a folded panel is not the bar: it is where the
    /// panel *travels to* on the way down, a hairline at the dock's right end
    /// with no height at all (see ``ChatPanelFrame/visibleHeight``). The bar the
    /// user sees and clicks is the strip's, because the strip scrolls and this
    /// rectangle could not say where a scrolled bar had got to.
    func chatPanelFrame(of panel: ChatPanel) -> ChatPanelFrame {
        guard panel.isCollapsed else { return panel.frame }
        return ChatPanelFrame.foldedAway(panel.frame, into: chatDockRegion, barWidth: chatDockBarWidth)
    }

    /// The folded conversations in the order their bars sit on the dock, left to
    /// right: the order they were folded in, until one is dragged somewhere else.
    ///
    /// Sorted by a key rather than by shuffling ``chats``, which is deliberate —
    /// that array's order is the order the terminals sit in the view hierarchy,
    /// and a `GhosttySurfaceView` moved inside it loses the keyboard mid-sentence.
    /// A bar with no key of its own falls to the end, so a conversation just
    /// folded lands at the right-hand end where the strip is already looking.
    var dockedChats: [ChatPanel] {
        chats.filter(\.isCollapsed)
            .enumerated()
            .sorted {
                ($0.element.dockOrder ?? Int.max, $0.offset) < ($1.element.dockOrder ?? Int.max, $1.offset)
            }
            .map(\.element)
    }

    /// How wide every bar on the dock is right now. One width for all of them:
    /// bars of different widths in a row read as different *kinds* of thing.
    var chatDockBarWidth: CGFloat {
        ChatPanelFrame.dockedBarWidth(for: dockedChats.count, in: chatDockRegion)
    }

    /// Where the user dropped a bar they dragged along the strip.
    ///
    /// The strip owns the layout, so this is an **order** and not a position: a
    /// free x cannot survive a strip that scrolls — the point it names moves the
    /// moment anything else is folded, and "off the end" means nothing when the
    /// end is somewhere else a second later. Every bar is renumbered from the
    /// result, so the keys stay dense and no two bars ever want the same slot.
    func moveDockedChat(_ panel: ChatPanel, to index: Int) {
        var order = dockedChats
        guard let from = order.firstIndex(where: { $0 === panel }) else { return }
        order.remove(at: from)
        order.insert(panel, at: min(max(index, 0), order.count))
        withAnimation(Self.chatPanelMotion) {
            for (slot, docked) in order.enumerated() {
                docked.dockOrder = slot
            }
        }
    }

    /// Floats a new conversation for this repository, in front of the rest.
    ///
    /// **Nothing is ever closed, folded or displaced to make room.** A new
    /// conversation opens in front of the rest and that is the whole of what it
    /// does to them — every other shell keeps running, every other turn keeps
    /// going, and every other panel stays where the reader put it.
    private func floatChat(in project: Project, title: String) -> ChatPanel {
        let session = TerminalSession(directory: project.url, title: title)
        // A panel is only ever opened to hold a conversation, so this is settled
        // here rather than by whichever `claude` command is about to be typed.
        session.runsClaude = true
        let panel = ChatPanel(
            projectID: project.id,
            projectName: project.name,
            session: session,
            frame: ChatPanelFrame.opening(
                remembered: ChatPanelFrame.saved(for: project.id),
                in: chatPanelBounds,
                beside: visibleChats.map { chatPanelFrame(of: $0) }
            )
        )
        session.onExit = { [weak self, weak panel] in
            guard let self, let panel else { return }
            // `/exit`, ^D, or `claude` falling over: the panel goes the way a
            // terminal tab does when its shell ends. Where it was is kept — the
            // conversation ending is no reason to forget the corner it was read
            // in — and `terminate` here is only the surface being handed back,
            // the process behind it having already gone.
            panel.remember()
            panel.session.terminate()
            withAnimation(Self.chatPanelMotion) {
                chats.removeAll { $0 === panel }
            }
        }
        session.onAttention = { [weak self, weak panel] body in
            guard let self, let panel else { return }
            // A panel folded down to the dock, or a window behind something
            // else, is not a conversation the user is watching — the rest of the
            // time the banner would say what is already on screen.
            let watching = NSApp.isActive && !panel.isCollapsed
            guard !watching else { return }
            TerminalNotifier.shared.notify(
                title: panel.session.notificationTitle,
                subtitle: panel.projectName,
                body: body,
                sessionID: panel.session.id
            )
        }

        withAnimation(Self.chatPanelMotion) {
            chats.append(panel)
            raise(panel)
        }
        // The list is where a conversation pushed out of sight is found again,
        // so the navigator is left on it. Only the tab, not the pane: a chat
        // opened with the navigator folded away was opened by somebody who
        // wanted the room.
        navigatorTab = .claude
        session.startIfNeeded()
        return panel
    }

    /// Ends one panel's conversation — the ✕, and nothing else. Being replaced
    /// on screen is not this: see ``chats``.
    func closeChatPanel(_ panel: ChatPanel) {
        panel.remember()
        panel.session.terminate()
        withAnimation(Self.chatPanelMotion) {
            chats.removeAll { $0 === panel }
        }
    }

    /// Brings a panel to the front, over the ones it was under and at no cost to
    /// any of them. Clicking anywhere in a panel does this, so the one being
    /// typed into is never the one underneath.
    /// **Nothing happens at all when it is already in front**, and that guard
    /// has to be out here rather than inside ``raise(_:)``.
    ///
    /// `ChatPanelClickMonitor` calls this on *every* left mouse-down in the
    /// window, which is what lets a click anywhere in a panel bring it forward.
    /// With the check inside `raise`, the mutation was correctly skipped but
    /// `withAnimation` had already opened a transaction — so every click on the
    /// front panel re-evaluated the whole overlay under an animation for a
    /// change that was not made. Clicking that panel's own fold button paid it
    /// on the way down and only then, on mouse-up, got to the fold: the pause
    /// before a fold began was this, not the fold.
    func raiseChatPanel(_ panel: ChatPanel) {
        guard isBehindAnother(panel) else { return }
        withAnimation(Self.chatPanelMotion) { raise(panel) }
    }

    /// Whether any other conversation is level with this one or above it.
    private func isBehindAnother(_ panel: ChatPanel) -> Bool {
        guard let top = chats.filter({ $0 !== panel }).map(\.depth).max() else { return false }
        return panel.depth <= top
    }

    /// The same, unfolded: what the Claude list, a banner and a resumed
    /// conversation all want, since each of them is a request to *read* it.
    func unfoldChatPanel(_ panel: ChatPanel) {
        withAnimation(Self.chatPanelMotion) {
            panel.isCollapsed = false
            // Its place on the strip goes with the bar. A panel that has been
            // read and folded again belongs where a newly folded one goes — the
            // right-hand end — rather than back in a gap the other bars have
            // long since closed over.
            panel.dockOrder = nil
            panel.remember()
            raise(panel)
        }
    }

    private func raise(_ panel: ChatPanel) {
        // Already alone at the top: leaving it there is what keeps a click
        // inside the front panel from redrawing the window for nothing. The
        // comparison is `<=` because two panels on the same depth have no order
        // between them, and one of them has just been asked to be in front.
        guard let top = chats.filter({ $0 !== panel }).map(\.depth).max(),
              panel.depth <= top
        else { return }
        panel.depth = top + 1
    }

    /// Folds a panel down to its bar on the dock, and back out again.
    ///
    /// The terminal is neither taken out of the window nor squashed: it stays
    /// mounted at the size it had, and the panel shrinking around it crops it
    /// away. Both of the other answers cost the user a wait they could see —
    /// unmounting means the surface has to be re-added and redrawn before the
    /// conversation is back, and resizing means `claude` rewrapping a whole
    /// transcript to a 300pt bar and back again.
    func toggleChatPanelCollapsed(_ panel: ChatPanel) {
        if panel.isCollapsed {
            unfoldChatPanel(panel)
        } else {
            collapseChatPanel(panel)
        }
    }

    /// Folds a conversation down to the dock, eased like everything else here.
    ///
    /// This was briefly instant, on the theory that compositing the live
    /// terminal through a moving clip was what a fold felt slow *because* of.
    /// It was not: the pause came before the animation had started at all — see
    /// ``raiseChatPanel``, which was animating a no-op on the mouse-down that
    /// preceded the button's own mouse-up. With that gone there is nothing to
    /// buy by dropping the movement, and a panel that vanishes rather than
    /// folding gives the reader nothing to follow to the dock.
    func collapseChatPanel(_ panel: ChatPanel) {
        withAnimation(Self.chatPanelMotion) {
            panel.isCollapsed = true
            panel.remember()
            raise(panel)
        }
    }

    /// Where a drag or a resize left a panel. Written once it is over rather
    /// than on every frame of it: the panel follows the pointer on its own while
    /// the mouse is down, and a store this size redrawing the whole window sixty
    /// times a second to move one rectangle is a stutter you can feel.
    func placeChatPanel(_ panel: ChatPanel, frame: ChatPanelFrame) {
        panel.frame = frame.clamped(to: chatPanelBounds)
        panel.remember()
    }

    /// The overlay has been laid out: the window's size, and with it any panel
    /// the window just got too small for. A folded panel is clamped the same
    /// way, since what is being kept in bounds is where it will come *back* to;
    /// its place on the dock is worked out afresh from ``chatDockRegion`` every
    /// time it is asked for, so it follows a resized window on its own.
    func chatPanelsDidLayout(in bounds: CGSize) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        chatPanelBounds = bounds
        for panel in chats {
            let clamped = panel.frame.clamped(to: bounds)
            guard clamped != panel.frame else { continue }
            panel.frame = clamped
        }
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
        forgetJustCreatedIfDeselected()
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
        forgetJustCreatedIfDeselected()
    }

    func selectFiles(_ urls: [URL]) {
        selectedFiles = Set(urls)
        fileSelectionAnchor = urls.last
        forgetJustCreatedIfDeselected()
    }

    func clearFileSelection() {
        selectedFiles = []
        fileSelectionAnchor = nil
        forgetJustCreatedIfDeselected()
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
                if let showAgain { openFile(showAgain) }
            }
            await project.refreshGitStatus()
            // Leave what landed picked, so the next action carries on with the
            // files just dropped rather than with where they came from.
            if !result.finished.isEmpty { selectFiles(result.finished) }

            report(result, action: kind.pastTense, verb: kind.verb, place: "to \(folder.lastPathComponent)")
        }
    }

    // MARK: Copy and paste
    //
    // The pasteboard is the other end of the drag: ⌘C in Finder and ⌘V here
    // does what dragging the file into the tree does, and ⌘C here puts real
    // files on the pasteboard, so they can be pasted into Finder, into another
    // app, or into another folder of this tree.

    /// The files on the pasteboard, if it is holding any. Read fresh every
    /// time — anything, in any app, can have written to it since the last look.
    var pasteboardFiles: [URL] {
        let objects = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        return (objects as? [URL] ?? []).map(\.standardizedFileURL)
    }

    /// ⌘C in the Files tab: the files themselves, not their paths — Finder's
    /// own Paste, and every app that takes a file, wants a file URL. The paths
    /// are what the context menu's **Copy Path** is for.
    func copyFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        showStatus(urls.count == 1
            ? "Copied \(urls[0].lastPathComponent)"
            : "Copied \(urls.count) items")
    }

    /// ⌘V in the Files tab: whatever files are on the pasteboard, copied into
    /// `folder`. False when the pasteboard is holding something else — text
    /// copied out of the editor, an image — so the key can go on to whatever
    /// else might want it.
    @discardableResult
    func pasteFiles(into folder: URL, project: Project) -> Bool {
        let sources = pasteboardFiles
        guard !sources.isEmpty else { return false }
        Task {
            let result = await Task.detached {
                FileOperations.paste(sources, into: folder)
            }.value

            // Expands the folder as well, when the paste is the first thing to
            // reach into one nobody has opened yet.
            project.refreshFileTree(at: folder)
            await project.refreshGitStatus()
            if !result.finished.isEmpty { selectFiles(result.finished) }

            report(result, action: "Copied", verb: "paste", place: "to \(folder.lastPathComponent)")
        }
        return true
    }

    /// Where the Files tab's **+** puts what it makes: the selected folder, the
    /// folder of the selected file, or the repository itself. With several rows
    /// picked the first one decides, which is the row the user clicked last
    /// before reaching for the button.
    func newItemFolder(in project: Project) -> URL {
        guard let selected = selectedFiles.sorted(by: { $0.path < $1.path }).first else {
            return project.url
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDirectory)
        guard exists else { return project.url }
        return isDirectory.boolValue ? selected : selected.deletingLastPathComponent()
    }

    /// The row the **+** just made, if it is still the one being worked on.
    ///
    /// The tree draws it **first inside its folder** rather than in alphabetical
    /// order — a new `untitled` sorted into a long list is a row you have to go
    /// looking for, and the box waiting for its name is at the top of the pane
    /// where the button that made it was. It goes back into order as soon as the
    /// selection moves off it.
    private(set) var justCreatedFile: URL?

    /// Makes an empty file or folder and **hands it straight to the rename box**,
    /// so the name is typed on the row itself rather than into a sheet first.
    /// The Files tab's **+** is the only caller.
    func createItem(_ kind: FileOperations.NewItem, in project: Project) {
        let folder = newItemFolder(in: project)
        // A search is showing its results instead of the tree, and the new row
        // is in the tree — so the box that put it there is cleared.
        fileSearchText = ""
        Task {
            let result = await Task.detached { FileOperations.create(kind, in: folder) }.value

            // The row has to exist before it can be renamed, and a new file
            // inside a folder nobody has opened yet would have no row.
            if let node = project.root.loadedNode(at: folder), node.isDirectory {
                node.isExpanded = true
            }
            project.refreshFileTree(at: folder)

            if let made = result.finished.first {
                // Before the selection: `selectFiles` drops this the moment the
                // selection does not hold it.
                justCreatedFile = made
                selectFiles([made])
                renamingFile = made
            }
            // Git last. It is a process, and the box the name is typed into
            // must not wait behind one — a new file is untracked, so the
            // Changes tab has something to say either way.
            await project.refreshGitStatus()

            // Nothing is said when it works: the row is on screen with its name
            // waiting to be typed, which tells the user more than a line in the
            // status bar could.
            guard !result.errors.isEmpty else { return }
            report(result, action: "Created", verb: "create", place: "")
        }
    }

    /// Lets the new row fall back into alphabetical order once the selection has
    /// moved on. Called from everything that sets the selection.
    private func forgetJustCreatedIfDeselected() {
        guard let made = justCreatedFile, !selectedFiles.contains(made) else { return }
        justCreatedFile = nil
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
                // A row named right after it was made keeps its place at the
                // top of the folder: ⏎ should not send it off to wherever its
                // new name sorts before it has even been opened.
                if justCreatedFile == url { justCreatedFile = renamed }
                selectFiles([renamed])
                if let showAgain { openFile(showAgain) }
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
            forgetJustCreatedIfDeselected()

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
            let paths = await FileFinder.paths(in: root)
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

/// One conversation floating over the window: a shell running `claude` in a
/// repository, plus where on the window it sits.
///
/// It is a class and not a value because of the shell — a `TerminalSession`
/// owns a running process and the `NSView` drawing it, and both have to survive
/// every redraw the panel does while being dragged around.
@MainActor
@Observable
final class ChatPanel: Identifiable {
    nonisolated let id = UUID()
    /// The repository this conversation was started in, which is also the folder
    /// `claude` is running in and the key its geometry is remembered under.
    nonisolated let projectID: URL
    /// Kept rather than looked up: a banner naming the repository has to say
    /// something even for a repository removed while the panel was up.
    nonisolated let projectName: String
    let session: TerminalSession

    var frame: ChatPanelFrame

    /// Folded down to the title bar, the way a chat window on a desktop browser
    /// folds. The conversation carries on behind it.
    var isCollapsed: Bool {
        get { frame.isCollapsed }
        set { frame.isCollapsed = newValue }
    }

    /// Which panel is in front. A counter rather than the array's order: two
    /// panels swapping places in the array would move their views in the view
    /// hierarchy, and a terminal pulled out and put back loses the keyboard
    /// mid-sentence.
    var depth = 0

    /// Where this bar sits on the dock, once it has been dragged there — the
    /// same trick as ``depth`` and for the same reason, a key the strip sorts by
    /// instead of an order ``WorkspaceStore/chats`` is shuffled into.
    ///
    /// Not saved with the frame, and deliberately: it is an index among the
    /// conversations folded *right now*, which is a fact about this window this
    /// afternoon and not about the repository. A number written down would come
    /// back next launch meaning a strip that no longer exists.
    var dockOrder: Int?

    /// What the panel is called: the conversation, once Claude Code has named
    /// it, and whatever the shell is calling itself until then.
    ///
    /// The repository used to be the stand-in, and it was the wrong one twice
    /// over. It is already on the line below, so a new conversation put the same
    /// words on the bar twice — and it is a *constant*, so the bar then sat on
    /// them: a name is only read back once the first prompt has been answered
    /// and the transcript written, which is a whole turn of chatting away, and
    /// nothing moved on the bar for the length of it. `claude` renames its own
    /// terminal throughout, which is what the Claude list and the old
    /// centre-pane tab have always fallen back to — so all three now say the
    /// same thing at the same moment.
    var title: String { session.displayTitle }

    init(projectID: URL, projectName: String, session: TerminalSession, frame: ChatPanelFrame) {
        self.projectID = projectID
        self.projectName = projectName
        self.session = session
        self.frame = frame
    }

    /// Writes where this panel is, so the next one opened on this repository
    /// comes back the same size in the same corner.
    func remember() {
        frame.save(for: projectID)
    }
}

/// Where a floating chat is and how big, in the window's own coordinates with
/// the origin at its top-left corner.
///
/// It is always the **unfolded** geometry, even while the panel is folded: a
/// folded panel's bar belongs to the strip along the bottom of the centre pane,
/// which lays its own bars out (see ``ChatDockStrip``) — so this is free to go
/// on saying where the panel came from and where it goes back to.
///
/// A folded bar used to carry a `dockX` here as well, the free x the user had
/// dragged it to. The strip replaced it with an order, so the field is gone; an
/// old one still in `UserDefaults` decodes to nothing, since a key with no
/// property to land in is simply dropped.
struct ChatPanelFrame: Equatable, Codable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var isCollapsed = false

    /// A terminal narrower than about forty columns or shorter than ten rows is
    /// not a terminal any more — `claude` draws a boxed prompt and wraps its own
    /// spinner — so this is the floor for both the resize grip and anything read
    /// back from disk.
    static let minimumWidth: CGFloat = 340
    static let minimumHeight: CGFloat = 240
    /// The bar the panel is dragged by, and all that is left of it folded.
    static let titleBarHeight: CGFloat = 30
    /// How much of that bar has to stay inside the window. Enough to grab and to
    /// read part of the name by, so a panel can be pushed most of the way off
    /// the edge to get it out of the way without ever being lost.
    private static let minimumVisible: CGFloat = 150

    /// What the panel takes up where it floats — nothing at all once it is
    /// folded, because by then the only part of it on screen is a bar on the
    /// dock and that is the strip's to draw. What is left behind here is the
    /// panel itself, cropped to a line: it goes on holding the live terminal at
    /// full size, which is what makes coming back instant.
    var visibleHeight: CGFloat { isCollapsed ? 0 : height }

    /// The rectangle a click has to land in to be this panel's. Empty while it
    /// is folded — a bar on a strip that scrolls has no rectangle this frame
    /// could name.
    var onScreenRect: CGRect {
        CGRect(x: x, y: y, width: width, height: visibleHeight)
    }

    /// What a chat opens at when this repository has never had one.
    static let defaultSize = CGSize(width: 460, height: 420)
    /// The gap left to the window's edge, and between two panels.
    static let margin: CGFloat = 18
    /// The gap between two bars on the dock. Tighter than ``margin``, because
    /// bars on a strip are one row of one thing and the strip's own inset is
    /// what separates it from the pane.
    static let dockedGap: CGFloat = 10
    /// How wide a folded panel is on the dock. Narrower than the panel it came
    /// from: what is left of it is a name and two buttons, and a bar the width
    /// of the conversation would read as the conversation still being there.
    private static let dockedWidth: CGFloat = 300
    /// How narrow a bar is allowed to get, and now genuinely a floor. **The dock
    /// is shared by every repository**, so a bar carries the project as well as
    /// the conversation, and of the two the project is what has to survive — two
    /// bars from two repositories called the same truncated thing is the dock
    /// failing at the one job it has. The bar gives the project its width first
    /// and truncates the conversation into whatever is left; this is the point
    /// below which there is nothing left to give.
    ///
    /// Below it the bars used to be allowed to overlap, which was only ever the
    /// least bad thing to do with bars there was no room for. The strip scrolls
    /// now, so there is somewhere to put them and nothing to trade away.
    private static let dockedMinimumWidth: CGFloat = 190

    /// How many bars the dock shows at once — **two and a half**, and the half
    /// is the point.
    ///
    /// Dividing the room by the real count is what made a fourth conversation
    /// shrink every bar to `backend | ✳…`: the repository takes its width first,
    /// so the conversation — the only thing telling two bars from the same
    /// repository apart — is what disappeared, and the row became four identical
    /// stubs. Fixing the number fixed that, but a row that ends exactly at the
    /// edge of the pane is a row with nothing to say it goes on. A bar cut down
    /// the middle says it, and says it without a scroller sitting over the bars
    /// it is about — which on a 30pt row is most of them.
    static let dockedBarsShown: CGFloat = 2.5

    /// How wide each of `count` bars is on a dock this wide: the full width
    /// while they fit, squeezed down towards the floor when they nearly do, and
    /// no narrower than that — past it the strip scrolls instead.
    static func dockedBarWidth(for count: Int, in region: CGRect) -> CGFloat {
        let places = min(CGFloat(max(count, 1)), dockedBarsShown)
        let room = region.width - margin * 2 - dockedGap * (places.rounded(.up) - 1)
        return min(dockedWidth, max(room / places, dockedMinimumWidth))
    }


    /// The line the strip's bars sit on, in the overlay's coordinates.
    static func dockLine(in region: CGRect) -> CGFloat {
        max(region.maxY - margin - titleBarHeight, 0)
    }

    /// Where a panel goes as it folds: down to the right-hand end of the dock,
    /// and to nothing. The strip is what the user then sees and clicks; this is
    /// the travel that says the conversation went *there* rather than vanishing,
    /// and the resting place of the panel that goes on holding the terminal.
    static func foldedAway(_ frame: ChatPanelFrame, into region: CGRect, barWidth: CGFloat) -> ChatPanelFrame {
        var result = frame
        result.x = max(region.maxX - margin - barWidth, region.minX)
        result.y = dockLine(in: region)
        result.isCollapsed = true
        return result
    }

    /// The frame a pull on one edge or corner leaves, with every edge that is
    /// not being pulled left exactly where it was.
    ///
    /// That is the whole of what makes the top and the left different from the
    /// bottom and the right: those two move the origin *and* change the size,
    /// and doing one without the other is what makes a panel walk across the
    /// window as it is being sized. Written in edges rather than in an origin
    /// and a size for that reason — there is nothing left to get wrong.
    func resized(pulling edges: ChatPanelEdges, by translation: CGSize, in bounds: CGSize) -> ChatPanelFrame {
        var left = x
        var right = x + width
        var top = y
        var bottom = y + height

        if edges.contains(.leading) {
            left = min(max(left + translation.width, 0), right - Self.minimumWidth)
        }
        if edges.contains(.trailing) {
            right = max(min(right + translation.width, bounds.width), left + Self.minimumWidth)
        }
        if edges.contains(.top) {
            top = min(max(top + translation.height, 0), bottom - Self.minimumHeight)
        }
        if edges.contains(.bottom) {
            bottom = max(min(bottom + translation.height, bounds.height), top + Self.minimumHeight)
        }

        var result = self
        result.x = left
        result.y = top
        result.width = right - left
        result.height = bottom - top
        return result
    }

    /// Where a chat opens: where this repository's last one was left, or the
    /// bottom-right corner — where a chat window on a desktop browser lives, and
    /// the one corner of this window nothing is ever read in.
    ///
    /// Never exactly on top of a panel already up: two chats are usually two
    /// halves of one thought, and a second one landing on the first reads as the
    /// first having vanished. It goes beside it while the window is wide enough
    /// for both, and steps up and across when it is not.
    static func opening(
        remembered: ChatPanelFrame?,
        in bounds: CGSize,
        beside existing: [ChatPanelFrame]
    ) -> ChatPanelFrame {
        var frame = remembered ?? ChatPanelFrame(
            x: bounds.width - defaultSize.width - margin,
            y: bounds.height - defaultSize.height - margin,
            width: defaultSize.width,
            height: defaultSize.height
        )
        // Looped, not tested once. With no ceiling on how many conversations can
        // be open, the first free-looking spot is routinely taken by the third
        // panel and the fourth would land straight back on it. The step is
        // bounded because a window can genuinely run out of distinct corners —
        // past that the cascade wraps to the start and panels do overlap, which
        // is what every window manager does and is honest about it.
        let taken = { (frame: ChatPanelFrame) in
            existing.contains { abs($0.x - frame.x) < 24 && abs($0.y - frame.y) < 24 }
        }
        var step = 0
        while step < 12, taken(frame) {
            let beside = frame.x - frame.width - margin
            if step == 0, beside >= margin {
                frame.x = beside
            } else {
                frame.x -= 28
                frame.y -= 28
                // Off the top or the left: back to the corner it started from,
                // nudged in, so the pile stays somewhere the reader can reach.
                if frame.x < margin || frame.y < margin {
                    frame.x = bounds.width - frame.width - margin - CGFloat(step % 5) * 14
                    frame.y = bounds.height - frame.height - margin - CGFloat(step % 5) * 14
                }
            }
            step += 1
        }
        // Asking for a chat is asking for somewhere to type, so one that was
        // left folded still comes back open.
        frame.isCollapsed = false
        return frame.clamped(to: bounds)
    }

    /// Pulls a frame back inside a window of this size, keeping enough of the
    /// title bar in view to grab it by.
    func clamped(to bounds: CGSize) -> ChatPanelFrame {
        var result = self
        result.width = min(max(width, Self.minimumWidth), max(bounds.width, Self.minimumWidth))
        result.height = min(max(height, Self.minimumHeight), max(bounds.height, Self.minimumHeight))

        let lastX = bounds.width - Self.minimumVisible
        let firstX = Self.minimumVisible - result.width
        result.x = min(max(x, firstX), max(firstX, lastX))
        // The top edge stays inside on both sides: a bar dragged above the
        // window is one nothing can reach, and the traffic lights are up there.
        let lastY = bounds.height - Self.titleBarHeight
        result.y = min(max(y, 0), max(0, lastY))
        return result
    }

    // MARK: - Remembering it

    /// Per repository, so the chat you keep in the bottom-right corner of one
    /// project is in the bottom-right corner the next time it is opened — and
    /// the next launch, since the geometry outlives the shell that is gone.
    private static func key(for projectID: URL) -> String {
        "workspace.chatPanel." + projectID.path
    }

    static func saved(for projectID: URL) -> ChatPanelFrame? {
        guard let data = UserDefaults.standard.data(forKey: key(for: projectID)),
              let frame = try? JSONDecoder().decode(ChatPanelFrame.self, from: data)
        else { return nil }
        return frame
    }

    func save(for projectID: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(for: projectID))
    }
}

/// Which sides of a panel a drag is pulling. A corner is two of them, which is
/// the only reason this is an option set and not four cases.
struct ChatPanelEdges: OptionSet, Sendable {
    let rawValue: Int

    static let top = ChatPanelEdges(rawValue: 1 << 0)
    static let bottom = ChatPanelEdges(rawValue: 1 << 1)
    static let leading = ChatPanelEdges(rawValue: 1 << 2)
    static let trailing = ChatPanelEdges(rawValue: 1 << 3)

    /// The pointer that says what a pull here would do. macOS ships no public
    /// diagonal-resize cursor — the one every window uses is private — so a
    /// corner keeps the crosshair the old bottom-right grip had rather than
    /// reaching into `NSCursor`'s undeclared selectors for it.
    @MainActor
    /// The macOS 14 fallback, and the reason the corners look wrong on it:
    /// there is no public diagonal `NSCursor`, so all four settle for a
    /// crosshair. ``resizePosition`` is the real answer where it exists.
    var cursor: NSCursor {
        switch self {
        case .top, .bottom: .resizeUpDown
        case .leading, .trailing: .resizeLeftRight
        default: .crosshair
        }
    }

    /// The same eight places, named the way SwiftUI names them — which draws the
    /// proper diagonal at a corner, and settles against the other pointer
    /// regions on the panel instead of being overruled by them. See
    /// `View.resizePointer(_:)`.
    @available(macOS 15.0, *)
    var resizePosition: FrameResizePosition {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        case [.top, .leading]: .topLeading
        case [.top, .trailing]: .topTrailing
        case [.bottom, .leading]: .bottomLeading
        default: .bottomTrailing
        }
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
