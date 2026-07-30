import CodeEditLanguages
import Foundation

/// One language server, scoped to a project root and a language.
///
/// Owns the handshake, keeps documents in sync, and hands requests to
/// ``LSPConnection``. Diagnostics arrive unsolicited, so observers register a
/// callback per document URI.
@MainActor
@Observable
final class LanguageService {
    enum Status: Equatable {
        case notStarted
        case starting
        case running
        case unavailable(String)
        case failed(String)

        var label: String {
            switch self {
            case .notStarted: "not started"
            case .starting: "starting…"
            case .running: "running"
            case .unavailable(let tool): "\(tool) not installed"
            case .failed(let message): message
            }
        }

        var isHealthy: Bool { self == .running }
    }

    let definition: LanguageServerDefinition
    let root: URL

    private(set) var status: Status = .notStarted
    /// Diagnostics per document URI, replaced whenever the server republishes.
    private(set) var diagnostics: [String: [LSP.Diagnostic]] = [:]
    /// What the server asked for in its `initialize` reply. Read by the editor's
    /// coordinator to decide whether it may send ranges or must send the file.
    private(set) var syncKind: LSP.SyncKind = .full

    /// Since when this server has been holding no documents at all, or nil
    /// while it is holding one.
    ///
    /// A language server is an expensive thing to leave running — a few hundred
    /// megabytes each for the node ones, more for sourcekit-lsp — and nothing
    /// used to stop one until the repository it belongs to was removed from the
    /// sidebar. A day of looking at eight repositories left every server of all
    /// eight resident. ``LanguageServerRegistry`` reads this and stops the ones
    /// that have been idle long enough; opening a file in that language starts
    /// a fresh one, which is what already happens the first time.
    private(set) var idleSince: Date? {
        didSet { if idleSince != nil { onIdle?() } }
    }

    /// Told when this server stops holding documents, so the registry can put
    /// a wait on it rather than sweeping every server on a clock.
    @ObservationIgnored var onIdle: (() -> Void)?

    @ObservationIgnored private let connection: LSPConnection
    @ObservationIgnored private var versions: [String: Int] = [:]
    @ObservationIgnored private var openCount: [String: Int] = [:] {
        didSet {
            guard openCount.isEmpty != oldValue.isEmpty else { return }
            idleSince = openCount.isEmpty ? Date() : nil
        }
    }
    @ObservationIgnored private var diagnosticObservers: [ObjectIdentifier: (String, [LSP.Diagnostic]) -> Void] = [:]
    @ObservationIgnored private var startTask: Task<Bool, Never>?
    @ObservationIgnored private var settings: LSP.Value?

    init(definition: LanguageServerDefinition, root: URL) {
        self.definition = definition
        self.root = root
        self.connection = LSPConnection(command: definition.command, directory: root)
    }

    // MARK: - Start-up

    /// Starts the server and completes the `initialize` handshake once.
    @discardableResult
    func startIfNeeded() async -> Bool {
        if case .running = status { return true }
        if let startTask { return await startTask.value }

        let task = Task { @MainActor [self] in
            status = .starting

            // The app's own copy first: it is the one whose whereabouts are
            // certain, and the user's `PATH` is only consulted when we did not
            // install this server ourselves.
            let managed = ManagedLanguageServers.shared.binDirectory(for: definition.executable)
            let onPath = managed != nil ? true : await Shell.isAvailable(definition.executable)
            guard onPath else {
                status = .unavailable(definition.executable)
                return false
            }

            // Settled before the process is spawned: a server that cannot be
            // configured is one there is no point in running.
            let options: LSP.Value?
            do {
                options = try await LanguageServerOptions.initializationOptions(for: definition, root: root)
            } catch {
                status = .failed(error.localizedDescription)
                return false
            }

            do {
                let settings = await LanguageServerConfiguration.settings(for: definition, root: root)
                try await connection.start(binPath: managed?.path, settings: settings) { [weak self] method, params in
                    Task { @MainActor in self?.handle(notification: method, params: params) }
                }
                self.settings = settings
            } catch {
                status = .failed(error.localizedDescription)
                return false
            }

            do {
                let reply = try await connection.request(
                    "initialize",
                    params: InitializeParams(
                        rootURI: root.absoluteString,
                        rootPath: root.path,
                        initializationOptions: options
                    ),
                    timeout: 30
                )
                // The reply used to be thrown away. It carries the one thing the
                // editor cannot guess — see ``LSP/SyncKind``.
                let decoded = reply.flatMap { try? JSONSerialization.jsonObject(with: $0) }
                syncKind = LSP.SyncKind.from(
                    capabilities: (decoded as? [String: Any])?["capabilities"]
                )
                await connection.notify("initialized", params: EmptyParams())
                // Pushed as well as answered on request: vtsls reads its plugin
                // list from whichever arrives, and a server that never asks
                // would otherwise start without the settings that matter.
                if let settings {
                    await connection.notify(
                        "workspace/didChangeConfiguration",
                        params: DidChangeConfigurationParams(settings: settings)
                    )
                }
                status = .running
                // A prewarmed server holds nothing yet, so its idle clock
                // starts here. `open` clears it the moment a file arrives.
                if openCount.isEmpty, idleSince == nil { idleSince = Date() }
                return true
            } catch {
                status = .failed(error.localizedDescription)
                return false
            }
        }
        startTask = task
        let started = await task.value
        if !started { startTask = nil }
        return started
    }

