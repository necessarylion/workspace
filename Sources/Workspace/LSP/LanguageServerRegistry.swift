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
    /// Roots already prewarmed, so the dashboard reappearing does not start the
    /// walk again.
    private var prewarmed: Set<URL> = []

    /// How many servers one repository may start before a file is opened.
    ///
    /// A monorepo can want a dozen, and starting all of them at once is a
    /// dozen node processes for languages the user may not touch today. The
    /// ones kept are those with the most files in the repository — the rarest
    /// language is the one least likely to be opened first, and it still starts
    /// on demand the moment it is.
    private static let prewarmLimit = 6

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

    // MARK: - Prewarming

    /// Starts the servers a repository is going to want, before a file is
    /// opened in it.
    ///
    /// Starting one on demand is the slowest thing about opening a file: the
    /// process has to launch, read the project and index it, and until it has,
    /// the file on screen has no completions, no diagnostics and no go-to. That
    /// wait belongs to the dashboard, which is what is on screen while nothing
    /// is being read, so this is called from there and the repository's own
    /// file list says which servers to start.
    ///
    /// Once per root per run — a server already running is left alone, and a
    /// repository whose walk has been done is not walked again when the board
    /// comes back on screen.
    func prewarm(root: URL) {
        guard !prewarmed.contains(root) else { return }
        prewarmed.insert(root)
        Task { await startServers(inside: root) }
    }

    private func startServers(inside root: URL) async {
        let wanted = LanguageServerCatalog.shared.entriesByFileExtension
        let paths = await FileFinder.paths(in: root)

        // How much of the repository each server would serve. Counted rather
        // than collected: the list is only used to rank them.
        var counts: [String: Int] = [:]
        var byLanguage: [String: LanguageServerEntry] = [:]
        for path in paths {
            guard let dot = path.lastIndex(of: "."), dot != path.startIndex else { continue }
            let fileExtension = path[path.index(after: dot)...].lowercased()
            guard let entry = wanted[fileExtension] else { continue }
            counts[entry.language, default: 0] += 1
            byLanguage[entry.language] = entry
        }

        // Most of the repository first, and by name where two are level, so the
        // same repository always prewarms the same servers.
        let ranked = counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .compactMap { byLanguage[$0.key] }

        let wantedNow = Array(ranked.prefix(Self.prewarmLimit))
        var toInstall = wantedNow.map(\.executable)
        // A Vue repository needs the TypeScript server whether or not it has
        // enough `.ts` files of its own to rank for one: in hybrid mode the Vue
        // server answers nothing about types without it.
        if wantedNow.contains(where: { $0.language == LanguageServerCatalog.vue }),
           let typescript = typeScriptService(root: root)?.definition.executable,
           !toInstall.contains(typescript) {
            toInstall.append(typescript)
        }
        // Anything npm publishes and this Mac has not got, fetched into the
        // app's own folder first — see ``ManagedLanguageServers``. It asks
        // before the first one and does nothing at all if the answer was no.
        await ManagedLanguageServers.shared.installIfNeeded(toInstall)

        var started = 0
        for entry in wantedNow {
            guard started < Self.prewarmLimit else { break }
            // Asked before a service is made, so a server that is still not
            // there does not leave an "unavailable" row in the Info panel for a
            // file the user never opened.
            let ready = ManagedLanguageServers.shared.isInstalled(entry.executable)
                ? true
                : await Shell.isAvailable(entry.executable)
            guard ready else { continue }
            started += 1

            let key = Self.key(root: root, language: entry.language)
            let service = services[key]
                ?? LanguageService(definition: Self.definition(for: entry), root: root)
            services[key] = service
            // Deliberately not awaited in turn: sourcekit-lsp can spend the
            // best part of a minute on its handshake, and the servers behind it
            // in the queue should not be waiting for it to finish.
            Task { await service.startIfNeeded() }
        }
    }

    // MARK: - Hybrid mode

    /// The TypeScript server for a repository, started if it is not already.
    ///
    /// The Vue server needs it — see ``LanguageService/relayToTypeScript(_:)`` —
    /// and needs it whether or not a `.ts` file has ever been opened here, which
    /// is why this makes one rather than only finding one.
    func typeScriptService(root: URL) -> LanguageService? {
        let catalog = LanguageServerCatalog.shared
        guard let entry = catalog.entries.first(where: {
            $0.language == TreeSitterLanguage.typescript.rawValue
        }) else { return nil }
        let key = Self.key(root: root, language: entry.language)
        if let existing = services[key] { return existing }
        let service = LanguageService(definition: Self.definition(for: entry), root: root)
        services[key] = service
        return service
    }

    /// The second server a file wants open alongside its own, or nil for the
    /// files — nearly all of them — that want none.
    ///
    /// Only `.vue` does. Its server answers the template and the styles itself
    /// and forwards everything else to the TypeScript server, and that server
    /// can only answer about text it has been given: without this, every
    /// keystroke in a `<script>` block would be answered from the file as it
    /// was last saved.
    func companionService(for url: URL, root: URL) -> LanguageService? {
        guard url.pathExtension.lowercased() == "vue" else { return nil }
        return typeScriptService(root: root)
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
        // A repository added back is a repository to prewarm again.
        prewarmed.remove(root)
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
