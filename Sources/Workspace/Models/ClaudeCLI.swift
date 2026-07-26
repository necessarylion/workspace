import Foundation

/// Which `claude` this Mac has, and what that particular one understands.
///
/// The flags are not the same from one version to the next: what a recent
/// Claude Code calls `--permission-mode auto` an older one calls `default`, and
/// `--effort` only exists on the newer ones. Passing a flag it does not know is
/// not a degraded chat, it is a process that refuses to start — so the CLI is
/// asked what it accepts, once, and the chat only ever sends it that.
struct ClaudeCLIInfo: Sendable {
    /// The absolute path to run, or nil when Claude Code is not installed.
    var executable: String?
    /// What `--permission-mode` accepts. Empty means the help could not be
    /// read, which is treated as "no idea, send what was asked for".
    var permissionModes: Set<String> = []
    var supportsEffort = false

    var isInstalled: Bool { executable != nil }

    /// Whether this CLI knows any of the names a mode goes by.
    func supports(_ mode: ClaudePermissionMode) -> Bool {
        permissionModes.isEmpty || mode.flagCandidates.contains { permissionModes.contains($0) }
    }

    /// What to actually pass for a mode: the first name this CLI knows it by.
    func flagValue(for mode: ClaudePermissionMode) -> String {
        guard !permissionModes.isEmpty else { return mode.flagCandidates[0] }
        return mode.flagCandidates.first { permissionModes.contains($0) }
            ?? permissionModes.first
            ?? mode.flagCandidates[0]
    }
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
            permissionModes: permissionModes(in: help.stdout),
            supportsEffort: help.stdout.contains("--effort")
        )
    }

    /// Pulls the quoted list out of
    /// `--permission-mode <mode>  … (choices: "acceptEdits", "auto", …)`.
    /// The help wraps that list over several lines, so it is read as one run of
    /// text between `choices:` and the bracket that closes it.
    private static func permissionModes(in help: String) -> Set<String> {
        guard let flag = help.range(of: "--permission-mode") else { return [] }
        let tail = help[flag.upperBound...]
        guard let choices = tail.range(of: "choices:"),
              let close = tail[choices.upperBound...].firstIndex(of: ")") else { return [] }

        let names = tail[choices.upperBound..<close]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"\n\t")) }
            .filter { !$0.isEmpty }
        return Set(names)
    }
}
