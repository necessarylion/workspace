import Foundation

/// Which branch a repository calls its own — `main` on one, `develop` on the
/// next, `master` on the one that never moved.
///
/// The host is asked rather than a list of likely names guessed at: a checkout
/// can hold `main`, `develop` and `master` all at once, and only GitHub or
/// Bitbucket knows which of them a pull request is opened against. `gh repo
/// view` and `bkt api` answer that in one call.
///
/// Git itself is the fallback, and only that: `refs/remotes/origin/HEAD` is
/// written by the clone and says the same thing, but it goes stale when the
/// host's default moves and is missing altogether from a repository that was
/// `git init`ed here. A folder with no remote at all has nobody to ask, so the
/// usual names are tried against the branches that exist — the button names the
/// branch it will switch to, so a wrong guess is visible before it is clicked.
enum DefaultBranch {
    /// The names worth trying when there is no host and no `origin/HEAD`, in
    /// the order a repository that has more than one of them usually means.
    private static let conventionalNames = ["main", "master", "develop", "dev", "trunk"]

    /// Nil when nothing could name a branch — no host, no CLI, no `origin/HEAD`
    /// and none of the usual names among the local branches.
    static func load(remote: RemoteInfo?, in directory: URL) async -> String? {
        switch remote?.kind {
        case .github:
            if let name = await gitHub(in: directory) { return name }
        case .bitbucket:
            if let remote, let name = await bitbucket(remote: remote, in: directory) { return name }
        case .unknown, nil:
            break
        }
        return await fromGit(in: directory)
    }

    // MARK: - Hosts

    /// `gh repo view` reads the repository from the checkout's own `origin`, so
    /// there is nothing to pass it. The account this repository is pinned to is
    /// the one that asks — a private repository answers nobody else.
    private static func gitHub(in directory: URL) async -> String? {
        guard await Shell.isAvailable("gh") else { return nil }
        let result = await GitHubCLI.run(
            ["repo", "view", "--json", "defaultBranchRef"],
            in: directory,
            timeout: 30
        )
        guard result.isSuccess,
              let object = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              let ref = object["defaultBranchRef"] as? [String: Any]
        else { return nil }
        return name(ref["name"])
    }

    /// Cloud first, then the two paths Data Center has used for the same thing.
    /// Both flavours answer through `bkt api`; the wrong one answers nothing,
    /// which is why this is a list rather than a branch on the flavour — the app
    /// never learns which flavour a host is, it just asks.
    private static func bitbucket(remote: RemoteInfo, in directory: URL) async -> String? {
        guard !remote.owner.isEmpty, !remote.slug.isEmpty,
              await Shell.isAvailable("bkt")
        else { return nil }
        let repository = "\(remote.owner)/\(remote.slug)"

        // Cloud: the repository object carries its default as `mainbranch`.
        if let object = await PullRequestService.bitbucketAPIObject(
            "/2.0/repositories/\(repository)",
            params: ["fields=mainbranch.name"],
            in: directory,
            timeout: 30
        ) as? [String: Any],
            let branch = object["mainbranch"] as? [String: Any],
            let name = name(branch["name"]) {
            return name
        }

        // Data Center: `default-branch` on the newer releases, `branches/default`
        // on the ones before it. Both answer `{ id, displayId }`, where
        // `displayId` is the branch name and `id` its full ref.
        let paths = [
            "/rest/api/1.0/projects/\(remote.owner)/repos/\(remote.slug)/default-branch",
            "/rest/api/1.0/projects/\(remote.owner)/repos/\(remote.slug)/branches/default",
        ]
        for path in paths {
            guard let object = await PullRequestService.bitbucketAPIObject(
                path,
                in: directory,
                timeout: 30
            ) as? [String: Any] else { continue }
            if let name = name(object["displayId"]) { return name }
            if let name = name(object["id"]) { return stripRefPrefix(name) }
        }
        return nil
    }

    // MARK: - Git

    /// What the clone left behind, and then the usual names.
    private static func fromGit(in directory: URL) async -> String? {
        let head = await Shell.run(
            ["git", "symbolic-ref", "--short", "--quiet", "refs/remotes/origin/HEAD"],
            in: directory,
            timeout: 15
        )
        if head.isSuccess,
           let ref = name(head.stdout),
           // `origin/main` — the remote's own name is not part of the branch.
           let branch = ref.split(separator: "/", maxSplits: 1).last.map(String.init),
           !branch.isEmpty {
            return branch
        }

        let listed = await Shell.run(
            ["git", "for-each-ref", "--format=%(refname:short)", "refs/heads"],
            in: directory,
            timeout: 15
        )
        guard listed.isSuccess else { return nil }
        let local = Set(
            listed.stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        )
        return conventionalNames.first { local.contains($0) }
    }

    // MARK: - Helpers

    /// A trimmed, non-empty string, or nothing.
    private static func name(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stripRefPrefix(_ ref: String) -> String {
        ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
    }
}
