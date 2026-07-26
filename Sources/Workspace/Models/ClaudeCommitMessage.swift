import Foundation

/// Asks Claude Code to write the commit message for what is about to be
/// committed.
///
/// This is a one-shot `claude -p`, not a conversation: the chat pane's session
/// keeps a process up for a whole transcript, while this asks one question and
/// wants one line of prose back. The change goes in on **stdin** rather than in
/// the prompt argument, because a diff is easily larger than the command line a
/// process is allowed to have.
enum ClaudeCommitMessage {
    enum Failure: LocalizedError {
        case notInstalled
        case nothingToDescribe
        case claudeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                "Claude Code is not installed. Install it, or check Settings ▸ Requirements."
            case .nothingToDescribe:
                "Nothing to write a message about."
            case .claudeFailed(let message):
                message.isEmpty ? "Claude could not write a message." : message
            }
        }
    }

    /// What Claude is told to do. Short and fixed, so it can travel as the
    /// prompt argument while the change itself goes through stdin.
    private static let instruction = """
        Write the git commit message for the change on stdin. Answer with the \
        message itself and nothing else: no preamble, no explanation, no quotes \
        and no code fence. The first line is a summary under 72 characters in \
        the present tense, and it does not end with a full stop. Add a blank \
        line and a short body only when the change needs one. Follow the style \
        of the recent messages listed in the input, and never mention Claude or \
        this instruction.
        """

    /// How much diff is sent. A commit message comes from what changed, not
    /// from every line of it, and a large refactor would otherwise cost far
    /// more than the answer is worth.
    private static let diffLimit = 60_000

    /// `stagedOnly` follows what the Commit button would take: the index when
    /// anything is staged, the whole working tree when nothing is.
    static func write(
        in directory: URL,
        stagedOnly: Bool,
        branch: String?,
        recentSubjects: [String]
    ) async throws -> String {
        guard let executable = await ClaudeCLI.shared.info().executable else {
            throw Failure.notInstalled
        }

        let context = await context(
            in: directory,
            stagedOnly: stagedOnly,
            branch: branch,
            recentSubjects: recentSubjects
        )
        guard !context.isEmpty else { throw Failure.nothingToDescribe }

        // The context lives in a file for the same reason it is not an
        // argument: it is piped in, and a pipe written from here would need
        // draining while the tool runs.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-commit-\(UUID().uuidString).txt")
        try? context.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let script = "cat \(Shell.quote(file.path)) | \(Shell.quote(executable))"
            + " -p \(Shell.quote(instruction)) --output-format text"
        let result = await Shell.runScript(script, in: directory, timeout: 180)
        guard result.isSuccess else { throw Failure.claudeFailed(result.failureMessage) }

        let message = clean(result.stdout)
        guard !message.isEmpty else { throw Failure.claudeFailed(result.failureMessage) }
        return message
    }

    /// Everything Claude is shown: which branch this is, how the repository
    /// writes its messages, which files moved, and the change itself.
    private static func context(
        in directory: URL,
        stagedOnly: Bool,
        branch: String?,
        recentSubjects: [String]
    ) async -> String {
        async let statusTask = Shell.run(
            ["git", "status", "--porcelain=v1"],
            in: directory,
            timeout: 30,
            // Reading must not rewrite `.git/index`; see `GitStatus.load`.
            environment: ["GIT_OPTIONAL_LOCKS": "0"]
        )
        let diffArguments = stagedOnly ? ["--cached"] : ["HEAD"]
        async let statTask = Shell.run(
            ["git", "diff"] + diffArguments + ["--stat"],
            in: directory,
            timeout: 30,
            environment: ["GIT_OPTIONAL_LOCKS": "0"]
        )
        async let diffTask = Shell.run(
            ["git", "diff"] + diffArguments,
            in: directory,
            timeout: 60,
            environment: ["GIT_OPTIONAL_LOCKS": "0"]
        )

        let status = await statusTask.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stat = await statTask.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var diff = await diffTask.stdout
        guard !stat.isEmpty || !status.isEmpty else { return "" }

        if diff.count > diffLimit {
            diff = String(diff.prefix(diffLimit))
                + "\n\n[diff cut off here — the summary above lists every file]"
        }

        var text = ""
        if let branch { text += "Branch: \(branch)\n" }
        text += stagedOnly
            ? "Committing: the staged files only.\n"
            : "Committing: everything in the working tree — nothing is staged yet.\n"
        if !recentSubjects.isEmpty {
            text += "\nRecent commit messages in this repository, newest first:\n"
            text += recentSubjects.map { "- \($0)" }.joined(separator: "\n")
            text += "\n"
        }
        if !status.isEmpty {
            text += "\ngit status --porcelain:\n\(status)\n"
        }
        if !stat.isEmpty {
            text += "\nFiles changed:\n\(stat)\n"
        }
        if !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "\nThe change:\n\(diff)\n"
        }
        return text
    }

    /// Claude answers with the message alone, but a model that wrapped it in a
    /// code fence or quotes would otherwise put those straight into git.
    private static func clean(_ output: String) -> String {
        var lines = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true {
            lines.removeFirst()
            if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        }
        var message = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if message.count > 1, message.hasPrefix("\""), message.hasSuffix("\"") {
            message = String(message.dropFirst().dropLast())
        }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
