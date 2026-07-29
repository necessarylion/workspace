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

    var canReply: Bool { replyToken != nil }

    var canResolve: Bool { resolveToken != nil }

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
    var preview: String {
        comment.body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
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

        var inline = await gitHubReviewComments(for: pr, in: directory)
        await applyGitHubThreads(to: &inline, for: pr, in: directory)
        items.append(contentsOf: inline)

        return items.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    /// Marks the review comments whose thread has been resolved, and records the
    /// handle each thread is resolved by.
    ///
    /// The REST endpoint the comments themselves come from says nothing about
    /// resolution — it exists only in GraphQL, and only per thread — so this is
    /// a second call over the same comments. It is allowed to fail: a token
    /// without the scope, an enterprise host on an older schema, or no `gh` at
    /// all leaves every thread looking open, which is what the app showed
    /// before and still reads correctly.
    private static func applyGitHubThreads(
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
            + "{pullRequest(number:$number){reviewThreads(first:100){nodes"
            + "{id isResolved comments(first:100){nodes{databaseId}}}}}}}"
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
            struct PullRequestNode: Decodable { let reviewThreads: Threads? }
            struct Threads: Decodable { let nodes: [Thread]? }
            struct Thread: Decodable {
                struct Comments: Decodable { let nodes: [Comment]? }
                struct Comment: Decodable { let databaseId: Int? }
                let id: String?
                let isResolved: Bool?
                let comments: Comments?
            }
            let data: Root?
        }

        guard let response = try? JSONDecoder().decode(Response.self, from: Data(result.stdout.utf8)),
              let threads = response.data?.repository?.pullRequest?.reviewThreads?.nodes
        else { return }

        var byCommentID: [String: (token: String, isResolved: Bool)] = [:]
        for thread in threads {
            guard let token = thread.id else { continue }
            for comment in thread.comments?.nodes ?? [] {
                guard let databaseId = comment.databaseId else { continue }
                byCommentID["review-comment-\(databaseId)"] = (token, thread.isResolved ?? false)
            }
        }

        for index in comments.indices {
            guard let thread = byCommentID[comments[index].id] else { continue }
            comments[index].resolveToken = thread.token
            comments[index].isResolved = thread.isResolved
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
                return decodeCloudComments(values)
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
            return decodeBitbucketComments(from: object)
        }
        throw PullRequestError.commandFailed(lastMessage)
    }

    /// Decodes the fixed shape of Bitbucket Cloud's `/pullrequests/N/comments`.
    private static func decodeCloudComments(_ values: [[String: Any]]) -> [PullRequestComment] {
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
                createdAt: (item["created_on"] as? String).flatMap(parseTimestamp),
                kind: .comment,
                path: inline?["path"] as? String,
                line: toLine ?? fromLine,
                side: toLine != nil ? .new : .old,
                replyToken: identifier,
                isResolved: resolution != nil,
                resolvedBy: BitbucketUser.name(from: resolution?["user"] as? [String: Any]),
                resolveToken: identifier
            )
        }
        .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    /// Walks the JSON for any comment-shaped object. Data Center nests replies
    /// in a `comments` array on the parent, so descend into those explicitly
    /// and carry the parent's id down.
    private static func decodeBitbucketComments(from object: Any) -> [PullRequestComment] {
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
                createdAt: timestamp.flatMap(parseTimestamp),
                kind: .comment,
                path: path,
                line: toLine ?? fromLine ?? anchorLine,
                side: isOldSide ? .old : .new,
                replyToken: dictionary["id"].map { "\($0)" },
                isResolved: isResolved,
                resolvedBy: BitbucketUser.name(from: resolver),
                resolveToken: dictionary["id"].map { "\($0)" }
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
