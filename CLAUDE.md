# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Workspace — a native macOS app (SwiftUI + AppKit, Swift 6, macOS 14+) for working
across GitHub and Bitbucket repositories: repo dashboard, PR review with comments,
diff viewing, a custom code editor (tree-sitter + LSP), and an embedded terminal
that can drive Claude Code. Single executable target, no test target.

## Build and run

```sh
Scripts/run.sh          # build, wrap in Workspace.app, launch
Scripts/bundle.sh       # build + bundle only, prints the .app path
Scripts/bundle.sh Release   # both scripts take an optional configuration
```

- **`swift build` does NOT work.** A dependency ships an asset catalog that only
  Xcode's build system can compile. Always build via the scripts (they run
  `xcodebuild` with derived data in `.build/xcode`) or open `Package.swift` in Xcode.
- The scripts set `DISABLE_SWIFTLINT=1` and `-skipPackagePluginValidation` because
  CodeEditLanguages' SwiftLint plugin fails on Xcode 26. Keep those if editing the scripts.
- For a compile check without launching: `Scripts/bundle.sh` is the fastest supported path.
- `Release` builds a universal arm64 + x86_64 binary; `Debug` builds only for this
  machine, so the edit-run loop stays fast. `UNIVERSAL=1` forces both in Debug.
- A bare checkout builds, which is what lets CI (`.github/workflows/build.yml`,
  hosted macOS runner) work. `CodeEditLanguages` is vendored in `Vendor/` and
  referenced with `.package(path:)` — cloning it instead costs ~600 MB, see
  `Vendor/README.md`. `libghostty` arrives through the `libghostty-spm`
  package, which supplies it as a checksum-pinned universal xcframework.
- Ghostty's runtime resources live in `Resources/ghostty-share/` and are checked
  in; they are not part of the xcframework, and the terminal needs them.

Runtime expectations: `gh` (GitHub), `bkt` (Bitbucket), and `claude` are external
CLIs discovered on the user's PATH, not bundled.

## Architecture

The app is one window with three panes, and the mental model that drives the code:

- **`Models/WorkspaceStore.swift`** — the single source of truth (`@Observable`,
  `@MainActor`). The centre viewer shows exactly **one** `ViewerItem` (file | diff |
  PR | terminal) at a time; opening something replaces it and pushes the previous
  item onto a browser-style back/forward history. Most UI state changes go through
  this store.
- **`Models/Project.swift`** — one added repository: remote detection
  (`RemoteInfo.swift` parses the `origin` URL, including SSH aliases), git status,
  PRs, listening ports, lazy file tree.
- **`Models/KeyboardShortcuts.swift`** — every key the app binds for itself, and
  the only place one is named. A command declares a `ShortcutAction` with a
  default `KeyChord`; the menu item wears it with `.shortcut(_:)` and a window
  key monitor matches it with `chord.matches(event)`, so Settings → Shortcuts
  changes both at once. Adding a shortcut means adding a case, not a literal —
  a `.keyboardShortcut("x", …)` anywhere but a sheet's Cancel/Default button is
  a key the user cannot change. Overrides only, stored in `UserDefaults`, so a
  default that moves in a later release follows.
- **`Support/Shell.swift`** — the only way external tools are run. Everything goes
  through the user's **login shell** (`$SHELL -lc`) on purpose, because a GUI app
  inherits a bare PATH. A login shell alone still misses version managers (gvm,
  nvm, pyenv), which extend PATH from `~/.zshrc` — zsh only reads that when
  interactive — so `InteractivePath` resolves `$PATH` once via `$SHELL -ilc` and
  injects it into every command. It quotes arguments, uses temp files instead of
  pipes (avoids deadlock), and enforces a timeout. Route any new git/gh/bkt/claude
  invocation through it. The one exception is a command **typed into the embedded
  terminal** (`TerminalSession.send`/`runClaude`): that PTY is already an
  interactive login shell, so it has the fuller PATH by itself, and `Shell` — no
  terminal, output captured, watchdog timeout — cannot host a CLI a person is
  talking to. Such a call still quotes outside values with `Shell.quote`.
- **Host abstraction** — `PullRequest.swift` / `PullRequestComment.swift` define a
  unified PR model with separate `gh` and `bkt` loaders. New PR features must be
  implemented for both hosts.
- **Themes** (`Themes/`) — one `SyntaxPalette` per file (capture name → colour),
  listed in `Themes.swift`; the first entry is the default. They are checked in
  rather than read from the user's VS Code at runtime, so a file looks the same
  on every Mac. `Scripts/import-vscode-theme.swift "Some Theme"` ports a new one.
- **Editor** (`Editor/`) — `CodeEditSourceEditor`, used with its own defaults:
  highlighting, the gutter, find and replace and bracket matching are the
  package's. `CodeEditorView` is the whole of the app's side — the text binding,
  the caret the status bar reads, and the coordinators. Two of those exist:
  one makes the scroll view clip (the gutter is a floating subview and would
  otherwise draw up through the header), and `LanguageServerCoordinator` is the
  language server join. `TreeSitterHighlighter` survives for the diff and for
  markdown snippets, which live in no editor. Don't reach for an `NSTextView`
  API here: the package's `TextView` is not one.
