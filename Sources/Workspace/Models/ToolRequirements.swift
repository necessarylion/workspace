import Foundation

/// A command line tool the app drives.
///
/// Nothing is bundled: `git`, `gh`, `bkt` and `claude` have to be on the user's
/// PATH, and half of them have to be logged in before a pull request loads.
/// Settings is where that is checked and fixed, so a missing tool is something
/// you see once in a list rather than as a failed request later.
enum RequiredTool: String, CaseIterable, Identifiable, Sendable {
    case git, gh, bkt, claude

    var id: String { rawValue }
    var executable: String { rawValue }

    var title: String {
        switch self {
        case .git: "Git"
        case .gh: "GitHub CLI"
        case .bkt: "Bitbucket CLI"
        case .claude: "Claude Code"
        }
    }

    var purpose: String {
        switch self {
        case .git: "Status, diffs, branches and checkouts."
        case .gh: "GitHub pull requests, comments and reviews."
        case .bkt: "Bitbucket pull requests, comments and reviews."
        case .claude: "The Claude actions that drive a repository's terminal."
        }
    }

    /// Without git nothing works; the host CLIs only matter for the hosts you
    /// actually have repositories on, so a missing one is a note, not an alarm.
    var isEssential: Bool { self == .git }

    /// A key of ``BrandPath/all``, where there is a real mark for it.
    var brand: String? {
        switch self {
        case .git: "git"
        case .gh: "github"
        case .bkt: "bitbucket"
        case .claude: nil
        }
    }

    /// Used when there is no brand mark.
    var symbol: String {
        switch self {
        case .claude: "sparkles"
        default: "terminal"
        }
    }

    /// What the Install button runs. Homebrew is what a Mac developer has;
    /// git is the exception, since the command line tools carry it.
    var installCommand: String {
        switch self {
        case .git: "xcode-select --install"
        case .gh: "brew install gh"
        case .bkt: "brew install avivsinai/tap/bitbucket-cli"
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        }
    }

    var needsHomebrew: Bool { installCommand.hasPrefix("brew ") }

    /// The sign-in command, and whether it can simply be run.
    ///
    /// `bkt` is the one that cannot: it logs in to a *host*, and only the user
    /// knows whether that is bitbucket.org or their company's Data Center. Its
    /// command is typed into the terminal with the Cloud host filled in and left
    /// for them to correct before pressing Return.
    var signIn: (command: String, autoRun: Bool)? {
        switch self {
        // git authenticates over ssh/https itself, and `claude` asks for a login
        // the first time it runs.
        case .git, .claude: nil
        case .gh: ("gh auth login", true)
        case .bkt: ("bkt auth login https://bitbucket.org --kind cloud --web", false)
        }
    }

    var homepage: URL {
        switch self {
        case .git: URL(string: "https://git-scm.com")!
        case .gh: URL(string: "https://cli.github.com")!
        case .bkt: URL(string: "https://github.com/avivsinai/bitbucket-cli")!
        case .claude: URL(string: "https://docs.claude.com/en/docs/claude-code/overview")!
        }
    }

    /// Asks the tool itself whether it is there, and who it is logged in as.
    func probe() async -> ToolState {
        let version = await Self.version(of: executable)
        guard let version else { return ToolState(version: nil, account: .signedOut) }
        return ToolState(version: version, account: await account())
    }

    private static func version(of executable: String) async -> String? {
        let result = await Shell.run([executable, "--version"], timeout: 20)
        // A tool that is not on PATH exits non-zero with "command not found".
        guard result.isSuccess else { return nil }
        let line = result.stdout
            .split(separator: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return line?.trimmingCharacters(in: .whitespaces)
    }

    private func account() async -> ToolState.Account {
        switch self {
        case .git, .claude:
            return .notNeeded
        case .gh:
            // The same list the per-repository account picker uses, reloaded so
            // a sign-in that just happened is picked up.
            let accounts = await GitHubAccounts.shared.available(reloading: true)
            guard !accounts.isEmpty else { return .signedOut }
            return .signedIn(accounts.map(\.login).joined(separator: ", "))
        case .bkt:
            return await Self.bitbucketAccount()
        }
    }

    /// `bkt auth status --json` lists every host it holds credentials for.
    private static func bitbucketAccount() async -> ToolState.Account {
        let result = await Shell.run(["bkt", "auth", "status", "--json"], timeout: 30)
        guard result.isSuccess else { return .signedOut }

        struct Status: Decodable {
            struct Host: Decodable {
                let key: String?
                let username: String?
            }
            let hosts: [Host]?
        }

        guard let status = try? JSONDecoder().decode(Status.self, from: Data(result.stdout.utf8)),
              let hosts = status.hosts, !hosts.isEmpty else {
            // An older `bkt` without `--json` still exits zero when logged in.
            return result.stdout.contains("user:") ? .signedIn("Signed in") : .signedOut
        }

        let described = hosts.map { host in
            let name = (host.key ?? "").replacingOccurrences(of: "api.bitbucket.org", with: "bitbucket.org")
            guard let user = host.username, !user.isEmpty else { return name }
            return name.isEmpty ? user : "\(user) on \(name)"
        }
        return .signedIn(described.joined(separator: ", "))
    }
}

/// What one tool looks like on this Mac right now.
struct ToolState: Sendable {
    enum Account: Sendable, Equatable {
        /// The tool has no sign-in of its own.
        case notNeeded
        case signedOut
        /// Who it is logged in as, ready to show.
        case signedIn(String)
    }

    /// The tool's own `--version` line, or nil when it is not on PATH.
    var version: String?
    var account: Account

    var isInstalled: Bool { version != nil }

    var needsSignIn: Bool {
        isInstalled && account == .signedOut
    }
}

/// Which of the tools are installed and logged in.
///
/// Every check runs the tool itself rather than looking for a file, because the
/// answer has to match what the app's own commands will find: the same login
/// shell, the same resolved PATH.
@MainActor
@Observable
final class ToolInventory {
    private(set) var states: [RequiredTool: ToolState] = [:]
    private(set) var isChecking = false
    /// Homebrew installs most of them; without it those buttons cannot work.
    private(set) var hasHomebrew = true

    func state(of tool: RequiredTool) -> ToolState? { states[tool] }

    /// Tools that are installed but still need a sign-in, plus the ones missing
    /// altogether — what Settings has a badge for.
    var unresolved: [RequiredTool] {
        RequiredTool.allCases.filter { tool in
            guard let state = states[tool] else { return false }
            return !state.isInstalled || state.needsSignIn
        }
    }

    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        async let homebrew = Shell.isAvailable("brew")
        let probed = await withTaskGroup(of: (RequiredTool, ToolState).self) { group in
            for tool in RequiredTool.allCases {
                group.addTask { (tool, await tool.probe()) }
            }
            var result: [RequiredTool: ToolState] = [:]
            for await (tool, state) in group { result[tool] = state }
            return result
        }

        states = probed
        hasHomebrew = await homebrew
    }

    /// Re-checks a single tool, after an install or a sign-in.
    func refresh(_ tool: RequiredTool) async {
        states[tool] = await tool.probe()
        if tool.needsHomebrew {
            hasHomebrew = await Shell.isAvailable("brew")
        }
    }
}
