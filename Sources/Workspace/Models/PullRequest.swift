import Foundation

/// A pull request, normalised across GitHub (`gh`) and Bitbucket (`bkt`).
struct PullRequest: Identifiable, Sendable, Hashable {
    var number: Int
    var title: String
    var author: String
    /// The author's picture, when the host tells us where to find one.
    var avatarURL: URL?
    var sourceBranch: String
    var targetBranch: String
    var body: String
    var url: URL?
    var isDraft: Bool
    var updatedAt: Date?
    var additions: Int?
    var deletions: Int?
    var reviewDecision: String?
    var host: GitHostKind
    /// Owner / workspace / project key, kept for CLI calls that need it.
    var repositoryOwner: String = ""
    var repositorySlug: String = ""
    /// Commit at the head of the source branch. GitHub needs it to anchor a new
    /// inline comment to a line.
    var headSHA: String = ""

    var id: Int { number }

    var reviewLabel: String? {
        switch reviewDecision {
        case "APPROVED": "Approved"
        case "CHANGES_REQUESTED": "Changes requested"
        case "REVIEW_REQUIRED": "Review required"
        default: nil
        }
    }
}

/// The `links` object Bitbucket hangs off a user. Cloud keeps the avatar there;
/// Data Center puts it in a plain `avatarUrl` beside it.
struct BitbucketUserLinks: Decodable {
    struct Link: Decodable { let href: String? }
    let avatar: Link?
}

