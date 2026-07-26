import Foundation

/// One commit on a pull request, normalised across hosts.
struct PullRequestCommit: Identifiable, Sendable, Hashable {
    /// The full hash: what the host wants back when asked for this commit's diff.
    var sha: String
    /// Subject and body together, exactly as the author wrote them.
    var message: String
    var author: String
    /// The author's picture, when the host tells us where to find one.
    var avatarURL: URL?
    var date: Date?
    var url: URL?

    var id: String { sha }

    var shortSHA: String { String(sha.prefix(7)) }

    /// The first line, which is what the list shows.
    var headline: String {
        let first = message.split(separator: "\n", maxSplits: 1).first
        let trimmed = first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return trimmed.isEmpty ? shortSHA : trimmed
    }

    /// Everything after the first line.
    var body: String {
        let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count > 1 else { return "" }
        return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension PullRequestService {

    // MARK: - Reading

    /// The commits of one pull request, newest first — the order a log reads in.
    static func commits(for pr: PullRequest, in directory: URL) async throws -> [PullRequestCommit] {
        switch pr.host {
        case .github: try await gitHubCommits(for: pr, in: directory)
        case .bitbucket: try await bitbucketCommits(for: pr, in: directory)
        case .unknown: throw PullRequestError.unsupportedHost
        }
    }

    private static func gitHubCommits(
        for pr: PullRequest,
        in directory: URL
    ) async throws -> [PullRequestCommit] {
        let result = await GitHubCLI.run(
            ["pr", "view", "\(pr.number)", "--json", "commits"],
            in: directory,
            timeout: 60
        )
        guard result.isSuccess else {
            throw PullRequestError.commandFailed(result.failureMessage)
        }

        struct Response: Decodable {
            struct Commit: Decodable {
                struct Author: Decodable {
                    let name: String?
                    let login: String?
                    /// Set when the commit was authored outside GitHub, which is
                    /// the only handle on a picture for that person.
                    let email: String?
                }
                let oid: String
                let messageHeadline: String?
                let messageBody: String?
                let committedDate: String?
                let authors: [Author]?
            }
            let commits: [Commit]?
        }

        guard let response = try? JSONDecoder().decode(Response.self, from: Data(result.stdout.utf8)) else {
            throw PullRequestError.commandFailed("Could not read gh's list of commits.")
        }

        let commits = (response.commits ?? []).map { commit in
            let body = commit.messageBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let headline = commit.messageHeadline ?? ""
            let author = commit.authors?.first
            return PullRequestCommit(
                sha: commit.oid,
                message: body.isEmpty ? headline : "\(headline)\n\n\(body)",
                author: author?.login?.isEmpty == false
                    ? (author?.login ?? "unknown")
                    : (author?.name ?? "unknown"),
                avatarURL: AvatarURL.gitHub(login: author?.login, host: pr.url?.host)
                    ?? AvatarURL.gitIdentity(email: author?.email),
                date: commit.committedDate.flatMap(parseTimestamp),
                url: commitURL(for: pr, sha: commit.oid)
            )
        }
        // gh lists them oldest first.
        return commits.reversed()
    }

    /// Bitbucket has no `bkt pr commits`, so both flavours go through the REST
    /// API — Cloud first, then Data Center, the same order the rest of the
    /// Bitbucket code tries them in.
    private static func bitbucketCommits(
        for pr: PullRequest,
        in directory: URL
    ) async throws -> [PullRequestCommit] {
        guard !pr.repositoryOwner.isEmpty, !pr.repositorySlug.isEmpty else {
            throw PullRequestError.commandFailed(
                "This repository's workspace and slug are unknown, so its commits cannot be listed."
            )
        }

        let attempts: [(path: String, param: String)] = [
            (
                "/2.0/repositories/\(pr.repositoryOwner)/\(pr.repositorySlug)"
                    + "/pullrequests/\(pr.number)/commits",
                "pagelen=100"
            ),
            (
                "/rest/api/1.0/projects/\(pr.repositoryOwner)/repos/\(pr.repositorySlug)"
                    + "/pull-requests/\(pr.number)/commits",
                "limit=100"
            ),
        ]

        var lastMessage = "Could not read the commits from bkt."
        for attempt in attempts {
            let result = await Shell.run(
                ["bkt", "api", attempt.path, "--param", attempt.param],
                in: directory,
                timeout: 60
            )
            guard result.isSuccess else {
                lastMessage = result.failureMessage
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)),
                  let values = (object as? [String: Any])?["values"] as? [[String: Any]]
            else {
                continue
            }
            // Both APIs already answer newest first.
            return decodeBitbucketCommits(values, pr: pr)
        }
        throw PullRequestError.commandFailed(lastMessage)
    }

    /// Cloud names the hash `hash` and the author `author.raw`; Data Center
    /// names them `id` and `author.displayName`. Read whichever is there.
    private static func decodeBitbucketCommits(
        _ values: [[String: Any]],
        pr: PullRequest
    ) -> [PullRequestCommit] {
        values.compactMap { item in
            guard let sha = (item["hash"] as? String) ?? (item["id"] as? String) else { return nil }
            let author = item["author"] as? [String: Any]
            let user = author?["user"] as? [String: Any]
            let name = BitbucketUser.name(from: user)
                ?? author?["displayName"] as? String
                ?? author?["name"] as? String
                ?? (author?["raw"] as? String).map(stripEmail)
                ?? "unknown"

            // A Bitbucket account carries its own picture; a commit from someone
            // without one leaves only the `Name <email>` line to go on.
            let links = user?["links"] as? [String: Any]
            let avatar = (links?["avatar"] as? [String: Any])?["href"] as? String
                ?? user?["avatarUrl"] as? String

            // Cloud sends an ISO timestamp in `date`, Data Center epoch
            // milliseconds in `authorTimestamp`.
            let timestamp = (item["date"] as? String)
                ?? (item["authorTimestamp"] as? Int).map { "\($0)" }
                ?? (item["committerTimestamp"] as? Int).map { "\($0)" }

            return PullRequestCommit(
                sha: sha,
                message: (item["message"] as? String) ?? "",
                author: name,
                avatarURL: AvatarURL.hosted(avatar)
                    ?? AvatarURL.gitIdentity(raw: author?["raw"] as? String),
                date: timestamp.flatMap(parseTimestamp),
                url: commitURL(for: pr, sha: sha)
            )
        }
    }

    /// `Name <name@example.com>` → `Name`.
    private static func stripEmail(_ raw: String) -> String {
        guard let angle = raw.firstIndex(of: "<") else { return raw }
        let name = raw[..<angle].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? raw : name
    }

    /// The commit's page on the host, derived from the pull request's own URL so
    /// that self-hosted instances keep their address. Both hosts end their pull
    /// request URL with `<something>/<number>`, so dropping two components lands
    /// on the repository.
    private static func commitURL(for pr: PullRequest, sha: String) -> URL? {
        guard let url = pr.url else { return nil }
        let repository = url.deletingLastPathComponent().deletingLastPathComponent()
        let segment = pr.host == .github ? "commit" : "commits"
        return repository.appendingPathComponent(segment).appendingPathComponent(sha)
    }

    // MARK: - Commit diff

    /// The patch for one commit of a pull request.
    ///
    /// Git itself first: the commit is usually already in the checkout, and a
    /// local `git show` is both faster and offline. Only when it is not — a
    /// branch that was never fetched — does this go out to the host.
    static func diff(
        forCommit sha: String,
        of pr: PullRequest,
        in directory: URL
    ) async -> String? {
        let local = await Shell.run(
            ["git", "show", "--format=", "--patch", "--no-color", sha],
            in: directory,
            timeout: 60
        )
        if local.isSuccess, local.stdout.contains("diff --git") {
            return local.stdout
        }

        switch pr.host {
        case .github:
            let result = await GitHubCLI.run(
                ["api", "-H", "Accept: application/vnd.github.diff",
                 "repos/{owner}/{repo}/commits/\(sha)"],
                in: directory,
                timeout: 90
            )
            return result.isSuccess && result.stdout.contains("diff --git") ? result.stdout : nil

        case .bitbucket:
            guard !pr.repositoryOwner.isEmpty, !pr.repositorySlug.isEmpty else { return nil }
            let path = "/2.0/repositories/\(pr.repositoryOwner)/\(pr.repositorySlug)/diff/\(sha)"
            let result = await Shell.run(["bkt", "api", path], in: directory, timeout: 90)
            return result.isSuccess && result.stdout.contains("diff --git") ? result.stdout : nil

        case .unknown:
            return nil
        }
    }
}
