// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Workspace",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Tree-sitter grammars and highlight queries. The editor itself is ours:
        // NSTextView + tree-sitter + LSP, see Sources/Workspace/Editor.
        // Vendored rather than fetched: the upstream repository carries every
        // historical revision of every grammar, so cloning it costs ~600 MB
        // against 34 MB for the release source. See Vendor/README.md.
        .package(path: "Vendor/CodeEditLanguages"),
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
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages")
            ],
            path: "Sources/Workspace",
            // The Mermaid renderer's HTML host and its bundled script, loaded
            // through `Bundle.module` at runtime.
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
