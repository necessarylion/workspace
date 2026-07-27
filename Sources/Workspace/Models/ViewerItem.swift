import Foundation
import SwiftUI

/// One thing shown in the centre of the window.
///
/// The viewer shows a single item at a time — opening a file replaces what is
/// there — and the store keeps a back/forward history of these.
@MainActor
@Observable
final class ViewerItem: Identifiable {
    enum Kind: Hashable {
        case file(URL)
        case workingDiff(projectID: URL, path: String, isUntracked: Bool)
        case commit(projectID: URL, sha: String)
        case pullRequest(projectID: URL, number: Int)
        /// Shells. A `nil` project is the window-wide terminal — shells that
        /// belong to no repository, rooted in the home folder.
        case terminal(projectID: URL?)
        /// A conversation with Claude Code about one repository.
        case claude(projectID: URL)

        var key: String {
            switch self {
            case .file(let url): "file:\(url.path)"
            case .workingDiff(let project, let path, _): "diff:\(project.path):\(path)"
            case .commit(let project, let sha): "commit:\(project.path):\(sha)"
            case .pullRequest(let project, let number): "pr:\(project.path):\(number)"
            case .terminal(let project): "term:\(project?.path ?? "~")"
            case .claude(let project): "claude:\(project.path)"
            }
        }
    }

    /// Which part of a pull request the viewer is showing. It lives here rather
    /// than in the view because the picker sits up in the window header, next to
    /// back and forward, and each pull request remembers where you left it.
    enum PullRequestTab: String, CaseIterable, Identifiable {
        case details, diff, commits
        var id: String { rawValue }

        var title: String {
            switch self {
            case .details: "Details"
            case .diff: "Diff"
            case .commits: "Commits"
            }
        }

        var symbol: String {
            switch self {
            case .details: "bubble.left.and.bubble.right"
            case .diff: "plusminus"
            case .commits: "clock.arrow.circlepath"
            }
        }
    }

    enum DiffLayout: String, CaseIterable, Identifiable {
        case split, unified
        var id: String { rawValue }
        var title: String { self == .split ? "Split" : "Unified" }
        var icon: String { self == .split ? "rectangle.split.2x1" : "list.bullet.rectangle" }
    }

    nonisolated let kind: Kind
    var title: String
    var subtitle: String?

    /// Whoever wrote what is open, when that is one person — a commit. The
    /// header shows their face where it would otherwise draw a glyph.
    var authorName: String?
    var authorAvatarURL: URL?

    /// Whether the file index shows beside a commit's or the working tree's
    /// combined diff. Off to start with: a commit is read top to bottom as one
    /// change, and the combined diff already has the navigator's change list
    /// beside it, so a second copy of the same list only takes width. Either way
    /// the list is in the way until it is asked for — unlike a pull request,
    /// where it is how you get around. Kept per item rather than window-wide for
    /// the same reason.
    var showsDiffFileList = false

    // Payloads, filled in depending on `kind`.
    var document: OpenDocument?
    var diff: Diff?
    var pullRequest: PullRequest?

    // Conversations with Claude: one item holds every one of them for its
    // project, the way the terminal item holds every shell. They run at the
    // same time — a long turn in one keeps going while another is typed into —
    // so the viewer picks which is on screen rather than which exists.
    var claudes: [ClaudeSession] = []
    var selectedClaudeID: UUID?

    /// The conversation on screen. Falls back to the newest, so an item that has
    /// only just been given its first session needs no separate selection step.
    var claude: ClaudeSession? {
        claudes.first { $0.id == selectedClaudeID } ?? claudes.last
    }

    // Terminal tabs: one item holds every shell for its project.
    var terminals: [TerminalSession] = []
    var selectedTerminalID: UUID?

    var selectedTerminal: TerminalSession? {
        terminals.first { $0.id == selectedTerminalID } ?? terminals.last
    }

    // Pull request conversation.
    var comments: [PullRequestComment] = []
    var isLoadingComments = false
    var isPostingComment = false
    var commentError: String?

    // Pull request commits. The tab shows the list until a commit is picked,
    // and that commit's own diff afterwards.
    var commits: [PullRequestCommit] = []
    var isLoadingCommits = false
    var commitsError: String?
    var selectedCommit: PullRequestCommit? {
        // A commit's patch is its own diff, so the file being read there is not
        // the file being read in the Diff tab — and it means nothing once a
        // different commit is open.
        didSet { commitDiffFile = nil }
    }

