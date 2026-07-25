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
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data?, Error>] = [:]
    private var buffer = Data()
    private var isStopped = false

    /// Called for every server-initiated notification, with `params` re-encoded
    /// as JSON — `Any` cannot safely leave the actor.
    private var notificationHandler: (@Sendable (String, Data?) -> Void)?

    init(command: String, directory: URL) {
        self.command = command
        self.directory = directory
    }

    // MARK: - Lifecycle

    func start(onNotification handler: @escaping @Sendable (String, Data?) -> Void) throws {
        guard process == nil else { return }
        notificationHandler = handler

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: Shell.loginShell)
        // `exec` replaces the shell, so terminating the process really does
        // terminate the server rather than an orphaned wrapper.
        process.arguments = ["-lc", "exec \(command)"]
        process.currentDirectoryURL = directory
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
        // Drain stderr so a chatty server never fills its pipe and blocks.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
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
        failAllPending(with: Failure.notRunning)
    }

    private func handleTermination() {
        process = nil
        inputPipe = nil
        failAllPending(with: Failure.notRunning)
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
        guard process?.isRunning == true else { throw Failure.notRunning }

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
                let items = (message["params"] as? [String: Any])?["items"] as? [Any]
                let answer = Array(repeating: [String: Any](), count: items?.count ?? 1)
                reply(to: id, result: answer)
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
