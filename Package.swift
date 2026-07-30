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
        // The text view that editor is built on. It would arrive transitively
        // through CodeEditSourceEditor regardless; it is named here because our
        // own sources `import CodeEditTextView` and one of them reaches past the
        // editor's public surface into this package's layout internals.
        // `WidenDocumentForLongLines` in `Editor/CodeEditorView.swift` walks
        // `layoutManager.lineStorage`, reads each line's `lineFragments` and each
        // fragment's `width`, and adds `layoutManager.edgeInsets` back, so that an
        // unwrapped long line can be scrolled to its end — none of which the
        // package offers an API for. A transitive dependency is one nothing in
        // this manifest promises, and the version that satisfies it can move
        // whenever the editor's own requirement is re-resolved.
        //
        // Pinned exactly, to the version already in Package.resolved.
        // CodeEditSourceEditor 0.15.2 asks for `from: "0.12.1"`, so this narrows
        // that range rather than contradicting it. The pin is deliberate: raising
        // it is an audit of that coordinator, not a routine update, because
        // internal layout can be rearranged in a patch release and the compiler
        // is the only thing that would notice — and only if the names change.
        .package(url: "https://github.com/CodeEditApp/CodeEditTextView.git", exact: "0.12.1"),
        // The Markdown parser, and only a parser: an immutable markup tree over
        // swift-cmark — the same cmark-gfm both hosts render a comment with, so
        // the preview reads a document the way the host that served it does.
        // Nothing of the renderer comes from here; see Docs/Markdown.md for why
        // a library that draws as well was the wrong trade.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
        // The C parser under it. Named here rather than left transitive for the
        // same reason CodeEditTextView is: the grammar of the document is what
        // decides how every `.md` file, PR description and comment comes out, so
        // the version that decides it should be one this manifest states.
        .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.8.0"),
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
                .product(name: "CodeEditSourceEditor", package: "CodeEditSourceEditor"),
                .product(name: "CodeEditTextView", package: "CodeEditTextView"),
                .product(name: "Markdown", package: "swift-markdown")
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
