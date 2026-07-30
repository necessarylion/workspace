import Foundation

/// Where a pull request has ended up. Both hosts have their own words for it —
/// GitHub says `MERGED` / `CLOSED`, Bitbucket `MERGED` / `DECLINED` /
/// `SUPERSEDED` — and the app only cares whether there is still anything to do
/// with it.
enum PullRequestState: String, Sendable, Hashable {
    case open
    case merged
    /// Closed without merging: GitHub's `CLOSED`, Bitbucket's `DECLINED` and
    /// `SUPERSEDED`.
    case closed

    /// Reads whatever word the host used. Anything unrecognised counts as open,
    /// which is what the list endpoints return and what leaves the actions where
    /// they were.
    init(hostValue: String?) {
        switch hostValue?.uppercased() {
        case "MERGED": self = .merged
        case "CLOSED", "DECLINED", "SUPERSEDED", "REJECTED": self = .closed
        default: self = .open
        }
    }

    /// The word the summary bar shows. Open needs none — the actions below it
    /// already say as much.
    var badge: String? {
        switch self {
        case .open: nil
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }
}

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
    /// When it was opened. The list is read by age as much as by name — a
    /// request that has sat for a week is the one worth looking at first.
    var createdAt: Date?
    var additions: Int?
    var deletions: Int?
    var reviewDecision: String?
    /// How much has been said on it. Nil when the host did not say, which is
    /// not the same as nobody having said anything.
    var commentCount: Int?
    /// Who is reviewing, when the host hands them over with the list itself —
    /// GitHub always does, Bitbucket depending on the flavour. Otherwise it is
    /// filled in afterwards, one request at a time.
    var reviewers: [PullRequestReviewer] = []
    /// The CI verdict for the whole request, rolled up from its jobs. Nil while
    /// nothing has been read; `.unknown` when nothing has run.
    var buildState: PullRequestBuild.State?
    /// Whether the list already carried everything the board's columns need, so
    /// nothing has to be asked per request afterwards. True on GitHub, whose
    /// list answers for all of it, and on Bitbucket Cloud, whose API does —
    /// false only on the flavours that leave a column to fill in.
    var hasLoadedDetails = false
    /// Open unless the host said otherwise — see `PullRequestState`. Only the
    /// single-request loaders can see anything else: the lists ask for open ones
    /// only, and a merged request reaches the app through a `#123`.
    var state: PullRequestState = .open
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

    /// `workspace/slug`, which is what every Bitbucket REST path is built on.
    /// Nil when the remote named neither, and then only `bkt`'s own subcommands
    /// can be used — they fall back to whatever context it is configured with.
    var bitbucketRepository: String? {
        guard host == .bitbucket, !repositoryOwner.isEmpty, !repositorySlug.isEmpty else {
            return nil
        }
        return "\(repositoryOwner)/\(repositorySlug)"
    }

    /// The word in the list's leading badge — the state, or "Draft" for one
    /// that is not being offered for review yet.
    var stateBadge: String {
        if isDraft { return "Draft" }
        switch state {
        case .open: return "Open"
        case .merged: return "Merged"
        case .closed: return "Closed"
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
    case editUnsupported
    case deleteUnsupported

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
        case .editUnsupported:
            "That comment cannot be edited from here."
        case .deleteUnsupported:
            "That comment cannot be deleted from here."
        }
    }
}

/// Loads open pull requests by shelling out to the host's CLI.
enum PullRequestService {
    /// One read of Bitbucket's REST API through `bkt api`, as raw JSON.
    ///
    /// Everything the app *reads* from Bitbucket comes through here rather than
    /// through `bkt`'s own `pr` subcommands. Two reasons, and the second is the
    /// one that matters: `pr list` and `pr view` hand on a thinned-out pull
    /// request — no reviewers, no comment count, no draft flag — so every
    /// column beside the title cost a call of its own, per request; and the API
    /// takes `fields=`, so what does come back can be exactly what is wanted
    /// instead of a description the caller throws away.
    ///
    /// Cloud only. Data Center speaks `/rest/api/1.0/` and answers these paths
    /// with nothing, which is why every caller keeps its `bkt pr …` path
    /// underneath as a fallback rather than replacing it.
    ///
    /// Nil means the call failed — a wrong flavour, a missing scope, no
    /// network. It never throws: a fallback is always the next line.
    static func bitbucketAPI(
        _ path: String,
        params: [String] = [],
        in directory: URL,
        timeout: TimeInterval = 60
    ) async -> String? {
        var command = ["bkt", "api", path]
        for param in params { command += ["--param", param] }
        let result = await Shell.run(command, in: directory, timeout: timeout)
        return result.isSuccess ? result.stdout : nil
    }

