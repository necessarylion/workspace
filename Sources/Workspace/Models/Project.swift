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
    var isLoadingPullRequests = false
    var hasLoadedPullRequests = false

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

    init(url: URL) {
        self.url = url
        self.root = FileNode(url: url, isDirectory: true)
        root.isExpanded = true
        root.loadChildrenIfNeeded()
    }

    /// Loads remote, git status, head commit and pull requests.
    func refresh(loadPullRequests: Bool = true) async {
        async let remoteTask = RemoteInfo.load(for: url)
        async let statusTask = GitStatus.load(for: url)
        async let commitTask = RepositoryCommit.load(in: url, limit: commitLimit)
        remote = await remoteTask
        gitStatus = await statusTask
        apply(await commitTask)

        if loadPullRequests {
            await refreshPullRequests()
        }
    }

    func refreshGitStatus() async {
        gitStatus = await GitStatus.load(for: url)
        await refreshCommits()
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

    func refreshPullRequests() async {
        guard let remote, remote.kind != .unknown else {
            pullRequests = []
            pullRequestError = gitStatus == nil
                ? "Not a git repository."
                : "No GitHub or Bitbucket remote."
            hasLoadedPullRequests = true
            return
        }

        isLoadingPullRequests = true
        pullRequestError = nil
        defer {
            isLoadingPullRequests = false
            hasLoadedPullRequests = true
        }

        do {
            pullRequests = try await PullRequestService.loadOpen(for: remote, in: url)
        } catch {
            pullRequests = []
            pullRequestError = error.localizedDescription
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

    var stagedChanges: [GitStatus.Change] { gitStatus?.changes.filter(\.isStaged) ?? [] }
    var unstagedChanges: [GitStatus.Change] { gitStatus?.changes.filter { !$0.isStaged } ?? [] }

    func stage(_ paths: [String]) async {
        await runGit(["add", "--"] + paths)
    }

    /// `git restore --staged` leaves the working tree alone, so unstaging never
    /// costs the user their edits.
    func unstage(_ paths: [String]) async {
        await runGit(["restore", "--staged", "--"] + paths)
    }

    func stageAll() async {
        await runGit(["add", "--all"])
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
        // `-d` because git collapses a wholly untracked folder to the folder.
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
        return result.isSuccess
    }
}
