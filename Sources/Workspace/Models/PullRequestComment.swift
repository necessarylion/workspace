import Foundation

/// One comment on a pull request, normalised across hosts.
struct PullRequestComment: Identifiable, Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case comment
        case review(state: String)

        var symbol: String {
            switch self {
            case .comment: "text.bubble"
            case .review(let state):
                switch state.uppercased() {
                case "APPROVED": "checkmark.seal.fill"
                case "CHANGES_REQUESTED": "exclamationmark.bubble.fill"
                default: "eye"
                }
            }
        }
    }

    /// What the host wants named when a comment's text is replaced.
    ///
    /// Three kinds of GitHub comment arrive from three different APIs and are
    /// edited through three different calls, so the loader — the only thing that
    /// knows which one it read — says so here rather than leaving the writer to
    /// guess it back out of an id.
    enum EditTarget: Sendable, Hashable {
        /// A comment on the conversation tab, by its GraphQL node id.
        case gitHubIssueComment(String)
        /// A review's summary, by its GraphQL node id.
        case gitHubReview(String)
        /// An inline review comment, by its REST id.
        case gitHubReviewComment(String)
        /// A Bitbucket comment. Data Center refuses an edit that does not name
        /// the version it replaces; Cloud has no such idea and sends nothing.
        case bitbucket(id: String, version: Int?)
    }

    /// Which column of the diff a line number refers to.
    enum Side: String, Sendable, Hashable {
        /// The file before the change — a removed or context line.
        case old
        /// The file after the change — an added or context line.
        case new
    }

    var id: String
    /// The comment this one replies to, when the host threads its comments.
    var parentID: String?
    var author: String
    /// The author's picture, when the host tells us where to find one.
    var avatarURL: URL?
    var body: String
    /// The Markdown the host itself stores, when that is not what `body` says.
    ///
    /// Bitbucket Cloud writes a mention as an account id and the app puts the
    /// person's name in its place for reading — see ``BitbucketMarkup``. Saving
    /// that back would post the name as plain words and lose the mention, so an
    /// edit starts from what the host actually holds. Nil everywhere else, where
    /// `body` is already the original.
    var rawBody: String?
    var createdAt: Date?
    var kind: Kind
    /// Set when the comment is anchored to a file in the diff.
    var path: String?
    /// Set when it is anchored to a line of that file as well.
    var line: Int?
    var side: Side = .new
    /// The host's own identifier for this comment, set only when the host can
    /// attach a reply to it. `nil` means "reply is not possible here".
    var replyToken: String?
    /// Whether the thread this comment belongs to has been marked resolved.
    ///
    /// Resolution belongs to the thread rather than to any one comment, and
    /// every host records it on the thread's first comment, so the flag is left
    /// where the host put it and read back off the root — see
    /// `PullRequestCommentNode.isResolved`. Copying it onto every reply would
    /// mean the tree builder had to know what a thread is, which it does not.
    var isResolved: Bool = false
    /// Who resolved it, when the host says.
    var resolvedBy: String?
    /// The handle the host wants when the thread is resolved or opened again.
    /// GitHub resolves a review *thread* by its GraphQL node id, Bitbucket the
    /// comment the thread hangs off; `nil` means this thread cannot be resolved
    /// from here and the button is not drawn.
    var resolveToken: String?
    /// The handle the host wants when this comment's text is replaced. `nil`
    /// means it cannot be edited from here — someone else wrote it, or the host
    /// gave no way to tell whose it is.
    var editTarget: EditTarget?

    var canReply: Bool { replyToken != nil }

    var canResolve: Bool { resolveToken != nil }

    var canEdit: Bool { editTarget != nil }

    /// Whether this comment can be taken down altogether.
    ///
    /// The same handle an edit uses answers this everywhere but one: GitHub
    /// deletes a review only while it is still pending, and everything loaded
    /// here has been submitted. So a review summary is the reader's to rewrite
    /// and not to remove, and no button is drawn for it.
    var canDelete: Bool {
        switch editTarget {
        case .gitHubReview, nil: false
        default: true
        }
    }

    /// The text an edit box opens with: what the host stores, which is not
    /// always what is on screen — see ``rawBody``.
    var editableBody: String { rawBody ?? body }

    /// The first line with anything in it — what a folded comment is read by.
    var preview: String {
        body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    /// Where in the diff this comment belongs, when it belongs anywhere.
    var anchor: DiffLineAnchor? {
        guard let path, let line else { return nil }
        return DiffLineAnchor(path: path, line: line, side: side)
    }
}

/// One line of one file in a diff: what an inline comment hangs off.
struct DiffLineAnchor: Sendable, Hashable {
    var path: String
    var line: Int
    var side: PullRequestComment.Side
}

/// One comment with its replies, ready to render.
struct PullRequestCommentNode: Identifiable, Sendable, Hashable {
    let comment: PullRequestComment
    let replies: [PullRequestCommentNode]

    /// Everything said under this comment, however deep it is nested.
    ///
    /// Counted as the tree is built rather than each time it is read: the
    /// number rides in a bubble's header and in every resolved thread's row,
    /// both of which are drawn again for reasons that have nothing to do with
    /// the conversation, and walking the whole subtree on each of those passes
    /// is a cost that grows with the review.
    let totalReplies: Int

    init(comment: PullRequestComment, replies: [PullRequestCommentNode] = []) {
        self.comment = comment
        self.replies = replies
        totalReplies = replies.reduce(replies.count) { $0 + $1.totalReplies }
    }

    var id: String { comment.id }

    /// Whether the whole thread is settled. The root carries the host's answer,
    /// so a reply never has to be consulted.
    var isResolved: Bool { comment.isResolved }

    /// The first line with anything in it, for a thread shown as one row.
    var preview: String { comment.preview }
}

