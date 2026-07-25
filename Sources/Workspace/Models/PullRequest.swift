import Foundation

/// A pull request, normalised across GitHub (`gh`) and Bitbucket (`bkt`).
struct PullRequest: Identifiable, Sendable, Hashable {
    var number: Int
    var title: String
    var author: String
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

    // MARK: - GitHub

    private static func loadGitHub(in directory: URL) async throws -> [PullRequest] {
        guard await Shell.isAvailable("gh") else { throw PullRequestError.cliMissing("gh") }

        let fields = "number,title,author,headRefName,headRefOid,baseRefName,url,isDraft,updatedAt,additions,deletions,body,reviewDecision"
        let result = await GitHubCLI.run(
            ["pr", "list", "--state", "open", "--limit", "50", "--json", fields],
            in: directory,
            timeout: 60
        )
        guard result.isSuccess else {
            throw PullRequestError.commandFailed(result.failureMessage)
        }

        struct Item: Decodable {
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

        let data = Data(result.stdout.utf8)
        let items = (try? JSONDecoder().decode([Item].self, from: data)) ?? []

        return items.map { item in
            PullRequest(
                number: item.number,
                title: item.title,
                author: item.author?.login ?? "unknown",
                sourceBranch: item.headRefName,
                targetBranch: item.baseRefName,
                body: item.body ?? "",
                url: item.url.flatMap(URL.init(string:)),
                isDraft: item.isDraft,
                updatedAt: item.updatedAt.flatMap(parseDate),
                additions: item.additions,
                deletions: item.deletions,
                reviewDecision: item.reviewDecision,
                host: .github,
                headSHA: item.headRefOid ?? ""
            )
        }
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

    private static func decodeBitbucket(_ json: String) -> [PullRequest]? {
        struct Response: Decodable {
            struct Item: Decodable {
                struct Author: Decodable {
                    let display_name: String?
                    let username: String?
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

                let id: Int
                let title: String
                let state: String?
                let author: Author?
                let source: Ref?
                let destination: Ref?
                let links: Links?
                let summary: Summary?
                let updated_on: String?
            }
            let pull_requests: [Item]
        }

        guard let response = try? JSONDecoder().decode(Response.self, from: Data(json.utf8)) else {
            return nil
        }

        return response.pull_requests.map { item in
            let author = item.author?.display_name?.isEmpty == false
                ? item.author?.display_name
                : item.author?.username
            return PullRequest(
                number: item.id,
                title: item.title,
                author: author ?? "unknown",
                sourceBranch: item.source?.branch?.name ?? "",
                targetBranch: item.destination?.branch?.name ?? "",
                body: item.summary?.raw ?? "",
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
