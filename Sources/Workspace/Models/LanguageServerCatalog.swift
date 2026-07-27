import CodeEditLanguages
import Foundation

/// One language server: which language it serves, and how to start it.
///
/// The built-in list covers the languages most repositories are written in, but
/// a language server is just a program on `$PATH`, so Settings lets the user add
/// their own and correct the command of any of ours.
struct LanguageServerEntry: Codable, Identifiable, Hashable, Sendable {
    /// `TreeSitterLanguage` raw value — what a file's language is matched on.
    var language: String
    /// The binary we look for on `$PATH`.
    var executable: String
    /// The full command line, run through a login shell.
    var command: String
    /// The LSP `languageId` sent with every document.
    var languageID: String
    /// What the Install button runs; empty when the server arrives with a
    /// toolchain rather than a package manager.
    var installCommand: String = ""

    var id: String { language }

    var languageName: String { LanguageServerCatalog.name(of: language) }
}

/// Every language server the app knows about, ours and the user's.
///
/// The built-in entries are the defaults; anything the user changes is kept in
/// `UserDefaults` as an override on top of them, so a later version of the app
/// can improve a default without silently overwriting a command someone fixed.
@MainActor
@Observable
final class LanguageServerCatalog {
    static let shared = LanguageServerCatalog()

    /// Built-ins the user has edited, plus the servers they added, by language.
    private var overrides: [String: LanguageServerEntry] = [:]
    /// Built-ins the user deleted.
    private var removed: Set<String> = []

    /// The merged list, sorted by language — what Settings shows and what the
    /// editor starts.
    private(set) var entries: [LanguageServerEntry] = []
    /// Whether each executable was found on `$PATH`, by executable name.
    private(set) var installed: [String: Bool] = [:]
    private(set) var isChecking = false

    private let overridesKey = "languageServers.overrides"
    private let removedKey = "languageServers.removed"

    private init() {
        load()
        rebuild()
    }

    // MARK: - Reading

    /// The server for a file's language, or nil when there is none.
    func entry(for language: CodeLanguage) -> LanguageServerEntry? {
        entries.first { $0.language == language.id.rawValue }
    }

    /// The server for a file whose language has no grammar, found by extension.
    ///
    /// Tried before ``entry(for:)``, because such a file is coloured with the
    /// nearest grammar there is — a `.vue` file as HTML — and that stand-in is
    /// not the language whose server it wants.
    func entry(forFile url: URL) -> LanguageServerEntry? {
        guard let language = Self.languagesByExtension[url.pathExtension.lowercased()] else { return nil }
        return entries.first { $0.language == language }
    }

    /// Which server each file extension wants — the whole catalog, turned
    /// round, for ``LanguageServerRegistry/prewarm(root:)``.
    ///
    /// A repository's file list is matched on extension alone and never on
    /// ``CodeLanguage/forFile(url:)``: that reads the *contents* of every file
    /// with no extension looking for a shebang, and a repository holds
    /// thousands of them. The languages with no grammar are folded in the same
    /// way ``entry(forFile:)`` does it, so a `.vue` file still asks for the Vue
    /// server rather than the HTML one.
    var entriesByFileExtension: [String: LanguageServerEntry] {
        var map: [String: LanguageServerEntry] = [:]
        for entry in entries {
            guard let language = Self.codeLanguage(for: entry.language) else { continue }
            for fileExtension in language.extensions {
                map[fileExtension.lowercased()] = entry
            }
        }
        for (fileExtension, language) in Self.languagesByExtension {
            guard let entry = entries.first(where: { $0.language == language }) else { continue }
            map[fileExtension] = entry
        }
        return map
    }

    func isBuiltIn(_ entry: LanguageServerEntry) -> Bool {
        Self.builtIn.contains { $0.language == entry.language }
    }

    /// True for a built-in whose command the user has changed.
    func isEdited(_ entry: LanguageServerEntry) -> Bool {
        guard let original = Self.builtIn.first(where: { $0.language == entry.language }) else { return false }
        return original != entry
    }

    var hasCustomisations: Bool { !overrides.isEmpty || !removed.isEmpty }

