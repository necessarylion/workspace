import Foundation

/// The language servers the app installs and owns, as against the ones the user
/// put on their `PATH` themselves.
///
/// Zed's arrangement, for Zed's reason: a language server is a dependency of
/// the editor, not of the machine. Everything lands under Application Support,
/// nothing is written to Homebrew, the global npm prefix or the gems, and
/// uninstalling is deleting one folder. It also settles the `PATH` question for
/// good — a server the app put there is one the app knows the absolute path of,
/// whatever nvm is doing today.
///
/// Only the **npm-published** servers are handled. They are the ones worth
/// automating: they install the same way on every Mac, they are what most
/// repositories want, and they are the ones a version manager hides. The rest
/// either arrive with a toolchain (`sourcekit-lsp`, `clangd`, `dart`) or need a
/// release asset picked per architecture (`rust-analyzer`, `kotlin-lsp`), and
/// they keep the Install button in Settings.
@MainActor
@Observable
final class ManagedLanguageServers {
    static let shared = ManagedLanguageServers()

    /// Whether the app may install servers on its own.
    ///
    /// `unasked` until the first repository wants one, which is the only moment
    /// the question means anything — asking at launch would be asking about
    /// something that may never happen.
    enum Consent: String {
        case unasked, allowed, denied
    }

    /// What one package installs, and the binaries it puts in `.bin`.
    struct Recipe: Sendable, Hashable {
        /// What `npm install` is given — several when a server is useless
        /// without a peer.
        let packages: [String]
        let executables: [String]

        /// The folder this package gets to itself, under ``directory`` —
        /// `@vue/language-server@2` becomes `vue-language-server`.
        ///
        /// The version is dropped so that changing the pin reuses the folder
        /// and npm upgrades in place, rather than leaving the old one behind.
        var folder: String {
            var name = packages[0]
            // The `@` that starts a scope is not the one that marks a version.
            if !name.isEmpty,
               let version = name.range(of: "@", range: name.index(after: name.startIndex)..<name.endIndex) {
                name = String(name[..<version.lowerBound])
            }
            return name
                .replacingOccurrences(of: "@", with: "")
                .replacingOccurrences(of: "/", with: "-")
        }
    }

    /// Servers currently being installed, by executable — the Info panel and
    /// Settings both read this to say so rather than "not installed".
    private(set) var installing: Set<String> = []
    /// Why the last attempt failed, by executable.
    private(set) var failures: [String: String] = [:]
    /// Set when an install wants the user's answer. ``ContentView`` shows it.
    var consentRequest: [String]?

    /// Stored rather than read back out of `UserDefaults` each time: this is
    /// what the Settings checkbox is bound to, and `@Observable` only notices a
    /// stored property changing.
    private(set) var consent: Consent

