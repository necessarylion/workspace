// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Workspace",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Tree-sitter grammars and highlight queries. The editor itself is ours:
        // NSTextView + tree-sitter + LSP, see Sources/Workspace/Editor.
        .package(url: "https://github.com/CodeEditApp/CodeEditLanguages.git", exact: "0.1.20")
    ],
    targets: [
        .executableTarget(
            name: "Workspace",
            dependencies: [
                "GhosttyKit",
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages")
            ],
            path: "Sources/Workspace",
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
        ),
        // The terminal: libghostty built as an xcframework with
        // `zig build -Dxcframework-target=native`; see Docs/Terminal.md.
        .binaryTarget(
            name: "GhosttyKit",
            path: ".deps/GhosttyKit.xcframework"
        )
    ]
)
