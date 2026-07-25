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
- Dependencies: `.deps/CodeEditLanguages` is a shallow local mirror (the full clone
  is ~600 MB); `.swiftpm/configuration/mirrors.json` points SwiftPM at it. Don't
  delete either unless you intend to resolve from GitHub.

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
- **`Support/Shell.swift`** — the only way external tools are run. Everything goes
  through the user's **login shell** (`$SHELL -lc`) on purpose, because a GUI app
  inherits a bare PATH. A login shell alone still misses version managers (gvm,
  nvm, pyenv), which extend PATH from `~/.zshrc` — zsh only reads that when
  interactive — so `InteractivePath` resolves `$PATH` once via `$SHELL -ilc` and
  injects it into every command. It quotes arguments, uses temp files instead of
  pipes (avoids deadlock), and enforces a timeout. Route any new git/gh/bkt/claude
  invocation through it.
- **Host abstraction** — `PullRequest.swift` / `PullRequestComment.swift` define a
  unified PR model with separate `gh` and `bkt` loaders. New PR features must be
  implemented for both hosts.
- **Editor** (`Editor/`) — hand-rolled, not a library: `CodeEditorController` wires
  an `NSTextView` subclass (`CodeTextView`), the gutter (`LineNumberRuler`),
  incremental tree-sitter highlighting (`TreeSitterHighlighter`), and LSP.
  `CodeEditorView` is the SwiftUI bridge.
- **LSP** (`LSP/`) — hand-rolled JSON-RPC over stdio (`LSPConnection`), a typed
  subset of the protocol (`LSPTypes`), one `LanguageService` per server, and
  `LanguageServerRegistry` mapping language → server binary, started lazily per
  project root. Servers are whatever is on PATH; nothing is bundled.
- **Terminal** — everything sits behind `Models/TerminalSession.swift` (owns the
  process and the reusable view) and `Views/TerminalPaneView.swift`. The rest of
  the app only calls `send(_:)` and `startIfNeeded(runningCommand:)` — this narrow
  interface hides the libghostty embedding (GhosttyRuntime + GhosttySurfaceView
  in `Terminal/`) so the engine could be swapped again without
  touching anything else (see `Docs/Terminal.md` for the plan and current state).

`README.md` has the full feature table, keyboard shortcuts, and a per-file source
layout map — keep it updated when adding features.