/// Reading a Bitbucket user object, whichever flavour of Bitbucket sent it.
enum BitbucketUser {
    /// The handle the account signs in with, which is what the app shows —
    /// GitHub has nothing but handles, so a Bitbucket repository reading
    /// "Pankaj Kamadiya" beside a GitHub one reading "ajsead" is two apps in
    /// one. Cloud calls it `nickname` (older payloads `username`), Data Center
    /// `name` or `slug`.
    static func login(from user: [String: Any]?) -> String? {
        for key in ["nickname", "username", "name", "slug"] {
            if let value = user?[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// The handle when the payload carries one, the person's full name when it
    /// does not.
    static func name(from user: [String: Any]?) -> String? {
        if let login = login(from: user) { return login }
        for key in ["display_name", "displayName"] {
            if let value = user?[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}

enum PullRequestError: LocalizedError {
    case cliMissing(String)
    case commandFailed(String)
    case unsupportedHost
    case replyUnsupported

    var errorDescription: String? {
        switch self {
        case .cliMissing(let tool):
            "`\(tool)` is not installed or not on your PATH."
        case .commandFailed(let message):
            message
        case .unsupportedHost:
            "This repository's remote is neither GitHub nor Bitbucket."
        case .replyUnsupported:
            "This host cannot thread a reply onto that comment."
        }
    }
}

/// Loads open pull requests by shelling out to the host's CLI.
enum PullRequestService {
    static func loadOpen(for remote: RemoteInfo, in directory: URL) async throws -> [PullRequest] {
        var prs: [PullRequest]
        switch remote.kind {
        case .github: prs = try await loadGitHub(in: directory)
        case .bitbucket: prs = try await loadBitbucket(remote: remote, in: directory)
        case .unknown: throw PullRequestError.unsupportedHost
        }
        for index in prs.indices {
            prs[index].repositoryOwner = remote.owner
            prs[index].repositorySlug = remote.slug
        }
        return prs
    }

    /// One pull request by number, in whatever state it is in. A `#123` in a
    /// commit message usually points at a request that has already merged, so
    /// this cannot go looking through the list of open ones.
    static func load(number: Int, for remote: RemoteInfo, in directory: URL) async throws -> PullRequest {
        var pr: PullRequest
        switch remote.kind {
        case .github: pr = try await loadGitHub(number: number, in: directory)
        case .bitbucket: pr = try await loadBitbucket(number: number, remote: remote, in: directory)
        case .unknown: throw PullRequestError.unsupportedHost
        }
        pr.repositoryOwner = remote.owner
        pr.repositorySlug = remote.slug
        return pr
    }

    /// Unified diff for one pull request.
    static func diff(for pr: PullRequest, in directory: URL) async -> String? {
        switch pr.host {
        case .github:
            let result = await GitHubCLI.run(["pr", "diff", "\(pr.number)"], in: directory, timeout: 90)
            return result.isSuccess ? result.stdout : nil

        case .bitbucket:
            // `bkt pr diff` only speaks to Data Center; it exits non-zero on
            // Cloud. Cloud goes through the raw REST API instead.
            let direct = await Shell.run(["bkt", "pr", "diff", "\(pr.number)"], in: directory, timeout: 90)
            if direct.isSuccess, direct.stdout.contains("diff --git") {
                return direct.stdout
            }
            guard !pr.repositoryOwner.isEmpty, !pr.repositorySlug.isEmpty else { return nil }
            let path = "/2.0/repositories/\(pr.repositoryOwner)/\(pr.repositorySlug)/pullrequests/\(pr.number)/diff"
            let api = await Shell.run(["bkt", "api", path], in: directory, timeout: 90)
            return api.isSuccess && api.stdout.contains("diff --git") ? api.stdout : nil

        case .unknown:
            return nil
        }
    }

    /// The description again, with its mentions named — or nothing when it
    /// already reads properly.
    ///
    /// `bkt pr list` hands back the raw Markdown alone, and there a mention is
    /// an account id: "Hello @{712020:297e58ad-…}". The name lives only in
    /// Bitbucket's own rendering of the same text, so a description that has one
    /// of those in it costs one extra call to fetch that rendering. A
    /// description without any costs nothing.
    static func namedMentions(in pr: PullRequest, directory: URL) async -> String? {
        guard pr.host == .bitbucket, pr.body.contains("@{"),
              !pr.repositoryOwner.isEmpty, !pr.repositorySlug.isEmpty
        else { return nil }

        let path = "/2.0/repositories/\(pr.repositoryOwner)/\(pr.repositorySlug)/pullrequests/\(pr.number)"
        let result = await Shell.run(["bkt", "api", path], in: directory, timeout: 60)
        guard result.isSuccess,
              let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              let rendered = object["rendered"] as? [String: Any],
              let html = (rendered["description"] as? [String: Any])?["html"] as? String
        else { return nil }

        let resolved = BitbucketMarkup.resolvingMentions(in: pr.body, html: html)
        return resolved == pr.body ? nil : resolved
    }

    // MARK: - GitHub

    private static let gitHubFields = "number,title,author,headRefName,headRefOid,baseRefName,url,isDraft,updatedAt,additions,deletions,body,reviewDecision"

    private struct GitHubItem: Decodable {
        struct Author: Decodable { let login: String? }
        let number: Int
        let title: String
        let author: Author?
        let headRefName: String
        let headRefOid: String?
        let baseRefName: String
        let url: String?
        let isDraft: Bool
        let updatedAt: String?
        let additions: Int?
        let deletions: Int?
        let body: String?
        let reviewDecision: String?
    }

    private static func loadGitHub(in directory: URL) async throws -> [PullRequest] {
        guard await Shell.isAvailable("gh") else { throw PullRequestError.cliMissing("gh") }

        let result = await GitHubCLI.run(
            ["pr", "list", "--state", "open", "--limit", "50", "--json", gitHubFields],
            in: directory,
            timeout: 60
        )
        guard result.isSuccess else {
            throw PullRequestError.commandFailed(result.failureMessage)
        }

        let data = Data(result.stdout.utf8)
        let items = (try? JSONDecoder().decode([GitHubItem].self, from: data)) ?? []
        return items.map(pullRequest(from:))
    }

    /// `gh pr view` answers for a request in any state, which is what a `#123`
    /// pointing at a merged one needs.
    private static func loadGitHub(number: Int, in directory: URL) async throws -> PullRequest {
        guard await Shell.isAvailable("gh") else { throw PullRequestError.cliMissing("gh") }

        let result = await GitHubCLI.run(
            ["pr", "view", "\(number)", "--json", gitHubFields],
            in: directory,
            timeout: 60
        )
        guard result.isSuccess else {
            throw PullRequestError.commandFailed(result.failureMessage)
        }
        guard let item = try? JSONDecoder().decode(GitHubItem.self, from: Data(result.stdout.utf8)) else {
            throw PullRequestError.commandFailed("Could not read what gh said about #\(number).")
        }
        return pullRequest(from: item)
    }

    private static func pullRequest(from item: GitHubItem) -> PullRequest {
        let url = item.url.flatMap(URL.init(string:))
        return PullRequest(
            number: item.number,
            title: item.title,
            author: item.author?.login ?? "unknown",
            // `gh` gives a login and no picture, and the pull request's own
            // URL says which GitHub the login belongs to.
            avatarURL: AvatarURL.gitHub(login: item.author?.login, host: url?.host),
            sourceBranch: item.headRefName,
            targetBranch: item.baseRefName,
            body: item.body ?? "",
            url: url,
            isDraft: item.isDraft,
            updatedAt: item.updatedAt.flatMap(parseDate),
            additions: item.additions,
            deletions: item.deletions,
            reviewDecision: item.reviewDecision,
            host: .github,
            headSHA: item.headRefOid ?? ""
        )
    }

    // MARK: - Bitbucket

    private static func loadBitbucket(remote: RemoteInfo, in directory: URL) async throws -> [PullRequest] {
        guard await Shell.isAvailable("bkt") else { throw PullRequestError.cliMissing("bkt") }

        // Point bkt at this repo explicitly; fall back to its configured context
        // when the overrides do not apply (e.g. Data Center uses --project).
        var attempts: [[String]] = []
        let base = ["bkt", "pr", "list", "--json", "--state", "OPEN", "--limit", "50"]
        if !remote.owner.isEmpty && !remote.slug.isEmpty {
            attempts.append(base + ["--workspace", remote.owner, "--repo", remote.slug])
            attempts.append(base + ["--project", remote.owner, "--repo", remote.slug])
        }
        attempts.append(base)

        var lastMessage = "bkt returned no pull requests."
        for command in attempts {
            let result = await Shell.run(command, in: directory, timeout: 90)
            guard result.isSuccess else {
                lastMessage = result.failureMessage
                continue
            }
            if let prs = decodeBitbucket(result.stdout) {
                return prs
            }
            lastMessage = "Could not read bkt's JSON output."
        }
        throw PullRequestError.commandFailed(lastMessage)
    }

    private static func loadBitbucket(
        number: Int,
        remote: RemoteInfo,
        in directory: URL
    ) async throws -> PullRequest {
        guard await Shell.isAvailable("bkt") else { throw PullRequestError.cliMissing("bkt") }

        // Same dance as the list: name the repository outright, and fall back to
        // whatever context bkt is configured with.
        var attempts: [[String]] = []
        let base = ["bkt", "pr", "view", "\(number)", "--json"]
        if !remote.owner.isEmpty && !remote.slug.isEmpty {
            attempts.append(base + ["--workspace", remote.owner, "--repo", remote.slug])
            attempts.append(base + ["--project", remote.owner, "--repo", remote.slug])
        }
        attempts.append(base)

        var lastMessage = "bkt found no pull request #\(number)."
        for command in attempts {
            let result = await Shell.run(command, in: directory, timeout: 60)
            guard result.isSuccess else {
                lastMessage = result.failureMessage
                continue
            }
            if let pr = decodeBitbucketOne(result.stdout) {
                return pr
            }
            lastMessage = "Could not read bkt's JSON output."
        }
        throw PullRequestError.commandFailed(lastMessage)
    }

    /// `bkt pr view` answers with one pull request where `pr list` answers with
    /// a list, and which key it hangs it off differs between flavours. Whatever
    /// shape it arrives in, it is re-wrapped as a one-item list, so the list
    /// decoder stays the only place that knows Bitbucket's field names.
    private static func decodeBitbucketOne(_ json: String) -> PullRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return nil }

        var item: [String: Any]?
        if let dictionary = object as? [String: Any] {
            if let one = dictionary["pull_request"] as? [String: Any] {
                item = one
            } else if let list = dictionary["pull_requests"] as? [[String: Any]] {
                item = list.first
            } else if dictionary["id"] != nil {
                item = dictionary
            }
        } else if let list = object as? [[String: Any]] {
            item = list.first
        }

        guard let item,
              let wrapped = try? JSONSerialization.data(withJSONObject: ["pull_requests": [item]]),
              let text = String(data: wrapped, encoding: .utf8)
        else { return nil }
        return decodeBitbucket(text)?.first
    }

    private static func decodeBitbucket(_ json: String) -> [PullRequest]? {
        struct Response: Decodable {
            struct Item: Decodable {
                struct Author: Decodable {
                    let display_name: String?
                    /// Cloud dropped `username` for `nickname`; both turn up,
                    /// depending on the payload and the flavour.
                    let username: String?
                    let nickname: String?
                    /// Cloud puts the picture under `links.avatar`; Data Center
                    /// names it `avatarUrl` on the user itself.
                    let links: BitbucketUserLinks?
                    let avatarUrl: String?
                }
                struct Ref: Decodable {
                    struct Branch: Decodable { let name: String? }
                    let branch: Branch?
                }
                struct Links: Decodable {
                    struct Link: Decodable { let href: String? }
                    let html: Link?
                }
                struct Summary: Decodable { let raw: String? }
                /// Bitbucket's own rendering of the description. Only `bkt pr
                /// view` and the REST API carry it — `pr list` does not — and it
                /// is the only place a mention's account id is paired with a
                /// name, which is what `BitbucketMarkup` needs.
                struct Rendered: Decodable {
                    struct Field: Decodable { let html: String? }
                    let description: Field?
                }

                let id: Int
                let title: String
                let state: String?
                let author: Author?
                let source: Ref?
                let destination: Ref?
                let links: Links?
                let summary: Summary?
                let description: String?
                let rendered: Rendered?
                let updated_on: String?
            }
            let pull_requests: [Item]
        }

        guard let response = try? JSONDecoder().decode(Response.self, from: Data(json.utf8)) else {
            return nil
        }

        return response.pull_requests.map { item in
            // The handle first, to read the same way GitHub's login does.
            let author = [item.author?.username, item.author?.nickname, item.author?.display_name]
                .compactMap { $0 }
                .first { !$0.isEmpty }
            return PullRequest(
                number: item.id,
                title: item.title,
                author: author ?? "unknown",
                avatarURL: AvatarURL.hosted(item.author?.links?.avatar?.href)
                    ?? AvatarURL.hosted(item.author?.avatarUrl),
                sourceBranch: item.source?.branch?.name ?? "",
                targetBranch: item.destination?.branch?.name ?? "",
                body: BitbucketMarkup.resolvingMentions(
                    in: item.summary?.raw ?? item.description ?? "",
                    html: item.rendered?.description?.html
                ),
                url: item.links?.html?.href.flatMap(URL.init(string:)),
                isDraft: false,
                updatedAt: item.updated_on.flatMap(parseDate),
                additions: nil,
                deletions: nil,
                reviewDecision: nil,
                host: .bitbucket
            )
        }
    }

    private static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
