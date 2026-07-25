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

    var id: String
    var author: String
    var body: String
    var createdAt: Date?
    var kind: Kind
    /// Set when the comment is anchored to a file in the diff.
    var path: String?
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
        let result = await Shell.run(
            ["gh", "pr", "view", "\(pr.number)", "--json", "comments,reviews"],
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
                    id: comment.id ?? "comment-\(index)",
                    author: comment.author?.login ?? "unknown",
                    body: comment.body ?? "",
                    createdAt: comment.createdAt.flatMap(parseTimestamp),
                    kind: .comment,
                    path: nil
                )
            )
        }
        for (index, review) in (response.reviews ?? []).enumerated() {
            // Reviews with no body are just an approval click; keep them, the
            // state is the message.
            let state = review.state ?? "COMMENTED"
            items.append(
                PullRequestComment(
                    id: review.id ?? "review-\(index)",
                    author: review.author?.login ?? "unknown",
                    body: review.body ?? "",
                    createdAt: review.submittedAt.flatMap(parseTimestamp),
                    kind: .review(state: state),
                    path: nil
                )
            )
        }

        return items.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
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

            return PullRequestComment(
                id: "\(item["id"] ?? "cloud-\(index)")",
                author: author,
                body: body,
                createdAt: (item["created_on"] as? String).flatMap(parseTimestamp),
                kind: .comment,
                path: (item["inline"] as? [String: Any])?["path"] as? String
            )
        }
        .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    /// Walks the JSON for any array of comment-shaped objects.
    private static func decodeBitbucketComments(from object: Any) -> [PullRequestComment] {
        var found: [PullRequestComment] = []

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

            let path = ((dictionary["inline"] as? [String: Any])?["path"] as? String)
                ?? ((dictionary["anchor"] as? [String: Any])?["path"] as? String)

            return PullRequestComment(
                id: "\(dictionary["id"] ?? "bitbucket-\(index)")",
                author: author,
                body: content,
                createdAt: timestamp.flatMap(parseTimestamp),
                kind: .comment,
                path: path
            )
        }

        func walk(_ value: Any, key: String?) {
            if let dictionary = value as? [String: Any] {
                for (childKey, child) in dictionary {
                    walk(child, key: childKey)
                }
                return
            }
            guard let array = value as? [Any], let key,
                  key.lowercased().contains("comment") else {
                if let array = value as? [Any] {
                    for item in array { walk(item, key: key) }
                }
                return
            }
            for (index, item) in array.enumerated() {
                guard let dictionary = item as? [String: Any] else { continue }
                if let decoded = comment(from: dictionary, index: index) {
                    found.append(decoded)
                }
            }
        }

        walk(object, key: nil)
        return found.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
    }

    // MARK: - Writing

    /// Posts a comment. Returns nothing on success, throws with the CLI's own
    /// message otherwise.
    static func postComment(_ body: String, on pr: PullRequest, in directory: URL) async throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        switch pr.host {
        case .github:
            let result = await Shell.run(
                ["gh", "pr", "comment", "\(pr.number)", "--body", trimmed],
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