    func shutdown() {
        // Before the resets below, so emptying the documents does not report a
        // server that is going away as one that has just gone idle.
        onIdle = nil
        Task { await connection.stop() }
        status = .notStarted
        // The handshake is what `startIfNeeded` remembers; without this a
        // service stopped for being idle could never be started again.
        startTask = nil
        openCount = [:]
        versions = [:]
        diagnostics = [:]
        idleSince = nil
    }

    // MARK: - Document sync

    /// - Parameter languageID: What to call the document, when that is not this
    ///   server's own language. A companion server is holding a file belonging to
    ///   the server it accompanies — vtsls opened alongside the Vue server holds a
    ///   `.vue` file — and announcing it as `typescript` would be a lie with
    ///   consequences: `@vue/typescript-plugin` serves a document only when it
    ///   arrives as `vue`, so tsserver would instead try to read `<template>` as
    ///   TypeScript and report a file full of syntax errors.
    /// - Returns: Whether the server is now holding this document. False means the
    ///   server never started — nothing was sent, and nothing may be sent, since
    ///   every later notification is guarded on a document this one never opened.
    @discardableResult
    func open(uri: String, text: String, languageID: String? = nil) async -> Bool {
        guard await startIfNeeded() else { return false }
        openCount[uri, default: 0] += 1
        guard openCount[uri] == 1 else { return true }
        versions[uri] = 1
        await connection.notify(
            "textDocument/didOpen",
            params: DidOpenParams(
                textDocument: .init(
                    uri: uri,
                    languageId: languageID ?? definition.languageID,
                    version: 1,
                    text: text
                )
            )
        )
        return true
    }

    /// Full-text sync: simple, and correct for every server.
    ///
    /// Still the route for a server that only advertised `full`, and for the
    /// cases where the editor cannot say what changed — a reload from disk, or
    /// an edit whose pre-edit range it could not resolve.
    func change(uri: String, text: String) async {
        guard status.isHealthy, openCount[uri] != nil else { return }
        await send(uri: uri, changes: [DidChangeParams.Change(range: nil, text: text)])
    }

    /// Incremental sync: only the spans that changed.
    ///
    /// Ordered, and sent in one notification, because each range is stated
    /// against the document the edits before it produced — see
    /// ``LSP/TextChange``. Dropped rather than downgraded if the server never
    /// asked for ranges; the caller checks ``syncKind`` and sends full text
    /// instead, since one wrong range poisons every later answer.
    func change(uri: String, changes: [LSP.TextChange]) async {
        guard status.isHealthy, openCount[uri] != nil, !changes.isEmpty else { return }
        guard syncKind == .incremental else { return }
        await send(uri: uri, changes: changes.map { .init(range: $0.range, text: $0.text) })
    }

    private func send(uri: String, changes: [DidChangeParams.Change]) async {
        let version = (versions[uri] ?? 1) + 1
        versions[uri] = version
        await connection.notify(
            "textDocument/didChange",
            params: DidChangeParams(
                textDocument: .init(uri: uri, version: version),
                contentChanges: changes
            )
        )
    }

    func save(uri: String, text: String) async {
        guard status.isHealthy, openCount[uri] != nil else { return }
        await connection.notify(
            "textDocument/didSave",
            params: DidSaveParams(textDocument: .init(uri: uri), text: text)
        )
    }

    func close(uri: String) async {
        guard let count = openCount[uri] else { return }
        if count > 1 {
            openCount[uri] = count - 1
            return
        }
        openCount[uri] = nil
        versions[uri] = nil
        guard status.isHealthy else { return }
        await connection.notify(
            "textDocument/didClose",
            params: DidCloseParams(textDocument: .init(uri: uri))
        )
    }

    // MARK: - Requests

    func completions(uri: String, position: LSP.Position) async -> [LSP.CompletionItem] {
        guard status.isHealthy else { return [] }
        let result = try? await connection.request(
            "textDocument/completion",
            params: PositionParams(textDocument: .init(uri: uri), position: position),
            timeout: 6
        )
        return LSP.decodeCompletions(Self.json(result))
    }

