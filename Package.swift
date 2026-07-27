// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Workspace",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Tree-sitter grammars and highlight queries. Still a direct dependency
        // of ours as well as CodeEditSourceEditor's: `DiffHighlighter` and
        // `MarkdownCodeHighlighter` colour snippets that live in no editor.
        //
        // Vendored rather than fetched: the upstream repository carries every
        // historical revision of every grammar, so cloning it costs ~600 MB
        // against 34 MB for the release source. See Vendor/README.md. This path
        // dependency also *overrides* the `exact: "0.1.20"` requirement
        // CodeEditSourceEditor declares on the same package — a root-package
        // path dependency wins on identity — which is what keeps that 600 MB
        // clone from arriving through the back door. The vendored tree is 0.1.20,
        // so the version it asks for is the version it gets.
        .package(path: "Vendor/CodeEditLanguages"),
        // The editor. Was hand-rolled (NSTextView + TextKit 1 + our own
        // tree-sitter highlighter); this replaces it wholesale, and is used with
        // its own defaults — its highlighting, its gutter, its find panel.
        .package(url: "https://github.com/CodeEditApp/CodeEditSourceEditor.git", exact: "0.15.2"),
        // The terminal engine. Upstream ghostty ships no reusable framework, so
        // this package supplies libghostty as a prebuilt universal
        // (arm64 + x86_64) xcframework that SwiftPM downloads and
        // checksum-verifies; see Docs/Terminal.md.
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", exact: "1.3.1")
    ],
    targets: [
        .executableTarget(
            name: "Workspace",
            dependencies: [
                // Re-exports the libghostty C module, so `import GhosttyKit`
                // still yields ghostty_app_t, ghostty_surface_new and friends.
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages"),
                .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor")
            ],
            path: "Sources/Workspace",
            // The diagram renderers' HTML hosts with their bundled scripts, and
            // Claude's mark — all loaded through `Bundle.module` at runtime.
            resources: [.process("Resources")],
            linkerSettings: [
                // Everything libghostty (a static Zig/C/C++ archive) pulls in.
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedFramework("Cocoa"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Carbon"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        )
    ]
)
