import Foundation

/// A repository the user added to the workspace.
@MainActor
@Observable
final class Project: Identifiable {
    /// Head commit, for the Info panel.
    struct Commit: Sendable, Hashable {
        var hash: String
        var subject: String
        var author: String
        var avatarURL: URL?
        var date: Date?
    }

    nonisolated let url: URL
    let root: FileNode
    var remote: RemoteInfo?
    var gitStatus: GitStatus?

    /// Bumped every time the status above is read again, whatever came of it.
    ///
    /// For the things that are derived from git rather than from a file, and so
    /// cannot tell that they are stale by watching the file. The editor's gutter
    /// markers are the case that asked for it: they are the working tree against
    /// HEAD, and a commit or a branch switch moves HEAD without touching a
    /// single byte of the file they are drawn beside — so nothing in the
    /// document changes, and every marker silently goes on describing a baseline
    /// that has moved. A counter rather than observing `gitStatus` itself, since
    /// a read that finds nothing changed still has to say so.
    private(set) var gitRevision = 0

    /// The newest commits on the checked-out branch, newest first. The dashboard
    /// lists them by day; the Info panel only wants the first one.
    var recentCommits: [RepositoryCommit] = []
    var isLoadingCommits = false
    /// Whether git has older commits than the ones read so far.
    var hasMoreCommits = false
    /// Set only while “Load older commits” is running, so that button alone goes
    /// quiet — a plain refresh should not blank the list that is on screen.
    var isLoadingMoreCommits = false

    /// How deep into the history the dashboard is reading. It grows a page at a
    /// time and stays there, so a refresh keeps whatever the user loaded.
    private var commitLimit = RepositoryCommit.pageSize

    /// What the branch is sitting on right now.
    var headCommit: Commit? {
        recentCommits.first.map {
            Commit(
                hash: $0.shortSHA,
                subject: $0.headline,
                author: $0.displayAuthor,
                avatarURL: $0.avatarURL,
                date: $0.date
            )
        }
    }

    var pullRequests: [PullRequest] = []
    var pullRequestError: String?
    /// Whether a spinner should be up for the read that is running. **Not the
    /// same as one running**: a read nobody asked for — the five-minute sweep
    /// of the sidebar — leaves this alone, so the cards stay still. See
    /// ``pullRequestReads`` for the one that answers "is a call in the air",
    /// which is what stops two of them overlapping.
    var isLoadingPullRequests = false

    /// How many reads are in the air, spinner or no spinner. A sweep on a clock
    /// gives way while any of them is running.
    @ObservationIgnored private var pullRequestReads = 0

    /// Which read is the newest one started.
    ///
    /// Two can overlap — a sweep on a clock while a merge asks for the list
    /// again — and the host answers in whatever order it likes, so the older
    /// one landing last would write its stale list over the newer one's and
    /// take the spinner down while the newer read is still running. A read
    /// only writes anything if it is still the newest when it lands.
    @ObservationIgnored private var pullRequestReadGeneration = 0

    /// When the host was last asked for the pull requests. `nil` until the first
    /// read, which is what makes a repository restored from the last launch fill
    /// its table the first time its board is looked at. The dashboard reads
    /// them again every time it comes back on screen, and unlike the git reads
    /// beside it that costs a call to GitHub or Bitbucket — so a glance that
    /// lands within `pullRequestRefreshInterval` of the last one keeps what is
    /// already listed. Escape out of a file and straight back in should not
    /// spend a call.
    @ObservationIgnored private var lastPullRequestRead: Date?

    /// How stale the pull requests may be before landing on the dashboard reads
    /// them again.
    private static let pullRequestRefreshInterval: TimeInterval = 10

    /// The branch the host calls this repository's default — `main` on one,
    /// `develop` on the next. Nil until it has been read, and when nobody could
    /// answer; the dashboard's "Switch to …" button is the only thing that uses
    /// it, and it stays away rather than guessing. See ``DefaultBranch``.
    var defaultBranch: String?

    /// When the host was last asked. A default branch is set once and then left
    /// alone for years, so it is read once and kept — but a read that failed
    /// (not signed in, no network) is worth trying again later rather than
    /// leaving the button away for the rest of the launch.
    @ObservationIgnored private var lastDefaultBranchRead: Date?
    private static let defaultBranchRetryInterval: TimeInterval = 300

    var ports: [ListeningPort] = []
    var isScanningPorts = false
    /// Why the last attempt to stop a port failed, if it did.
    var portError: String?

    /// Which GitHub account `gh` talks to for this repository. `nil` means the
    /// user has not chosen, so `gh` uses its own active account. Set through
    /// `WorkspaceStore`, which persists it and tells `GitHubAccounts`.
    var gitHubAccount: String?