extension PullRequestComment {
    /// Rebuilds the reply tree from a flat list. A comment whose parent is
    /// missing from the list (deleted, or on a page we did not fetch) is kept
    /// as a root, and so is anything a malformed parent chain would otherwise
    /// strand: every comment shows up exactly once, whatever the input.
    static func tree(from comments: [PullRequestComment]) -> [PullRequestCommentNode] {
        let byID = Dictionary(comments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var childrenByParent: [String: [PullRequestComment]] = [:]
        var roots: [PullRequestComment] = []

        for comment in comments {
            if let parentID = comment.parentID, parentID != comment.id, byID[parentID] != nil {
                childrenByParent[parentID, default: []].append(comment)
            } else {
                roots.append(comment)
            }
        }

        var placed: Set<String> = []

        func node(for comment: PullRequestComment) -> PullRequestCommentNode {
            placed.insert(comment.id)
            // Skipping what is already placed keeps a parent chain that loops
            // back on itself from recursing forever.
            let replies = (childrenByParent[comment.id] ?? [])
                .filter { !placed.contains($0.id) }
                .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
                .map(node(for:))
            return PullRequestCommentNode(comment: comment, replies: replies)
        }

        func byDate(_ lhs: PullRequestComment, _ rhs: PullRequestComment) -> Bool {
            (lhs.createdAt ?? .distantPast) < (rhs.createdAt ?? .distantPast)
        }

        var nodes = roots.sorted(by: byDate).map(node(for:))

        // A cycle leaves its members parented but unreachable; surface them as
        // roots rather than dropping them.
        let stranded = comments.filter { !placed.contains($0.id) }.sorted(by: byDate)
        nodes += stranded.compactMap { placed.contains($0.id) ? nil : node(for: $0) }

        return nodes
    }

    /// The thread roots that hang off a line of the diff, keyed by that line.
    /// A thread whose line is no longer in the diff simply does not appear; it
    /// is still listed in the conversation, so nothing is lost.
    static func inlineThreads(
        in nodes: [PullRequestCommentNode]
    ) -> [DiffLineAnchor: [PullRequestCommentNode]] {
        var grouped: [DiffLineAnchor: [PullRequestCommentNode]] = [:]
        for node in nodes {
            guard let anchor = node.comment.anchor else { continue }
            grouped[anchor, default: []].append(node)
        }
        return grouped
    }
}

/// Who `bkt` is signed in as, so a comment of one's own can be told from
/// everyone else's.
///
/// GitHub answers that question itself — every comment in GraphQL carries
/// `viewerCanUpdate` — and Bitbucket has nothing of the kind on either flavour,
/// so the account has to be looked up and matched by hand. Cloud gives an
/// account id, which is what a comment carries too; Data Center has only the
/// handle, which is what its comments carry.
///
/// Read once per checkout and kept: one answer covers every comment on every
/// pull request in it, and a failed read is not cached, so a `bkt` that was
/// signed out and back in is picked up on the next conversation.
actor BitbucketIdentity {
    static let shared = BitbucketIdentity()

    struct Account: Sendable, Hashable {
        var accountID: String?
        var uuid: String?
        var login: String?

        /// Whether a comment's `user` object is this account. The id is the
        /// answer wherever there is one; the handle is what Data Center leaves.
        func owns(_ user: [String: Any]?) -> Bool {
            guard let user else { return false }
            if let accountID, !accountID.isEmpty, user["account_id"] as? String == accountID {
                return true
            }
            if let uuid, !uuid.isEmpty, user["uuid"] as? String == uuid {
                return true
            }
            guard let login, !login.isEmpty,
                  let theirs = BitbucketUser.login(from: user)
            else { return false }
            return theirs.caseInsensitiveCompare(login) == .orderedSame
        }
    }

    private var accounts: [String: Account] = [:]

    func current(in directory: URL) async -> Account? {
        let key = directory.path
        if let known = accounts[key] { return known }
        guard let account = await Self.read(in: directory) else { return nil }
        accounts[key] = account
        return account
    }

    private static func read(in directory: URL) async -> Account? {
        // Cloud hands over the whole account, id and all.
        let cloud = await Shell.run(["bkt", "api", "/2.0/user"], in: directory, timeout: 30)
        if cloud.isSuccess,
           let object = try? JSONSerialization.jsonObject(with: Data(cloud.stdout.utf8)) as? [String: Any],
           object["account_id"] != nil || object["uuid"] != nil {
            return Account(
                accountID: object["account_id"] as? String,
                uuid: object["uuid"] as? String,
                login: BitbucketUser.login(from: object)
            )
        }

        // Data Center has no such endpoint, but `bkt` knows what it signed in
        // with. This is also where a Cloud token without the `account` scope
        // lands, and there the handle it gives — the username — is not the
        // nickname a Cloud comment is signed with, so nothing matches and no
        // comment offers an edit. That is the same shape of retreat resolution
        // already makes when GraphQL is out of reach.
        let status = await Shell.run(["bkt", "auth", "status", "--json"], in: directory, timeout: 30)
        guard status.isSuccess,
              let object = try? JSONSerialization.jsonObject(with: Data(status.stdout.utf8)) as? [String: Any],
              let hosts = object["hosts"] as? [[String: Any]],
              let login = hosts.compactMap({ $0["username"] as? String }).first(where: { !$0.isEmpty })
        else { return nil }
        return Account(login: login)
    }
}

extension PullRequestService {

    // MARK: - Reading

    static func comments(for pr: PullRequest, in directory: URL) async throws -> [PullRequestComment] {
        switch pr.host {
        case .github: try await gitHubComments(for: pr, in: directory)
        case .bitbucket: try await bitbucketComments(for: pr, in: directory)
        case .unknown: throw PullRequestError.unsupportedHost
        }
    }