- **Markdown** — the parse and the renderer are separate on purpose, and only
  the renderer is ours. `Support/MarkdownParser.swift` walks
  [swift-markdown](https://github.com/swiftlang/swift-markdown)'s tree (cmark-gfm,
  which is what both hosts render a comment with) into `MarkdownText.Block`, and
  `Views/MarkdownPreview.swift` draws those blocks for `.md` files, PR
  descriptions and comments alike. Read `Docs/Markdown.md` before changing any of
  it: it records why the parser was replaced and why a library that renders too
  was the wrong trade.
  - The blocks carry **Markdown strings**, which the views read back with
    `AttributedString(markdown:)` — so everything the parser writes into one goes
    through `Support/MarkdownInline.swift`, which escapes plain text and is also
    where the four things cmark does not answer live: a bare URL, `:tada:`,
    `#123` and `@name`. That is one scan over `Text` nodes, not four passes.
  - HTML arrives **raw and flat**: cmark splits `<details>` into three siblings —
    the open tag, the inner Markdown parsed properly, the close tag — so
    `Support/MarkdownHTMLText.swift` reads one raw block into events and
    `ContainerStack` in the parser keeps the stack. It is not an HTML parser: an
    unknown tag is dropped and its text kept, `<!-- … -->` goes nowhere, and
    only the plain shape of a `<table>` is read.
  - Comments are dropped **from the tree, not from the text**, because every
    node carries a 1-based source line and that is what a tickable checkbox
    writes back to (`MarkdownTask.toggling`). Cutting lines out beforehand would
    move every line number in the document.
  - A fenced block is coloured by `Models/MarkdownCodeHighlighter.swift`, which
    runs the editor's `TreeSitterHighlighter` over the snippet and takes its
    colours from the current palette — the fence's language word replaces the
    file name the editor detects from, and the result is cached per (language,
    palette, text). A ` ```mermaid ` fence goes to `Views/MermaidDiagramView.swift`.
  - `MarkdownText.Block` is `indirect` because a quote, a `<details>` section and
    a list item all hold blocks, so a new case has to be answered in
    `Support/MarkdownHTML.swift` too — that is the PDF, and it walks the same
    blocks on purpose so the page and the file cannot drift.
- **Diagrams** (`Views/DiagramWebView.swift`) — mermaid fences and `.drawio`
  files are both drawn by the real JavaScript library in a `WKWebView`, and both
  go through this one representable: it loads a page from `Resources/` as a
  **file URL** (which is what lets the page pull its library in with a plain
  relative `<script src>`), calls one function on it with the diagram's text,
  and hands whatever the page posts back to the caller. `MermaidDiagramView`
  sizes itself to the height the page reports; `DrawioPreview` fills the pane.
  The libraries (`mermaid.min.js`, `drawio-viewer.min.js`) are checked in and
  declared in `Package.swift` (`resources:`), reached through `Bundle.module`;
  `Scripts/bundle.sh` already copies the resource bundle into the app. Nothing
  is fetched at runtime — same reason as the themes. Two traps if you touch
  `drawio-host.html`: draw.io's `toolbar-nohide` pins the toolbar by holding the
  diagram at `overflow: visible`, which kills scrolling *and* panning, and a
  top-level `let` in the page is invisible to the JS Swift evaluates — hang
  anything Swift must reach off `window`.
- **PDF** (`Views/PDFPreviewView.swift`) — a `.pdf` file is a `Content.pdf`
  document shown in a PDFKit `PDFView`, wrapped only enough to add the floating
  page/zoom bar the window has no toolbar for. `PDFPreviewController` owns the
  `PDFView` (so the bar can drive it and scrolling survives SwiftUI updates) and
  reads page and scale back out of `PDFViewPageChanged`/`PDFViewScaleChanged`.
  `OpenDocument` detects the extension before its 4 MB text guard — PDFKit reads
  a document page by page.
- **LSP** (`LSP/` + `Editor/LanguageServerCoordinator.swift`) — hand-rolled
  JSON-RPC over stdio (`LSPConnection`), a typed subset of the protocol
  (`LSPTypes`), one `LanguageService` per server, and `LanguageServerRegistry`
  mapping language → server binary, started lazily per project root. Servers are
  whatever is on PATH; nothing is bundled. Deliberately **not** on ChimeHQ's
  `LanguageClient`, and Vue is the reason — its hybrid mode needs two
  non-protocol methods that `LanguageServerProtocol`'s closed enums cannot
  carry. Read `Docs/LSP.md` before changing any of this; it records that
  decision, and what the editor package does and does not offer.
- **Updates** (`Models/AppUpdater.swift`) — the app updates itself from its own
  GitHub releases, over plain HTTPS to `api.github.com` and the release asset.
  **Not through `gh`**: `gh` is a tool the user installs and signs in to, and the
  update has to work on a Mac with neither. `Scripts/bundle.sh` stamps
  `CFBundleShortVersionString` from the git tag (`0.0.0` when there is none), and
  that is the only thing compared against the release tag. Checking and
  downloading can happen on their own; the relaunch that swaps the bundle is
  always a button. The swap is a detached bash script — the app cannot replace
  the copy it is running from — that waits for the process to go, renames the old
  bundle aside, `ditto`s the new one in, and puts the old one back if that fails.
- **Terminal** — everything sits behind `Models/TerminalSession.swift` (owns the
  process and the reusable view) and `Views/TerminalPaneView.swift`. The rest of
  the app only calls `send(_:)` and `startIfNeeded(runningCommand:)` — this narrow
  interface hides the libghostty embedding (GhosttyRuntime + GhosttySurfaceView
  in `Terminal/`) so the engine could be swapped again without
  touching anything else (see `Docs/Terminal.md` for the plan and current state).

`README.md` is the user-facing page: logo, feature list, shortcuts, credits and
the contribution guide — keep the feature list updated when adding something a
user can see. `Docs/Development.md` carries the developer half: build and release
details, the language server table, and the per-file source layout map — keep
that map updated when adding files.