    /// Starred: the sidebar keeps pinned repositories above the rest, sorted by
    /// name. Set through `WorkspaceStore`, which persists it and reorders.
    var isPinned = false

    nonisolated var id: URL { url }
    nonisolated var name: String { url.lastPathComponent }
    var host: GitHostKind { remote?.kind ?? .unknown }
    var isGitRepository: Bool { gitStatus != nil }

    var changeCount: Int { gitStatus?.changes.count ?? 0 }

    /// The default branch when the checkout is not already sitting on it, which
    /// is exactly when the dashboard has a switch to offer. A detached head
    /// counts as somewhere else, because it is.
    var defaultBranchToSwitchTo: String? {
        guard let defaultBranch, let branch = gitStatus?.branch, branch != defaultBranch
        else { return nil }
        return defaultBranch
    }

    /// Whether `.gitignore` covers this path — the file tree draws those faded.
    /// A file inside an ignored folder counts, since git only lists the folder.
    func isIgnored(_ fileURL: URL) -> Bool {
        guard let ignored = gitStatus?.ignored, !ignored.isEmpty else { return false }
        let root = url.standardizedFileURL.path
        let full = fileURL.standardizedFileURL.path
        guard full.hasPrefix(root) else { return false }

        var components = full.dropFirst(root.count)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        while !components.isEmpty {
            if ignored.contains(components.joined(separator: "/")) { return true }
            components.removeLast()
        }
        return false
    }

    // MARK: - What git says about one row of the tree

    /// Where the repository actually starts, which is not always the folder that
    /// was added — see ``GitStatus/root(of:)``. Every path `git status` reports
    /// is relative to it, so it is what turns one of those back into a file on
    /// disk. Read once and kept: a checkout does not move.
    @ObservationIgnored private var gitRoot: URL?

    /// Absolute path → verdict, for every changed file **and every folder above
    /// one**, so a change deep in a collapsed tree still shows on the folder the
    /// user can see. Built from the whole status in one pass rather than
    /// searched per row: the tree asks this once per visible row on every redraw,
    /// and a repository mid-rebase has hundreds of changes.
    @ObservationIgnored private var changeKindsCache: [String: GitChangeKind] = [:]
    /// Which ``gitRevision`` the cache above was built from. `-1` is "never".
    @ObservationIgnored private var changeKindsRevision = -1

    /// What git says about one file or folder, or nil when it says nothing.
    ///
    /// Reads ``gitRevision`` first and on purpose: that is what makes a SwiftUI
    /// row calling this observe the next status read, and it is also what tells
    /// the cache it has gone stale. A commit moves every verdict in the tree
    /// without touching a byte of any file, so watching the files is not enough.
    func changeKind(for fileURL: URL) -> GitChangeKind? {
        let revision = gitRevision
        if changeKindsRevision != revision {
            changeKindsCache = Self.changeKinds(in: gitStatus, folder: url, gitRoot: gitRoot)
            changeKindsRevision = revision
        }
        return changeKindsCache[fileURL.standardizedFileURL.path]
    }

    /// One status → the map above.
    ///
    /// Each change is written against its own path and then walked up, keeping
    /// the strongest verdict at every level. The walk stops as soon as it meets
    /// an ancestor that already holds something at least as strong, because
    /// everything above that one does too — which is what keeps this linear in
    /// practice rather than changes × depth.
    ///
    /// A rename contributes both of its names: the old one so a folder that only
    /// lost a file still says so, the new one so the file now on disk does.
    ///
    /// **Keys are built from the added folder, not from the repository root**,
    /// even though the paths git reports are relative to the root. The tree's
    /// rows are URLs made by walking down from `folder`, and a dictionary
    /// lookup is an exact string match — so a checkout reached through a
    /// symlink (`/tmp/…` against git's `/private/tmp/…`) would agree about the
    /// file and match on nothing at all. Resolving each row instead would be a
    /// filesystem call per visible row per redraw. This resolves twice, here,
    /// and only to work out how deep the opened folder sits.
    private static func changeKinds(
        in status: GitStatus?,
        folder: URL,
        gitRoot: URL?
    ) -> [String: GitChangeKind] {
        guard let status, !status.changes.isEmpty else { return [:] }
        let base = folder.standardizedFileURL
        let basePath = base.path
        let prefix = subpath(of: base, under: gitRoot)
        var result: [String: GitChangeKind] = [:]

        for change in status.changes {
            let kind = change.kind
            for path in change.gitPaths {
                // A change elsewhere in the repository — a sibling package of
                // the monorepo — has no row here to colour.
                guard path.hasPrefix(prefix) else { continue }
                let relative = String(path.dropFirst(prefix.count))
                guard !relative.isEmpty else { continue }

                var current = base.appendingPathComponent(relative).standardizedFileURL
                // Strictly inside the folder: it is not a row in the tree
                // itself, and this is also what stops the walk.
                while current.path.count > basePath.count {
                    if let existing = result[current.path], existing >= kind { break }
                    result[current.path] = kind
                    current = current.deletingLastPathComponent()
                }
            }
        }
        return result
    }

