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
