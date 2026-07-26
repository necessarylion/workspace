import Foundation

/// Which host account belongs to which commit email.
///
/// A local `git log` knows a name and an address and nothing else, so the same
/// person can show their GitHub picture and login on a pull request tile and,
/// two rows below, whatever they happened to set `user.name` to and plain
/// initials on the commit they just pushed.
///
/// The host knows the connection: its own commit listing carries both what git
/// recorded and the account it belongs to. This asks for that listing once per
/// repository, and what it learns is keyed by address alone, so a person
/// recognised in one repository is recognised in all of them.
@MainActor
@Observable
final class AvatarDirectory {
    static let shared = AvatarDirectory()

    /// What the host knows about whoever commits from one address.
    struct Account: Sendable, Hashable {
        var login: String?
        var avatarURL: URL?
    }

    private var byEmail: [String: Account] = [:]
    /// Addresses the host had no account for — a commit from a machine user, or
    /// from someone who left. Remembered so one of them does not make every
    /// later refresh ask the host again.
    private var unknown: Set<String> = []
    /// Repositories with a request out right now.
    private var asking: Set<URL> = []

    private init() {}

    /// What the host said about an address, once it has been asked.
    func account(forEmail email: String) -> Account? {
        byEmail[normalise(email)]
    }

    /// Looks up the addresses among `emails` that are still unaccounted for.
    ///
    /// Does nothing when they are all either known or already known to be
    /// unknown, which is the usual case: the dashboard re-reads its commits
    /// every time it comes back on screen, and that must not become a request
    /// per refresh.
    func learn(emails: [String], remote: RemoteInfo?, branch: String?, in directory: URL) {
        guard let remote, remote.kind != .unknown, !asking.contains(directory) else { return }
        let wanted = Set(emails.filter { $0.contains("@") }.map(normalise))
            .subtracting(byEmail.keys)
            .subtracting(unknown)
        guard !wanted.isEmpty else { return }

        asking.insert(directory)
        Task {
            let found = await fetch(remote: remote, branch: branch, in: directory)
            for (email, account) in found where byEmail[email] == nil {
                byEmail[email] = account
            }
            // Whatever the listing did not name stays unnamed until the app is
            // launched again; asking a second time would only cost a request.
            unknown.formUnion(wanted.subtracting(found.keys))
            asking.remove(directory)
        }
    }

    private func normalise(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: - Asking the host

    private func fetch(
        remote: RemoteInfo,
        branch: String?,
        in directory: URL
    ) async -> [String: Account] {
        switch remote.kind {
        case .github: await fetchGitHub(branch: branch, in: directory)
        case .bitbucket: await fetchBitbucket(remote: remote, in: directory)
        case .unknown: [:]
        }
    }

    /// GitHub's commit listing pairs `commit.author.email` — what git recorded —
    /// with `author`, the account it was matched to. That pairing is the whole
    /// point of the request.
    private func fetchGitHub(branch: String?, in directory: URL) async -> [String: Account] {
        struct Item: Decodable {
            struct GitCommit: Decodable {
                struct Identity: Decodable { let email: String? }
                let author: Identity?
            }
            struct User: Decodable {
                let login: String?
                let avatarURL: String?

                enum CodingKeys: String, CodingKey {
                    case login
                    case avatarURL = "avatar_url"
                }
            }
            let commit: GitCommit?
            /// Absent when git's address matches no account on the host.
            let author: User?
        }

        // The branch that is checked out first, since its commits are the ones
        // on screen; it may never have been pushed, and then the default branch
        // is still worth asking about — the same people work on both.
        var paths = ["repos/{owner}/{repo}/commits?per_page=100"]
        if let branch, !branch.isEmpty {
            paths.insert("repos/{owner}/{repo}/commits?per_page=100&sha=\(branch)", at: 0)
        }

        for path in paths {
            let result = await GitHubCLI.run(["api", path], in: directory, timeout: 30)
            guard result.isSuccess,
                  let items = try? JSONDecoder().decode([Item].self, from: Data(result.stdout.utf8))
            else { continue }

            var found: [String: Account] = [:]
            for item in items {
                guard let email = item.commit?.author?.email, let author = item.author else {
                    continue
                }
                found[normalise(email)] = Account(
                    login: author.login,
                    avatarURL: AvatarURL.hosted(author.avatarURL)
                        ?? AvatarURL.gitHub(login: author.login)
                )
            }
            if !found.isEmpty { return found }
        }
        return [:]
    }

    /// Bitbucket Cloud writes the identity as `Name <email>` in `author.raw` and
    /// hangs the account, when it matched one, off `author.user`. Data Center
    /// serves its pictures behind the same login the API needs, so an `<img>`
    /// would only get a redirect to a sign-in page — it is left alone.
    private func fetchBitbucket(remote: RemoteInfo, in directory: URL) async -> [String: Account] {
        guard !remote.owner.isEmpty, !remote.slug.isEmpty else { return [:] }

        let result = await Shell.run(
            ["bkt", "api", "/2.0/repositories/\(remote.owner)/\(remote.slug)/commits",
             "--param", "pagelen=100"],
            in: directory,
            timeout: 30
        )
        guard result.isSuccess,
              let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)),
              let values = (object as? [String: Any])?["values"] as? [[String: Any]]
        else { return [:] }

        var found: [String: Account] = [:]
        for item in values {
            let author = item["author"] as? [String: Any]
            guard let raw = author?["raw"] as? String, let email = Self.email(inRaw: raw),
                  let user = author?["user"] as? [String: Any]
            else { continue }

            let links = user["links"] as? [String: Any]
            let href = (links?["avatar"] as? [String: Any])?["href"] as? String
            found[normalise(email)] = Account(
                login: BitbucketUser.login(from: user),
                avatarURL: AvatarURL.hosted(href)
            )
        }
        return found
    }

    /// The address out of `Name <name@example.com>`.
    private static func email(inRaw raw: String) -> String? {
        guard let open = raw.firstIndex(of: "<"), let close = raw.lastIndex(of: ">"), open < close
        else { return nil }
        return String(raw[raw.index(after: open)..<close])
    }
}