    /// How deep the added folder sits inside its repository, as the path prefix
    /// git puts in front of everything under it — `"apps/web/"`, or `""` when
    /// the folder *is* the repository, which is the ordinary case.
    private static func subpath(of folder: URL, under gitRoot: URL?) -> String {
        guard let gitRoot else { return "" }
        let rootPath = gitRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let folderPath = folder.resolvingSymlinksInPath().path
        guard folderPath.hasPrefix(rootPath), folderPath.count > rootPath.count else { return "" }
        let suffix = folderPath.dropFirst(rootPath.count).drop { $0 == "/" }
        return suffix.isEmpty ? "" : suffix + "/"
    }

    /// Asks git for the top level, unless it already answered.
    private func resolveGitRootIfNeeded() async {
        guard gitRoot == nil else { return }
        gitRoot = await GitStatus.root(of: url)
    }

    init(url: URL) {
        self.url = url
        self.root = FileNode(url: url, isDirectory: true)
        root.isExpanded = true
        root.loadChildrenIfNeeded()
        startWatchingWorkingTree()
    }

    /// Loads remote, git status, head commit and pull requests.
    ///
    /// `quietly` is the read nobody asked for: everything lands the same way,
    /// but no spinner goes up while it is happening. What is on screen was
    /// right a moment ago and is about to be right again — a card that starts
    /// twitching on a clock only reads as something going wrong.
    func refresh(loadPullRequests: Bool = true, quietly: Bool = false) async {
        async let remoteTask = RemoteInfo.load(for: url)
        async let statusTask = GitStatus.load(for: url)
        async let commitTask = RepositoryCommit.load(in: url, limit: commitLimit)
        // Alongside the rest rather than before them: it is one process, it is
        // only ever run once, and nothing here needs its answer until the
        // revision below moves and the tree asks what changed.
        async let rootTask: Void = resolveGitRootIfNeeded()
        remote = await remoteTask
        gitStatus = await statusTask
        await rootTask
        gitRevision += 1
        apply(await commitTask)
        startWatchingGitIfNeeded()

        if loadPullRequests {
            await refreshPullRequests(quietly: quietly)
        }
    }

    func refreshGitStatus() async {
        async let rootTask: Void = resolveGitRootIfNeeded()
        gitStatus = await GitStatus.load(for: url)
        await rootTask
        gitRevision += 1
        await refreshCommits()
        startWatchingGitIfNeeded()
    }

    /// Everything the dashboard shows, read again. Called every time the board
    /// comes back on screen: the branch may have been checked out, a commit
    /// made, a server started and a pull request merged while something else
    /// was in the centre pane, and the board that reappears should not be the
    /// one that was left behind.
    ///
    /// The reads run together rather than one after another — they are separate
    /// processes and the slowest of them is the host call — and each writes what
    /// it owns as it lands, so the board fills in piece by piece instead of
    /// sitting still until the last one returns. Nothing here blanks what is
    /// already drawn.
    func refreshDashboard() async {
        async let status: Void = refreshGitStatus()
        async let ports: Void = refreshPorts()
        async let requests: Void = refreshPullRequestsIfStale()
        async let branch: Void = refreshDefaultBranchIfNeeded()
        _ = await (status, ports, requests, branch)
    }

    /// Asks the host which branch is the default, unless it already answered.
    /// One call to `gh`/`bkt` per repository per launch — the answer does not
    /// change — and one more every five minutes while nobody will answer.
    func refreshDefaultBranchIfNeeded() async {
        guard defaultBranch == nil else { return }
        if let last = lastDefaultBranchRead,
           Date().timeIntervalSince(last) < Self.defaultBranchRetryInterval {
            return
        }
        lastDefaultBranchRead = Date()
        // The board can appear before the first `refresh()` has named the
        // remote, and asking git instead of the host would then cache the
        // staler answer — so the remote is read here rather than skipped.
        var host = remote
        if host == nil {
            host = await RemoteInfo.load(for: url)
            remote = host
        }
        defaultBranch = await DefaultBranch.load(remote: host, in: url)
    }