    /// The file picked in a commit's own diff. Separate from `diffFile`: the
    /// pull request's diff and one commit's are different sets of files.
    var commitDiffFile: DiffFile.ID?

    // Who is reviewing the pull request, and how many of them have approved.
    // Loaded with the conversation, because the count sits in the summary bar
    // that is on screen whichever tab is open.
    var reviewers: [PullRequestReviewer] = []
    var isLoadingReviewers = false
    var reviewersError: String?
    /// The people the picker offers, fetched the first time it is opened — the
    /// list costs a call to the host and most pull requests never ask for it.
    var reviewerCandidates: [ReviewerCandidate] = []
    var isLoadingReviewerCandidates = false
    var hasLoadedReviewerCandidates = false

    // Pull request builds: the CI runs on its head commit.
    var builds: [PullRequestBuild] = []
    var isLoadingBuilds = false
    var buildsError: String?
    /// Patches already fetched, keyed by hash: a commit does not change, so
    /// stepping back and forth through the list costs one load each.
    var commitDiffs: [String: Diff] = [:]
    var isLoadingCommitDiff = false
    var commitDiffError: String?

    // How far the pull request's branch has drifted from the branch it targets,
    // and whether a merge, a rejection or a sync is running right now.
    var syncState: PullRequestSyncState?
    var isCheckingSync = false
    var isRunningPullRequestAction = false

    var isLoading = false
    var errorMessage: String?
    var diffLayout: DiffLayout = .split
    /// Which file of a multi-file diff is on screen; nil shows every file. It
    /// belongs to the item rather than to the view so that leaving the Diff tab
    /// of a pull request and coming back returns to the file being reviewed.
    var diffFile: DiffFile.ID?
    var pullRequestTab: PullRequestTab = .details

    nonisolated var id: String { kind.key }

    nonisolated var projectID: URL? {
        switch kind {
        case .file(let url): url
        case .workingDiff(let project, _, _): project
        case .commit(let project, _): project
        case .pullRequest(let project, _): project
        case .terminal(let project): project
        case .claude(let project): project
        }
    }

    nonisolated var symbol: String {
        switch kind {
        case .file(let url): FileIcon.symbol(for: url)
        case .workingDiff: "plusminus"
        case .commit: "clock.arrow.circlepath"
        case .pullRequest: "arrow.triangle.pull"
        case .terminal: "terminal"
        case .claude: "sparkles"
        }
    }

    /// The logo to draw in place of ``symbol``, for a file whose format has one.
    /// The header reads as the same file the navigator has selected, so it has
    /// to reach for the same mark — an SF Symbol next to a brand icon looks
    /// like two different files.
    nonisolated var brand: (name: String, color: Color)? {
        if case .file(let url) = kind { FileIcon.brand(for: url) } else { nil }
    }

    var isDirty: Bool { document?.isDirty ?? false }

    nonisolated var isPullRequest: Bool {
        if case .pullRequest = kind { true } else { false }
    }

    nonisolated var isCommit: Bool {
        if case .commit = kind { true } else { false }
    }

    /// The one diff holding everything in the working tree — see
    /// `WorkspaceStore.openAllChanges`, which marks it with an empty path.
    nonisolated var isAllChanges: Bool {
        if case .workingDiff(_, let path, _) = kind { path.isEmpty } else { false }
    }

    /// The full hash of the commit on screen, for the header's copy button. The
    /// breadcrumb only shows the short form, which is not what a `git` command
    /// or a ticket wants pasted into it.
    nonisolated var commitSHA: String? {
        if case .commit(_, let sha) = kind { sha } else { nil }
    }

    /// Terminals are the one item the store never throws away on its own.
    nonisolated var isTerminal: Bool {
        if case .terminal = kind { true } else { false }
    }

    nonisolated var isClaude: Bool {
        if case .claude = kind { true } else { false }
    }

    /// A file in the editor. Only one of these is ever alive at a time — see
    /// `WorkspaceStore.closeOtherFiles(keeping:)`.
    nonisolated var isFile: Bool {
        if case .file = kind { true } else { false }
    }

    /// Whether closing the item should keep it alive. A shell and a Claude
    /// conversation both have something running behind them, so ✕ puts the
    /// dashboard back rather than throwing the session away.
    nonisolated var survivesClosing: Bool { isTerminal || isClaude }

    init(kind: Kind, title: String, subtitle: String? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
    }
}
