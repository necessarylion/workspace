import CodeEditLanguages
import Foundation

/// The `initializationOptions` a server is handed, for the ones that need more
/// than a command line to start usefully.
///
/// Almost every server we ship needs nothing here — it reads the project's own
/// configuration off disk and gets on with it. Vue is the exception, and the
/// reason this exists.
///
/// What it needs is much smaller than it was, because the arrangement changed:
/// the Vue server now runs in **hybrid mode**, keeping no TypeScript project of
/// its own and forwarding every typed question to the `tsserver` vtsls is
/// already running for the repository. Finding a TypeScript for it to *load* is
/// therefore no longer this file's problem — that is
/// ``LanguageServerConfiguration``' job, on the vtsls side.
@MainActor
enum LanguageServerOptions {
    /// What went wrong before the server was even started.
    enum Failure: LocalizedError {
        case typeScriptServerMissing(String)
        case typeScriptSDKMissing

        var errorDescription: String? {
            switch self {
            case .typeScriptServerMissing(let executable):
                "The Vue server cannot answer anything about types without \(executable). "
                    + "Install it from Settings → Language Servers."
            case .typeScriptSDKMissing:
                "The Vue server needs a TypeScript 5 or 6 to load. Add one to the project "
                    + "(npm install -D typescript), or install one globally — a global "
                    + "TypeScript 7 cannot be used, it is the Go rewrite and ships no "
                    + "typescript.js for a language server to load."
            }
        }
    }

    /// Options for one server rooted at one project, or nil when it wants none.
    static func initializationOptions(
        for definition: LanguageServerDefinition,
        root: URL
    ) async throws -> LSP.Value? {
        guard definition.language == LanguageServerCatalog.vue else { return nil }

        // Asked outright, because the alternative is every hover and completion
        // in a `.vue` file hanging until it times out: in hybrid mode the Vue
        // server asks the client, and a client with no TypeScript server behind
        // it has nothing to answer with.
        let typescript = typeScriptExecutable
        guard await isAvailable(typescript) else { throw Failure.typeScriptServerMissing(typescript) }

        // **Not optional, whatever it looks like.** The server's entry point does
        //
        //     loadTsdkByPath(options.typescript.tsdk, params.locale)
        //
        // before it looks at anything else, so options without this key are not
        // "options with a default" — they are a `TypeError` on `initialize` and a
        // server that dies during the handshake. Every ⌘-click then draws the
        // package's "no definition" bezel, for symbols that plainly have one,
        // which is a long way from the actual problem. Better to refuse here and
        // say what is missing.
        guard let tsdk = await typeScriptSDK(near: root) else {
            throw Failure.typeScriptSDKMissing
        }

        return .object([
            // Hybrid mode is this server's default (`options.vue?.hybridMode ??
            // true`); said out loud because it is the arrangement the vtsls side
            // is configured for, and a default is free to change.
            "vue": .object(["hybridMode": .bool(true)]),
            "typescript": .object(["tsdk": .string(tsdk)])
        ])
    }

    private static var typeScriptExecutable: String {
        LanguageServerCatalog.shared.entries
            .first { $0.language == TreeSitterLanguage.typescript.rawValue }?
            .executable ?? "vtsls"
    }

    private static func isAvailable(_ executable: String) async -> Bool {
        if ManagedLanguageServers.shared.isInstalled(executable) { return true }
        return await Shell.isAvailable(executable)
    }

    /// The `lib` directory of a TypeScript the Vue server can load.
    ///
    /// The project's own copy comes first: it is the version the code was
    /// written against, and a Vue project has one nearly always. A workspace
    /// keeps its `node_modules` at the top rather than in each package, so the
    /// parent folders are tried too, and the app's own copy is the last resort.
    ///
    /// What is looked for is `typescript.js` rather than the directory, because
    /// that file is also what tells a usable version from the rest: the 7.x
    /// package is the Go rewrite, and ships a `lib` holding little more than
    /// `tsc.js`.
    private static func typeScriptSDK(near root: URL) async -> String? {
        var directory = root.standardizedFileURL
        while true {
            let lib = directory.appendingPathComponent("node_modules/typescript/lib")
            if FileManager.default.fileExists(atPath: lib.appendingPathComponent("typescript.js").path) {
                return lib.path
            }
            let parent = directory.deletingLastPathComponent().standardizedFileURL
            if parent == directory { break }
            directory = parent
        }
        if let managed = ManagedLanguageServers.shared.packageDirectory(for: "vtsls", package: "typescript") {
            let lib = managed.appendingPathComponent("lib")
            if FileManager.default.fileExists(atPath: lib.appendingPathComponent("typescript.js").path) {
                return lib.path
            }
        }
        return await globalTypeScriptSDK()
    }

    /// `npm root -g`, asked once — it costs a shell and does not change while
    /// the app is open. The box holds the answer even when that answer is
    /// "none", so a machine without a global TypeScript is not asked again.
    private static func globalTypeScriptSDK() async -> String? {
        if let cached = cachedGlobalSDK { return cached }
        let result = await Shell.run(["npm", "root", "-g"], timeout: 20)
        var found: String?
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isSuccess, !path.isEmpty {
            let lib = URL(fileURLWithPath: path).appendingPathComponent("typescript/lib")
            if FileManager.default.fileExists(atPath: lib.appendingPathComponent("typescript.js").path) {
                found = lib.path
            }
        }
        cachedGlobalSDK = .some(found)
        return found
    }

    private static var cachedGlobalSDK: String??
}