    /// The tree-sitter language an entry belongs to, when the grammar is known.
    static func codeLanguage(for language: String) -> CodeLanguage? {
        CodeLanguage.allLanguages.first { $0.id.rawValue == language }
    }

    /// Languages with no server yet — what the Add sheet offers. Helper grammars
    /// like `regex` and `jsdoc` never stand on their own, so they are left out.
    var languagesWithoutServer: [CodeLanguage] {
        let taken = Set(entries.map(\.language))
        let helpers: Set<String> = [
            TreeSitterLanguage.regex.rawValue,
            TreeSitterLanguage.jsdoc.rawValue,
            TreeSitterLanguage.markdownInline.rawValue
        ]
        return CodeLanguage.allLanguages
            .filter { !taken.contains($0.id.rawValue) && !helpers.contains($0.id.rawValue) }
            .sorted { Self.name(of: $0.id.rawValue) < Self.name(of: $1.id.rawValue) }
    }

    // MARK: - Editing

    /// Adds a server, or replaces the one for that language.
    func save(_ entry: LanguageServerEntry) {
        overrides[entry.language] = entry
        removed.remove(entry.language)
        persist()
        rebuild()
        restart(entry.language)
        Task { await refresh(entry.executable) }
    }

    /// Removes a server the user added, or hides one of ours.
    func delete(_ entry: LanguageServerEntry) {
        overrides[entry.language] = nil
        if Self.builtIn.contains(where: { $0.language == entry.language }) {
            removed.insert(entry.language)
        }
        persist()
        rebuild()
        restart(entry.language)
    }

    /// Puts a built-in back the way it shipped.
    func restoreDefault(for language: String) {
        overrides[language] = nil
        removed.remove(language)
        persist()
        rebuild()
        restart(language)
    }

    /// Drops every change, back to the built-in list.
    func restoreAllDefaults() {
        let touched = Set(overrides.keys).union(removed)
        overrides = [:]
        removed = []
        persist()
        rebuild()
        for language in touched { restart(language) }
        Task { await refresh() }
    }

    // MARK: - Installed check

