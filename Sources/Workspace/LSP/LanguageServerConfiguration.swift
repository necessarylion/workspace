import Foundation

/// The workspace settings a server is given — what it gets back when it asks
/// `workspace/configuration`, and what it is sent on
/// `workspace/didChangeConfiguration`.
///
/// Separate from ``LanguageServerOptions`` because the two are answered at
/// different moments and mean different things: `initializationOptions` is part
/// of the handshake and cannot change, settings are the user's configuration
/// and are asked for again whenever the server feels like it.
///
/// Only one server needs any of this, and it is the important one — see
/// ``vtslsSettings``.
@MainActor
enum LanguageServerConfiguration {
    /// Settings for one server rooted at one project, or nil when it wants none.
    static func settings(for definition: LanguageServerDefinition, root: URL) async -> LSP.Value? {
        guard definition.executable == "vtsls" else { return nil }
        return await vtslsSettings()
    }

    /// Tells vtsls to load `@vue/typescript-plugin` into its `tsserver`.
    ///
    /// This is the whole of hybrid mode on the TypeScript side. The Vue server
    /// answers a `.vue` file's template and styles itself, but everything that
    /// needs to know what a type *is* it forwards to a `tsserver` — and only a
    /// `tsserver` with this plugin loaded understands a `.vue` file at all.
    /// Without it the forwarded questions come back empty and the file appears
    /// to have no types, which looks exactly like a broken server.
    ///
    /// Nil when the Vue server cannot be found: there is then no plugin to
    /// point at, and vtsls is better off starting as a plain TypeScript server
    /// than refusing to start over a plugin path that does not exist.
    private static func vtslsSettings() async -> LSP.Value? {
        guard let plugin = await vuePluginLocation() else { return nil }
        return .object([
            "vtsls": .object([
                "tsserver": .object([
                    "globalPlugins": .array([
                        .object([
                            "name": .string("@vue/typescript-plugin"),
                            // The *package* directory, not the binary: tsserver
                            // loads it as a module.
                            "location": .string(plugin),
                            // Both of these are required even though the name
                            // suggests otherwise — the plugin serves `.vue`
                            // only when it is listed here, and it reads its
                            // configuration out of the `typescript` namespace.
                            "languages": .array([.string("vue")]),
                            "configNamespace": .string("typescript"),
                            "enableForWorkspaceTypeScriptVersions": .bool(true)
                        ])
                    ])
                ])
            ])
        ])
    }

    /// Where `@vue/language-server` is unpacked — the app's own copy first,
    /// since that is the one whose path is certain, then the global npm root
    /// for a user who installed it themselves.
    private static func vuePluginLocation() async -> String? {
        if let managed = ManagedLanguageServers.shared.packageDirectory(
            for: "vue-language-server",
            package: "@vue/language-server"
        ) {
            return managed.path
        }
        guard let global = await globalNodeModules() else { return nil }
        let path = global.appendingPathComponent("@vue/language-server").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// `npm root -g`, asked once — it costs a shell and does not change while
    /// the app is open.
    private static func globalNodeModules() async -> URL? {
        if let cached = cachedGlobalRoot { return cached }
        let result = await Shell.run(["npm", "root", "-g"], timeout: 20)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let found = result.isSuccess && !path.isEmpty ? URL(fileURLWithPath: path) : nil
        cachedGlobalRoot = .some(found)
        return found
    }

    private static var cachedGlobalRoot: URL??
}