    /// The same read, parsed. Most callers want the object; the decoders that
    /// predate this take the text.
    static func bitbucketAPIObject(
        _ path: String,
        params: [String] = [],
        in directory: URL,
        timeout: TimeInterval = 60
    ) async -> Any? {
        guard let json = await bitbucketAPI(path, params: params, in: directory, timeout: timeout)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(json.utf8))
    }

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
            // The API first. `bkt pr diff` only speaks to Data Center and exits
            // non-zero on Cloud, so trying it first spent a call that could
            // never work on every diff a Cloud repository opens.
            if let repository = pr.bitbucketRepository,
               let json = await bitbucketAPI(
                   "/2.0/repositories/\(repository)/pullrequests/\(pr.number)/diff",
                   in: directory,
                   timeout: 90
               ),
               json.contains("diff --git") {
                return json
            }
            let direct = await Shell.run(["bkt", "pr", "diff", "\(pr.number)"], in: directory, timeout: 90)
            return direct.isSuccess && direct.stdout.contains("diff --git") ? direct.stdout : nil

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

    /// Everything the list needs in one call. The columns beside the title —
    /// when it was opened, how much has been said, who is reviewing, what CI
    /// made of it — are all fields `gh` will hand over with the list itself, so
    /// a board of ten requests still costs exactly one call.
    private static let gitHubFields = """
        number,title,author,headRefName,headRefOid,baseRefName,url,isDraft,updatedAt,createdAt,\
        additions,deletions,body,reviewDecision,state,comments,reviewRequests,latestReviews,\
        statusCheckRollup
        """

    struct GitHubReviewRequest: Decodable {
        /// A user asked to review has a login; a team has a name and a slug.
        let login: String?
        let name: String?
        let slug: String?
    }

    struct GitHubReview: Decodable {
        struct Author: Decodable { let login: String? }
        let author: Author?
        let state: String?
    }

    private struct GitHubItem: Decodable {
        struct Author: Decodable { let login: String? }
        /// Only the count is wanted here; the conversation itself is read when
        /// the request is opened.
        struct Comment: Decodable {}
        /// One check on the head commit. A check run reports `status` plus
        /// `conclusion`; a commit status reports `state` alone.
        struct Check: Decodable {
            let status: String?
            let conclusion: String?
            let state: String?

            /// A finished check run says how it went in `conclusion`; one still
            /// running leaves that an empty string — not null — so the fields
            /// are taken in order of how much they say, skipping the empty ones.
            var verdict: String? {
                [conclusion, status, state].compactMap { $0 }.first { !$0.isEmpty }
            }
        }
        let number: Int
        let title: String
        let author: Author?
        let headRefName: String
        let headRefOid: String?
        let baseRefName: String
        let url: String?
        let isDraft: Bool
        let updatedAt: String?
        let createdAt: String?
        let additions: Int?
        let deletions: Int?
        let body: String?
        let reviewDecision: String?
        /// `OPEN`, `MERGED` or `CLOSED`.
        let state: String?
        let comments: [Comment]?
        let reviewRequests: [GitHubReviewRequest]?
        let latestReviews: [GitHubReview]?
        let statusCheckRollup: [Check]?
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
            createdAt: item.createdAt.flatMap(parseDate),
            additions: item.additions,
            deletions: item.deletions,
            reviewDecision: item.reviewDecision,
            commentCount: item.comments?.count,
            reviewers: gitHubReviewers(
                requested: item.reviewRequests,
                reviewed: item.latestReviews,
                author: item.author?.login,
                host: url?.host
            ),
            buildState: rollUp(raw: item.statusCheckRollup?.map(\.verdict)),
            // `gh pr list` answers for every column in one go, so nothing here
            // is ever asked for a second time.
            hasLoadedDetails: true,
            state: PullRequestState(hostValue: item.state),
            host: .github,
            headSHA: item.headRefOid ?? ""
        )
    }

    /// One verdict for a whole set of jobs, for the list's single glyph: the
    /// worst news wins. Nil for a request nothing has ever run against, which
    /// the column draws as a dash rather than as a state.
    static func rollUp(_ states: [PullRequestBuild.State]) -> PullRequestBuild.State? {
        guard !states.isEmpty else { return nil }
        for state in [PullRequestBuild.State.failed, .running, .pending, .cancelled, .passed] {
            if states.contains(state) { return state }
        }
        return .unknown
    }

    static func rollUp(_ builds: [PullRequestBuild]) -> PullRequestBuild.State? {
        rollUp(builds.map(\.state))
    }

    private static func rollUp(raw: [String?]?) -> PullRequestBuild.State? {
        guard let raw else { return nil }
        return rollUp(raw.map(PullRequestBuild.State.parse))
    }

    /// GitHub's two lists read as one row of faces. Shared by the list, which
    /// gets both with everything else, and by the panel, which asks for them on
    /// their own.
    static func gitHubReviewers(
        requested: [GitHubReviewRequest]?,
        reviewed: [GitHubReview]?,
        author: String?,
        host: String?
    ) -> [PullRequestReviewer] {
        var reviewers: [PullRequestReviewer] = []
        for review in reviewed ?? [] {
            guard let login = review.author?.login, !login.isEmpty else { continue }
            reviewers.append(
                PullRequestReviewer(
                    handle: login,
                    name: login,
                    avatarURL: AvatarURL.gitHub(login: login, host: host),
                    state: .parse(review.state)
                )
            )
        }
        // Anyone still on the request list has not answered — and someone whose
        // review was asked for again is on both lists, where being asked again
        // is the newer fact of the two.
        for request in requested ?? [] {
            guard let handle = [request.login, request.slug, request.name]
                .compactMap({ $0 })
                .first(where: { !$0.isEmpty })
            else { continue }
            let isTeam = request.login == nil
            reviewers.removeAll { $0.handle.caseInsensitiveCompare(handle) == .orderedSame }
            reviewers.append(
                PullRequestReviewer(
                    handle: handle,
                    name: request.login ?? request.name ?? handle,
                    avatarURL: isTeam ? nil : AvatarURL.gitHub(login: handle, host: host),
                    state: .pending,
                    isGroup: isTeam
                )
            )
        }
        // Nobody reviews their own request; GitHub keeps them out of both lists
        // anyway, but a self-review would count wrong in the summary.
        guard let author, !author.isEmpty else { return reviewers }
        return reviewers.filter { $0.handle.caseInsensitiveCompare(author) != .orderedSame }
    }

    // MARK: - Bitbucket

    private static func loadBitbucket(remote: RemoteInfo, in directory: URL) async throws -> [PullRequest] {
        guard await Shell.isAvailable("bkt") else { throw PullRequestError.cliMissing("bkt") }

        // Cloud answers the whole board in two calls made at once — see
        // `loadBitbucketCloud`. Everything below is the fallback for the
        // flavours that cannot.
        if let cloud = await loadBitbucketCloud(remote: remote, in: directory) {
            return cloud
        }

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
            if var prs = decodeBitbucket(result.stdout) {
                await addBitbucketCommentCounts(to: &prs, remote: remote, in: directory)
                return prs
            }
            lastMessage = "Could not read bkt's JSON output."
        }
        throw PullRequestError.commandFailed(lastMessage)
    }

    /// The whole board from Bitbucket Cloud, in two calls made at the same time.
    ///
    /// `bkt pr list` hands on a thinned-out pull request: no reviewers, no
    /// comment count, no draft flag — so the columns beside the title had to be
    /// filled in afterwards, one call per request per column. Ten open requests
    /// meant twenty more calls and a table that assembled itself while you
    /// watched. The REST API answers all of it at once:
    ///
    /// - **`/pullrequests`** with `fields=+values.…` keeps everything the list
    ///   already returns and adds the reviewers with their verdicts, the
    ///   participants, the comment count and the draft flag.
    /// - **`/pipelines`** newest first: a pipeline run for a pull request names
    ///   the request in `target.pullrequest.id`, so one page of runs is a build
    ///   verdict for every request that has one.
    ///
    /// Nil means this is not a Cloud repository, or Cloud would not answer —
    /// Data Center speaks `/rest/api/1.0/` and nothing here reaches it. The
    /// caller then falls back to `bkt pr list` exactly as before.
    private static func loadBitbucketCloud(
        remote: RemoteInfo,
        in directory: URL
    ) async -> [PullRequest]? {
        guard !remote.owner.isEmpty, !remote.slug.isEmpty else { return nil }
        let repository = "\(remote.owner)/\(remote.slug)"

        async let listed = Shell.run(
            [
                "bkt", "api", "/2.0/repositories/\(repository)/pullrequests",
                "--param", "state=OPEN",
                "--param", "pagelen=50",
                // The leading `+` is what keeps the endpoint's own fields; a
                // bare `fields=` would replace them and take the title with it.
                "--param",
                "fields=+values.participants,+values.reviewers,+values.comment_count,+values.draft",
            ],
            in: directory,
            timeout: 90
        )
        async let piped = Shell.run(
            [
                "bkt", "api", "/2.0/repositories/\(repository)/pipelines",
                "--param", "sort=-created_on",
                "--param", "pagelen=50",
                "--param",
                "fields=values.state,values.target.pullrequest.id,values.target.source",
            ],
            in: directory,
            timeout: 90
        )

        let list = await listed
        let pipelines = await piped
        guard list.isSuccess, var prs = decodeBitbucketCloudList(list.stdout) else { return nil }
        guard !prs.isEmpty else { return prs }

        let builds = pipelines.isSuccess
            ? decodeBitbucketPipelineStates(pipelines.stdout)
            : nil

        var matched = false
        for index in prs.indices {
            guard let builds else { continue }
            if let state = builds.byNumber[prs[index].number]
                ?? builds.byBranch[prs[index].sourceBranch] {
                prs[index].buildState = state
                matched = true
            }
        }

        // Marked complete only when the pipelines actually said something about
        // this repository. A repository that reports its builds as **commit
        // statuses** instead has pipelines to answer with, and there the
        // per-request fallback is still the only way to the verdict — so it is
        // left to run. Where a pipeline was found, a request without one has
        // genuinely had nothing run against it.
        if matched {
            for index in prs.indices {
                if prs[index].buildState == nil { prs[index].buildState = .unknown }
                prs[index].hasLoadedDetails = true
            }
        }
        return prs
    }

    /// The `{"values": […]}` a Cloud list comes back as, read by the decoder
    /// that already knows every spelling of a Bitbucket pull request. Only the
    /// wrapper differs from what `bkt pr list` prints, so only the wrapper is
    /// rewritten here. Nil means the answer was not a list at all.
    private static func decodeBitbucketCloudList(_ json: String) -> [PullRequest]? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let values = root["values"] as? [[String: Any]],
              let wrapped = try? JSONSerialization.data(withJSONObject: ["pull_requests": values]),
              let text = String(data: wrapped, encoding: .utf8)
        else { return nil }
        return decodeBitbucket(text)
    }

    /// The newest pipeline run per pull request, and per branch for the runs
    /// that name a branch rather than a request. The query asks for them newest
    /// first, so the first sighting of each is the one that counts.
    private static func decodeBitbucketPipelineStates(
        _ json: String
    ) -> (byNumber: [Int: PullRequestBuild.State], byBranch: [String: PullRequestBuild.State])? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let values = root["values"] as? [[String: Any]]
        else { return nil }

        var byNumber: [Int: PullRequestBuild.State] = [:]
        var byBranch: [String: PullRequestBuild.State] = [:]
        for value in values {
            let raw = value["state"] as? [String: Any]
            // A finished run says how it finished one level down; one still
            // going has no result yet and its own name is the answer.
            let verdict = (raw?["result"] as? [String: Any])?["name"] as? String
                ?? raw?["name"] as? String
            let state = PullRequestBuild.State.parse(verdict)

            let target = value["target"] as? [String: Any]
            if let number = (target?["pullrequest"] as? [String: Any])?["id"] as? Int,
               byNumber[number] == nil {
                byNumber[number] = state
            }
            if let branch = target?["source"] as? String, byBranch[branch] == nil {
                byBranch[branch] = state
            }
        }
        return (byNumber, byBranch)
    }

    /// How much has been said on each open request, in one call for all of them.
    ///
    /// Bitbucket Cloud counts the conversation on the pull request itself, but
    /// `bkt pr list` drops the field on its way through — so the count is asked
    /// for straight from the API, `fields=` narrowed to the two things wanted so
    /// this stays a small answer rather than every description again. Data
    /// Center has no `/2.0/` to answer it and the column stays empty there,
    /// which is the point of the column showing a dash rather than a zero.
    private static func addBitbucketCommentCounts(
        to prs: inout [PullRequest],
        remote: RemoteInfo,
        in directory: URL
    ) async {
        guard !prs.isEmpty, !remote.owner.isEmpty, !remote.slug.isEmpty else { return }
        let result = await Shell.run(
            [
                "bkt", "api", "/2.0/repositories/\(remote.owner)/\(remote.slug)/pullrequests",
                "--param", "state=OPEN",
                "--param", "pagelen=50",
                "--param", "fields=values.id,values.comment_count",
            ],
            in: directory,
            timeout: 60
        )
        guard result.isSuccess,
              let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)),
              let values = (object as? [String: Any])?["values"] as? [[String: Any]]
        else { return }

        var counts: [Int: Int] = [:]
        for value in values {
            guard let id = value["id"] as? Int, let count = value["comment_count"] as? Int else {
                continue
            }
            counts[id] = count
        }
        for index in prs.indices {
            prs[index].commentCount = counts[prs[index].number]
        }
    }

    private static func loadBitbucket(
        number: Int,
        remote: RemoteInfo,
        in directory: URL
    ) async throws -> PullRequest {
        guard await Shell.isAvailable("bkt") else { throw PullRequestError.cliMissing("bkt") }

        // The API answers with the request in full — reviewers, participants,
        // comment count and draft flag included — so a `#123` opened out of a
        // commit message arrives as complete as one picked off the board, in
        // the same single call `bkt pr view` would have spent on less.
        if !remote.owner.isEmpty, !remote.slug.isEmpty,
           let json = await bitbucketAPI(
               "/2.0/repositories/\(remote.owner)/\(remote.slug)/pullrequests/\(number)",
               in: directory
           ),
           let pr = decodeBitbucketOne(json) {
            return pr
        }

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
                let created_on: String?
                /// Cloud has had draft pull requests since 2023, and says so
                /// here — the app used to call every Bitbucket request final.
                let draft: Bool?
                /// Only in the API's answer: `bkt pr list` drops it, and the
                /// fallback path fills it in with a call of its own.
                let comment_count: Int?
            }
            let pull_requests: [Item]
        }

        guard let response = try? JSONDecoder().decode(Response.self, from: Data(json.utf8)) else {
            return nil
        }

        // Who is reviewing arrives in the same payload on the flavours that
        // send it, and is worth digging out by hand: the alternative is a call
        // per request to fill in one column.
        let reviewersByNumber = bitbucketReviewersByNumber(in: json)

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
                isDraft: item.draft ?? false,
                updatedAt: item.updated_on.flatMap(parseDate),
                createdAt: item.created_on.flatMap(parseDate),
                additions: nil,
                deletions: nil,
                reviewDecision: nil,
                // Present in the API's answer; filled in by
                // `addBitbucketCommentCounts` on the `bkt pr list` path, which
                // drops it.
                commentCount: item.comment_count,
                reviewers: (reviewersByNumber[item.id] ?? []).filter { reviewer in
                    // The author is a participant on Bitbucket, and counting
                    // them would make "2 of 3 approved" read wrong.
                    guard let author, !author.isEmpty else { return true }
                    return reviewer.name.caseInsensitiveCompare(author) != .orderedSame
                        && reviewer.handle.caseInsensitiveCompare(author) != .orderedSame
                },
                state: PullRequestState(hostValue: item.state),
                host: .bitbucket
            )
        }
    }

    /// The reviewers each request in a `bkt pr list` payload carries, by number.
    ///
    /// The list is decoded twice on purpose: once through `Codable` for the
    /// fields with fixed names, and once as loose JSON for these, because a
    /// reviewer is spelled four different ways across Bitbucket's flavours and
    /// `decodeBitbucketReviewers` already knows all of them.
    private static func bitbucketReviewersByNumber(in json: String) -> [Int: [PullRequestReviewer]] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let items = (root as? [String: Any])?["pull_requests"] as? [[String: Any]]
        else { return [:] }

        var found: [Int: [PullRequestReviewer]] = [:]
        for item in items {
            guard let id = item["id"] as? Int,
                  let reviewers = decodeBitbucketReviewers(from: item),
                  !reviewers.isEmpty
            else { continue }
            found[id] = reviewers
        }
        return found
    }

    private static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