    /// The pull requests, unless they were read a moment ago. See
    /// ``lastPullRequestRead``.
    private func refreshPullRequestsIfStale() async {
        // A read already running counts as the fresh one: the stamp is only put
        // down when it lands, so without this a slow host would be asked twice.
        guard pullRequestReads == 0 else { return }
        if let last = lastPullRequestRead,
           Date().timeIntervalSince(last) < Self.pullRequestRefreshInterval {
            return
        }
        await refreshPullRequests()
    }

    // MARK: - Git run outside the app

    /// Live while this is a repository; see `startWatchingGitIfNeeded`.
    @ObservationIgnored private var gitWatcher: GitDirectoryWatcher?
    /// Live for as long as the project is; see `startWatchingWorkingTree`.
    @ObservationIgnored private var workingTreeWatcher: WorkingTreeWatcher?
    /// The pending reload, kept so a burst of writes coalesces into one.
    @ObservationIgnored private var gitWatchTask: Task<Void, Never>?

    /// Starts listening for git commands the app did not run itself — a
    /// `git checkout` in the embedded terminal above all. Everything on screen
    /// that names the branch reads `gitStatus`, so nothing noticed until the
    /// user happened to trigger a refresh by hand.
    ///
    /// Called after every status read rather than from `init`, because a folder
    /// can become a repository (`git init`) while the app is open, and because
    /// this is the point where we know it is one.
    private func startWatchingGitIfNeeded() {
        guard gitWatcher == nil, gitStatus != nil else { return }
        gitWatcher = GitDirectoryWatcher(repository: url) { [weak self] in
            Task { @MainActor in self?.gitDirectoryChanged() }
        }
    }

