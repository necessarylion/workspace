import Foundation

/// A command that stays up, taking lines on stdin and answering with lines on
/// stdout as they happen.
///
/// ``Shell`` is for commands that finish: it waits for the process and hands
/// back everything it printed at the end. A Claude conversation is the
/// opposite — one `claude` process lives for the whole chat, is fed a line of
/// JSON per prompt and answers with a line of JSON per event — so it gets its
/// own runner. What it keeps from `Shell` is how a tool is found: the user's
/// login shell, and the `PATH` an interactive one would have.
///
/// The command is `exec`'d rather than run as a child of that shell, so
/// ``terminate()`` reaches the tool itself instead of leaving it orphaned.
final class StreamingShellProcess: @unchecked Sendable {
    /// stdout, split into lines, in the order they were printed. The stream
    /// finishes when the process exits.
    let lines: AsyncStream<String>

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let continuation: AsyncStream<String>.Continuation

    /// Writes are queued rather than made from wherever `send` was called:
    /// a full pipe blocks the writer until the child drains it, which must
    /// never be the main thread, and the queue keeps the prompts in order.
    private let writeQueue = DispatchQueue(label: "workspace.streaming-process.stdin")

    /// Only ever touched from the read pipe's own serial queue.
    private var pending = Data()

    private let lock = NSLock()
    private var collectedErrors = ""

    init() {
        (lines, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    var isRunning: Bool { process.isRunning }

    /// Whatever the command wrote to stderr so far — the reason it died, when
    /// it dies.
    var errorOutput: String {
        lock.withLock { collectedErrors.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Starts the command. `onExit` is called on a background thread when it
    /// ends, however it ends.
    func start(
        _ executable: String,
        arguments: [String],
        in directory: URL,
        onExit: @escaping @Sendable (Int32) -> Void
    ) async {
        let script = "exec " + ([executable] + arguments).map(Shell.quote).joined(separator: " ")
        var environment = ProcessInfo.processInfo.environment
        if let path = await Shell.resolvedPath() {
            environment["PATH"] = path
        }

        process.executableURL = URL(fileURLWithPath: Shell.loginShell)
        process.arguments = ["-lc", script]
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.read(handle.availableData)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.lock.withLock { self?.collectedErrors.append(text) }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            // The last partial line, if the tool died mid-write, and then the
            // end of the stream so the reader's loop returns.
            self.read(Data())
            self.continuation.finish()
            self.output.fileHandleForReading.readabilityHandler = nil
            self.errors.fileHandleForReading.readabilityHandler = nil
            onExit(process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            lock.withLock { collectedErrors.append(error.localizedDescription) }
            continuation.finish()
            onExit(-1)
        }
    }

    /// Splits whatever arrived on the tool's own boundaries: one read can carry
    /// half a line, or six of them. Empty data means end of file.
    private func read(_ data: Data) {
        guard !data.isEmpty else {
            if !pending.isEmpty {
                emit(pending)
                pending = Data()
            }
            return
        }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            emit(pending[pending.startIndex..<newline])
            pending = pending[pending.index(after: newline)...]
        }
    }

    private func emit(_ data: some DataProtocol) {
        guard let line = String(bytes: data, encoding: .utf8) else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        continuation.yield(trimmed)
    }

    /// Writes one line to the command's stdin.
    func send(_ line: String) {
        let data = Data((line + "\n").utf8)
        writeQueue.async { [weak self] in
            guard let self, self.process.isRunning else { return }
            try? self.input.fileHandleForWriting.write(contentsOf: data)
        }
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }
}
