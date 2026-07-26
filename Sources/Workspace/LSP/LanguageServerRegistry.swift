import CodeEditLanguages
import Foundation

/// How to launch a language server for one language.
struct LanguageServerDefinition: Sendable, Hashable {
    /// The catalog entry's key — usually a `TreeSitterLanguage`, but see
    /// ``LanguageServerCatalog/vue``. ``LanguageServerOptions`` reads it to tell
    /// which server it is being asked to configure.
    let language: String
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

    /// How to start a catalog entry, as Settings currently has it —
    /// ``LanguageServerCatalog`` holds the defaults and the user's changes.
    static func definition(for entry: LanguageServerEntry) -> LanguageServerDefinition {
        LanguageServerDefinition(
            language: entry.language,
            executable: entry.executable,
            command: entry.command,
            languageID: entry.languageID
        )
    }

    /// The service for a file, or nil when no server is defined for it.
    ///
    /// The file name is asked first, since a language with no grammar is
    /// highlighted as the nearest one there is and so cannot be recognised by
    /// `language` alone — a `.vue` file arrives here as HTML.
    func service(for url: URL, language: CodeLanguage, root: URL) -> LanguageService? {
        let catalog = LanguageServerCatalog.shared
        guard let entry = catalog.entry(forFile: url) ?? catalog.entry(for: language) else { return nil }
        let key = Self.key(root: root, language: entry.language)
        if let existing = services[key] { return existing }
        let service = LanguageService(definition: Self.definition(for: entry), root: root)
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

    /// Stops the servers for one language, in every project.
    ///
    /// A running server was launched from the command line as it read then, so
    /// editing that command in Settings has to end the old process; the next
    /// file opened starts it again from the new entry.
    func shutdownServices(forLanguage language: String) {
        let suffix = "|\(language)"
        for (key, service) in services where key.hasSuffix(suffix) {
            service.shutdown()
            services[key] = nil
        }
    }

    private static func key(root: URL, language: String) -> String {
        "\(root.path)|\(language)"
    }
}
