import Foundation

/// Runs command line tools (`git`, `gh`, `bkt`, `claude`) off the main actor.
///
/// Everything goes through a login shell on purpose: a GUI app inherits a bare
/// `PATH`, so `gh` in /opt/homebrew/bin or `bkt` under ~/.gvm would not be found
/// otherwise.
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

    static func run(
        _ arguments: [String],
        in directory: URL? = nil,
        timeout: TimeInterval = 60
    ) async -> Output {
        let command = arguments.map(quote).joined(separator: " ")
        return await runScript(command, in: directory, timeout: timeout)
    }

    static func runScript(
        _ script: String,
        in directory: URL? = nil,
        timeout: TimeInterval = 60
    ) async -> Output {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: loginShell)
            process.arguments = ["-lc", script]
            if let directory {
                process.currentDirectoryURL = directory
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
            nonisolated(unsafe) let watched = process
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

    /// Whether a tool is on the login shell's PATH.
    static func isAvailable(_ tool: String) async -> Bool {
        await runScript("command -v \(quote(tool))", timeout: 10).isSuccess
    }
}
