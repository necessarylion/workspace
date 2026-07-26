import Foundation

/// Runs command line tools (`git`, `gh`, `bkt`, `claude`) off the main actor.
///
/// Everything goes through a login shell on purpose: a GUI app inherits a bare
/// `PATH`, so `gh` in /opt/homebrew/bin would not be found otherwise. A login
/// shell alone is not enough either — version managers (gvm, nvm, pyenv) extend
/// `PATH` from ~/.zshrc, which zsh only reads when it is *interactive*, so `bkt`
/// under ~/.gvm stays invisible. `InteractivePath` resolves that fuller `PATH`
/// once and every command inherits it.
enum Shell {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String

        var isSuccess: Bool { status == 0 }
        /// stderr first — tools report the useful message there.
        var failureMessage: String {
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : text
        }
    }

    /// The user's login shell, falling back to zsh.
    static var loginShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// The `PATH` every command here runs with, for the one runner that cannot
    /// go through `run`/`runScript`: ``StreamingShellProcess`` stays up for a
    /// whole conversation, so it starts its process itself and needs the same
    /// answer this resolved once.
    static func resolvedPath() async -> String? {
        await InteractivePath.shared.value()
    }

    /// Where a tool actually is, as the user's own prompt would find it.
    ///
    /// Asking `command -v` through `runScript` is not the same question. That
    /// runs a **login** shell, and a login shell re-reads ~/.zprofile — where
    /// `brew shellenv` puts /opt/homebrew/bin back in front of whatever `PATH`
    /// we handed it. A tool installed in two places is then found in the copy
    /// the user's own prompt would *not* use, which is how the chat ended up
    /// driving a `claude` two hundred versions behind the one they run.
    ///
    /// An interactive shell has the last word on `PATH`, so it gets asked, and
    /// the absolute path it gives back settles the question for good.
    static func interactiveLocation(of tool: String) async -> String? {
        // A marker, because an interactive rc file prints whatever it likes.
        let marker = "__workspace_which__"
        let output = await execute(
            ["-ilc", "printf '\\n\(marker)%s\\n' \"$(command -v \(quote(tool)) 2>/dev/null)\""],
            timeout: 20
        )
        guard let line = output.stdout
            .split(separator: "\n")
            .last(where: { $0.hasPrefix(marker) })
        else { return nil }

        let path = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    static func run(
        _ arguments: [String],
        in directory: URL? = nil,
        timeout: TimeInterval = 60,
        environment: [String: String] = [:]
    ) async -> Output {
        let command = arguments.map(quote).joined(separator: " ")
        return await runScript(command, in: directory, timeout: timeout, environment: environment)
    }

    /// `environment` is merged on top of the app's own; it is passed to the
    /// process rather than written into the script so a secret like `GH_TOKEN`
    /// never shows up in the command line other processes can read.
    static func runScript(
        _ script: String,
        in directory: URL? = nil,
        timeout: TimeInterval = 60,
        environment: [String: String] = [:]
    ) async -> Output {
        // The resolved PATH goes in first, so a caller that passes its own still
        // wins.
        var merged: [String: String] = [:]
        if let path = await InteractivePath.shared.value() {
            merged["PATH"] = path
        }
        merged.merge(environment) { _, new in new }
        return await execute(["-lc", script], in: directory, timeout: timeout, environment: merged)
    }

    fileprivate static func execute(
        _ arguments: [String],
        in directory: URL? = nil,
        timeout: TimeInterval = 60,
        environment: [String: String] = [:]
    ) async -> Output {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: loginShell)
            process.arguments = arguments
            if let directory {
                process.currentDirectoryURL = directory
            }
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            }

            // Output goes to temp files rather than pipes: a pipe whose buffer
            // fills up would block the child until we read it, and draining two
            // pipes concurrently is not possible from an async context.
            let temporary = FileManager.default.temporaryDirectory
            let outURL = temporary.appendingPathComponent("workspace-\(UUID().uuidString).out")
            let errURL = temporary.appendingPathComponent("workspace-\(UUID().uuidString).err")
            FileManager.default.createFile(atPath: outURL.path, contents: nil)
            FileManager.default.createFile(atPath: errURL.path, contents: nil)
            defer {
                try? FileManager.default.removeItem(at: outURL)
                try? FileManager.default.removeItem(at: errURL)
            }

            guard let outHandle = try? FileHandle(forWritingTo: outURL),
                  let errHandle = try? FileHandle(forWritingTo: errURL) else {
                return Output(status: -1, stdout: "", stderr: "Could not create temporary output files.")
            }
            process.standardOutput = outHandle
            process.standardError = errHandle

            do {
                try process.run()
            } catch {
                try? outHandle.close()
                try? errHandle.close()
                return Output(status: -1, stdout: "", stderr: error.localizedDescription)
            }

            // Kill runaway network calls so the UI never waits forever.
            let watched = process
            let watchdog = DispatchWorkItem {
                if watched.isRunning { watched.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

            process.waitUntilExit()
            watchdog.cancel()
            try? outHandle.close()
            try? errHandle.close()

            return Output(
                status: process.terminationStatus,
                stdout: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
                stderr: (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            )
        }.value
    }

    /// Single-quotes an argument for safe interpolation into the shell command.
    static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether a tool is on the resolved PATH.
    static func isAvailable(_ tool: String) async -> Bool {
        await runScript("command -v \(quote(tool))", timeout: 10).isSuccess
    }
}

/// The `PATH` an interactive login shell would have, resolved once.
///
/// Starting an interactive shell runs the user's whole ~/.zshrc — version
/// manager hooks and all — which is far too slow to pay for on every `git
/// status`. So it happens once and the answer is reused.
private actor InteractivePath {
    static let shared = InteractivePath()

    /// A `Task` rather than a plain cached string: concurrent first callers then
    /// await one resolution instead of each starting their own shell.
    private var resolution: Task<String?, Never>?

    func value() async -> String? {
        if let resolution { return await resolution.value }
        let task = Task { await Self.resolve() }
        resolution = task
        return await task.value
    }

    private static func resolve() async -> String? {
        // A marker line, because an interactive rc file is free to print
        // whatever it likes to stdout before we get a word in.
        let marker = "__workspace_path__"
        let output = await Shell.execute(
            ["-ilc", "printf '\\n\(marker)%s\\n' \"$PATH\""],
            timeout: 20
        )
        guard let line = output.stdout
            .split(separator: "\n")
            .last(where: { $0.hasPrefix(marker) })
        else { return nil }

        let path = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }
}
