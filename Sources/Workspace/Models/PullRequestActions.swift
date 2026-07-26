import Foundation

/// How a pull request lands on its target branch.
enum PullRequestMergeStrategy: String, CaseIterable, Identifiable, Sendable {
    /// Everything on the branch folded into one commit.
    case squash
    /// The commits as they are, with no merge commit added on top.
    case fastForward

    var id: String { rawValue }

    var title: String {
        switch self {
        case .squash: "Squash and Merge"
        case .fastForward: "Merge (fast-forward)"
        }
    }

    var symbol: String {
        switch self {
        case .squash: "arrow.triangle.merge"
        case .fastForward: "arrow.forward.to.line"
        }
    }

    func detail(target: String) -> String {
        switch self {
        case .squash:
            "Every commit on the branch becomes a single commit on \(target)."
        case .fastForward:
            "The commits go onto \(target) as they are, with no extra merge commit."
        }
    }
}

/// What a reviewer says about a pull request without ending it.
enum PullRequestReviewDecision: String, CaseIterable, Identifiable, Sendable {
    case approve
    case requestChanges

    var id: String { rawValue }

    var title: String {
        switch self {
        case .approve: "Approve"
        case .requestChanges: "Request Changes"
        }
    }

    var symbol: String {
        switch self {
        case .approve: "checkmark.seal"
        case .requestChanges: "exclamationmark.bubble"
        }
    }

    /// Whether the host insists on a comment. GitHub will not take a
    /// "changes requested" review without one.
    var needsComment: Bool { self == .requestChanges }
}

/// How far apart the pull request's branch and its target are.
struct PullRequestSyncState: Sendable, Hashable {
    /// Commits the pull request has that the target branch does not.
    var ahead: Int
    /// Commits the target branch has that the pull request does not — what
    /// "out of date" means.
    var behind: Int

    var isBehind: Bool { behind > 0 }

    func summary(target: String) -> String {
        if behind == 0 {
            return "Up to date with \(target)."
        }
        return behind == 1
            ? "1 commit behind \(target)."
            : "\(behind) commits behind \(target)."
    }
}

extension PullRequestService {

    // MARK: - Merging and rejecting

    /// Merges the pull request on the host. Nothing is deleted: neither CLI is
    /// asked to remove the source branch, so a merge here does exactly what was
    /// asked and no more.
    static func merge(
        _ pr: PullRequest,
        using strategy: PullRequestMergeStrategy,
        in directory: URL
    ) async throws {
        switch pr.host {
        case .github:
            // GitHub has no fast-forward merge; rebasing is its way of landing
            // the commits without a merge commit.
            let flag = strategy == .squash ? "--squash" : "--rebase"
            let result = await GitHubCLI.run(
                ["pr", "merge", "\(pr.number)", flag],
                in: directory,
                timeout: 120
            )
            guard result.isSuccess else {
                throw PullRequestError.commandFailed(result.failureMessage)
            }

        case .bitbucket:
            // Strategy ids differ between Cloud and Data Center, so try the
            // names each one uses and keep the last complaint.
            let strategies = strategy == .squash
                ? ["squash"]
                : ["fast_forward", "ff", "rebase_fast_forward"]
            var lastMessage = "Bitbucket refused the merge."
            for name in strategies {
                let result = await Shell.run(
                    ["bkt", "pr", "merge", "\(pr.number)",
                     "--strategy", name, "--close-source=false"],
                    in: directory,
                    timeout: 120
                )
                if result.isSuccess { return }
                lastMessage = result.failureMessage
            }
            throw PullRequestError.commandFailed(lastMessage)

        case .unknown:
            throw PullRequestError.unsupportedHost
        }
    }

    /// Closes the pull request without merging it — `gh pr close` on GitHub,
    /// `bkt pr decline` on Bitbucket. The reason, when given, is posted as the
    /// closing comment.
    static func reject(
        _ pr: PullRequest,
        reason: String,
        in directory: URL
    ) async throws {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)