    /// Whether each server can be started: either the app installed it itself,
    /// or it is on the same `$PATH` the editor will look on.
    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let executables = Set(entries.map(\.executable))
        let found = await withTaskGroup(of: (String, Bool).self) { group in
            for executable in executables {
                group.addTask { (executable, await Self.isPresent(executable)) }
            }
            var result: [String: Bool] = [:]
            for await pair in group { result[pair.0] = pair.1 }
            return result
        }
        installed = found
    }

    /// Re-checks one server, after an install.
    func refresh(_ executable: String) async {
        installed[executable] = await Self.isPresent(executable)
    }

    /// The app's own copy counts as installed — it is what the editor starts.
    private static func isPresent(_ executable: String) async -> Bool {
        if ManagedLanguageServers.shared.isInstalled(executable) { return true }
        return await Shell.isAvailable(executable)
    }

    // MARK: - Storage

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: overridesKey),
           let stored = try? JSONDecoder().decode([LanguageServerEntry].self, from: data) {
            overrides = Dictionary(uniqueKeysWithValues: stored.map { ($0.language, $0) })
        }
        removed = Set(defaults.stringArray(forKey: removedKey) ?? [])
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(Array(overrides.values)) {
            defaults.set(data, forKey: overridesKey)
        }
        defaults.set(Array(removed), forKey: removedKey)
    }

    private func rebuild() {
        var merged: [LanguageServerEntry] = []
        for entry in Self.builtIn where !removed.contains(entry.language) {
            merged.append(overrides[entry.language] ?? entry)
        }
        let builtInLanguages = Set(Self.builtIn.map(\.language))
        for entry in overrides.values where !builtInLanguages.contains(entry.language) {
            merged.append(entry)
        }
        entries = merged.sorted { $0.languageName.localizedCaseInsensitiveCompare($1.languageName) == .orderedAscending }
    }

    /// A running server still holds the old command line, so anything already
    /// started for that language is stopped; the next file opened starts it
    /// again from the entry as it now reads.
    private func restart(_ language: String) {
        LanguageServerRegistry.shared.shutdownServices(forLanguage: language)
    }

    // MARK: - Names

    private nonisolated static let displayNames: [String: String] = [
        TreeSitterLanguage.cpp.rawValue: "C++",
        TreeSitterLanguage.cSharp.rawValue: "C#",
        TreeSitterLanguage.c.rawValue: "C",
        TreeSitterLanguage.css.rawValue: "CSS",
        TreeSitterLanguage.goMod.rawValue: "Go Module",
        TreeSitterLanguage.html.rawValue: "HTML",
        TreeSitterLanguage.javascript.rawValue: "JavaScript",
        TreeSitterLanguage.jsdoc.rawValue: "JSDoc",
        TreeSitterLanguage.json.rawValue: "JSON",
        TreeSitterLanguage.jsx.rawValue: "JSX",
        TreeSitterLanguage.markdownInline.rawValue: "Markdown (inline)",
        TreeSitterLanguage.objc.rawValue: "Objective-C",
        TreeSitterLanguage.ocamlInterface.rawValue: "OCaml Interface",
        TreeSitterLanguage.ocaml.rawValue: "OCaml",
        TreeSitterLanguage.php.rawValue: "PHP",
        TreeSitterLanguage.sql.rawValue: "SQL",
        TreeSitterLanguage.toml.rawValue: "TOML",
        TreeSitterLanguage.tsx.rawValue: "TSX",
        TreeSitterLanguage.typescript.rawValue: "TypeScript",
        TreeSitterLanguage.yaml.rawValue: "YAML"
    ]

    /// What a language is called in the interface.
    nonisolated static func name(of language: String) -> String {
        if let name = displayNames[language] { return name }
        return language.prefix(1).uppercased() + language.dropFirst()
    }

    // MARK: - Defaults

    /// Vue, as an entry key. Not a `TreeSitterLanguage`: the grammars live in a
    /// prebuilt binary (`CodeLanguagesContainer`) that has no Vue in it and that
    /// we cannot add a case to. An entry may be keyed on any name, so Vue is
    /// keyed on this one and reached through ``languagesByExtension``.
    nonisolated static let vue = "vue"

    /// File extension → the entry key of a language with no grammar.
    private nonisolated static let languagesByExtension: [String: String] = ["vue": vue]

    /// The servers that ship with the app. `sourcekit-lsp` and `dart` come with
    /// their toolchains; everything else is one package manager line away.
    static let builtIn: [LanguageServerEntry] = [
        .init(
            language: TreeSitterLanguage.swift.rawValue,
            executable: "sourcekit-lsp",
            command: "sourcekit-lsp",
            languageID: "swift"
        ),
        .init(
            language: TreeSitterLanguage.objc.rawValue,
            executable: "clangd",
            command: "clangd --background-index",
            languageID: "objective-c",
            installCommand: "brew install llvm"
        ),
        .init(
            language: TreeSitterLanguage.c.rawValue,
            executable: "clangd",
            command: "clangd --background-index",
            languageID: "c",
            installCommand: "brew install llvm"
        ),
        .init(
            language: TreeSitterLanguage.cpp.rawValue,
            executable: "clangd",
            command: "clangd --background-index",
            languageID: "cpp",
            installCommand: "brew install llvm"
        ),
        .init(
            language: TreeSitterLanguage.typescript.rawValue,
            executable: "vtsls",
            command: "vtsls --stdio",
            languageID: "typescript",
            installCommand: "npm install -g typescript @vtsls/language-server"
        ),
        .init(
            language: TreeSitterLanguage.tsx.rawValue,
            executable: "vtsls",
            command: "vtsls --stdio",
            languageID: "typescriptreact",
            installCommand: "npm install -g typescript @vtsls/language-server"
        ),
        .init(
            language: TreeSitterLanguage.javascript.rawValue,
            executable: "vtsls",
            command: "vtsls --stdio",
            languageID: "javascript",
            installCommand: "npm install -g typescript @vtsls/language-server"
        ),
        .init(
            language: TreeSitterLanguage.jsx.rawValue,
            executable: "vtsls",
            command: "vtsls --stdio",
            languageID: "javascriptreact",
            installCommand: "npm install -g typescript @vtsls/language-server"
        ),
        // Hybrid mode, which is what 3.x does and all it does: this server
        // answers the template and the styles, and forwards everything needing
        // a type to the one `tsserver` vtsls is already running for the
        // repository. The editor carries those questions across — see
        // ``LanguageService/relayToTypeScript(_:)`` — and vtsls is told to load
        // `@vue/typescript-plugin` by ``LanguageServerSettings``.
        //
        // The 2.x pin this replaces was the other way round: hybrid mode turned
        // *off*, so the server kept a TypeScript project of its own and a Vue
        // repository paid for TypeScript twice.
        .init(
            language: vue,
            executable: "vue-language-server",
            command: "vue-language-server --stdio",
            languageID: "vue",
            // No TypeScript alongside it any more: it no longer loads one.
            installCommand: "npm install -g @vue/language-server"
        ),
        .init(
            language: TreeSitterLanguage.python.rawValue,
            executable: "pyright-langserver",
            command: "pyright-langserver --stdio",
            languageID: "python",
            installCommand: "npm install -g pyright"
        ),
        .init(
            language: TreeSitterLanguage.go.rawValue,
            executable: "gopls",
            command: "gopls",
            languageID: "go",
            installCommand: "go install golang.org/x/tools/gopls@latest"
        ),
        .init(
            language: TreeSitterLanguage.rust.rawValue,
            executable: "rust-analyzer",
            command: "rust-analyzer",
            languageID: "rust",
            installCommand: "brew install rust-analyzer"
        ),
        .init(
            // Shopify's, not solargraph: solargraph slows to a crawl on a large
            // repository and can hang outright on a symbol search, which is
            // exactly the size of project this app is pointed at.
            language: TreeSitterLanguage.ruby.rawValue,
            executable: "ruby-lsp",
            command: "ruby-lsp",
            languageID: "ruby",
            installCommand: "gem install ruby-lsp"
        ),
        .init(
            language: TreeSitterLanguage.php.rawValue,
            executable: "intelephense",
            command: "intelephense --stdio",
            languageID: "php",
            installCommand: "npm install -g intelephense"
        ),
        .init(
            language: TreeSitterLanguage.dart.rawValue,
            executable: "dart",
            command: "dart language-server --protocol=lsp",
            languageID: "dart"
        ),
        .init(
            language: TreeSitterLanguage.lua.rawValue,
            executable: "lua-language-server",
            command: "lua-language-server",
            languageID: "lua",
            installCommand: "brew install lua-language-server"
        ),
        .init(
            // JetBrains', built on IntelliJ's own analysis. The community
            // `kotlin-language-server` it replaces is a project its author has
            // said he no longer uses Kotlin to maintain.
            language: TreeSitterLanguage.kotlin.rawValue,
            executable: "kotlin-lsp",
            command: "kotlin-lsp --stdio",
            languageID: "kotlin",
            installCommand: "brew install JetBrains/utils/kotlin-lsp"
        ),
        .init(
            language: TreeSitterLanguage.json.rawValue,
            executable: "vscode-json-language-server",
            command: "vscode-json-language-server --stdio",
            languageID: "json",
            installCommand: "npm install -g vscode-langservers-extracted"
        ),
        .init(
            language: TreeSitterLanguage.yaml.rawValue,
            executable: "yaml-language-server",
            command: "yaml-language-server --stdio",
            languageID: "yaml",
            installCommand: "npm install -g yaml-language-server"
        ),
        .init(
            language: TreeSitterLanguage.html.rawValue,
            executable: "vscode-html-language-server",
            command: "vscode-html-language-server --stdio",
            languageID: "html",
            installCommand: "npm install -g vscode-langservers-extracted"
        ),
        .init(
            language: TreeSitterLanguage.css.rawValue,
            executable: "vscode-css-language-server",
            command: "vscode-css-language-server --stdio",
            languageID: "css",
            installCommand: "npm install -g vscode-langservers-extracted"
        ),
        .init(
            language: TreeSitterLanguage.bash.rawValue,
            executable: "bash-language-server",
            command: "bash-language-server start",
            languageID: "shellscript",
            installCommand: "npm install -g bash-language-server"
        )
    ]
}
