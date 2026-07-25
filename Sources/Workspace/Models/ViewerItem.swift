import Foundation

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
        case pullRequest(projectID: URL, number: Int)
        case terminal(projectID: URL)

        var key: String {
            switch self {
            case .file(let url): "file:\(url.path)"
            case .workingDiff(let project, let path, _): "diff:\(project.path):\(path)"
            case .pullRequest(let project, let number): "pr:\(project.path):\(number)"
            case .terminal(let project): "term:\(project.path)"
            }
        }
    }

    /// Which part of a pull request the viewer is showing. It lives here rather
    /// than in the view because the picker sits up in the window header, next to
    /// back and forward, and each pull request remembers where you left it.
    enum PullRequestTab: String, CaseIterable, Identifiable {
        case details, diff, builds
        var id: String { rawValue }

        var title: String {
            switch self {
            case .details: "Details"
            case .diff: "Diff"
            case .builds: "Builds"
            }
        }

        var symbol: String {
            switch self {
            case .details: "bubble.left.and.bubble.right"
            case .diff: "plusminus"
            case .builds: "hammer"
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

    // Payloads, filled in depending on `kind`.
    var document: OpenDocument?
    var diff: Diff?
    var pullRequest: PullRequest?

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

    var isLoading = false
    var errorMessage: String?
    var diffLayout: DiffLayout = .split
    var pullRequestTab: PullRequestTab = .details

    nonisolated var id: String { kind.key }

    nonisolated var projectID: URL? {
        switch kind {
        case .file(let url): url
        case .workingDiff(let project, _, _): project
        case .pullRequest(let project, _): project
        case .terminal(let project): project
        }
    }

    nonisolated var symbol: String {
        switch kind {
        case .file(let url): FileIcon.symbol(for: url)
        case .workingDiff: "plusminus"
        case .pullRequest: "arrow.triangle.pull"
        case .terminal: "terminal"
        }
    }

    var isDirty: Bool { document?.isDirty ?? false }

    nonisolated var isPullRequest: Bool {
        if case .pullRequest = kind { true } else { false }
    }

    /// Terminals are the one item the store never throws away on its own.
    nonisolated var isTerminal: Bool {
        if case .terminal = kind { true } else { false }
    }

    init(kind: Kind, title: String, subtitle: String? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
    }
}