    private static func gitHubComments(for pr: PullRequest, in directory: URL) async throws -> [PullRequestComment] {
        let result = await GitHubCLI.run(
            ["pr", "view", "\(pr.number)", "--json", "comments,reviews"],
            in: directory,
            timeout: 60
        )
        guard result.isSuccess else {
            throw PullRequestError.commandFailed(result.failureMessage)
        }

        struct Response: Decodable {
            struct Author: Decodable { let login: String? }
            struct Comment: Decodable {
                let id: String?
                let author: Author?
                let body: String?
                let createdAt: String?
            }
            struct Review: Decodable {
                let id: String?
                let author: Author?
                let body: String?
                let state: String?
                let submittedAt: String?
            }
            let comments: [Comment]?
            let reviews: [Review]?
        }

        guard let response = try? JSONDecoder().decode(Response.self, from: Data(result.stdout.utf8)) else {
            return []
        }

        var items: [PullRequestComment] = []
        for (index, comment) in (response.comments ?? []).enumerated() {
            items.append(
                PullRequestComment(
                    // Issue comments, review summaries and review comments come
                    // from three different id spaces, so keep them apart.
                    id: "issue-\(comment.id ?? "\(index)")",
                    parentID: nil,
                    author: comment.author?.login ?? "unknown",
                    avatarURL: AvatarURL.gitHub(login: comment.author?.login, host: pr.url?.host),
                    body: comment.body ?? "",
                    createdAt: comment.createdAt.flatMap(parseTimestamp),
                    kind: .comment,
                    path: nil,
                    // GitHub does not thread the conversation tab; a reply there
                    // is just another top-level comment.
                    replyToken: nil
                )
            )
        }
        for (index, review) in (response.reviews ?? []).enumerated() {
            let state = review.state ?? "COMMENTED"
            let body = review.body ?? ""
            // A bodiless "COMMENTED" review is only the envelope around inline
            // comments, which are loaded separately — showing it adds nothing.
            // A bodiless approval still carries its state as the message.
            if body.isEmpty, state.uppercased() == "COMMENTED" { continue }
            items.append(
                PullRequestComment(
                    id: "review-\(review.id ?? "\(index)")",
                    parentID: nil,
                    author: review.author?.login ?? "unknown",
                    avatarURL: AvatarURL.gitHub(login: review.author?.login, host: pr.url?.host),
                    body: body,
                    createdAt: review.submittedAt.flatMap(parseTimestamp),
                    kind: .review(state: state),
                    path: nil,
                    replyToken: nil
                )
            )
        }

        items.append(contentsOf: await gitHubReviewComments(for: pr, in: directory))
        await applyGitHubThreadsAndEditRights(to: &items, for: pr, in: directory)

        return items.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    /// Marks the review comments whose thread has been resolved, records the
    /// handle each thread is resolved by, and says which comments the signed-in
    /// account is allowed to rewrite.
    ///
    /// All three are GraphQL-only. The REST endpoint the inline comments come
    /// from says nothing about resolution — it exists per thread, and nowhere
    /// else — and neither `gh pr view` nor REST will say whether an edit would
    /// be accepted, which `viewerCanUpdate` answers for every kind of comment at
    /// once. So one query covers the conversation, the review summaries and the
    /// inline comments together.
    ///
    /// It is allowed to fail: a token without the scope, an enterprise host on
    /// an older schema, or no `gh` at all leaves every thread looking open and
    /// nothing editable, which is what the app showed before and still reads
    /// correctly.
    private static func applyGitHubThreadsAndEditRights(
        to comments: inout [PullRequestComment],
        for pr: PullRequest,
        in directory: URL
    ) async {
        guard !comments.isEmpty,
              let repository = await gitHubRepository(for: pr, in: directory)
        else { return }

        // `gh api graphql` does not expand {owner}/{repo} the way `gh api` does,
        // so the names are passed as variables.
        let query = "query($owner:String!,$repo:String!,$number:Int!)"
            + "{repository(owner:$owner,name:$repo)"
            + "{pullRequest(number:$number){"
            + "comments(first:100){nodes{id viewerCanUpdate}}"
            + "reviews(first:100){nodes{id viewerCanUpdate}}"
            + "reviewThreads(first:100){nodes"
            + "{id isResolved comments(first:100){nodes{databaseId viewerCanUpdate}}}}}}}"
        let result = await GitHubCLI.run(
            ["api", "graphql",
             "-f", "query=\(query)",
             "-f", "owner=\(repository.owner)",
             "-f", "repo=\(repository.name)",
             "-F", "number=\(pr.number)"],
            in: directory,
            timeout: 60
        )
        guard result.isSuccess else { return }

        struct Response: Decodable {
            struct Root: Decodable { let repository: Repository? }
            struct Repository: Decodable { let pullRequest: PullRequestNode? }
            struct PullRequestNode: Decodable {
                let comments: Nodes?
                let reviews: Nodes?
                let reviewThreads: Threads?
            }
            /// A conversation comment or a review summary: the node id the
            /// mutation names, and whether it would take one.
            struct Nodes: Decodable { let nodes: [Node]? }
            struct Node: Decodable {
                let id: String?
                let viewerCanUpdate: Bool?
            }
            struct Threads: Decodable { let nodes: [Thread]? }
            struct Thread: Decodable {
                struct Comments: Decodable { let nodes: [Comment]? }
                struct Comment: Decodable {
                    let databaseId: Int?
                    let viewerCanUpdate: Bool?
                }
                let id: String?
                let isResolved: Bool?
                let comments: Comments?
            }
            let data: Root?
        }

        guard let response = try? JSONDecoder().decode(Response.self, from: Data(result.stdout.utf8)),
              let pullRequest = response.data?.repository?.pullRequest
        else { return }

        // Keyed the way the loaders above spelled the ids, so each comment finds
        // its own row whatever kind it is.
        var threadByCommentID: [String: (token: String, isResolved: Bool)] = [:]
        var editableByCommentID: [String: PullRequestComment.EditTarget] = [:]

        for node in pullRequest.comments?.nodes ?? [] {
            guard let id = node.id, node.viewerCanUpdate == true else { continue }
            editableByCommentID["issue-\(id)"] = .gitHubIssueComment(id)
        }
        for node in pullRequest.reviews?.nodes ?? [] {
            guard let id = node.id, node.viewerCanUpdate == true else { continue }
            editableByCommentID["review-\(id)"] = .gitHubReview(id)
        }
        for thread in pullRequest.reviewThreads?.nodes ?? [] {
            guard let token = thread.id else { continue }
            for comment in thread.comments?.nodes ?? [] {
                guard let databaseId = comment.databaseId else { continue }
                let key = "review-comment-\(databaseId)"
                threadByCommentID[key] = (token, thread.isResolved ?? false)
                if comment.viewerCanUpdate == true {
                    editableByCommentID[key] = .gitHubReviewComment("\(databaseId)")
                }
            }
        }

        for index in comments.indices {
            if let thread = threadByCommentID[comments[index].id] {
                comments[index].resolveToken = thread.token
                comments[index].isResolved = thread.isResolved
            }
            comments[index].editTarget = editableByCommentID[comments[index].id]
        }
    }

    /// The owner and name GraphQL needs, from the pull request when the remote
    /// named them and from `gh` itself otherwise.
    private static func gitHubRepository(
        for pr: PullRequest,
        in directory: URL
    ) async -> (owner: String, name: String)? {
        if !pr.repositoryOwner.isEmpty, !pr.repositorySlug.isEmpty {
            return (pr.repositoryOwner, pr.repositorySlug)
        }
        let result = await GitHubCLI.run(
            ["repo", "view", "--json", "owner,name"],
            in: directory,
            timeout: 30
        )
        guard result.isSuccess else { return nil }

        struct Repository: Decodable {
            struct Owner: Decodable { let login: String? }
            let owner: Owner?
            let name: String?
        }

        guard let decoded = try? JSONDecoder().decode(Repository.self, from: Data(result.stdout.utf8)),
              let owner = decoded.owner?.login, let name = decoded.name,
              !owner.isEmpty, !name.isEmpty
        else { return nil }
        return (owner, name)
    }

    /// Inline review comments. `gh pr view` does not expose them, and they are
    /// the only GitHub comments that actually form threads (`in_reply_to_id`).
    private static func gitHubReviewComments(
        for pr: PullRequest,
        in directory: URL
    ) async -> [PullRequestComment] {
        // `gh api` fills in {owner}/{repo} from the checkout itself.
        let result = await GitHubCLI.run(
            ["api", "--paginate",
             "repos/{owner}/{repo}/pulls/\(pr.number)/comments?per_page=100"],
            in: directory,
            timeout: 60
        )
        guard result.isSuccess else { return [] }

        struct ReviewComment: Decodable {
            struct User: Decodable {
                let login: String?
                /// The REST API, unlike `gh pr view`, hands the picture over.
                let avatarURL: String?

                enum CodingKeys: String, CodingKey {
                    case login
                    case avatarURL = "avatar_url"
                }
            }
            let id: Int
            let inReplyToID: Int?
            let user: User?
            let body: String?
            let createdAt: String?
            let path: String?
            /// Absent once the line has scrolled out of the current diff, which
            /// is what `originalLine` is for.
            let line: Int?
            let originalLine: Int?
            /// "LEFT" for the old file, "RIGHT" (or absent) for the new one.
            let side: String?

            enum CodingKeys: String, CodingKey {
                case id, user, body, path, line, side
                case inReplyToID = "in_reply_to_id"
                case createdAt = "created_at"
                case originalLine = "original_line"
            }
        }

        let decoded = decodeJSONArrayPages(result.stdout, as: ReviewComment.self)
        return decoded.map { comment in
            PullRequestComment(
                id: "review-comment-\(comment.id)",
                parentID: comment.inReplyToID.map { "review-comment-\($0)" },
                author: comment.user?.login ?? "unknown",
                avatarURL: AvatarURL.hosted(comment.user?.avatarURL)
                    ?? AvatarURL.gitHub(login: comment.user?.login, host: pr.url?.host),
                body: comment.body ?? "",
                createdAt: comment.createdAt.flatMap(parseTimestamp),
                kind: .comment,
                path: comment.path,
                line: comment.line ?? comment.originalLine,
                side: comment.side?.uppercased() == "LEFT" ? .old : .new,
                replyToken: "\(comment.id)"
            )
        }
    }

    /// Recent `gh api --paginate` merges pages into one JSON array; older
    /// versions print one array per page, back to back. Handle both.
    static func decodeJSONArrayPages<T: Decodable>(
        _ text: String,
        as type: T.Type
    ) -> [T] {
        if let single = try? JSONDecoder().decode([T].self, from: Data(text.utf8)) {
            return single
        }
        let separated = text.replacingOccurrences(
            of: "]\\s*\\[",
            with: "]\u{1}[",
            options: .regularExpression
        )
        return separated.split(separator: "\u{1}").flatMap { chunk in
            (try? JSONDecoder().decode([T].self, from: Data(chunk.utf8))) ?? []
        }
    }

    private static func bitbucketComments(
        for pr: PullRequest,
        in directory: URL
    ) async throws -> [PullRequestComment] {
        // Which of these are the reader's own, and so may be rewritten. Nil
        // where `bkt` would not say; then nothing offers an edit.
        let account = await BitbucketIdentity.shared.current(in: directory)

        // Bitbucket Cloud: `bkt pr view` carries no comments at all, so go to
        // the REST API directly.
        if !pr.repositoryOwner.isEmpty, !pr.repositorySlug.isEmpty {
            let path = "/2.0/repositories/\(pr.repositoryOwner)/\(pr.repositorySlug)"
                + "/pullrequests/\(pr.number)/comments"
            let result = await Shell.run(
                ["bkt", "api", path, "--param", "pagelen=100"],
                in: directory,
                timeout: 60
            )
            if result.isSuccess,
               let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
               let values = object["values"] as? [[String: Any]] {
                return decodeCloudComments(values, ownedBy: account)
            }
        }

        // Data Center: `bkt pr view --json` shape varies, so read whatever
        // comment array it exposes rather than a fixed model.
        var attempts: [[String]] = [["bkt", "pr", "view", "\(pr.number)", "--json"]]
        if !pr.repositorySlug.isEmpty {
            attempts.insert(
                ["bkt", "pr", "view", "\(pr.number)", "--json",
                 "--repo", pr.repositorySlug],
                at: 0
            )
        }

        var lastMessage = "Could not read comments from bkt."
        for command in attempts {
            let result = await Shell.run(command, in: directory, timeout: 60)
            guard result.isSuccess else {
                lastMessage = result.failureMessage
                continue
            }
            guard let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) else {
                continue
            }
            return decodeBitbucketComments(from: object, ownedBy: account)
        }
        throw PullRequestError.commandFailed(lastMessage)
    }