    func hover(uri: String, position: LSP.Position) async -> String? {
        guard status.isHealthy else { return nil }
        let result = try? await connection.request(
            "textDocument/hover",
            params: PositionParams(textDocument: .init(uri: uri), position: position),
            timeout: 5
        )
        return LSP.decodeHoverText(Self.json(result))
    }

    /// Nil when the server never answered — sourcekit-lsp in particular can
    /// spend the best part of a minute preparing a package before it replies to
    /// the first request, and "no answer" must not read as "no definition".
    func definitions(uri: String, position: LSP.Position) async -> [LSP.Location]? {
        guard status.isHealthy else { return nil }
        do {
            let result = try await connection.request(
                "textDocument/definition",
                params: PositionParams(textDocument: .init(uri: uri), position: position),
                timeout: 45
            )
            return LSP.decodeLocations(Self.json(result))
        } catch {
            return nil
        }
    }

    /// Nil when the server never answered, for the same reason as ``definitions``
    /// — and here the distinction is what keeps the outline honest. An empty
    /// array is a real answer: the last declaration in the file was deleted, and
    /// the outline should empty with it. Collapsing the two would leave the
    /// window showing symbols that are no longer in the text.
    func symbols(uri: String) async -> [LSP.Symbol]? {
        guard status.isHealthy else { return nil }
        do {
            let result = try await connection.request(
                "textDocument/documentSymbol",
                params: DocumentParams(textDocument: .init(uri: uri)),
                timeout: 8
            )
            return LSP.decodeSymbols(Self.json(result))
        } catch {
            return nil
        }
    }

    private static func json(_ data: Data??) -> Any? {
        guard let data = data ?? nil else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    // MARK: - Diagnostics

    func addDiagnosticObserver(
        _ owner: AnyObject,
        handler: @escaping (String, [LSP.Diagnostic]) -> Void
    ) {
        diagnosticObservers[ObjectIdentifier(owner)] = handler
    }

    func removeDiagnosticObserver(_ owner: AnyObject) {
        diagnosticObservers[ObjectIdentifier(owner)] = nil
    }

    private func handle(notification method: String, params: Data?) {
        // Not a protocol method: the Vue server's way of asking the *client* to
        // put a question to the TypeScript server on its behalf. See
        // ``relayToTypeScript(_:)``.
        if method == "tsserver/request" {
            let requests = params.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[Any]] ?? []
            for request in requests { relayToTypeScript(request) }
            return
        }

        guard method == "textDocument/publishDiagnostics",
              let params = params.flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
              let uri = params["uri"] as? String else { return }

        let items = params["diagnostics"] as? [[String: Any]] ?? []
        let decoded: [LSP.Diagnostic] = items.compactMap { item in
            guard let data = try? JSONSerialization.data(withJSONObject: item) else { return nil }
            return try? JSONDecoder().decode(LSP.Diagnostic.self, from: data)
        }

        diagnostics[uri] = decoded
        for observer in diagnosticObservers.values {
            observer(uri, decoded)
        }
    }

    // MARK: - Hybrid mode

    /// Carries one question from the Vue server to the TypeScript server and
    /// the answer back.
    ///
    /// **Only older Vue servers ask for this.** `@vue/language-server` 2.0.x had
    /// the client relay every typed question: it arrived as `[id, command,
    /// payload]`, went out as the `typescript.tsserverRequest` command vtsls
    /// exposes for exactly this, and the answer came back as a
    /// `tsserver/response` notification carrying the same id. From 2.1 the relay
    /// is gone — `@vue/typescript-plugin` opens a named pipe inside `tsserver`
    /// and the Vue server connects to it directly, so neither method name appears
    /// in the package any more and this is never called. Kept because it is
    /// correct for the servers that do ask, and costs nothing for the ones that
    /// do not.
    ///
    /// What hybrid mode needs from us either way is in
    /// ``LanguageServerConfiguration``: vtsls has to load the plugin, and has to
    /// have the `.vue` file open, or there is no pipe and no project behind it.
    ///
    /// A question that cannot be delivered is still answered, with null. The
    /// Vue server waits on every id it issues, and one silently dropped is a
    /// hover or a completion that never returns.
    private func relayToTypeScript(_ request: [Any]) {
        guard request.count >= 2, let id = request[0] as? Int, let command = request[1] as? String else { return }
        let payload = request.count > 2 ? LSP.Value.from(json: request[2]) : .null

        Task { @MainActor in
            guard let typescript = LanguageServerRegistry.shared.typeScriptService(root: root),
                  await typescript.startIfNeeded() else {
                await answerTypeScript(id: id, body: .null)
                return
            }
            let answer = await typescript.executeCommand(
                "typescript.tsserverRequest",
                arguments: [.string(command), payload]
            )
            // `{ body: … }` is the tsserver envelope vtsls hands back; the Vue
            // server wants what is inside it.
            let json = answer.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
            let body = (json as? [String: Any])?["body"] ?? json
            await answerTypeScript(id: id, body: body.map(LSP.Value.from(json:)) ?? .null)
        }
    }

