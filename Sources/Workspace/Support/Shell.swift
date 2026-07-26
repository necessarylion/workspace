import Foundation

/// Runs command line tools (`git`, `gh`, `bkt`, `claude`) off the main actor.
///
/// A GUI app inherits a bare `PATH`, so `gh` in /opt/homebrew/bin would not be
/// found by itself. A login shell alone does not fix that either — version
/// managers (gvm, nvm, pyenv) extend `PATH` from ~/.zshrc, which zsh only reads
/// when it is *interactive*, so `bkt` under ~/.gvm stays invisible.
/// `InteractivePath` resolves that fuller `PATH` once and every command
/// inherits it.
///
/// With the `PATH` question settled that way, ``run`` starts the tool itself
/// rather than asking a shell to. A login shell is not free: it re-reads
/// /etc/zprofile, `path_helper` and ~/.zprofile every time, which measured at
/// ~32 ms on top of a `git status` that takes 13 ms — more than doubling the
/// cost of every read the app makes, for a `PATH` it had already worked out.
/// ``runScript`` keeps the shell, because a pipeline or an `if` needs one.
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
        let output = await shell(
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

    /// Runs one tool with one list of arguments — no shell in between.
    ///
    /// The arguments were being quoted into a command line only for a shell to
    /// take them apart again, so handing them to the process directly is the
    /// same call without the round trip. Every caller here names a real binary
    /// (`git`, `gh`, `bkt`, `kill`); anything that needs a pipe or an `if` goes
    /// through ``runScript``.
    static func run(
        _ arguments: [String],
        in directory: URL? = nil,
        timeout: TimeInterval = 60,
        environment: [String: String] = [:]
    ) async -> Output {
        guard let tool = arguments.first else {
            return Output(status: -1, stdout: "", stderr: "No command given.")
        }
        let path = await InteractivePath.shared.value()
        guard let executable = await ToolLocations.shared.location(of: tool, onPath: path) else {
            // Not on the `PATH` we resolved — which is nearly always because the
            // tool is genuinely not installed, but would also be the answer if
            // resolving `PATH` had failed and left us with the bare one a GUI
            // app inherits. A login shell was what used to run every command
            // and it reads ~/.zprofile for itself, so it is the second opinion
            // worth having before giving up. Only the failing case pays for it.
            return await runScript(
                arguments.map(quote).joined(separator: " "),
                in: directory,
                timeout: timeout,
                environment: environment
            )
        }

        var merged: [String: String] = [:]
        if let path { merged["PATH"] = path }
        merged.merge(environment) { _, new in new }

        return await execute(
            executable,
            Array(arguments.dropFirst()),
            in: directory,
            timeout: timeout,
            environment: merged
        )
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
        return await shell(["-lc", script], in: directory, timeout: timeout, environment: merged)
    }

    /// The user's login shell, with the arguments handed to it as they are.
    ///
    /// Deliberately does **not** resolve `PATH` first: `InteractivePath` is one
    /// of its callers, and asking it here is how that would become a loop.
    fileprivate static func shell(
        _ arguments: [String],
        in directory: URL? = nil,
        timeout: TimeInterval = 60,
        environment: [String: String] = [:]
    ) async -> Output {
        await execute(loginShell, arguments, in: directory, timeout: timeout, environment: environment)
    }

    private static func execute(
        _ executable: String,
        _ arguments: [String],
        in directory: URL? = nil,
        timeout: TimeInterval = 60,
        environment: [String: String] = [:]
    ) async -> Output {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
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

            // Kill runaway network calls so the UI never waits forever.
            let watched = process
            let watchdog = DispatchWorkItem {
                if watched.isRunning { watched.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

            // Awaited rather than waited on. `waitUntilExit` blocks the thread
            // it is called on, and this runs on the cooperative pool, which has
            // one thread per core and does not grow a replacement for a blocked
            // one. A screenful of concurrent commands — the language server
            // pane probes 23 of them at once — would take every thread the app
            // has, and *all* other async work, redraws included, would stop
            // until they drained. Suspending on the exit gives the thread back.
            let status: Int32
            do {
                status = try await withCheckedThrowingContinuation { continuation in
                    // Installed before the launch: a command that is already
                    // finished by the time `run` returns would never call a
                    // handler attached afterwards.
                    process.terminationHandler = { finished in
                        continuation.resume(returning: finished.terminationStatus)
                    }
                    do {
                        try process.run()
                    } catch {
                        // The launch failed, so the handler above will never
                        // fire and this is the only resume that happens.
                        process.terminationHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
            } catch {
                watchdog.cancel()
                try? outHandle.close()
                try? errHandle.close()
                return Output(status: -1, stdout: "", stderr: error.localizedDescription)
            }

            watchdog.cancel()
            try? outHandle.close()
            try? errHandle.close()

            return Output(
                status: status,
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
    ///
    /// A `PATH` walk rather than a `command -v` in a shell, which is the same
    /// question with a process behind it. The language server pane asks this 23
    /// times the moment it opens, and this way none of them starts anything.
    static func isAvailable(_ tool: String) async -> Bool {
        await ToolLocations.shared.location(
            of: tool,
            onPath: InteractivePath.shared.value()
        ) != nil
    }
}

/// Where each tool lives, looked up once.
///
/// This is `PATH` resolution done in-process: the directories of the resolved
/// `PATH`, in order, first one holding an executable of that name wins — the
/// same walk `execvp` would do, and the same one a shell would.
///
/// Only hits are remembered. A miss is a handful of `stat` calls and costs
/// nothing to repeat, and a tool the user installs from Settings while the app
/// is running has to be findable straight afterwards — a cached "not there"
/// would outlive the install.
private actor ToolLocations {
    static let shared = ToolLocations()

    /// Keyed by the `PATH` the answer was found on, so the handful of lookups
    /// made before `InteractivePath` resolves are not mistaken for answers
    /// about the fuller `PATH` that arrives after it.
    private var found: [String: [String: String]] = [:]

    func location(of tool: String, onPath path: String?) -> String? {
        // Something already spelled out — a full path, or one relative to the
        // working directory — is not a name to look up.
        guard !tool.contains("/") else { return tool }

        let key = path ?? ""
        if let cached = found[key]?[tool] { return cached }

        guard let resolved = Self.search(tool, on: path) else { return nil }
        found[key, default: [:]][tool] = resolved
        return resolved
    }

    private static func search(_ tool: String, on path: String?) -> String? {
        let searched = path
            ?? ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let manager = FileManager.default

        for directory in searched.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = directory.hasSuffix("/")
                ? "\(directory)\(tool)"
                : "\(directory)/\(tool)"
            if manager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
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
        let output = await Shell.shell(
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
