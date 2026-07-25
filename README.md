# Workspace

A native macOS app for working across your GitHub and Bitbucket repositories:
see your projects, their open pull requests, review diffs, comment on PRs,
browse and edit files, and drive Claude Code in an embedded terminal.

Inspired by [kero](https://github.com/egoist/kero).

## Layout

```
┌──────────────┬────────────────────────────────┬──────────────────┐
│ Repositories │  ‹ ›  breadcrumb          ✕    │ Files │PR│±│Info │
│              ├────────────────────────────────┼──────────────────┤
│ repo card    │                                │ file tree        │
│  branch ↑↓   │  one viewer:                   │ pull requests    │
│  2 PR clean  │  file · diff · PR · terminal   │ changes          │
│              │                                │ ports, open in…  │
│ + Add Repo   ├────────────────────────────────┤                  │
│              │ Ln 12, Col 4  Swift  ⚠2  sourcekit-lsp running    │
└──────────────┴────────────────────────────────┴──────────────────┘
```

- **Left sidebar — Repositories.** One card per repo you added: host, branch,
  ahead/behind, open-PR count, changed-file count, live ports. Collapsible (⌘0).
- **Centre — the viewer.** Exactly **one** thing at a time: opening a file
  replaces what is there. Back/forward (⌘[ / ⌘]) walk the history, like a
  browser. Not collapsible.
- **Right sidebar — the navigator**, four tabs for the selected repo:
  *Files*, *PRs*, *Changes*, *Info*. Collapsible (⌥⌘0).

Nothing appears in the app until you add a repository folder yourself.

## Features

| Area | What works |
| --- | --- |
| Repositories | Add any folder; the remote is detected from `origin` (GitHub, Bitbucket Cloud, Bitbucket Data Center, including SSH aliases like `bitbucket-ajzkk`). Remembered between launches. |
| Pull requests | Open PRs per repo via `gh pr list` / `bkt pr list`. Detail view shows author, branches, review state, description, diff — and the **conversation**: existing comments and a box to post a new one (`gh pr comment` / `bkt pr comment`). |
| Diffs | `git diff` for working-tree changes (per file or **all changes at once**) and `gh/bkt pr diff` for PRs, rendered **side by side** (default) or unified, with **tree-sitter syntax colours**. |
| Editor | Our own: `NSTextView` + **tree-sitter** highlighting + **LSP**. Gutter with line numbers and diagnostic markers, caret-line highlight, auto-indent, bracket matching, soft wrap toggle. |
| Language servers | Started lazily per language and project root: diagnostics (squiggles + gutter dots + hover), completions (⌃Space), hover help, and ⌘-click go-to-definition. See the table below. |
| Info tab | Folder path, remote, branch, head commit, **listening ports** for processes started inside the folder, running language servers, and one-click **Open in** VS Code / Cursor / Sublime / Zed / Finder / Terminal. |
| Terminal | Embedded **libghostty** (the [Ghostty](https://github.com/ghostty-org/ghostty) engine) rooted at the repo, with **multiple shell tabs** per repo. Your own Ghostty theme/font config applies. Used for PR checkout and Claude Code runs. |

### Language servers

Nothing is bundled — a server is used if it is on your `PATH`.

| Language | Server |
| --- | --- |
| Swift | `sourcekit-lsp` (ships with Xcode) |
| TypeScript / JS / TSX / JSX | `typescript-language-server` |
| Python | `pyright-langserver` |
| Go | `gopls` |
| Rust | `rust-analyzer` |
| C / C++ / Objective-C | `clangd` |
| Ruby, PHP, Dart, Lua, Kotlin | `solargraph`, `intelephense`, `dart`, `lua-language-server`, `kotlin-language-server` |
| JSON, YAML, HTML, CSS, Bash | the matching `vscode-*-language-server` / `yaml-language-server` / `bash-language-server` |

The Info tab shows which ones are running.

## Requirements

- macOS 14+, Xcode 16+ toolchain
- [`gh`](https://cli.github.com) authenticated, for GitHub pull requests
- [`bkt`](https://github.com/necessarylion/bkt) configured, for Bitbucket
- `claude` on your PATH, for the Claude Code actions

All tools run through your login shell, so a GUI app still sees your normal PATH.

## Run

```sh
Scripts/run.sh          # build, wrap in Workspace.app, launch
Scripts/bundle.sh       # build + bundle only, prints the .app path
```

Or open `Package.swift` in Xcode and run.

> `swift build` does **not** work: a dependency ships an asset catalog, which
> only `xcodebuild` can compile. Both scripts use `xcodebuild` and set
> `DISABLE_SWIFTLINT=1`, because CodeEditLanguages' SwiftLint build plugin fails
> on Xcode 26.

### Note on dependencies

`CodeEditLanguages` vendors every tree-sitter grammar, so a full clone is
~600 MB. `.deps/CodeEditLanguages` holds a 64 MB shallow clone at the pinned tag
and `.swiftpm/configuration/mirrors.json` points SwiftPM at it. Delete both to
resolve from GitHub instead.

## Keyboard

| Shortcut | Action |
| --- | --- |
| ⇧⌘O | Add repository |
| ⌘S | Save file |
| ⇧⌘W | Close what is open |
| ⌘[ / ⌘] | Back / forward through history |
| ⌘0 / ⌥⌘0 | Toggle the repositories / navigator sidebar |
| ⌘R | Refresh all repositories |
| ⌃⌘T | Open terminal in selected repo |
| ⌘T | New terminal tab (when the terminal is open) |
| ⌃⌘P | Create PR with Claude Code |
| ⌃Space | Completions |
| ⌘-click | Go to definition |
| ⌘↩ | Post the PR comment you typed |

## Layout of the source

```
Sources/Workspace/
  WorkspaceApp.swift          app + menu commands
  Support/Shell.swift         runs git/gh/bkt through the login shell
  Models/
    RemoteInfo.swift          origin URL → GitHub/Bitbucket + owner/slug
    Project.swift             one repository: remote, status, PRs, ports, tree
    PullRequest.swift         unified PR model + gh/bkt loaders
    PullRequestComment.swift  reading and posting PR comments
    GitStatus.swift           porcelain status + per-file diff
    DiffModel.swift           unified diff → side-by-side rows
    ProjectPorts.swift        lsof → ports owned by this folder
    FileNode.swift            lazy file tree
    OpenDocument.swift        a file being viewed/edited
    ViewerItem.swift          what the viewer shows: file | diff | PR | terminal
    TerminalSession.swift     a live shell (libghostty)
    WorkspaceStore.swift      window state + back/forward history
  Editor/
    CodeEditorController.swift  wires text view, gutter, tree-sitter and LSP
    CodeTextView.swift          NSTextView with code-editing habits
    LineNumberRuler.swift       gutter: numbers + diagnostic markers
    TreeSitterHighlighter.swift incremental parsing and capture ranges
    SyntaxTheme.swift           capture name → colour
    HoverInfoWindow.swift       floating hover / diagnostic panel
    CodeEditorView.swift        SwiftUI bridge
  LSP/
    LSPTypes.swift              the protocol subset we speak
    LSPConnection.swift         JSON-RPC over stdio
    LanguageService.swift       one server: handshake, sync, requests
    LanguageServerRegistry.swift  language → server, one per project root
  Views/                      projects sidebar, navigator, viewer, diff, PR, info
```

## Not done yet

- Creating a PR from a form inside the app (today: Claude Code or the web UI).
- PR approvals and merge actions (comments do work).
