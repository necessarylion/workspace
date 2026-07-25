# Workspace

A native macOS app for working across your GitHub and Bitbucket repositories:
see your projects, their open pull requests, review diffs, comment on PRs,
browse and edit files, and drive Claude Code in an embedded terminal.

Inspired by [kero](https://github.com/egoist/kero).

## Layout

```
┌──────────────┬────────────────────────────────┬──────────────────┐
│ Repositories │  ‹ ›  breadcrumb          ✕    │Files│PR│±│>_│Info│
│              ├────────────────────────────────┼──────────────────┤
│ repo card    │                                │ file tree        │
│  branch ↑↓   │  one viewer:                   │ pull requests    │
│  2 PR clean  │  file · diff · PR · terminal   │ changes          │
│              │                                │ terminals        │
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
- **Right sidebar — the navigator**, five tabs for the selected repo:
  *Files*, *PRs*, *Changes*, *Terminals*, *Info*. Collapsible (⌥⌘0).

Nothing appears in the app until you add a repository folder yourself.

## Features

| Area | What works |
| --- | --- |
| Repositories | Add any folder; the remote is detected from `origin` (GitHub, Bitbucket Cloud, Bitbucket Data Center, including SSH aliases like `bitbucket-ajzkk`). Remembered between launches. |
| GitHub accounts | Logged in to `gh` with more than one account? Adding a GitHub repo asks which one it belongs to, and every later `gh` call for that repo uses it — the choice is remembered between launches and changed from the repo's context menu or the Info tab. Nothing global is switched: each call carries that account's token in `GH_TOKEN`, so your own shell and your other repos are untouched. |
| Pull requests | Open PRs per repo via `gh pr list` / `bkt pr list`. A slim bar keeps the number, title, review state and branches in view, and the rest is **three tabs**: **Details** (description plus the conversation — existing comments and a box to post a new one, `gh pr comment` / `bkt pr comment`), **Diff** (the whole window, see below), and **Builds** (pipeline status — not wired up yet). |
| Comment threads | Replies are shown **nested under the comment they answer**, at any depth, and each one has its own **Reply** box. Every author's name gets a **colour of their own**, derived from the name so it is the same in every thread and every launch. Bitbucket threads every comment; on GitHub only inline review comments thread, so Reply appears on those (`.../comments/{id}/replies`). |
| Inline comments | A comment anchored to a line appears **in the diff, under that line**, with its replies nested. Hover any line and the **+** in the gutter starts a new thread there — in split view the column you click picks the side (before / after the change), in unified view the line does. Works in both layouts and on both hosts. |
| Diffs | `git diff` for working-tree changes (per file or **all changes at once**) and `gh/bkt pr diff` for PRs, rendered **side by side** (default) or unified, with **tree-sitter syntax colours**. |
| File tree | Every file, **dotfiles included** (`.env`, `.mcp.json`, `.github`) — only `.git`, `.build`, `.swiftpm`, `node_modules` and `DerivedData` are hidden. Anything `.gitignore` covers is **faded** but still there to open. Each row carries the **real logo** of what it is (TypeScript, React, Docker, Postgres, …) in that ecosystem's colour, and repositories show the **GitHub or Bitbucket mark**. |
| Editor | Our own: `NSTextView` + **tree-sitter** highlighting + **LSP**. Gutter with line numbers and diagnostic markers, caret-line highlight, auto-indent, bracket matching, soft wrap toggle. |
| Language servers | Started lazily per language and project root: diagnostics (squiggles + gutter dots + hover), completions (⌃Space), hover help, and ⌘-click go-to-definition. See the table below. |
| Info tab | Folder path, remote, GitHub account, branch, head commit, **listening ports** for processes started inside the folder (right-click one to open it, copy its URL, or **stop the process** holding it), running language servers, and one-click **Open in** VS Code / Cursor / Sublime / Zed / Finder / Terminal. |
| Terminal | Embedded **libghostty** (the [Ghostty](https://github.com/ghostty-org/ghostty) engine) rooted at the repo, **any number of shells** per repo, switched from the Terminals tab rather than a tab bar in the viewer. Your own Ghostty theme/font config applies. Used for PR checkout and Claude Code runs. |
| Terminals tab | Every shell that is still running, across all repos, newest first. A shell **keeps running until you close its tab** — leaving the terminal, opening a file or switching repo never kills it, and "Open Terminal" returns to the one you had. |

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
| ⇧⌘W | Close what is open (a terminal only goes back to the dashboard) |
| ⌘[ / ⌘] | Back / forward through history |
| ⌘0 / ⌥⌘0 | Toggle the repositories / navigator sidebar |
| ⌘R | Refresh all repositories |
| ⌃⌘T | Open (or return to) the terminal of the selected repo |
| ⌘T | New terminal tab |
| ⌃⌘P | Create PR with Claude Code |
| ⌃Space | Completions |
| ⌘-click | Go to definition |
| ⌘↩ | Post the PR comment you typed |

## Layout of the source

```
Sources/Workspace/
  WorkspaceApp.swift          app + menu commands
  Support/Shell.swift         runs git/gh/bkt through the login shell
  Support/BrandMark.swift     real logos (TypeScript, Docker, GitHub…) from SVG
  Support/BrandPath.swift     the path data behind them — generated, don't edit
  Models/
    RemoteInfo.swift          origin URL → GitHub/Bitbucket + owner/slug
    Project.swift             one repository: remote, status, PRs, ports, tree
    PullRequest.swift         unified PR model + gh/bkt loaders
    PullRequestComment.swift  reading and posting PR comments
    GitHubAccounts.swift      per-repo gh account choice + GH_TOKEN injection
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

- Pipeline builds: the PR's **Builds** tab is a placeholder; nothing is read from
  `gh pr checks` or Bitbucket pipelines yet.
- Creating a PR from a form inside the app (today: Claude Code or the web UI).
- PR approvals and merge actions (comments do work).
