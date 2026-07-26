# Workspace

A native macOS app for working across your GitHub and Bitbucket repositories:
see your projects, their open pull requests, review diffs, comment on PRs,
browse and edit files, and drive Claude Code in an embedded terminal.

Inspired by [kero](https://github.com/egoist/kero).

## Layout

```
┌──────────────┬────────────────────────────────┬──────────────────┐
│           >_ │  ‹ ›  breadcrumb          ✕    │Files│PR│±│>_│Info│
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
  ahead/behind, open-PR count, changed-file count, live ports. A **filter box**
  narrows the list by name or path, and cards are **reordered by dragging** them
  onto each other. Its header row carries the **home terminal button** (⇧⌘T)
  and nothing else. Collapsible (⌘0).
- **Centre — the viewer.** Exactly **one** thing at a time: opening a file
  replaces what is there. Back/forward (⌘[ / ⌘]) walk the history, like a
  browser. Its header row names what is open, and with nothing open the
  **selected repository and its branch**. Not collapsible.
- **Right sidebar — the navigator**, five tabs for the selected repo:
  *Files*, *PRs*, *Changes*, *Terminals*, *Info*. Collapsible (⌥⌘0).

**No scrollbars anywhere.** Every pane, list, diff and the editor scroll by
wheel, trackpad and keyboard as usual, but nothing is drawn over the content and
no strip is reserved for it, whatever the system's "show scroll bars" setting is.

Nothing appears in the app until you add a repository folder yourself.

## Features

| Area | What works |
| --- | --- |
| Repositories | Add any folder; the remote is detected from `origin` (GitHub, Bitbucket Cloud, Bitbucket Data Center, including SSH aliases like `bitbucket-ajzkk`). Remembered between launches. **Drag a card onto another** to reorder the list — the order is saved as you drag, so it survives a relaunch. The **filter box** at the top matches on repo name or folder path; reordering is off while it is filtering, since only part of the list is on screen. |
| GitHub accounts | Logged in to `gh` with more than one account? Adding a GitHub repo asks which one it belongs to, and every later `gh` call for that repo uses it — the choice is remembered between launches and changed from the repo's context menu or the Info tab. Nothing global is switched: each call carries that account's token in `GH_TOKEN`, so your own shell and your other repos are untouched. |
| Pull requests | Open PRs per repo via `gh pr list` / `bkt pr list`. The title sits in the window header next to back/forward; a slim bar under it keeps branches, line counts and review state on the left and, on the right, the **four tabs** that pick what fills the window: **Details** (description plus the conversation — existing comments and a box to post a new one, `gh pr comment` / `bkt pr comment`), **Diff** (the whole window, see below), **Commits** (see below), and **Builds** (pipeline status — not wired up yet). The source branch carries a **copy** and a **check out** button; checkout runs git in the background (fetching the branch first when it is only on the remote) and reports success or git's own error in a toast. |
| Comment threads | Replies are shown **nested under the comment they answer**, at any depth, and each one has its own **Reply** box. Every author's name gets a **colour of their own**, derived from the name so it is the same in every thread and every launch. Bitbucket threads every comment; on GitHub only inline review comments thread, so Reply appears on those (`.../comments/{id}/replies`). |
| Inline comments | A comment anchored to a line appears **in the diff, under that line**, with its replies nested. Hover any line and the **+** in the gutter starts a new thread there — in split view the column you click picks the side (before / after the change), in unified view the line does. Works in both layouts and on both hosts. |
| Dashboard | What the centre shows when nothing is open (the repo's name sits in the header row above it): the remote and branch, four counters (open PRs, changed files, ports, files) that jump to the matching navigator tab, the Terminal / Claude / VS Code buttons, a tile per open pull request, and — under them — the branch's **recent commits grouped by day** ("Today", "Yesterday", then the date), each day headed with how many commits it holds. A row shows short hash, subject, time and author; **click one to open that commit's diff** in the viewer (`git show`), or right-click to copy its hash or message. It starts at 8 commits with a **Show N more** button for the rest of the 40 it read, and a **Load 40 older** button that reads a page further back — as many times as the history allows, the button disappearing when there is nothing older left. How deep you went is kept, so the refresh it does every time the dashboard comes back on screen returns the same range, and a commit made in the terminal is there when you switch back. |
| Changes tab | The working tree in two groups, **Staged** and **Changes**, each with a bulk **Stage All** / **Unstage All**; the **+** / **−** on a row moves that one file, and the **↺** next to it discards that file (a **🗑** on an untracked file, which is deleted) after a confirmation. Below them a **commit box**: write a message, **Commit** (⌘⏎) the staged files, then **Push** — which shows how many commits are waiting (`Push 2`) and sets the upstream itself the first time the branch goes out. Unstaging uses `git restore --staged`, so it never touches your edits. Whatever git prints on a failure is shown in the box. |
| Commits | The **Commits** tab lists the pull request's commits newest first — short hash, subject, author and when — loaded the first time you open the tab (`gh pr view --json commits`, Bitbucket's REST API through `bkt api`). **Click one** and it opens that commit's own diff in the same tab, with the full message above it and a **‹ Commits** button back to the list; the hash can be copied or opened on the host. The patch comes from a local `git show` when the commit is already in the checkout, and from the host when it is not. |
| PR action bar | A second row under the summary holds what one actually does with a pull request, as buttons rather than menu items: **Approve** and **Request Changes** on the left (`gh pr review --approve` / `--request-changes`; `bkt pr approve` and Bitbucket Cloud's `request-changes` endpoint), then **Update from main** — only when the branch is behind — **Reject** and **Merge** on the right. **Every one of them opens the same confirmation sheet first** — what is about to happen, a box for the comment that goes with it, Cancel (⎋) and a confirm button (⏎) tinted to match. Nothing reaches the host unconfirmed, and "request changes" keeps its button disabled until a comment is written, because GitHub refuses a review without one. The review lands in the conversation and the bar's own review badge updates from the host. |
| Merge, reject, sync | The **Merge** button opens a sheet to pick the way: **Squash and Merge** (one commit on the target branch, selected by default) or **Merge (fast-forward)** (the commits as they are, no merge commit) — `gh pr merge --squash` / `--rebase`, `bkt pr merge --strategy`. The sheet warns when the branch is behind, and ⏎ merges the selected way. **Reject** closes it without merging (`gh pr close` / `bkt pr decline`) and takes an optional reason, posted as the closing comment. Each asks first, and none of them deletes the source branch. When the branch has fallen behind, an orange **“N behind main”** badge appears in the summary bar and an **Update from main** button in the action bar — it brings the target branch in: GitHub does it on the server, Bitbucket in your checkout (branch checked out, tree clean → fetch, merge, push). The count comes from `gh api …/compare` on GitHub and from your own refs elsewhere; **Check Again** fetches first. |
| Diffs | `git diff` for working-tree changes (per file or **all changes at once**) and `gh/bkt pr diff` for PRs, rendered **side by side** (default) or unified, with **tree-sitter syntax colours**. A changed line is coloured in **two tiers** — a wash over the whole line, and a stronger block behind the **words that actually differ**, matched token by token, so an edited argument stands out from the rest of the line it sits in. |
| Diff file list | A diff of more than one file gets an **index down its left side**: every file with its icon, folder and `+`/`−` counts. Picking one shows **that file alone** — only its rows are built — and **All Files** at the top of the list goes back to the whole diff. The sidebar button in the diff bar hides the index; the choice of file is remembered per pull request, so leaving the Diff tab and coming back returns to the file being reviewed. |
| File tree | Every file, **dotfiles included** (`.env`, `.mcp.json`, `.github`) — only `.git`, `.build`, `.swiftpm`, `node_modules` and `DerivedData` are hidden. Anything `.gitignore` covers is **hidden by default** — build output and caches bury the rest — and the **eye button** in the pane's bottom bar brings those rows back, **faded** but there to open. Each row carries the **real logo** of what it is (TypeScript, React, Docker, Postgres, …) in that ecosystem's colour, and repositories show the **GitHub or Bitbucket mark**. |
| Editor | Our own: `NSTextView` + **tree-sitter** highlighting + **LSP**. Gutter with line numbers and diagnostic markers, caret-line highlight, auto-indent, bracket matching, soft wrap toggle. |
| Language servers | Started lazily per language and project root: diagnostics (squiggles + gutter dots + hover), completions (⌃Space), hover help, and ⌘-click go-to-definition. See the table below. |
| Info tab | Folder path, remote, GitHub account, branch, head commit, **listening ports** for processes started inside the folder (right-click one to open it, copy its URL, or **stop the process** holding it), running language servers, and one-click **Open in** VS Code / Cursor / Sublime / Zed / Finder / Terminal. |
| Terminal | Embedded **libghostty** (the [Ghostty](https://github.com/ghostty-org/ghostty) engine) rooted at the repo, **any number of shells** per repo, switched from the Terminals tab rather than a tab bar in the viewer. Your own Ghostty theme/font config applies. Used for Claude Code runs. **Drop a file on it** and its path is typed at the prompt — several files land side by side, spaces and brackets escaped — which is how a screenshot or a log reaches `claude`. An image dragged straight out of a browser or Preview carries no file, so it is saved as a PNG in the temporary folder and *that* path is typed. |
| Home terminals | Shells that belong to **no repository**, rooted in your home folder (⇧⌘T). They sit in the same list as the rest, listed under *Home*, and they outlive removing every repository — so there is a prompt before a single folder has been added. |
| Terminals button | A **terminal glyph with a count** in the centre header, from anywhere in the app: a new shell in *Home* or in the selected repo, then every open shell, newest first, to jump straight back to one. It needs no repository and no sidebar, which is what makes the home shells always reachable. |
| Terminals tab | Every shell that is still open, across all repos, newest first. A shell **keeps running until you close its tab** — leaving the terminal, opening a file or switching repo never kills it, and "Open Terminal" returns to the one you had. |
| Saved terminals | The list **survives quitting the app**: every tab's folder, name and order is kept (in `UserDefaults`), and comes back on the next launch. A restored tab is listed dimmed and **starts its shell the moment you show it**, so relaunching never spawns ten processes at once. Tabs whose repo was removed, or whose folder has moved, are dropped. |
| Settings (⌘,) → Appearance | The **theme and the font code is shown in**. Four themes ship with the app — **Adonis Eclipse**, **GitHub Dark**, **Atom One Dark** and **Dark+** — each a full palette for the editor and the diff, including the background, gutter, current line and indent guides, with a row of swatches under the picker so two dark themes can be told apart at a glance. They travel with the app, so a file looks the same on every Mac you run it on. `Scripts/import-vscode-theme.swift "Some Theme"` ports any VS Code theme into a new one — it reads the extension's own theme file and translates its TextMate scopes into the tree-sitter captures our highlighter produces. Then the fonts: One face for the editor and the diff, each with its own size (a diff is denser on purpose), **line spacing** for the editor, and the terminal left to your own Ghostty config until you switch it over. Only **monospaced faces** are listed — Fira Code, JetBrains Mono, Monaspace and the rest are found even though those families leave the `monoSpace` trait unset — and each is drawn in itself in the menu. Every change applies at once: the editor re-lays out, and libghostty is handed a new configuration, so **shells already running** change font too. Kept in `UserDefaults`; **Restore Defaults** puts back SF Mono at 12.5 / 10 pt and ×1.0 spacing. |
| Settings (⌘,) → Requirements | The **command line tools** the app drives — `git`, `gh`, `bkt`, `claude` — each with its own `--version` line and who it is signed in as, all asked of the tool itself through your login shell. Missing one? **Install** runs the right command (`brew install gh`, …); logged out? **Sign In** runs `gh auth login` / `bkt auth login`. Both are interactive, so they run in a real terminal inside the sheet rather than silently in the background. The gear in the repositories footer carries a **dot** when a tool your repos actually need is missing or logged out. |
| Settings (⌘,) → Language Servers | Every server the editor can start, with a **ready / not installed** badge checked against the same PATH the editor uses. **Install** runs that server's own line (`brew install rust-analyzer`, `npm install -g pyright`, …) in a terminal. **Add** gives any other language a server — pick the language, then type the executable, the command, the LSP language ID and, if you like, an install command. Any built-in can be **edited**, **restored** to its default, or removed; changes are kept in `UserDefaults` and take effect the next time a file of that language is opened. |

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

That table is only the default list: **Settings → Language Servers** installs the
missing ones, corrects a command, and adds a server for any language that is not
here. The Info tab shows which ones are running.

## Requirements

- macOS 14+, Xcode 16+ toolchain
- [`gh`](https://cli.github.com) authenticated, for GitHub pull requests
- [`bkt`](https://github.com/avivsinai/bitbucket-cli) configured, for Bitbucket
- `claude` on your PATH, for the Claude Code actions

**Settings (⌘,) checks all of these for you** and installs or signs in to the
missing ones — you never have to work out which command it wanted.

All tools run through your login shell, so a GUI app still sees your normal PATH.

## Run

```sh
Scripts/run.sh          # build, wrap in Workspace.app, launch
Scripts/bundle.sh       # build + bundle only, prints the .app path
Scripts/make-icon.sh    # rebuild Resources/AppIcon.icns from icon.png
```

Or open `Package.swift` in Xcode and run.

> `swift build` does **not** work: a dependency ships an asset catalog, which
> only `xcodebuild` can compile. Both scripts use `xcodebuild` and set
> `DISABLE_SWIFTLINT=1`, because CodeEditLanguages' SwiftLint build plugin fails
> on Xcode 26.

### Note on dependencies

A bare clone builds with nothing installed beyond Xcode — that is what CI
(`.github/workflows/build.yml`) relies on. Where the two big pieces come from:

- **Tree-sitter grammars** — `CodeEditLanguages` is checked in under
  [Vendor/](Vendor/) and referenced by path. Its upstream repository keeps every
  historical revision of every grammar, so cloning it costs ~600 MB against
  34 MB for the release source; see [Vendor/README.md](Vendor/README.md).
- **The terminal engine** — comes from
  [libghostty-spm](https://github.com/Lakr233/libghostty-spm), which ships
  libghostty as a prebuilt, checksum-pinned universal xcframework. Upstream
  ghostty publishes no equivalent artifact; see
  [Docs/Terminal.md](Docs/Terminal.md).

## Keyboard

| Shortcut | Action |
| --- | --- |
| ⌘, | Settings — code font, required tools and language servers, install and sign-in |
| ⇧⌘O | Add repository |
| ⌘S | Save file |
| ⇧⌘W | Close what is open (a terminal only goes back to the dashboard) |
| ⎋ | The same, the editor and the terminal included — except with a completion list up, or while writing in a comment box, which keep ⎋ |
| ⌘[ / ⌘] | Back / forward through history |
| ⌘0 / ⌥⌘0 | Toggle the repositories / navigator sidebar |
| ⌃⇥ | Switch repository — hold ⌃ and the repos appear in a row on glass, ⇥ walks it (⇧⇥ back), letting go of ⌃ switches |
| ⌘R | Refresh all repositories |
| ⌃⌘T | Open (or return to) the terminal of the selected repo |
| ⌃` | Show the selected repo's terminal, and the same key to leave it |
| ⌘T | New terminal tab |
| ⇧⌘T | New terminal in your home folder (no repo needed) |
| ⌃⌘P | Create PR with Claude Code |
| ⌃Space | Completions |
| ⌘-click | Go to definition |
| ⌘↩ | Post the PR comment you typed · commit the staged files |

## Layout of the source

```
Sources/Workspace/
  WorkspaceApp.swift          app + menu commands
  Support/Shell.swift         runs git/gh/bkt through the login shell
  Support/BrandMark.swift     real logos (TypeScript, Docker, GitHub…) from SVG
  Support/BrandPath.swift     the path data behind them — generated, don't edit
  Support/AuthorAvatar.swift  author pictures: where to find one, cache, disc view
  Support/WindowKeyMonitor.swift  keys the terminal would otherwise eat (⌃⇥, ⎋)
  Support/EscapeKey.swift     ⎋ = close, and who keeps ⎋ for themselves
  Models/
    RemoteInfo.swift          origin URL → GitHub/Bitbucket + owner/slug
    Project.swift             one repository: remote, status, PRs, ports, tree
    PullRequest.swift         unified PR model + gh/bkt loaders
    PullRequestComment.swift  reading and posting PR comments
    PullRequestCommit.swift   a PR's commits + the diff of one commit
    PullRequestActions.swift  merge, reject, and drift from the target branch
    GitHubAccounts.swift      per-repo gh account choice + GH_TOKEN injection
    GitStatus.swift           porcelain status + per-file diff
    RepositoryCommit.swift    the branch's own git log, grouped by day
    DiffModel.swift           unified diff → side-by-side rows
    InlineDiff.swift          which words in a changed line actually changed
    ProjectPorts.swift        lsof → ports owned by this folder
    FileNode.swift            lazy file tree
    OpenDocument.swift        a file being viewed/edited
    ViewerItem.swift          what the viewer shows: file | diff | commit | PR | terminal
    TerminalSession.swift     a live shell (libghostty), started on first show
    ToolRequirements.swift    git/gh/bkt/claude: installed? signed in as whom?
    LanguageServerCatalog.swift  the language server list: defaults + yours
    AppearanceSettings.swift  the theme and the code font: face, sizes, spacing
    WorkspaceStore.swift      window state + back/forward history + saved terminals
  Editor/
    CodeEditorController.swift  wires text view, gutter, tree-sitter and LSP
    CodeTextView.swift          NSTextView with code-editing habits
    LineNumberRuler.swift       gutter: numbers + diagnostic markers
    TreeSitterHighlighter.swift incremental parsing and capture ranges
    SyntaxTheme.swift           fonts + the palette in use
    HoverInfoWindow.swift       floating hover / diagnostic panel
    CodeEditorView.swift        SwiftUI bridge
  LSP/
    LSPTypes.swift              the protocol subset we speak
    LSPConnection.swift         JSON-RPC over stdio
    LanguageService.swift       one server: handshake, sync, requests
    LanguageServerRegistry.swift  catalog → running server, one per project root
  Themes/
    SyntaxPalette.swift       capture name → colour, and the lookup behind it
    Themes.swift              the list Settings shows; first one is the default
    AdonisEclipse.swift       one theme, one file
    GitHubDark.swift          github.com's own dark
    AtomOneDark.swift         the One Dark everyone ported
    DarkPlus.swift            VS Code's default dark, and ours
  Views/                      projects sidebar, navigator, viewer, diff, PR, info
    ProjectSwitcherOverlay.swift  ⌃⇥ — the repositories in a row, on glass
    SettingsView.swift        ⌘, — Appearance, Requirements and Language Servers
    ToolConsoleSheet.swift    runs one install or sign-in in a real terminal
```

## Not done yet

- Pipeline builds: the PR's **Builds** tab is a placeholder; nothing is read from
  `gh pr checks` or Bitbucket pipelines yet.
- Creating a PR from a form inside the app (today: Claude Code or the web UI).
- PR approvals and merge actions (comments do work).
