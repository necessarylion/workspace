import Foundation

enum GitHostKind: String, Sendable {
    case github
    case bitbucket
    case unknown

    var displayName: String {
        switch self {
        case .github: "GitHub"
        case .bitbucket: "Bitbucket"
        case .unknown: "Git"
        }
    }

    var symbol: String {
        switch self {
        case .github: "chevron.left.forwardslash.chevron.right"
        case .bitbucket: "bucket"
        case .unknown: "questionmark.circle"
        }
    }

    /// CLI used to talk to this host.
    var cli: String? {
        switch self {
        case .github: "gh"
        case .bitbucket: "bkt"
        case .unknown: nil
        }
    }
}

/// What we can learn about a repository from its `origin` remote.
struct RemoteInfo: Sendable, Hashable {
    var kind: GitHostKind
    /// GitHub owner, Bitbucket Cloud workspace, or Data Center project key.
    var owner: String
    var slug: String
    var rawURL: String

    var fullName: String { owner.isEmpty ? slug : "\(owner)/\(slug)" }

    var webURL: URL? {
        switch kind {
        case .github: URL(string: "https://github.com/\(owner)/\(slug)")
        case .bitbucket: URL(string: "https://bitbucket.org/\(owner)/\(slug)")
        case .unknown: nil
        }
    }

    /// Parses SSH (`git@host:owner/repo.git`), SSH-with-scheme
    /// (`ssh://git@host:7999/scm/PROJ/repo.git`) and HTTPS remotes.
    ///
    /// The host is matched loosely, because SSH config aliases like
    /// `bitbucket-ajzkk` or `github-work` are common.
    static func parse(remoteURL raw: String) -> RemoteInfo {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return RemoteInfo(kind: .unknown, owner: "", slug: "", rawURL: raw)
        }

        var hostPart = ""
        var path = ""

        if let range = trimmed.range(of: "://") {
            // scheme://[user@]host[:port]/path
            let afterScheme = String(trimmed[range.upperBound...])
            let components = afterScheme.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            hostPart = String(components.first ?? "")
            path = components.count > 1 ? String(components[1]) : ""
        } else if let colon = trimmed.firstIndex(of: ":") {
            // [user@]host:path
            hostPart = String(trimmed[trimmed.startIndex..<colon])
            path = String(trimmed[trimmed.index(after: colon)...])
        } else {
            path = trimmed
        }

        // Strip user@ and :port from the host.
        if let at = hostPart.lastIndex(of: "@") {
            hostPart = String(hostPart[hostPart.index(after: at)...])
        }
        if let portColon = hostPart.firstIndex(of: ":") {
            hostPart = String(hostPart[hostPart.startIndex..<portColon])
        }

        let kind: GitHostKind
        let host = hostPart.lowercased()
        if host.contains("github") {
            kind = .github
        } else if host.contains("bitbucket") || host.contains("stash") {
            kind = .bitbucket
        } else {
            kind = .unknown
        }

        // Drop Data Center's /scm/ prefix, then take the last two components.
        var pieces = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.lowercased() != "scm" }

        if let last = pieces.last, last.hasSuffix(".git") {
            pieces[pieces.count - 1] = String(last.dropLast(4))
        }

        let slug = pieces.last ?? ""
        let owner = pieces.count >= 2 ? pieces[pieces.count - 2] : ""

        return RemoteInfo(kind: kind, owner: owner, slug: slug, rawURL: trimmed)
    }

    /// Reads `origin` (or the first remote) for a checkout.
    static func load(for directory: URL) async -> RemoteInfo? {
        let result = await Shell.run(["git", "remote", "get-url", "origin"], in: directory, timeout: 15)
        guard result.isSuccess else { return nil }
        let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        return parse(remoteURL: url)
    }
}