    private func answerTypeScript(id: Int, body: LSP.Value) async {
        await connection.notify(
            "tsserver/response",
            params: LSP.Value.array([.array([.int(id), body])])
        )
    }

    /// `workspace/executeCommand`, for the commands a server defines itself.
    /// Nil when it refused or never answered.
    func executeCommand(_ command: String, arguments: [LSP.Value]) async -> Data? {
        guard status.isHealthy else { return nil }
        return await connection.executeCommand(command, arguments: arguments)
    }

    // MARK: - Parameter types

    private struct InitializeParams: Encodable, Sendable {
        let processId: Int = Int(ProcessInfo.processInfo.processIdentifier)
        let rootUri: String
        let rootPath: String
        let capabilities = ClientCapabilities()
        let workspaceFolders: [WorkspaceFolder]
        /// Whatever this particular server wants — see ``LanguageServerOptions``.
        let initializationOptions: LSP.Value?

        init(rootURI: String, rootPath: String, initializationOptions: LSP.Value?) {
            self.rootUri = rootURI
            self.rootPath = rootPath
            self.workspaceFolders = [WorkspaceFolder(uri: rootURI, name: (rootPath as NSString).lastPathComponent)]
            self.initializationOptions = initializationOptions
        }
    }

    private struct WorkspaceFolder: Encodable, Sendable {
        let uri: String
        let name: String
    }

    /// Only what we implement — servers tailor their replies to this.
    private struct ClientCapabilities: Encodable, Sendable {
        struct TextDocument: Encodable, Sendable {
            struct Synchronization: Encodable, Sendable {
                let didSave = true
                let dynamicRegistration = false
            }
            struct Completion: Encodable, Sendable {
                struct Item: Encodable, Sendable {
                    let snippetSupport = false
                    let documentationFormat = ["plaintext"]
                }
                let completionItem = Item()
                let contextSupport = true
            }
            struct Hover: Encodable, Sendable {
                let contentFormat = ["plaintext", "markdown"]
            }
            struct Definition: Encodable, Sendable {
                let linkSupport = true
            }
            struct DocumentSymbol: Encodable, Sendable {
                let hierarchicalDocumentSymbolSupport = true
            }
            struct PublishDiagnostics: Encodable, Sendable {
                let relatedInformation = false
            }
            let synchronization = Synchronization()
            let completion = Completion()
            let hover = Hover()
            let definition = Definition()
            let documentSymbol = DocumentSymbol()
            let publishDiagnostics = PublishDiagnostics()
        }
        struct Workspace: Encodable, Sendable {
            let workspaceFolders = true
            let configuration = true
        }
        let textDocument = TextDocument()
        let workspace = Workspace()
    }

    private struct TextDocumentIdentifier: Encodable, Sendable {
        let uri: String
    }

    private struct VersionedIdentifier: Encodable, Sendable {
        let uri: String
        let version: Int
    }

    private struct DidOpenParams: Encodable, Sendable {
        struct Item: Encodable, Sendable {
            let uri: String
            let languageId: String
            let version: Int
            let text: String
        }
        let textDocument: Item
    }

    private struct DidChangeConfigurationParams: Encodable, Sendable {
        let settings: LSP.Value
    }

    private struct DidChangeParams: Encodable, Sendable {
        /// No `range` is how the protocol spells "this is the whole document";
        /// with one, only that span changed. The key has to be absent rather
        /// than null, which is what `Encodable` does with a nil optional.
        struct Change: Encodable, Sendable {
            var range: LSP.Range?
            let text: String
        }
        let textDocument: VersionedIdentifier
        let contentChanges: [Change]
    }

    private struct DidSaveParams: Encodable, Sendable {
        let textDocument: TextDocumentIdentifier
        let text: String
    }

    private struct DidCloseParams: Encodable, Sendable {
        let textDocument: TextDocumentIdentifier
    }

    private struct DocumentParams: Encodable, Sendable {
        let textDocument: TextDocumentIdentifier
    }

    private struct PositionParams: Encodable, Sendable {
        let textDocument: TextDocumentIdentifier
        let position: LSP.Position
    }
}
