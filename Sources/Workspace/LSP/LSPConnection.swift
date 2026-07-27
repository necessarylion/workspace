import Foundation

/// A JSON-RPC connection to a language server over stdio.
///
/// Servers are launched through a login shell so `$PATH` resolves the same way
/// it does in Terminal — a GUI app otherwise cannot find `typescript-language-server`
/// or anything else installed by a version manager.
actor LSPConnection {
    enum Failure: LocalizedError {
        case launchFailed(String)
        case notRunning
        case timedOut(String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let message): "Could not start the language server: \(message)"
            case .notRunning: "The language server is not running."
            case .timedOut(let method): "The language server did not answer \(method) in time."
            case .server(let message): message
            }
        }
    }

    /// One decoded message from the server, kept as a dictionary because the
    /// payload shapes vary per method.
    private typealias Message = [String: Any]

    private let command: String
    private let directory: URL

    private var process: Process?
    private var inputPipe: Pipe?
    private var errorPipe: Pipe?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data?, Error>] = [:]
    private var buffer = Data()
    private var isStopped = false
    /// The last of what the server wrote to stderr, kept for the message shown
    /// when it dies. A server that is not on `PATH` says so there and nowhere
    /// else, and without this it exits in silence.
    private var stderrTail = ""
    /// What this server is told when it asks `workspace/configuration`. Set
    /// before the handshake — a server asks for its settings the moment it is
    /// initialized, and an empty answer then is one some of them never re-ask.
    private var settings: LSP.Value?

    /// Called for every server-initiated notification, with `params` re-encoded
    /// as JSON — `Any` cannot safely leave the actor.
    private var notificationHandler: (@Sendable (String, Data?) -> Void)?

    init(command: String, directory: URL) {
        self.command = command
        self.directory = directory
    }

    // MARK: - Lifecycle

    /// - Parameter binPath: a folder to put on the front of the server's
    ///   `PATH` — where ``ManagedLanguageServers`` installed it, when the app
    ///   installed it rather than the user. In front, so the copy the app owns
    ///   is the one that runs even if an older one is on the user's `PATH` too.
    func start(
        binPath: String? = nil,
        settings: LSP.Value? = nil,
        onNotification handler: @escaping @Sendable (String, Data?) -> Void
    ) async throws {
        guard process == nil else { return }
        notificationHandler = handler
        self.settings = settings

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: Shell.loginShell)
        // `exec` replaces the shell, so terminating the process really does
        // terminate the server rather than an orphaned wrapper.
        process.arguments = ["-lc", "exec \(command)"]
        process.currentDirectoryURL = directory
        // The login shell reads ~/.zprofile and no further, so on its own it
        // finds none of the servers npm installed under nvm — and the app is
        // left saying "installed" (which asks the resolved `PATH`) about a
        // server that dies with "command not found" every time it is started.
        let resolved = await Shell.resolvedPath()
        let path = [binPath, resolved].compactMap { $0 }.joined(separator: ":")
        if !path.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(["PATH": path]) { _, new in new }
        }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { await self?.ingest(data) }
        }
        // Drain stderr so a chatty server never fills its pipe and blocks —
        // keeping the tail, which is the only place a start-up failure is
        // explained.
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            Task { await self?.record(stderr: text) }
        }

        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        self.process = process
        self.inputPipe = stdin
        self.errorPipe = stderr
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        notify("exit", params: EmptyParams())
        process?.terminate()
        process = nil
        inputPipe = nil
        errorPipe = nil
        failAllPending(with: Failure.notRunning)
    }

    private func handleTermination() {
        process = nil
        inputPipe = nil
        // What the server said on its way out may still be sitting in the pipe:
        // a process that dies in its first moments can be gone before the
        // handler above has run once.
        if let handle = errorPipe?.fileHandleForReading {
            handle.readabilityHandler = nil
            if let rest = try? handle.readToEnd(), !rest.isEmpty {
                record(stderr: String(decoding: rest, as: UTF8.self))
            }
        }
        errorPipe = nil
        failAllPending(with: exitFailure)
    }

    private func record(stderr text: String) {
        stderrTail = String((stderrTail + text).suffix(1000))
    }

    /// Why the server is gone, in the server's own words when it left any.
    private var exitFailure: Failure {
        let message = stderrTail
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let message else { return .notRunning }
        return .server("The language server stopped: \(message)")
    }

    private func failAllPending(with error: Error) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Sending

    /// Sends a request and waits for its result payload.
    /// The result payload, re-encoded as JSON for the caller to decode.
    func request<P: Encodable & Sendable>(
        _ method: String,
        params: P,
        timeout: TimeInterval = 10
    ) async throws -> Data? {
        guard process?.isRunning == true else { throw exitFailure }

        let id = nextID
        nextID += 1

        let envelope = Request(id: id, method: method, params: params)
        guard let data = try? JSONEncoder().encode(envelope) else {
            throw Failure.server("Could not encode \(method).")
        }

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            write(data)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.expire(id, method: method)
            }
        }
    }

    /// `workspace/executeCommand`, whose arguments belong to the server rather
    /// than to the protocol.
    func executeCommand(_ command: String, arguments: [LSP.Value], timeout: TimeInterval = 30) async -> Data? {
        // Flattened deliberately: the request itself answers with an optional,
        // and `try?` would wrap that in a second one.
        let answer = try? await request(
            "workspace/executeCommand",
            params: ExecuteCommandParams(command: command, arguments: arguments),
            timeout: timeout
        )
        return answer ?? nil
    }

    private struct ExecuteCommandParams: Encodable, Sendable {
        let command: String
        let arguments: [LSP.Value]
    }

    func notify<P: Encodable & Sendable>(_ method: String, params: P) {
        let envelope = Notification(method: method, params: params)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        write(data)
    }

    private func expire(_ id: Int, method: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: Failure.timedOut(method))
    }

    private func write(_ payload: Data) {
        guard let handle = inputPipe?.fileHandleForWriting else { return }
        var framed = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
        framed.append(payload)
        try? handle.write(contentsOf: framed)
    }

    /// Answers a server-to-client request. Ignoring these stalls some servers.
    private func reply(to id: Any, result: Any?) {
        var object: [String: Any] = ["jsonrpc": "2.0", "id": id]
        object["result"] = result ?? NSNull()
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        write(data)
    }

    // MARK: - Receiving

    private func ingest(_ data: Data) {
        buffer.append(data)

        // Frames look like: Content-Length: N\r\n[...headers...]\r\n\r\n<N bytes>
        while true {
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let header = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)

            var length: Int?
            for line in header.split(separator: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { continue }
                length = Int(parts[1].trimmingCharacters(in: .whitespaces))
            }

            guard let length else {
                // Unusable header — drop it and resynchronise.
                buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)
                continue
            }

            let bodyStart = headerEnd.upperBound
            guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return }
            let bodyEnd = buffer.index(bodyStart, offsetBy: length)
            let body = buffer[bodyStart..<bodyEnd]
            buffer.removeSubrange(buffer.startIndex..<bodyEnd)

            if let message = try? JSONSerialization.jsonObject(with: body) as? Message {
                handle(message)
            }
        }
    }

    private func handle(_ message: Message) {
        // A response carries an id and no method.
        if let id = message["id"], message["method"] == nil {
            guard let key = (id as? Int) ?? Int((id as? String) ?? "") ,
                  let continuation = pending.removeValue(forKey: key) else { return }
            if let error = message["error"] as? [String: Any] {
                let text = error["message"] as? String ?? "The language server reported an error."
                continuation.resume(throwing: Failure.server(text))
            } else {
                continuation.resume(returning: Self.encode(message["result"]))
            }
            return
        }

        guard let method = message["method"] as? String else { return }

        // A server-to-client request: answer it so the server can move on.
        if let id = message["id"] {
            switch method {
            case "workspace/configuration":
                // One answer per item, in order, each the subtree the server
                // named. An empty object for a section we hold nothing for —
                // which is most of them, and what every server expects when the
                // user has not configured it.
                let items = (message["params"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
                let answer: [Any] = items.map { item in
                    let section = item["section"] as? String ?? ""
                    return settings?.child(atPath: section)?.json ?? [String: Any]()
                }
                reply(to: id, result: answer.isEmpty ? [[String: Any]()] : answer)
            default:
                reply(to: id, result: nil)
            }
            return
        }

        notificationHandler?(method, Self.encode(message["params"]))
    }

    /// JSON cannot cross an actor boundary as `Any`, so it travels as `Data`.
    private static func encode(_ value: Any?) -> Data? {
        guard let value, !(value is NSNull) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }

    // MARK: - Envelopes

    private struct Request<P: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: Int
        let method: String
        let params: P
    }

    private struct Notification<P: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let method: String
        let params: P
    }
}

/// `{}` — for methods that take no parameters.
struct EmptyParams: Encodable, Sendable {}
