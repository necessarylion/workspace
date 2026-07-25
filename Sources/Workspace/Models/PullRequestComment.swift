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

    var canReply: Bool { replyToken != nil }

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
    var comment: PullRequestComment
    var replies: [PullRequestCommentNode] = []

    var id: String { comment.id }
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
                    body: body,
                    createdAt: review.submittedAt.flatMap(parseTimestamp),
                    kind: .review(state: state),
                    path: nil,
                    replyToken: nil
                )
            )
        }

        items.append(contentsOf: await gitHubReviewComments(for: pr, in: directory))

        return items.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
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
            struct User: Decodable { let login: String? }
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
    private static func decodeJSONArrayPages<T: Decodable>(
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
            let body = (item["content"] as? [String: Any])?["raw"] as? String ?? ""
            guard !body.isEmpty else { return nil }

            let user = item["user"] as? [String: Any]
            let author = user?["display_name"] as? String
                ?? user?["nickname"] as? String
                ?? "unknown"

            let identifier = "\(item["id"] ?? "cloud-\(index)")"
            let parent = (item["parent"] as? [String: Any])?["id"]
            let inline = item["inline"] as? [String: Any]
            // `to` is a line in the file after the change, `from` before it.
            let toLine = inline?["to"] as? Int
            let fromLine = inline?["from"] as? Int

            return PullRequestComment(
                id: identifier,
                parentID: parent.map { "\($0)" },
                author: author,
                body: body,
                createdAt: (item["created_on"] as? String).flatMap(parseTimestamp),
                kind: .comment,
                path: inline?["path"] as? String,
                line: toLine ?? fromLine,
                side: toLine != nil ? .new : .old,
                replyToken: identifier
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
            let content = (dictionary["content"] as? [String: Any])?["raw"] as? String
                ?? dictionary["text"] as? String
                ?? dictionary["body"] as? String
            guard let content, !content.isEmpty else { return nil }

            let userDictionary = (dictionary["user"] ?? dictionary["author"]) as? [String: Any]
            let author = userDictionary?["display_name"] as? String
                ?? userDictionary?["displayName"] as? String
                ?? userDictionary?["username"] as? String
                ?? userDictionary?["name"] as? String
                ?? "unknown"

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

            return PullRequestComment(
                id: identifier,
                parentID: parent.map { "\($0)" },
                author: author,
                body: content,
                createdAt: timestamp.flatMap(parseTimestamp),
                kind: .comment,
                path: path,
                line: toLine ?? fromLine ?? anchorLine,
                side: isOldSide ? .old : .new,
                replyToken: dictionary["id"].map { "\($0)" }
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

    static func parseTimestamp(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        if let date = ISO8601DateFormatter().date(from: string) { return date }
        // Bitbucket Data Center sends epoch milliseconds.
        if let milliseconds = Double(string) {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        return nil
    }
}
