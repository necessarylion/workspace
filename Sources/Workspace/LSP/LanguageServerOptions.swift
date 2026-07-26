import Foundation

/// The `initializationOptions` a server is handed, for the ones that need more
/// than a command line to start usefully.
///
/// Almost every server we ship needs nothing here — it reads the project's own
/// configuration off disk and gets on with it. Vue is the exception, and the
/// reason this exists.
@MainActor
enum LanguageServerOptions {
    /// What went wrong before the server was even started.
    enum Failure: LocalizedError {
        case typeScriptNotFound
        case vueServerTooNew(String)

        var errorDescription: String? {
            switch self {
            case .typeScriptNotFound:
                "No usable TypeScript for the Vue server — it needs 5.x. "
                    + "Install one in the project (`npm install -D typescript@5`) "
                    + "or globally (`npm install -g typescript@5`)."
            case .vueServerTooNew(let version):
                "vue-language-server \(version) cannot work here — it answers only through a "
                    + "tsserver this editor does not run. Install 2.x: "
                    + "`npm install -g @vue/language-server@2`."
            }
        }
    }

    /// Options for one server rooted at one project, or nil when it wants none.
    static func initializationOptions(
        for definition: LanguageServerDefinition,
        root: URL
    ) async throws -> LSP.Value? {
        guard definition.language == LanguageServerCatalog.vue else { return nil }

        // Asked outright, because the alternative is a 45-second wait on a
        // request the 3.x server was never going to answer, reported as though
        // it were still indexing.
        if let version = await vueServerVersion(definition.executable),
           let major = Int(version.prefix(while: \.isNumber)), major > 2 {
            throw Failure.vueServerTooNew(version)
        }

        guard let tsdk = await typeScriptSDK(near: root) else { throw Failure.typeScriptNotFound }
        return .object([
            // Where to load the TypeScript that types the `<script>` block.
            "typescript": .object(["tsdk": .string(tsdk)]),
            // Hybrid mode — the server's default — answers nothing itself. It
            // forwards every question to a `tsserver` the *client* is expected
            // to be running with `@vue/typescript-plugin` loaded, over
            // `tsserver/request` notifications that are not part of the
            // protocol. We run no such process, so those questions would never
            // be answered and every hover, completion and diagnostic would hang
            // for ever. Turned off, the server keeps its own TypeScript project
            // and replies on its own, which is what this editor can use.
            "vue": .object(["hybridMode": .bool(false)])
        ])
    }

    /// The `lib` directory of the TypeScript the Vue server should load.
    ///
    /// The project's own copy comes first, and not only out of politeness: it is
    /// the version the code was written against, and a Vue project has one
    /// nearly always. A workspace keeps its `node_modules` at the top rather
    /// than in each package, so the parent folders are tried too before falling
    /// back to whatever is installed globally.
    ///
    /// What is looked for is `typescript.js` rather than the directory, because
    /// that file is also what tells a usable version from the rest: the 7.x
    /// package is the Go rewrite, and ships a `lib` holding little more than
    /// `tsc.js`. Passing that one on is what turns into "the Vue server died on
    /// its first request"; skipping it gives the plain message above instead.
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
        return await globalTypeScriptSDK()
    }

    /// `npm root -g`, asked once — it costs a shell and does not change while
    /// the app is open. The box holds the answer even when that answer is "none",
    /// so a machine without a global TypeScript is not asked again and again.
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

    /// `vue-language-server --version`, which both 2.x and 3.x answer with a
    /// bare version and nothing else. Nil when it cannot be asked — then the
    /// server is given the benefit of the doubt and started anyway.
    private static func vueServerVersion(_ executable: String) async -> String? {
        let result = await Shell.run([executable, "--version"], timeout: 20)
        guard result.isSuccess else { return nil }
        let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? nil : version
    }
}
