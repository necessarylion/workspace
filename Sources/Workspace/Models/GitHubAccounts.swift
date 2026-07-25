import Foundation

/// One account `gh` is logged in to on github.com.
struct GitHubAccount: Identifiable, Sendable, Hashable {
    let login: String
    /// The one `gh` would use on its own, when a repository has no choice.
    let isActive: Bool

    var id: String { login }
}

/// Which GitHub account each repository talks to.
///
/// `gh` keeps a single active account per host, so switching it globally would
/// make two repositories owned by different accounts fight over it — and would
/// change what the user's own shell does. The choice is remembered per
/// repository instead, and every `gh` call the app makes carries that account's
/// token in `GH_TOKEN`, which overrides the active account for that one
/// invocation only.
///
/// `WorkspaceStore` owns the persisted copy of the choices and pushes them in
/// here; this is what the CLI layer reads.
actor GitHubAccounts {
    static let shared = GitHubAccounts()

    /// Repository path → account login.
    private var selections: [String: String] = [:]
    /// Login → token. In memory only: the tokens live in the user's keychain,
    /// and asking `gh` for one costs a keychain round trip.
    private var tokens: [String: String] = [:]
    private var cached: [GitHubAccount]?

    /// Accounts `gh auth status` reports for github.com.
    func available(reloading: Bool = false) async -> [GitHubAccount] {
        if !reloading, let cached { return cached }
        let accounts = await Self.readStatus()
        cached = accounts
        return accounts
    }

    func select(_ login: String?, forRepositoryAt path: String) {
        selections[path] = login
    }

    func replaceSelections(_ map: [String: String]) {
        selections = map
    }

    /// Environment for a `gh` call made inside `directory`. Empty when the
    /// repository it belongs to has no account recorded, which leaves `gh`
    /// using whichever account is active.
    func environment(for directory: URL?) async -> [String: String] {
        guard let login = selection(covering: directory),
              let token = await token(for: login) else { return [:] }
        return ["GH_TOKEN": token]
    }

    /// The nearest enclosing repository's account, so a call made from a
    /// subdirectory still uses the right one.
    private func selection(covering directory: URL?) -> String? {
        guard let path = directory?.path else { return nil }
        return selections
            .filter { path == $0.key || path.hasPrefix($0.key + "/") }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    private func token(for login: String) async -> String? {
        if let token = tokens[login] { return token }
        let result = await Shell.run(
            ["gh", "auth", "token", "--hostname", "github.com", "--user", login],
            timeout: 20
        )
        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.isSuccess, !token.isEmpty else { return nil }
        tokens[login] = token
        return token
    }

    /// `gh auth status` has no JSON mode, so its lines are read as they come:
    ///
    ///     ✓ Logged in to github.com account octocat (keyring)
    ///       - Active account: true
    private static func readStatus() async -> [GitHubAccount] {
        let result = await Shell.run(
            ["gh", "auth", "status", "--hostname", "github.com"],
            timeout: 30
        )

        var accounts: [GitHubAccount] = []
        var pending: String?

        func flush(active: Bool) {
            guard let login = pending else { return }
            accounts.append(GitHubAccount(login: login, isActive: active))
            pending = nil
        }

        // `gh` writes this to stdout, but has used stderr in the past.
        for line in (result.stdout + "\n" + result.stderr).split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.contains("Logged in to"), let range = text.range(of: "account ") {
                // An account with no "Active account" line of its own is not
                // the active one.
                flush(active: false)
                pending = text[range.upperBound...].split(separator: " ").first.map(String.init)
            } else if text.hasPrefix("- Active account:") {
                flush(active: text.hasSuffix("true"))
            }
        }
        flush(active: false)

        // A lone account is the active one whether or not `gh` says so.
        if accounts.count == 1 {
            accounts = [GitHubAccount(login: accounts[0].login, isActive: true)]
        }
        return accounts
    }
}

/// A repository waiting for the user to say which account it belongs to.
struct GitHubAccountPrompt: Identifiable {
    let projectID: URL
    /// Pre-selected in the sheet: the account `gh` would use on its own.
    let suggested: String

    var id: URL { projectID }
}

/// Runs `gh` as whichever account the repository at `directory` uses.
///
/// Every GitHub call in the app goes through here rather than `Shell.run`
/// directly, so the account choice applies without each call site knowing
/// about it.
enum GitHubCLI {
    static func run(
        _ arguments: [String],
        in directory: URL?,
        timeout: TimeInterval = 60
    ) async -> Shell.Output {
        let environment = await GitHubAccounts.shared.environment(for: directory)
        return await Shell.run(["gh"] + arguments, in: directory, timeout: timeout, environment: environment)
    }

    /// The same command, but for the user's own terminal. The shell fetches the
    /// token itself so nothing secret is printed on screen.
    static func terminalCommand(_ command: String, account: String?) -> String {
        guard let account, !account.isEmpty else { return command }
        let token = "$(gh auth token --hostname github.com --user \(Shell.quote(account)))"
        return "GH_TOKEN=\(token) \(command)"
    }
}
