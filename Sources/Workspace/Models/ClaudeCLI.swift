import Foundation

/// Which `claude` this Mac has, and what that particular one understands.
///
/// The flags are not the same from one version to the next, and passing one it
/// does not know is not a degraded run, it is a process that refuses to start —
/// so the CLI is asked what it accepts, once, and only ever sent that.
struct ClaudeCLIInfo: Sendable {
    /// The absolute path to run, or nil when Claude Code is not installed.
    var executable: String?
    /// Whether a one-shot run can be told to leave no transcript behind.
    var supportsNoSessionPersistence = false
    /// Whether a new conversation can be told what to call itself. Knowing the
    /// id up front is what lets a running conversation be told apart from the
    /// transcript it is writing — see ``WorkspaceStore/openClaude(in:)``.
    var supportsSessionID = false

    var isInstalled: Bool { executable != nil }
}

/// Resolved once and shared: finding the binary means starting an interactive
/// shell, and reading its help means starting the binary.
actor ClaudeCLI {
    static let shared = ClaudeCLI()

    private var resolution: Task<ClaudeCLIInfo, Never>?

    func info() async -> ClaudeCLIInfo {
        if let resolution { return await resolution.value }
        let task = Task { await Self.resolve() }
        resolution = task
        return await task.value
    }

    /// Forgets what was learned, for after Claude Code is installed or updated
    /// from the Requirements sheet.
    func reset() {
        resolution = nil
    }

    private static func resolve() async -> ClaudeCLIInfo {
        guard let executable = await Shell.interactiveLocation(of: "claude") else {
            return ClaudeCLIInfo(executable: nil)
        }
        let help = await Shell.runScript("\(Shell.quote(executable)) --help", timeout: 25)
        guard help.isSuccess else {
            return ClaudeCLIInfo(executable: executable)
        }
        return ClaudeCLIInfo(
            executable: executable,
            supportsNoSessionPersistence: help.stdout.contains("--no-session-persistence"),
            supportsSessionID: help.stdout.contains("--session-id")
        )
    }
}