    /// Decodes the fixed shape of Bitbucket Cloud's `/pullrequests/N/comments`.
    private static func decodeCloudComments(
        _ values: [[String: Any]],
        ownedBy account: BitbucketIdentity.Account?
    ) -> [PullRequestComment] {
        values.enumerated().compactMap { index, item in
            if item["deleted"] as? Bool == true { return nil }
            if item["pending"] as? Bool == true { return nil }
            let content = item["content"] as? [String: Any]
            let raw = content?["raw"] as? String ?? ""
            guard !raw.isEmpty else { return nil }
            // The raw Markdown spells a mention as an account id; only the
            // rendered HTML knows whose id it is.
            let body = BitbucketMarkup.resolvingMentions(
                in: raw,
                html: content?["html"] as? String
            )

            let user = item["user"] as? [String: Any]
            let author = BitbucketUser.name(from: user) ?? "unknown"
            let avatar = ((user?["links"] as? [String: Any])?["avatar"] as? [String: Any])?["href"]

            let identifier = "\(item["id"] ?? "cloud-\(index)")"
            let parent = (item["parent"] as? [String: Any])?["id"]
            let inline = item["inline"] as? [String: Any]
            // `to` is a line in the file after the change, `from` before it.
            let toLine = inline?["to"] as? Int
            let fromLine = inline?["from"] as? Int

            // Cloud hangs a `resolution` object off the thread's first comment
            // and leaves it out entirely while the thread is open, so its mere
            // presence is the answer.
            let resolution = item["resolution"] as? [String: Any]

            return PullRequestComment(
                id: identifier,
                parentID: parent.map { "\($0)" },
                author: author,
                avatarURL: AvatarURL.hosted(avatar as? String),
                body: body,
                // Only when the name put in place of an account id made it
                // something other than what the host holds.
                rawBody: body == raw ? nil : raw,
                createdAt: (item["created_on"] as? String).flatMap(parseTimestamp),
                kind: .comment,
                path: inline?["path"] as? String,
                line: toLine ?? fromLine,
                side: toLine != nil ? .new : .old,
                replyToken: identifier,
                isResolved: resolution != nil,
                resolvedBy: BitbucketUser.name(from: resolution?["user"] as? [String: Any]),
                resolveToken: identifier,
                // Cloud numbers a comment's revisions nowhere; only Data Center
                // asks for the version an edit replaces.
                editTarget: account?.owns(user) == true
                    ? .bitbucket(id: identifier, version: nil)
                    : nil
            )
        }
        .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    /// Walks the JSON for any comment-shaped object. Data Center nests replies
    /// in a `comments` array on the parent, so descend into those explicitly
    /// and carry the parent's id down.
    private static func decodeBitbucketComments(
        from object: Any,
        ownedBy account: BitbucketIdentity.Account?
    ) -> [PullRequestComment] {
        var found: [PullRequestComment] = []
        var seen: Set<String> = []

        func comment(from dictionary: [String: Any], index: Int) -> PullRequestComment? {
            let rendered = dictionary["content"] as? [String: Any]
            let raw = rendered?["raw"] as? String
                ?? dictionary["text"] as? String
                ?? dictionary["body"] as? String
            guard let raw, !raw.isEmpty else { return nil }
            let content = BitbucketMarkup.resolvingMentions(
                in: raw,
                html: rendered?["html"] as? String
            )

            let userDictionary = (dictionary["user"] ?? dictionary["author"]) as? [String: Any]
            let author = BitbucketUser.name(from: userDictionary) ?? "unknown"

            // Cloud hangs the picture off `links.avatar`, Data Center off a
            // plain `avatarUrl` — and Data Center's is often a path, which
            // `AvatarURL.hosted` drops rather than turn into a broken request.
            let links = userDictionary?["links"] as? [String: Any]
            let avatar = (links?["avatar"] as? [String: Any])?["href"] as? String
                ?? userDictionary?["avatarUrl"] as? String

            let timestamp = dictionary["created_on"] as? String
                ?? dictionary["createdDate"] as? String
                ?? dictionary["created"] as? String

            let inline = dictionary["inline"] as? [String: Any]
            let anchor = dictionary["anchor"] as? [String: Any]
            let path = (inline?["path"] as? String) ?? (anchor?["path"] as? String)

            // Cloud puts the line in `inline.to` / `inline.from`; Data Center
            // puts it in `anchor.line` and names the column in `fileType`.
            let toLine = inline?["to"] as? Int
            let fromLine = inline?["from"] as? Int
            let anchorLine = anchor?["line"] as? Int
            let isOldSide = toLine == nil
                && (fromLine != nil
                    || (anchor?["fileType"] as? String)?.uppercased() == "FROM"
                    || (anchor?["lineType"] as? String)?.uppercased() == "REMOVED")

            let identifier = "\(dictionary["id"] ?? "bitbucket-\(index)")"
            // Cloud-style parenting; Data Center nests instead, handled below.
            let parent = (dictionary["parent"] as? [String: Any])?["id"]

            // Data Center names the thread's standing in `state`; Cloud, which
            // can reach this decoder through `bkt pr view`, still says it with
            // a `resolution` object.
            let resolution = dictionary["resolution"] as? [String: Any]
            let isResolved = (dictionary["state"] as? String)?.uppercased() == "RESOLVED"
                || resolution != nil
            let resolver = (dictionary["resolver"] as? [String: Any])
                ?? (resolution?["user"] as? [String: Any])

            return PullRequestComment(
                id: identifier,
                parentID: parent.map { "\($0)" },
                author: author,
                avatarURL: AvatarURL.hosted(avatar),
                body: content,
                rawBody: content == raw ? nil : raw,
                createdAt: timestamp.flatMap(parseTimestamp),
                kind: .comment,
                path: path,
                line: toLine ?? fromLine ?? anchorLine,
                side: isOldSide ? .old : .new,
                replyToken: dictionary["id"].map { "\($0)" },
                isResolved: isResolved,
                resolvedBy: BitbucketUser.name(from: resolver),
                resolveToken: dictionary["id"].map { "\($0)" },
                // Data Center takes an edit only against the revision it is
                // replacing, and counts them here.
                editTarget: account?.owns(userDictionary) == true
                    ? .bitbucket(id: identifier, version: dictionary["version"] as? Int)
                    : nil
            )
        }

        /// Records one comment and its nested replies.
        func absorb(_ dictionary: [String: Any], parentID: String?, index: Int) {
            guard var decoded = comment(from: dictionary, index: index) else { return }
            decoded.parentID = decoded.parentID ?? parentID
            guard seen.insert(decoded.id).inserted else { return }
            found.append(decoded)
            for (childIndex, child) in (dictionary["comments"] as? [Any] ?? []).enumerated() {
                guard let child = child as? [String: Any] else { continue }
                absorb(child, parentID: decoded.id, index: childIndex)
            }
        }

        func walk(_ value: Any, key: String?) {
            let isCommentKey = key?.lowercased().contains("comment") ?? false

            if let dictionary = value as? [String: Any] {
                // An activity entry carries its comment under a `comment` key.
                if isCommentKey, dictionary["id"] != nil {
                    absorb(dictionary, parentID: nil, index: found.count)
                    return
                }
                for (childKey, child) in dictionary {
                    walk(child, key: childKey)
                }
                return
            }

            guard let array = value as? [Any] else { return }
            guard isCommentKey else {
                for item in array { walk(item, key: key) }
                return
            }
            for (index, item) in array.enumerated() {
                guard let dictionary = item as? [String: Any] else { continue }
                absorb(dictionary, parentID: nil, index: index)
            }
        }

        walk(object, key: nil)
        return found.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    // MARK: - Writing

    /// Posts a comment, or a reply to `replyingTo` when one is given. Returns
    /// nothing on success, throws with the CLI's own message otherwise.
    static func postComment(
        _ body: String,
        on pr: PullRequest,
        replyingTo parent: PullRequestComment? = nil,
        in directory: URL
    ) async throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let parent {
            guard let token = parent.replyToken else {
                throw PullRequestError.replyUnsupported
            }
            try await postReply(trimmed, to: token, on: pr, in: directory)
            return
        }

        switch pr.host {
        case .github:
            let result = await GitHubCLI.run(
                ["pr", "comment", "\(pr.number)", "--body", trimmed],
                in: directory,
                timeout: 60
            )
            guard result.isSuccess else {
                throw PullRequestError.commandFailed(result.failureMessage)
            }

        case .bitbucket:
            // Like `pr diff`, `pr comment` may be Data Center-only; Cloud
            // falls back to a REST POST.
            let direct = await Shell.run(
                ["bkt", "pr", "comment", "\(pr.number)", "--text", trimmed],
                in: directory,
                timeout: 60
            )
            if direct.isSuccess { return }

            guard !pr.repositoryOwner.isEmpty, !pr.repositorySlug.isEmpty,
                  let body = try? JSONSerialization.data(withJSONObject: ["content": ["raw": trimmed]])
            else {
                throw PullRequestError.commandFailed(direct.failureMessage)
            }
            let path = "/2.0/repositories/\(pr.repositoryOwner)/\(pr.repositorySlug)"
                + "/pullrequests/\(pr.number)/comments"
            let api = await Shell.run(
                ["bkt", "api", path, "--method", "POST", "--input", String(decoding: body, as: UTF8.self)],
                in: directory,
                timeout: 60
            )
            guard api.isSuccess else {
                throw PullRequestError.commandFailed(api.failureMessage)
            }

        case .unknown:
            throw PullRequestError.unsupportedHost
        }
    }

    /// Starts a new comment thread anchored to one line of the diff.
    static func postInlineComment(
        _ body: String,
        on pr: PullRequest,
        at anchor: DiffLineAnchor,
        in directory: URL
    ) async throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch pr.host {
        case .github:
            // GitHub pins the comment to a commit, not just to a line.
            guard !pr.headSHA.isEmpty else {
                throw PullRequestError.commandFailed(
                    "The head commit of this pull request is unknown, so the comment cannot be anchored. Reload the pull requests and try again."
                )
            }
            let result = await GitHubCLI.run(
                ["api", "--method", "POST",
                 "repos/{owner}/{repo}/pulls/\(pr.number)/comments",
                 "-f", "body=\(trimmed)",
                 "-f", "commit_id=\(pr.headSHA)",
                 "-f", "path=\(anchor.path)",
                 "-F", "line=\(anchor.line)",
                 "-f", "side=\(anchor.side == .old ? "LEFT" : "RIGHT")"],
                in: directory,
                timeout: 60
            )
            guard result.isSuccess else {
                throw PullRequestError.commandFailed(result.failureMessage)
            }

        case .bitbucket:
            guard !pr.repositoryOwner.isEmpty, !pr.repositorySlug.isEmpty else {
                throw PullRequestError.commandFailed(
                    "This repository's workspace and slug are unknown, so the comment cannot be anchored."
                )
            }
            let lineKey = anchor.side == .old ? "from" : "to"
            let attempts: [(path: String, payload: [String: Any])] = [
                (
                    "/2.0/repositories/\(pr.repositoryOwner)/\(pr.repositorySlug)"
                        + "/pullrequests/\(pr.number)/comments",
                    [
                        "content": ["raw": trimmed],
                        "inline": ["path": anchor.path, lineKey: anchor.line],
                    ]
                ),
                (
                    "/rest/api/1.0/projects/\(pr.repositoryOwner)/repos/\(pr.repositorySlug)"
                        + "/pull-requests/\(pr.number)/comments",
                    [
                        "text": trimmed,
                        "anchor": [
                            "path": anchor.path,
                            "line": anchor.line,
                            "lineType": anchor.side == .old ? "REMOVED" : "ADDED",
                            "fileType": anchor.side == .old ? "FROM" : "TO",
                        ],
                    ]
                ),
            ]

            var lastMessage = "Could not post the inline comment."
            for attempt in attempts {
                guard let data = try? JSONSerialization.data(withJSONObject: attempt.payload) else {
                    continue
                }
                let result = await Shell.run(
                    ["bkt", "api", attempt.path, "--method", "POST",
                     "--input", String(decoding: data, as: UTF8.self)],
                    in: directory,
                    timeout: 60
                )
                if result.isSuccess { return }
                lastMessage = result.failureMessage
            }
            throw PullRequestError.commandFailed(lastMessage)

        case .unknown:
            throw PullRequestError.unsupportedHost
        }
    }

