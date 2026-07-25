import CodeEditLanguages
import Foundation

/// How to launch a language server for one language.
struct LanguageServerDefinition: Sendable, Hashable {
    /// Binary we check for on `$PATH`.
    let executable: String
    /// Full command line, run through a login shell.
    let command: String
    /// The LSP `languageId` for documents we send to it.
    let languageID: String
    /// Shown in the editor status bar.
    var displayName: String { executable }
}

/// Keeps one server per (project root, language) and hands them out.
///
/// Servers are started lazily the first time a matching file is opened, so a
/// project with no Swift files never spawns sourcekit-lsp.
@MainActor
@Observable
final class LanguageServerRegistry {
    static let shared = LanguageServerRegistry()

    private var services: [String: LanguageService] = [:]

    private init() {}

    /// Every language we know how to serve. `swift` uses Xcode's own copy of
    /// sourcekit-lsp, which is always present on a machine with Xcode.
    static func definition(for language: CodeLanguage) -> LanguageServerDefinition? {
        switch language.id {
        case .swift:
            .init(executable: "sourcekit-lsp", command: "sourcekit-lsp", languageID: "swift")
        case .objc:
            .init(executable: "clangd", command: "clangd --background-index", languageID: "objective-c")
        case .c:
            .init(executable: "clangd", command: "clangd --background-index", languageID: "c")
        case .cpp:
            .init(executable: "clangd", command: "clangd --background-index", languageID: "cpp")
        case .typescript:
            .init(
                executable: "typescript-language-server",
                command: "typescript-language-server --stdio",
                languageID: "typescript"
            )
        case .tsx:
            .init(
                executable: "typescript-language-server",
                command: "typescript-language-server --stdio",
                languageID: "typescriptreact"
            )
        case .javascript:
            .init(
                executable: "typescript-language-server",
                command: "typescript-language-server --stdio",
                languageID: "javascript"
            )
        case .jsx:
            .init(
                executable: "typescript-language-server",
                command: "typescript-language-server --stdio",
                languageID: "javascriptreact"
            )
        case .python:
            .init(executable: "pyright-langserver", command: "pyright-langserver --stdio", languageID: "python")
        case .go:
            .init(executable: "gopls", command: "gopls", languageID: "go")
        case .rust:
            .init(executable: "rust-analyzer", command: "rust-analyzer", languageID: "rust")
        case .ruby:
            .init(executable: "solargraph", command: "solargraph stdio", languageID: "ruby")
        case .php:
            .init(executable: "intelephense", command: "intelephense --stdio", languageID: "php")
        case .dart:
            .init(executable: "dart", command: "dart language-server --protocol=lsp", languageID: "dart")
        case .lua:
            .init(executable: "lua-language-server", command: "lua-language-server", languageID: "lua")
        case .kotlin:
            .init(executable: "kotlin-language-server", command: "kotlin-language-server", languageID: "kotlin")
        case .json:
            .init(
                executable: "vscode-json-language-server",
                command: "vscode-json-language-server --stdio",
                languageID: "json"
            )
        case .yaml:
            .init(
                executable: "yaml-language-server",
                command: "yaml-language-server --stdio",
                languageID: "yaml"
            )
        case .html:
            .init(
                executable: "vscode-html-language-server",
                command: "vscode-html-language-server --stdio",
                languageID: "html"
            )
        case .css:
            .init(
                executable: "vscode-css-language-server",
                command: "vscode-css-language-server --stdio",
                languageID: "css"
            )
        case .bash:
            .init(
                executable: "bash-language-server",
                command: "bash-language-server start",
                languageID: "shellscript"
            )
        default:
            nil
        }
    }

    /// The service for a file, or nil when no server is defined for its language.
    func service(for language: CodeLanguage, root: URL) -> LanguageService? {
        guard let definition = Self.definition(for: language) else { return nil }
        let key = "\(root.path)|\(definition.languageID)"
        if let existing = services[key] { return existing }
        let service = LanguageService(definition: definition, root: root)
        services[key] = service
        return service
    }

    /// Every server we have spun up, for the Info panel.
    var activeServices: [LanguageService] {
        services.values
            .filter { $0.status != .notStarted }
            .sorted { $0.definition.executable < $1.definition.executable }
    }

    func services(inside root: URL) -> [LanguageService] {
        services.values
            .filter { $0.root == root }
            .sorted { $0.definition.executable < $1.definition.executable }
    }

    /// Stops every server rooted at a project the user removed.
    func shutdownServices(inside root: URL) {
        for (key, service) in services where service.root == root {
            service.shutdown()
            services[key] = nil
        }
    }
}