    /// Git writes in bursts — a checkout rewrites HEAD, the index and the logs
    /// one after another — so the reads wait for it to go quiet instead of
    /// running once per write.
    private func gitDirectoryChanged() {
        gitWatchTask?.cancel()
        gitWatchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.reloadAfterExternalGitChange()
        }
    }

    /// The branch name, the history, the change list and the Files tab, all of
    /// which a checkout moves at once.
    private func reloadAfterExternalGitChange() async {
        // One of our own commands is running: its writes are what woke us, and
        // it reloads everything itself when it finishes.
        guard !isRunningGitCommand else { return }
        await refreshGitStatus()
        refreshFileTree()
    }

    // MARK: - Files written outside the app

    /// The pending reload, and the files the burst has named so far.
    @ObservationIgnored private var workingTreeTask: Task<Void, Never>?
    @ObservationIgnored private var changedFiles: Set<URL> = []
    /// Set when the watcher handed over nil, meaning the kernel dropped the
    /// events and the list above is not the whole story — see
    /// ``WorkingTreeWatcher``. It survives until the reload it belongs to lands,
    /// so a burst that overflows in the middle still ends in a full sweep.
    @ObservationIgnored private var changedFilesUnknown = false

    /// Called on the main actor after files under the project changed on disk,
    /// with the ones that did — or with nil when something changed and nobody
    /// can say what, which is all the app-came-back-to-the-front sweep knows.
    /// `WorkspaceStore` installs it: the open editors and the diff on screen are
    /// the store's to reload, and a project knows about neither.
    @ObservationIgnored var onWorkingTreeChanged: (@MainActor (Set<URL>?) -> Void)?

    /// Starts listening for writes the app did not make — Claude Code in the
    /// embedded terminal above all, but a formatter, a code generator or an
    /// editor in another window just as much.
    ///
    /// Unlike `startWatchingGitIfNeeded` this asks nothing about git and
    /// happens once, from `init`: a folder that is not a repository has no
    /// Changes list to keep honest but still has a file tree and open editors,
    /// and those go stale exactly the same way.
    private func startWatchingWorkingTree() {
        workingTreeWatcher = WorkingTreeWatcher(root: url) { [weak self] paths in
            Task { @MainActor in self?.workingTreeChanged(paths) }
        }
    }

    /// One `npm install`, one `git checkout`, one Claude Code turn — each is a
    /// long burst of writes, and re-running `git status` per file in it would
    /// cost more than the work being watched. The reads wait for the burst to
    /// end, and the files it named pile up in the meantime so the callers still
    /// learn about every one of them.
    ///
    /// Nil paths mean the watcher lost track and everything has to be checked;
    /// see ``changedFilesUnknown``.
    private func workingTreeChanged(_ paths: [URL]?) {
        if let paths { changedFiles.formUnion(paths) } else { changedFilesUnknown = true }
        workingTreeTask?.cancel()
        workingTreeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.reloadAfterWorkingTreeChange()
        }
    }

    private func reloadAfterWorkingTreeChange() async {
        // One of our own commands is running and is still writing; it reloads
        // the status and the tree itself when it lands, but not the editors, so
        // the files stay on the pile and are picked up a beat later rather than
        // dropped.
        guard !isRunningGitCommand else {
            workingTreeChanged([])
            return
        }
        let changed = changedFilesUnknown ? nil : changedFiles
        changedFiles = []
        changedFilesUnknown = false
        await refreshGitStatus()
        // `refreshFileTree`, never `reloadFileTree`: this runs while the user is
        // reading the tree, and rebuilding it would fold every folder they had
        // opened shut under them.
        refreshFileTree()
        onWorkingTreeChanged?(changed)
    }

    /// The same reload, for the app coming back to the front. FSEvents is
    /// delivered whether or not we are in front, but a stream can coalesce a
    /// long absence away, and nothing else notices a repository that was
    /// rebuilt while the window was behind a browser.
    func reloadAfterReturningToFront() async {
        guard !isRunningGitCommand else { return }
        changedFiles = []
        changedFilesUnknown = false
        await refreshGitStatus()
        refreshFileTree()
        onWorkingTreeChanged?(nil)
    }

    /// Re-reads the history, as deep as it has been read so far. Cheap — it is
    /// one local `git log` — so the dashboard does it every time it comes back
    /// on screen, and every git command below does it after running.
    func refreshCommits() async {
        isLoadingCommits = true
        defer { isLoadingCommits = false }
        apply(await RepositoryCommit.load(in: url, limit: commitLimit))
    }

    /// Reads one page further back. The whole range is re-read rather than the
    /// new page alone: a single `git log` is cheap, and it cannot leave a gap in
    /// the list if the branch moved in between.
    func loadMoreCommits() async {
        guard hasMoreCommits, !isLoadingMoreCommits else { return }
        isLoadingMoreCommits = true
        defer { isLoadingMoreCommits = false }

        let deeper = commitLimit + RepositoryCommit.pageSize
        let page = await RepositoryCommit.load(in: url, limit: deeper)
        // Only keep the deeper limit if the read worked, so a failure does not
        // leave every later refresh asking for history it never got.
        guard !page.commits.isEmpty else { return }
        commitLimit = deeper
        apply(page)
    }

    private func apply(_ page: RepositoryCommit.Page) {
        recentCommits = page.commits
        hasMoreCommits = page.hasMore
        // Who these addresses belong to on the host, so a commit row shows the
        // same face the pull request tiles above it do.
        AvatarDirectory.shared.learn(
            emails: page.commits.map(\.authorEmail),
            remote: remote,
            branch: gitStatus?.branch,
            in: url
        )
    }

    func refreshPullRequests(quietly: Bool = false) async {
        // A sweep on a clock gives way to the read already running; a read the
        // user asked for is the one that is allowed to double up, since it is
        // answering a button that was just pressed.
        guard !quietly || pullRequestReads == 0 else { return }

        guard let remote, remote.kind != .unknown else {
            pullRequests = []
            pullRequestError = gitStatus == nil
                ? "Not a git repository."
                : "No GitHub or Bitbucket remote."
            lastPullRequestRead = Date()
            return
        }

        pullRequestReads += 1
        pullRequestReadGeneration += 1
        let generation = pullRequestReadGeneration
        if !quietly { isLoadingPullRequests = true }
        pullRequestError = nil
        defer {
            pullRequestReads -= 1
            // Only the newest read settles the spinner and the stamp. One that
            // started earlier and landed later would put the spinner down over
            // a read still running, and would date a list it did not write.
            if generation == pullRequestReadGeneration {
                isLoadingPullRequests = false
                lastPullRequestRead = Date()
            }
        }

        do {
            let loaded = try await PullRequestService.loadOpen(for: remote, in: url)
            guard generation == pullRequestReadGeneration else { return }
            pullRequests = loaded
            fillPullRequestColumns()
        } catch {
            guard generation == pullRequestReadGeneration else { return }
            pullRequests = []
            pullRequestError = error.localizedDescription
        }
    }

    /// The fill for the columns the list itself could not answer, kept so a
    /// second refresh cancels the first rather than racing it.
    @ObservationIgnored private var pullRequestColumnTask: Task<Void, Never>?

    /// Fills in the reviewers and the CI verdict for the requests whose host
    /// did not send them with the list.
    ///
    /// **Nothing to do in the ordinary case.** `gh pr list` answers for every
    /// column, and so does Bitbucket Cloud's API — both set `hasLoadedDetails`,
    /// and this returns without a single call. What is left is Bitbucket Data
    /// Center, and a Cloud repository that reports its builds as commit
    /// statuses rather than as pipelines: there a column still costs a call per
    /// request, so it is made *after* the board is on screen, a few at a time,
    /// and the columns fill in as the answers land. Nothing here can fail
    /// loudly — a column that stays empty is the whole cost of not being told.
    private func fillPullRequestColumns() {
        pullRequestColumnTask?.cancel()
        let pending = pullRequests.filter {
            !$0.hasLoadedDetails && ($0.buildState == nil || $0.reviewers.isEmpty)
        }
        guard !pending.isEmpty else { return }
        let directory = url

        pullRequestColumnTask = Task { [weak self] in
            // Four at a time: enough to fill a screen of rows quickly, few
            // enough that a repository with fifty open requests does not open
            // fifty shells at once.
            let width = 4
            var index = 0
            while index < pending.count, !Task.isCancelled {
                let batch = pending[index..<min(index + width, pending.count)]
                index += width

                let filled = await withTaskGroup(
                    of: (Int, [PullRequestReviewer]?, PullRequestBuild.State?).self
                ) { group in
                    for pr in batch {
                        group.addTask {
                            var reviewers: [PullRequestReviewer]?
                            if pr.reviewers.isEmpty {
                                reviewers = try? await PullRequestService.reviewers(
                                    for: pr,
                                    in: directory
                                )
                            }
                            var state: PullRequestBuild.State?
                            if pr.buildState == nil {
                                let builds = try? await PullRequestService.builds(
                                    for: pr,
                                    in: directory
                                )
                                // A request nothing has run against settles on
                                // `.unknown`, which is what stops it being
                                // asked again on the next refresh.
                                state = builds.map { PullRequestService.rollUp($0) ?? .unknown }
                            }
                            return (pr.number, reviewers, state)
                        }
                    }
                    var collected: [(Int, [PullRequestReviewer]?, PullRequestBuild.State?)] = []
                    for await answer in group { collected.append(answer) }
                    return collected
                }

                guard let self, !Task.isCancelled else { return }
                for (number, reviewers, buildState) in filled {
                    guard let row = self.pullRequests.firstIndex(where: { $0.number == number })
                    else { continue }
                    if let reviewers { self.pullRequests[row].reviewers = reviewers }
                    if let buildState { self.pullRequests[row].buildState = buildState }
                }
            }
        }
    }

    func refreshPorts() async {
        isScanningPorts = true
        defer { isScanningPorts = false }
        ports = await ProjectPorts.scan(root: url)
    }

    /// Signals whatever is holding a port, then rescans so the row disappears
    /// on its own. A process needs a moment to actually let the socket go.
    func stopPort(_ port: ListeningPort, force: Bool = false) async {
        portError = await ProjectPorts.stop(port, force: force)
        try? await Task.sleep(for: .milliseconds(600))
        await refreshPorts()
    }

    func reloadFileTree() {
        root.reloadChildren()
    }

    /// Re-reads every folder the tree has open. What the Files tab lists after a
    /// git command: staging, discarding and checking out all move files about,
    /// and the tab used to keep showing what was there before.
    func refreshFileTree() {
        root.refreshLoadedTree()
    }

    /// Re-reads one folder of the tree after files landed in it, and opens it so
    /// they are on screen. Everything else keeps the state it had.
    func refreshFileTree(at folderURL: URL) {
        guard let node = root.loadedNode(at: folderURL) else {
            // Not read yet: whatever was dropped is there the first time the
            // folder is expanded.
            return
        }
        if node.isDirectory && !node.isExpanded {
            node.isExpanded = true  // loads the children, the new files included
        } else {
            node.refreshChildren()
        }
    }

    // MARK: - Staging, committing, pushing

    /// Whatever is in the commit box. It lives on the project rather than in the
    /// view so switching navigator tabs does not throw a half-written message
    /// away.
    var commitMessage = ""

    /// Set while a git command is running, so the buttons can go quiet and no
    /// second command starts on top of the first.
    var isRunningGitCommand = false

    /// What the last staging, commit or push printed when it failed.
    var gitError: String?

    /// Set while Claude is writing the commit message, so the button can spin
    /// and nothing commits the box out from under it.
    var isWritingCommitMessage = false

    /// Fills the commit box with a message Claude wrote for the change in front
    /// of it — the staged files, or the whole working tree while nothing is
    /// staged, which is the same set the Commit button would take.
    func writeCommitMessage() async {
        guard !isWritingCommitMessage, !isRunningGitCommand else { return }
        isWritingCommitMessage = true
        gitError = nil
        defer { isWritingCommitMessage = false }

        do {
            commitMessage = try await ClaudeCommitMessage.write(
                in: url,
                stagedOnly: !stagedChanges.isEmpty,
                branch: gitStatus?.branch,
                recentSubjects: recentCommits.prefix(10).map(\.headline)
            )
        } catch {
            gitError = error.localizedDescription
        }
    }

    var stagedChanges: [GitStatus.Change] {
        gitStatus?.changes.filter(\.isStaged) ?? []
    }

    var unstagedChanges: [GitStatus.Change] {
        gitStatus?.changes.filter { !$0.isStaged && !$0.isConflicted } ?? []
    }

    /// What a merge, a rebase or a cherry-pick left half-done. These get their
    /// own pile: until each one is resolved, nothing here can be committed.
    var conflictedChanges: [GitStatus.Change] {
        gitStatus?.changes.filter(\.isConflicted) ?? []
    }

    var hasConflicts: Bool { !conflictedChanges.isEmpty }

    func stage(_ paths: [String]) async {
        await runGit(["add", "--"] + paths)
    }

    /// `git restore --staged` leaves the working tree alone, so unstaging never
    /// costs the user their edits.
    ///
    /// Except on the first commit, where it cannot run at all: `--staged` means
    /// "put back what `HEAD` has", and a branch with nothing on it has no `HEAD`
    /// to read — `fatal: could not resolve HEAD`, and the button did nothing.
    /// There is only an index to empty in that case, which is `rm --cached`; it
    /// leaves the file on disk just the same, so the file goes back to being
    /// untracked rather than being lost. Same pair of commands ``discard(_:)``
    /// already chooses between.
    func unstage(_ paths: [String]) async {
        guard gitStatus?.hasCommits ?? true else {
            await runGit(
                ["rm", "--cached", "--force", "-r", "--quiet", "--ignore-unmatch", "--"] + paths
            )
            return
        }
        await runGit(["restore", "--staged", "--"] + paths)
    }

    /// Stages everything that is not still conflicted. `git add --all` would
    /// sweep the conflicts up too and call them resolved with their `<<<<<<<`
    /// markers still in the file, which is the one thing this button must never
    /// do behind the user's back.
    func stageAll() async {
        guard hasConflicts else {
            await runGit(["add", "--all"])
            return
        }
        let paths = unstagedChanges.flatMap(\.gitPaths)
        guard !paths.isEmpty else { return }
        await stage(paths)
    }

    /// Tells git the working tree copy is the resolution — `git add` is what
    /// collapses the three merge stages into one entry. Refuses while the file
    /// still holds conflict markers, because nothing later in the flow catches
    /// that and the markers would go straight into the commit.
    func markResolved(_ paths: [String]) async {
        guard !paths.isEmpty, !isRunningGitCommand else { return }
        let unfinished = paths.filter(hasConflictMarkers)
        guard unfinished.isEmpty else {
            gitError = unfinished.count == 1
                ? "\(unfinished[0]) still has conflict markers in it."
                : "\(unfinished.count) files still have conflict markers in them."
            return
        }
        await stage(paths)
    }

    /// Whether the file on disk still has a merge marker at the start of a
    /// line. Conflicted files are source files a person is editing, so this
    /// reads them directly rather than paying for another `git` process.
    private func hasConflictMarkers(_ path: String) -> Bool {
        guard let text = try? String(contentsOf: url.appending(path: path), encoding: .utf8) else {
            // A binary file, or one side of the merge deleted it: neither has
            // markers to find, and git is the one to decide the rest.
            return false
        }
        // Only the two arrow markers, not the `=======` between them: a row of
        // equals signs is how markdown underlines a heading, and blocking on
        // that would refuse to resolve a perfectly finished file.
        return text.split(separator: "\n", omittingEmptySubsequences: false).contains {
            $0.hasPrefix("<<<<<<<") || $0.hasPrefix(">>>>>>>")
        }
    }

    /// Throws a file's changes away — staged and unstaged alike, because a file
    /// left half-reverted is not what "discard" means — and deletes it outright
    /// when git never tracked it. Nothing here can be undone, so the caller asks
    /// the user first.
    @discardableResult
    func discard(_ paths: [String]) async -> Bool {
        guard !paths.isEmpty, !isRunningGitCommand else { return false }
        isRunningGitCommand = true
        gitError = nil
        defer { isRunningGitCommand = false }

        // Which of these paths HEAD has a version of. The rest — new files, and
        // files staged but never committed — have nothing to restore, so they
        // are deleted instead. `-z` because ls-tree otherwise quotes any path
        // with an unusual character in it.
        let listed = await Shell.run(
            ["git", "ls-tree", "HEAD", "--name-only", "-z", "--"] + paths,
            in: url,
            timeout: 30
        )
        let known = Set(listed.stdout.split(separator: "\0").map(String.init))

        var steps: [[String]] = []
        if listed.isSuccess {
            // Drops the index entry for everything, new files included;
            // `restore --staged` cannot do that.
            steps.append(["reset", "--quiet", "HEAD", "--"] + paths)
        } else {
            // No HEAD yet: the branch has no commit, so there is only an index
            // to empty.
            steps.append(["rm", "--cached", "--force", "-r", "--quiet", "--ignore-unmatch", "--"] + paths)
        }
        let restore = paths.filter { known.contains($0) }
        if !restore.isEmpty { steps.append(["checkout", "--"] + restore) }
        let remove = paths.filter { !known.contains($0) }
        // `-d` for the path that names a folder rather than a file; a file
        // pathspec leaves the folder it was in behind either way, empty.
        if !remove.isEmpty { steps.append(["clean", "--force", "-d", "--"] + remove) }

        var succeeded = true
        for step in steps {
            let result = await Shell.run(["git"] + step, in: url, timeout: 120)
            guard !result.isSuccess else { continue }
            gitError = result.failureMessage.isEmpty
                ? "git \(step.first ?? "") failed."
                : result.failureMessage
            succeeded = false
            break
        }
        await refreshGitStatus()
        // Discarding deletes untracked files and brings tracked ones back, so
        // the Files tab is out of date until it re-reads.
        refreshFileTree()
        return succeeded
    }

    /// True when the commit was made. `--only` with the staged paths would be
    /// the same thing here: plain `git commit` already commits just the index.
    @discardableResult
    func commit() async -> Bool {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            gitError = "Write a commit message first."
            return false
        }
        // git refuses this itself, but with a wall of advice about paths it
        // calls unmerged. Say which files, in the words the list uses.
        let conflicts = conflictedChanges
        guard conflicts.isEmpty else {
            gitError = conflicts.count == 1
                ? "Resolve the conflict in \(conflicts[0].path) first."
                : "Resolve \(conflicts.count) conflicted files first."
            return false
        }
        guard await runGit(["commit", "-m", message]) else { return false }
        commitMessage = ""
        return true
    }

    /// Pushes the current branch, setting an upstream the first time so the user
    /// does not have to run the `--set-upstream` line git suggests by hand.
    @discardableResult
    func push() async -> Bool {
        let upstream = await Shell.run(
            ["git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
            in: url,
            timeout: 15
        )
        if upstream.isSuccess {
            return await runGit(["push"])
        }
        guard let branch = gitStatus?.branch, branch != "detached" else {
            gitError = "Not on a branch, so there is nothing to push."
            return false
        }
        return await runGit(["push", "--set-upstream", "origin", branch])
    }

    /// Brings the current branch up to date with its remote. Plain `git pull`,
    /// with no upstream invented and no rebase chosen for the user: which of
    /// those a repository wants is its own configuration, and git already reads
    /// it. A branch with no upstream, a dirty tree, a conflicted merge — git
    /// refuses each of those in its own words, and those words are what the
    /// toast says.
    @discardableResult
    func pull() async -> Bool {
        guard let branch = gitStatus?.branch, branch != "detached" else {
            gitError = "Not on a branch, so there is nothing to pull."
            return false
        }
        return await runGit(["pull"])
    }

    /// Switches to an existing branch. A pull request's source branch is often
    /// only on the remote, and git can only create a local branch from it once
    /// that ref has been fetched — so fetch first when there is no local branch
    /// yet. A failed fetch is not fatal: an earlier fetch may already have left
    /// the remote-tracking ref behind, and the checkout below reports the real
    /// problem if it has not.
    @discardableResult
    func checkout(_ branch: String) async -> Bool {
        let isLocal = await Shell.run(
            ["git", "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"],
            in: url,
            timeout: 15
        ).isSuccess
        if !isLocal {
            await runGit(["fetch", "origin", branch])
        }
        return await runGit(["checkout", branch])
    }

    /// Runs one git command and reloads the status, so the list always shows
    /// what git thinks rather than what the button hoped for.
    @discardableResult
    private func runGit(_ arguments: [String]) async -> Bool {
        guard !isRunningGitCommand else { return false }
        isRunningGitCommand = true
        gitError = nil
        defer { isRunningGitCommand = false }

        let result = await Shell.run(
            ["git"] + arguments,
            in: url,
            timeout: 180,
            // Without this a push that needs a password waits for a terminal
            // that is not there, and the command hangs until it times out.
            environment: ["GIT_TERMINAL_PROMPT": "0"]
        )
        if !result.isSuccess {
            gitError = result.failureMessage.isEmpty
                ? "git \(arguments.first ?? "") failed."
                : result.failureMessage
        }
        await refreshGitStatus()
        // Every one of these can change what is on disk — a checkout most of
        // all — so the file tree re-reads with the status.
        refreshFileTree()
        return result.isSuccess
    }
}
