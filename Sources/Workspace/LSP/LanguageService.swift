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

    @ObservationIgnored private let connection: LSPConnection
    @ObservationIgnored private var versions: [String: Int] = [:]
    @ObservationIgnored private var openCount: [String: Int] = [:]
    @ObservationIgnored private var diagnosticObservers: [ObjectIdentifier: (String, [LSP.Diagnostic]) -> Void] = [:]
    @ObservationIgnored private var startTask: Task<Bool, Never>?

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

            guard await Shell.isAvailable(definition.executable) else {
                status = .unavailable(definition.executable)
                return false
            }

            do {
                try await connection.start { [weak self] method, params in
                    Task { @MainActor in self?.handle(notification: method, params: params) }
                }
            } catch {
                status = .failed(error.localizedDescription)
                return false
            }

            do {
                _ = try await connection.request(
                    "initialize",
                    params: InitializeParams(rootURI: root.absoluteString, rootPath: root.path),
                    timeout: 30
                )
                await connection.notify("initialized", params: EmptyParams())
                status = .running
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
        Task { await connection.stop() }
        status = .notStarted
    }

    // MARK: - Document sync

    func open(uri: String, text: String) async {
        guard await startIfNeeded() else { return }
        openCount[uri, default: 0] += 1
        guard openCount[uri] == 1 else { return }
        versions[uri] = 1
        await connection.notify(
            "textDocument/didOpen",
            params: DidOpenParams(
                textDocument: .init(
                    uri: uri,
                    languageId: definition.languageID,
                    version: 1,
                    text: text
                )
            )
        )
    }

    /// Full-text sync: simple, and correct for every server.
    func change(uri: String, text: String) async {
        guard status.isHealthy, openCount[uri] != nil else { return }
        let version = (versions[uri] ?? 1) + 1
        versions[uri] = version
        await connection.notify(
            "textDocument/didChange",
            params: DidChangeParams(
                textDocument: .init(uri: uri, version: version),
                contentChanges: [.init(text: text)]
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

    func symbols(uri: String) async -> [LSP.Symbol] {
        guard status.isHealthy else { return [] }
        let result = try? await connection.request(
            "textDocument/documentSymbol",
            params: DocumentParams(textDocument: .init(uri: uri)),
            timeout: 8
        )
        return LSP.decodeSymbols(Self.json(result))
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

    // MARK: - Parameter types

    private struct InitializeParams: Encodable, Sendable {
        let processId: Int = Int(ProcessInfo.processInfo.processIdentifier)
        let rootUri: String
        let rootPath: String
        let capabilities = ClientCapabilities()
        let workspaceFolders: [WorkspaceFolder]

        init(rootURI: String, rootPath: String) {
            self.rootUri = rootURI
            self.rootPath = rootPath
            self.workspaceFolders = [WorkspaceFolder(uri: rootURI, name: (rootPath as NSString).lastPathComponent)]
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

    private struct DidChangeParams: Encodable, Sendable {
        struct Change: Encodable, Sendable {
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
