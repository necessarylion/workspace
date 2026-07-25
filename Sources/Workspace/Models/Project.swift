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
        var date: Date?
    }

    nonisolated let url: URL
    let root: FileNode
    var remote: RemoteInfo?
    var gitStatus: GitStatus?
    var headCommit: Commit?

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
        async let commitTask = Self.loadHeadCommit(in: url)
        remote = await remoteTask
        gitStatus = await statusTask
        headCommit = await commitTask

        if loadPullRequests {
            await refreshPullRequests()
        }
    }

    func refreshGitStatus() async {
        gitStatus = await GitStatus.load(for: url)
        headCommit = await Self.loadHeadCommit(in: url)
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

    private static func loadHeadCommit(in directory: URL) async -> Commit? {
        // Unit separators keep the fields apart even when a subject has commas.
        let result = await Shell.run(
            ["git", "log", "-1", "--format=%h%x1f%s%x1f%an%x1f%aI"],
            in: directory,
            timeout: 15
        )
        guard result.isSuccess else { return nil }
        let fields = result.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\u{1f}")
        guard fields.count == 4 else { return nil }
        return Commit(
            hash: fields[0],
            subject: fields[1],
            author: fields[2],
            date: ISO8601DateFormatter().date(from: fields[3])
        )
    }
}