    private static let consentKey = "languageServers.autoInstall"

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.consentKey) ?? ""
        consent = Consent(rawValue: stored) ?? .unasked
    }

    // MARK: - Consent

    func setConsent(_ value: Consent) {
        consent = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.consentKey)
    }

    /// Answers the alert. Allowing it starts what was waiting behind it.
    func answerConsent(allow: Bool) {
        let waiting = consentRequest ?? []
        consentRequest = nil
        setConsent(allow ? .allowed : .denied)
        guard allow else { return }
        for executable in waiting {
            Task { await install(executable) }
        }
    }

    // MARK: - Where they live

    /// `~/Library/Application Support/Workspace/LanguageServers`.
    static let directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base
            .appendingPathComponent("Workspace", isDirectory: true)
            .appendingPathComponent("LanguageServers", isDirectory: true)
    }()

    /// The `.bin` folder holding an executable we installed, or nil when we did
    /// not install it. This is what goes on the front of the server's `PATH`.
    func binDirectory(for executable: String) -> URL? {
        guard let recipe = Self.recipe(for: executable) else { return nil }
        let bin = Self.directory
            .appendingPathComponent(recipe.folder, isDirectory: true)
            .appendingPathComponent("node_modules/.bin", isDirectory: true)
        let binary = bin.appendingPathComponent(executable)
        return FileManager.default.isExecutableFile(atPath: binary.path) ? bin : nil
    }

    /// Where one npm package landed, for the servers that have to be pointed at
    /// another server's *files* rather than at its binary —
    /// ``LanguageServerSettings`` needs the Vue plugin's package directory.
    func packageDirectory(for executable: String, package: String) -> URL? {
        guard let recipe = Self.recipe(for: executable) else { return nil }
        let directory = Self.directory
            .appendingPathComponent(recipe.folder, isDirectory: true)
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent(package, isDirectory: true)
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }

    /// True when the app either has this server already or knows how to get it.
    func isManaged(_ executable: String) -> Bool {
        Self.recipe(for: executable) != nil
    }

    func isInstalled(_ executable: String) -> Bool {
        binDirectory(for: executable) != nil
    }

    // MARK: - Installing

    /// Installs every server in the list that is missing, asking first if the
    /// question has not been put yet.
    ///
    /// Returns the ones that are ready by the time it comes back, so a caller
    /// prewarming a repository can start those and leave the rest.
    @discardableResult
    func installIfNeeded(_ executables: [String]) async -> [String] {
        let missing = executables.filter { isManaged($0) && !isInstalled($0) }
        guard !missing.isEmpty else { return executables.filter(isInstalled) }

        switch consent {
        case .denied:
            return executables.filter(isInstalled)
        case .unasked:
            // Queued rather than installed: nothing is written until the sheet
            // is answered, and answering it picks this list back up.
            if consentRequest == nil { consentRequest = missing }
            return executables.filter(isInstalled)
        case .allowed:
            break
        }

        for executable in missing {
            await install(executable)
        }
        return executables.filter(isInstalled)
    }

    /// One server, fetched into its own folder. Idempotent — a package already
    /// there is left alone.
    @discardableResult
    func install(_ executable: String) async -> Bool {
        guard let recipe = Self.recipe(for: executable) else { return false }
        guard !isInstalled(executable) else { return true }
        // Several servers come out of one package; one install serves them all.
        guard !installing.contains(executable) else { return false }

        let claimed = recipe.executables
        installing.formUnion(claimed)
        for name in claimed { failures[name] = nil }
        defer { installing.subtract(claimed) }

        let folder = Self.directory.appendingPathComponent(recipe.folder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            for name in claimed { failures[name] = error.localizedDescription }
            return false
        }

        // `--prefix` is what keeps this out of the user's global npm: the
        // package tree is written under our folder and nothing else is touched.
        // `--no-package-lock` because there is no project here to lock, and the
        // silencing flags because nobody is reading npm's output.
        let result = await Shell.run(
            ["npm", "install", "--prefix", folder.path,
             "--no-fund", "--no-audit", "--no-package-lock", "--loglevel", "error"]
                + recipe.packages,
            in: folder,
            timeout: 300
        )

        guard result.isSuccess, isInstalled(executable) else {
            let message = result.failureMessage
            for name in claimed {
                failures[name] = message.isEmpty ? "npm could not install \(recipe.packages.joined(separator: " "))." : message
            }
            return false
        }
        return true
    }

    /// Throws the folder away, for Settings.
    func removeAll() {
        try? FileManager.default.removeItem(at: Self.directory)
        failures = [:]
    }

    // MARK: - Recipes

    static func recipe(for executable: String) -> Recipe? {
        recipes.first { $0.executables.contains(executable) }
    }

    /// The npm-published servers, and what to ask npm for.
    ///
    /// `typescript` is asked for alongside vtsls because vtsls is a wrapper: it
    /// brings no compiler of its own, and a repository that has not had
    /// `npm install` run in it yet has none either. The Vue server needs none —
    /// in hybrid mode it does no type checking itself.
    private static let recipes: [Recipe] = [
        .init(
            packages: ["@vtsls/language-server", "typescript@5"],
            executables: ["vtsls"]
        ),
        .init(
            packages: ["@vue/language-server"],
            executables: ["vue-language-server"]
        ),
        .init(
            packages: ["vscode-langservers-extracted"],
            executables: [
                "vscode-html-language-server",
                "vscode-css-language-server",
                "vscode-json-language-server",
                "vscode-eslint-language-server"
            ]
        ),
        .init(packages: ["yaml-language-server"], executables: ["yaml-language-server"]),
        .init(packages: ["bash-language-server"], executables: ["bash-language-server"]),
        .init(packages: ["pyright"], executables: ["pyright-langserver"]),
        .init(packages: ["intelephense"], executables: ["intelephense"])
    ]
}