        switch pr.host {
        case .github:
            var arguments = ["pr", "close", "\(pr.number)"]
            if !trimmed.isEmpty { arguments += ["--comment", trimmed] }
            let result = await GitHubCLI.run(arguments, in: directory, timeout: 60)
            guard result.isSuccess else {
                throw PullRequestError.commandFailed(result.failureMessage)
            }

        case .bitbucket:
            var arguments = ["bkt", "pr", "decline", "\(pr.number)"]
            if !trimmed.isEmpty { arguments += ["--comment", trimmed] }
            let result = await Shell.run(arguments, in: directory, timeout: 60)
            guard result.isSuccess else {
                throw PullRequestError.commandFailed(result.failureMessage)
            }

        case .unknown:
            throw PullRequestError.unsupportedHost
        }
    }

    // MARK: - Reviewing

    /// Approves the pull request, or asks for changes on it.
    ///
    /// GitHub has one command for both. Bitbucket has `bkt pr approve` and
    /// nothing for the other half, so the comment is posted first and the
    /// review state set through the API afterwards.
    static func review(
        _ pr: PullRequest,
        decision: PullRequestReviewDecision,
        comment: String,
        in directory: URL
    ) async throws {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if decision.needsComment, trimmed.isEmpty {
            throw PullRequestError.commandFailed(
                "Say what needs changing: a “changes requested” review needs a comment."
            )
        }

        switch pr.host {
        case .github:
            var arguments = ["pr", "review", "\(pr.number)"]
            arguments.append(decision == .approve ? "--approve" : "--request-changes")
            if !trimmed.isEmpty { arguments += ["--body", trimmed] }
            let result = await GitHubCLI.run(arguments, in: directory, timeout: 60)
            guard result.isSuccess else {
                throw PullRequestError.commandFailed(result.failureMessage)
            }

        case .bitbucket:
            // The comment goes first either way, so that a review that lands
            // without one still says why.
            if !trimmed.isEmpty {
                try await postComment(trimmed, on: pr, in: directory)
            }
            switch decision {
            case .approve:
                let result = await Shell.run(
                    ["bkt", "pr", "approve", "\(pr.number)"],
                    in: directory,
                    timeout: 60
                )
                guard result.isSuccess else {
                    throw PullRequestError.commandFailed(result.failureMessage)
                }
            case .requestChanges:
                // `bkt` has no subcommand for this; Cloud has an endpoint.
                guard !pr.repositoryOwner.isEmpty, !pr.repositorySlug.isEmpty else {
                    throw PullRequestError.commandFailed(
                        "This repository's workspace and slug are unknown, so the review cannot be sent."
                    )
                }
                let path = "/2.0/repositories/\(pr.repositoryOwner)/\(pr.repositorySlug)"
                    + "/pullrequests/\(pr.number)/request-changes"
                let result = await Shell.run(
                    ["bkt", "api", path, "--method", "POST"],
                    in: directory,
                    timeout: 60
                )
                guard result.isSuccess else {
                    throw PullRequestError.commandFailed(result.failureMessage)
                }
            }

        case .unknown:
            throw PullRequestError.unsupportedHost
        }
    }

    // MARK: - Sync with the target branch

    /// How far the pull request's branch has drifted from the branch it targets.
    ///
    /// GitHub can answer this outright. Everything else is counted from the
    /// checkout's own refs, which is instant but only as fresh as the last
    /// fetch — hence `fetching`, which the "check again" action passes.
    static func syncState(
        for pr: PullRequest,
        in directory: URL,
        fetching: Bool = false
    ) async -> PullRequestSyncState? {
        if pr.host == .github, let state = await gitHubSyncState(for: pr, in: directory) {
            return state
        }
        return await localSyncState(for: pr, in: directory, fetching: fetching)
    }

    private static func gitHubSyncState(
        for pr: PullRequest,
        in directory: URL
    ) async -> PullRequestSyncState? {
        let result = await GitHubCLI.run(
            ["api", "repos/{owner}/{repo}/compare/\(pr.targetBranch)...\(pr.sourceBranch)"],
            in: directory,
            timeout: 60
        )
        // A pull request from a fork has no such branch in this repository, so
        // the call 404s and the local count takes over.
        guard result.isSuccess else { return nil }

        struct Comparison: Decodable {
            let aheadBy: Int
            let behindBy: Int

            enum CodingKeys: String, CodingKey {
                case aheadBy = "ahead_by"
                case behindBy = "behind_by"
            }
        }

        guard let comparison = try? JSONDecoder().decode(
            Comparison.self,
            from: Data(result.stdout.utf8)
        ) else { return nil }
        return PullRequestSyncState(ahead: comparison.aheadBy, behind: comparison.behindBy)
    }

    private static func localSyncState(
        for pr: PullRequest,
        in directory: URL,
        fetching: Bool
    ) async -> PullRequestSyncState? {
        if fetching {
            // Fetching branches by name also updates their remote-tracking
            // refs, which is what the count below reads.
            _ = await Shell.run(
                ["git", "fetch", "origin", pr.targetBranch, pr.sourceBranch],
                in: directory,
                timeout: 120,
                environment: ["GIT_TERMINAL_PROMPT": "0"]
            )
        }

        guard let base = await resolveRef(pr.targetBranch, in: directory),
              let head = await resolveRef(pr.sourceBranch, in: directory)
        else { return nil }

        let result = await Shell.run(
            ["git", "rev-list", "--left-right", "--count", "\(base)...\(head)"],
            in: directory,
            timeout: 30
        )
        guard result.isSuccess else { return nil }
        // "<commits only on base>\t<commits only on the branch>".
        let counts = result.stdout.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard counts.count == 2 else { return nil }
        return PullRequestSyncState(ahead: counts[1], behind: counts[0])
    }

    /// The remote-tracking ref for a branch, or the local one when the branch
    /// has never been fetched under that name.
    private static func resolveRef(_ branch: String, in directory: URL) async -> String? {
        for candidate in ["refs/remotes/origin/\(branch)", "refs/heads/\(branch)"] {
            let result = await Shell.run(
                ["git", "rev-parse", "--verify", "--quiet", candidate],
                in: directory,
                timeout: 15
            )
            if result.isSuccess { return candidate }
        }
        return nil
    }

    /// Brings the target branch's commits into the pull request's branch.
    ///
    /// GitHub does it on the server, so nothing local is touched. Bitbucket has
    /// no such endpoint, so it happens in the checkout — which means the branch
    /// has to be the one that is checked out, with nothing uncommitted in the
    /// way.
    static func updateFromBase(_ pr: PullRequest, in directory: URL) async throws {
        switch pr.host {
        case .github:
            let result = await GitHubCLI.run(
                ["api", "--method", "PUT",
                 "repos/{owner}/{repo}/pulls/\(pr.number)/update-branch"],
                in: directory,
                timeout: 120
            )
            guard result.isSuccess else {
                throw PullRequestError.commandFailed(result.failureMessage)
            }

        case .bitbucket:
            try await updateFromBaseLocally(pr, in: directory)

        case .unknown:
            throw PullRequestError.unsupportedHost
        }
    }

    private static func updateFromBaseLocally(_ pr: PullRequest, in directory: URL) async throws {
        let environment = ["GIT_TERMINAL_PROMPT": "0"]

        let branch = await Shell.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            in: directory,
            timeout: 15
        )
        let current = branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == pr.sourceBranch else {
            throw PullRequestError.commandFailed(
                "Bitbucket cannot do this on the server, so it runs here — check out “\(pr.sourceBranch)” first."
            )
        }

        let status = await Shell.run(["git", "status", "--porcelain"], in: directory, timeout: 30)
        guard status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PullRequestError.commandFailed(
                "Commit or stash your changes first: merging \(pr.targetBranch) needs a clean working tree."
            )
        }

        let fetch = await Shell.run(
            ["git", "fetch", "origin", pr.targetBranch],
            in: directory,
            timeout: 120,
            environment: environment
        )
        guard fetch.isSuccess else {
            throw PullRequestError.commandFailed(fetch.failureMessage)
        }

        let merge = await Shell.run(
            ["git", "merge", "FETCH_HEAD", "-m",
             "Merge branch '\(pr.targetBranch)' into \(pr.sourceBranch)"],
            in: directory,
            timeout: 120,
            environment: environment
        )
        guard merge.isSuccess else {
            throw PullRequestError.commandFailed(merge.failureMessage)
        }

        let push = await Shell.run(
            ["git", "push", "origin", pr.sourceBranch],
            in: directory,
            timeout: 180,
            environment: environment
        )
        guard push.isSuccess else {
            throw PullRequestError.commandFailed(push.failureMessage)
        }
    }
}