    /// Attaches a reply to an existing comment. `token` is the host's own id
    /// for that comment, as recorded when the conversation was loaded.
    private static func postReply(
        _ body: String,
        to token: String,
        on pr: PullRequest,
        in directory: URL
    ) async throws {
        switch pr.host {
        case .github:
            // Only review comments thread on GitHub, and they have their own
            // reply endpoint.
            let result = await GitHubCLI.run(
                ["api", "--method", "POST",
                 "repos/{owner}/{repo}/pulls/\(pr.number)/comments/\(token)/replies",
                 "-f", "body=\(body)"],
                in: directory,
                timeout: 60
            )
            guard result.isSuccess else {
                throw PullRequestError.commandFailed(result.failureMessage)
            }

        case .bitbucket:
            guard !pr.repositoryOwner.isEmpty, !pr.repositorySlug.isEmpty else {
                throw PullRequestError.replyUnsupported
            }
            // The parent id is numeric in both APIs; keep the string only if it
            // somehow is not.
            let parentID: Any = Int(token) ?? token
            let base = "/repositories/\(pr.repositoryOwner)/\(pr.repositorySlug)"

            let attempts: [(path: String, payload: [String: Any])] = [
                (
                    "/2.0\(base)/pullrequests/\(pr.number)/comments",
                    ["content": ["raw": body], "parent": ["id": parentID]]
                ),
                (
                    "/rest/api/1.0/projects/\(pr.repositoryOwner)/repos/\(pr.repositorySlug)"
                        + "/pull-requests/\(pr.number)/comments",
                    ["text": body, "parent": ["id": parentID]]
                ),
            ]

            var lastMessage = "Could not post the reply."
            for attempt in attempts {
                guard let data = try? JSONSerialization.data(withJSONObject: attempt.payload) else {
                    continue
                }
                let result = await Shell.run(
                    ["bkt", "api", attempt.path, "--method", "POST",
                     "--input", String(decoding: data, as: UTF8.self)],
                    in: directory,
                    timeout: 60
                )
                if result.isSuccess { return }
                lastMessage = result.failureMessage
            }
            throw PullRequestError.commandFailed(lastMessage)

        case .unknown:
            throw PullRequestError.unsupportedHost
        }
    }

    /// Replaces what a comment says.
    ///
    /// `comment` has to be one the conversation was loaded with: the handle each
    /// host wants rides on it, and only the loader knew which kind of comment it
    /// was reading — see ``PullRequestComment/EditTarget``.
    static func updateComment(
        _ body: String,
        of comment: PullRequestComment,
        on pr: PullRequest,
        in directory: URL
    ) async throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PullRequestError.commandFailed(
                "A comment cannot be emptied. Delete it on the host instead."
            )
        }
        guard let target = comment.editTarget else {
            throw PullRequestError.editUnsupported
        }

        switch target {
        case .gitHubIssueComment(let nodeID):
            try await updateGitHubNode(
                nodeID,
                to: trimmed,
                mutation: "updateIssueComment",
                idField: "id",
                in: directory
            )

        case .gitHubReview(let nodeID):
            try await updateGitHubNode(
                nodeID,
                to: trimmed,
                mutation: "updatePullRequestReview",
                idField: "pullRequestReviewId",
                in: directory
            )

        case .gitHubReviewComment(let id):
            // The one kind with a REST id in hand, and so the one that needs no
            // GraphQL at all.
            let result = await GitHubCLI.run(
                ["api", "--method", "PATCH",
                 "repos/{owner}/{repo}/pulls/comments/\(id)",
                 "-f", "body=\(trimmed)"],
                in: directory,
                timeout: 60
            )
            guard result.isSuccess else {
                throw PullRequestError.commandFailed(result.failureMessage)
            }

        case .bitbucket(let id, let version):
            try await updateBitbucketComment(
                trimmed,
                id: id,
                version: version,
                on: pr,
                in: directory
            )
        }
    }

    /// One of GitHub's two "change the text" mutations, which differ only in
    /// what they call the id. Neither has a REST equivalent that takes what is
    /// in hand: `gh pr view` reports a conversation comment and a review by
    /// their GraphQL node ids, and those are exactly what GraphQL wants.
    private static func updateGitHubNode(
        _ nodeID: String,
        to body: String,
        mutation: String,
        idField: String,
        in directory: URL
    ) async throws {
        let query = "mutation($id:ID!,$body:String!){"
            + "\(mutation)(input:{\(idField):$id,body:$body}){clientMutationId}}"
        let result = await GitHubCLI.run(
            ["api", "graphql",
             "-f", "query=\(query)",
             "-f", "id=\(nodeID)",
             "-f", "body=\(body)"],
            in: directory,
            timeout: 60
        )
        guard result.isSuccess else {
            throw PullRequestError.commandFailed(result.failureMessage)
        }
    }

    /// The same edit on both Bitbucket flavours: Cloud takes the new Markdown
    /// under `content.raw`, Data Center takes it as `text` and insists on the
    /// version it is replacing. Tried in that order, like every other write here.
    private static func updateBitbucketComment(
        _ body: String,
        id: String,
        version: Int?,
        on pr: PullRequest,
        in directory: URL
    ) async throws {
        guard !pr.repositoryOwner.isEmpty, !pr.repositorySlug.isEmpty else {
            throw PullRequestError.commandFailed(
                "This repository's workspace and slug are unknown, so the comment cannot be edited."
            )
        }

        var dataCenter: [String: Any] = ["text": body]
        if let version { dataCenter["version"] = version }

        let attempts: [(path: String, payload: [String: Any])] = [
            (
                "/2.0/repositories/\(pr.repositoryOwner)/\(pr.repositorySlug)"
                    + "/pullrequests/\(pr.number)/comments/\(id)",
                ["content": ["raw": body]]
            ),
            (
                "/rest/api/1.0/projects/\(pr.repositoryOwner)/repos/\(pr.repositorySlug)"
                    + "/pull-requests/\(pr.number)/comments/\(id)",
                dataCenter
            ),
        ]

        var lastMessage = "Could not save the comment."
        for attempt in attempts {
            guard let data = try? JSONSerialization.data(withJSONObject: attempt.payload) else {
                continue
            }
            let result = await Shell.run(
                ["bkt", "api", attempt.path, "--method", "PUT",
                 "--input", String(decoding: data, as: UTF8.self)],
                in: directory,
                timeout: 60
            )
            if result.isSuccess { return }
            lastMessage = result.failureMessage
        }
        throw PullRequestError.commandFailed(lastMessage)
    }

    /// Takes a comment down.
    ///
    /// It travels on the same handle an edit does — the loader is still the only
    /// thing that knew which kind of comment it read — with one exception, which
    /// is why ``PullRequestComment/canDelete`` is not simply `canEdit`: GitHub
    /// deletes a review only while it is pending.
    ///
    /// Replies are the host's business. GitHub keeps them and re-parents nothing,
    /// so a thread whose root is gone comes back as its replies, each a root of
    /// its own — which is what `tree(from:)` already does with an orphan.
    /// Bitbucket refuses to delete a comment that has been replied to at all.
    /// Either answer is the host's to give; the conversation is read back
    /// afterwards and shows whichever it was.
    static func deleteComment(
        _ comment: PullRequestComment,
        on pr: PullRequest,
        in directory: URL
    ) async throws {
        guard let target = comment.editTarget, comment.canDelete else {
            throw PullRequestError.deleteUnsupported
        }

        switch target {
        case .gitHubIssueComment(let nodeID):
            // No REST id was ever read for a conversation comment — `gh pr view`
            // reports the node id — and GraphQL takes exactly that.
            let query = "mutation($id:ID!){deleteIssueComment(input:{id:$id}){clientMutationId}}"
            let result = await GitHubCLI.run(
                ["api", "graphql", "-f", "query=\(query)", "-f", "id=\(nodeID)"],
                in: directory,
                timeout: 60
            )
            guard result.isSuccess else {
                throw PullRequestError.commandFailed(result.failureMessage)
            }

        case .gitHubReview:
            throw PullRequestError.deleteUnsupported

        case .gitHubReviewComment(let id):
            let result = await GitHubCLI.run(
                ["api", "--method", "DELETE",
                 "repos/{owner}/{repo}/pulls/comments/\(id)"],
                in: directory,
                timeout: 60
            )
            guard result.isSuccess else {
                throw PullRequestError.commandFailed(result.failureMessage)
            }

        case .bitbucket(let id, let version):
            try await deleteBitbucketComment(id: id, version: version, on: pr, in: directory)
        }
    }

    /// Cloud deletes by path alone; Data Center insists on the version it is
    /// removing, and a DELETE carries no body to put it in — so it goes as a
    /// query parameter. Tried in that order, like every other write here.
    private static func deleteBitbucketComment(
        id: String,
        version: Int?,
        on pr: PullRequest,
        in directory: URL
    ) async throws {
        guard !pr.repositoryOwner.isEmpty, !pr.repositorySlug.isEmpty else {
            throw PullRequestError.commandFailed(
                "This repository's workspace and slug are unknown, so the comment cannot be deleted."
            )
        }

        let attempts: [(path: String, parameters: [String])] = [
            (
                "/2.0/repositories/\(pr.repositoryOwner)/\(pr.repositorySlug)"
                    + "/pullrequests/\(pr.number)/comments/\(id)",
                []
            ),
            (
                "/rest/api/1.0/projects/\(pr.repositoryOwner)/repos/\(pr.repositorySlug)"
                    + "/pull-requests/\(pr.number)/comments/\(id)",
                version.map { ["--param", "version=\($0)"] } ?? []
            ),
        ]

        var lastMessage = "Could not delete the comment."
        for attempt in attempts {
            let result = await Shell.run(
                ["bkt", "api", attempt.path, "--method", "DELETE"] + attempt.parameters,
                in: directory,
                timeout: 60
            )
            if result.isSuccess { return }
            lastMessage = result.failureMessage
        }
        throw PullRequestError.commandFailed(lastMessage)
    }

    /// Settles a thread, or opens it again. `comment` is the thread's root, the
    /// only comment either host records resolution on.
    static func setResolved(
        _ resolved: Bool,
        for comment: PullRequestComment,
        on pr: PullRequest,
        in directory: URL
    ) async throws {
        guard let token = comment.resolveToken else {
            throw PullRequestError.commandFailed(
                "This host does not let that thread be resolved from here."
            )
        }

        switch pr.host {
        case .github:
            // Resolution is a GraphQL-only idea on GitHub, and it names the
            // review thread rather than any comment in it — which is why the
            // conversation is loaded with that node id already in hand.
            let mutation = "mutation($id:ID!){"
                + (resolved ? "resolveReviewThread" : "unresolveReviewThread")
                + "(input:{threadId:$id}){thread{id isResolved}}}"
            let result = await GitHubCLI.run(
                ["api", "graphql", "-f", "query=\(mutation)", "-f", "id=\(token)"],
                in: directory,
                timeout: 60
            )
            guard result.isSuccess else {
                throw PullRequestError.commandFailed(result.failureMessage)
            }

        case .bitbucket:
            // `bkt` has the verb itself, and it knows both flavours: Cloud's
            // resolve endpoint and Data Center's comment state are one command
            // here. Going to the REST path directly instead is what a 403 was
            // answering — Cloud's `/resolve` refuses the credential `bkt api`
            // presents, and `bkt` is the thing that knows how to ask properly.
            // It wants the thread's own comment, which is the only one this is
            // ever called with.
            var arguments = ["bkt", "pr", "comments",
                             resolved ? "resolve" : "reopen",
                             "\(pr.number)", token]
            // The checkout usually says which repository this is, but bkt reads
            // that from its own context; naming it keeps a context pointing
            // somewhere else from settling the wrong thread.
            if !pr.repositorySlug.isEmpty {
                arguments += ["--repo", pr.repositorySlug]
            }
            let result = await Shell.run(arguments, in: directory, timeout: 60)
            guard result.isSuccess else {
                throw PullRequestError.commandFailed(result.failureMessage)
            }

        case .unknown:
            throw PullRequestError.unsupportedHost
        }
    }

    static func parseTimestamp(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return real(date) }
        if let date = ISO8601DateFormatter().date(from: string) { return real(date) }
        // Bitbucket Data Center sends epoch milliseconds.
        if let milliseconds = Double(string) {
            return real(Date(timeIntervalSince1970: milliseconds / 1000))
        }
        return nil
    }

    /// Nothing, for a time that only means the host had none to give.
    ///
    /// `gh` writes a check with no time of its own as `0001-01-01T00:00:00Z` —
    /// Go's zero `time.Time` — and a check posted by a bot that never ran (a
    /// review it declined, say) carries exactly that. Read as a date it is real
    /// enough to format, which is how "2,025 years ago" ends up on screen.
    /// Nothing this app reads about a pull request predates the epoch.
    private static func real(_ date: Date) -> Date? {
        date.timeIntervalSince1970 > 0 ? date : nil
    }
}
